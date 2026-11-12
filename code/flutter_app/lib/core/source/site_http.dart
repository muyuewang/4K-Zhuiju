/// HTML 采集站的统一接入层。
///
/// 为什么要单独一层：新接入的影视站几乎都是「HTML 页面 + 若干固定路径」，
/// 但每家都有自己的反爬。把 UA、编码、Cookie、准入挑战、重试收在这里，
/// 具体源只负责「拼路径 + 解析 HTML」，不用各自造一套 HTTP 轮子。
///
/// 目前内置一种准入挑战：[CdndefendGate]（keke1.app 的 SHA1 工作量证明）。
/// 以后遇到别家挑战，实现同样的 `request()` 契约挂到 [SiteHttp.gate] 即可。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/digests/sha1.dart';

import '../api.dart';
import 'data_source.dart';

const String kSiteUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

// ---------------------------------------------------------------------------
// 钉住的单连接 HTTP/1.1 通道
// ---------------------------------------------------------------------------

/// 一条 TLS 连接上串行收发 HTTP/1.1 的最小实现。
///
/// 为什么不用 `HttpClient` / Dio：**cdndefend 的准入 Cookie 与 TCP 连接绑定**。
/// 2026-11-12 实测（三种客户端各跑多轮）：
///   * Python 裸 socket，同一条 CONNECT 隧道内「挑战 → 解 PoW → 带 Cookie 重发」
///     → 4/4 全部 200；
///   * curl 每次新进程（必然新连接）→ 5 次里只偶然过 1 次；
///   * Dart `HttpClient` 复用同一个实例串行发两次 → 稳定失败，
///     且响应上的 `connectionInfo.localPort` 第一次 5571、第二次 5573，
///     **端口变了，说明连接根本没被复用**。
///
/// 也就是说 Dart 在收到 850 这个非标准状态码后直接丢弃了连接，而服务端认的是
/// 「这条连接上刚算出来的那个前缀」。换连接再带 Cookie 过去，
/// 服务端一律重发 850（且换一个新前缀），看起来就像 PoW 算错了。
/// 跨连接复用同一 Cookie 的实测通过率也只有 1/4，延迟 1 秒即失效。
///
/// 所以这里绕开 HttpClient，直接拿 SecureSocket 自己拼 HTTP/1.1 报文，
/// 保证「建连 → 过闸 → 后续所有页面请求」都发生在同一条连接上。
class _PinnedChannel {
  _PinnedChannel({
    required this.host,
    this.proxy,
    this.port = 443,
    this.tls = true,
  });

  final String host;

  /// 目标端口。默认 443；只为本地回归测试（假源站）才需要改。
  final int port;

  /// 是否走 TLS。默认 true；同样只为本地测试服务。
  final bool tls;

  /// `host:port` 形式的 HTTP 代理（仅支持 CONNECT 隧道）。null 表示直连。
  final (String, int)? proxy;

  /// 建连超时。源站不可达时（Windows 实测系统 TCP 超时 21s）必须提前收口，
  /// 否则界面上就是无尽的转圈。
  static const Duration connectTimeout = Duration(seconds: 10);

  /// 单次读写的超时。直播/搜索偶发慢响应，给到 20s 足够。
  static const Duration ioTimeout = Duration(seconds: 20);

  Socket? _sock;
  _SocketReader? _reader;
  String _cookie = '';

  /// 所有请求串行化：一条 HTTP/1.1 连接不能并发。
  Future<void> _tail = Future<void>.value();

  String get cookie => _cookie;

  bool get isOpen => _sock != null;

  /// 串行执行 [fn]，保证同一条连接上一次只有一个在途请求。
  Future<T> _enqueue<T>(Future<T> Function() fn) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await fn());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<_HttpResp> request(
    String path, {
    Map<String, String>? query,
    String? referer,
  }) {
    final target = query == null || query.isEmpty
        ? path
        : Uri(path: path, queryParameters: query).toString();
    return _enqueue(() => _requestLocked(target, referer: referer));
  }

  Future<_HttpResp> _requestLocked(String target, {String? referer}) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _ensureOpen();
        final first = await _send(target, referer: referer);
        if (first.status == 200 && !first.body.contains('cdndefend')) {
          return first;
        }
        // 收到挑战：必须在**当前这条连接**上解出来并重发
        final solved = await _solveOnCurrentConn(first.body);
        if (!solved) {
          lastError = ApiException(first.status, '无法解析站点准入挑战');
          _drop();
          continue;
        }
        final second = await _send(target, referer: referer);
        if (second.status == 200 && !second.body.contains('cdndefend')) {
          return second;
        }
        // 解出来了服务器还是不认：说明这条连接的会话已废，重建再试
        lastError = ApiException(
            second.status, '站点准入校验未通过，站点可能已更换校验方式');
        _drop();
      } on ApiException catch (e) {
        lastError = e;
        _drop();
        // 连不上就没必要重试，直接交给界面
        if (e.code == CdndefendGate.kUnreachable) rethrow;
      } catch (e) {
        lastError = e;
        _drop();
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(
        CdndefendGate.kUnreachable, '站点连接失败（${lastError.runtimeType}）');
  }

  Future<void> _ensureOpen() async {
    if (_sock != null) return;
    final routes = _routes();
    Object? lastError;
    for (var idx = 0; idx < routes.length; idx++) {
      try {
        _sock = await _connectVia(routes[idx]);
        _reader = _SocketReader(_sock!, ioTimeout);
        if (idx > 0) {
          debugPrintK('[GATE] 使用线路 ${routes[idx]} 连上 $host'
              '（前面 $idx 条不通）');
        }
        return;
      } catch (e) {
        lastError = e;
        _sock = null;
        _reader = null;
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(
        CdndefendGate.kUnreachable, '无法连接源站（${lastError.runtimeType}）');
  }

  /// 候选线路：显式指定的代理 → 环境变量里的代理 → 直连。
  ///
  /// 顺序把代理放前面是有意的：旧实现走 Dio，而 Dio 在 Windows 上会自动读
  /// 系统代理。改成手写 socket 后这条链路就断了，若用户本身靠代理上网，
  /// 会从「看到挑战页」退化成「连不上」。所以这里既认环境变量，
  /// 也保留直连兜底 —— 两条路都试，谁通用谁。
  List<_Route> _routes() {
    // 回环地址一律直连：本地回归测试的假源站不该被环境里的代理变量劫持。
    if (_isLoopback(host)) return <_Route>[const _Route(null, 0)];

    final out = <_Route>[];
    final explicit = proxy;
    if (explicit != null) out.add(_Route(explicit.$1, explicit.$2));
    for (final raw in _envProxies()) {
      final p = _parseProxy(raw);
      if (p == null) continue;
      if (!out.any((r) => r.host == p.$1 && r.port == p.$2)) {
        out.add(_Route(p.$1, p.$2));
      }
    }
    // 没有显式代理也没配环境变量时，直连就是唯一线路
    out.add(const _Route(null, 0));
    return out;
  }

  static bool _isLoopback(String h) {
    final v = h.toLowerCase();
    return v == 'localhost' ||
        v == '127.0.0.1' ||
        v == '::1' ||
        v.startsWith('127.');
  }

  static List<String> _envProxies() {
    final env = Platform.environment;
    final out = <String>[];
    for (final k in const [
      'https_proxy', 'HTTPS_PROXY',
      'all_proxy', 'ALL_PROXY',
      'http_proxy', 'HTTP_PROXY',
    ]) {
      final v = env[k];
      if (v != null && v.trim().isNotEmpty) out.add(v);
    }
    return out;
  }

  static (String, int)? _parseProxy(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.isEmpty) return null;
    // WinINET 的格式是 "PROXY host:port; DIRECT"
    if (v.toLowerCase().startsWith('proxy ')) v = v.substring(6).trim();
    v = v.split(';').first.trim();
    v = v.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    v = v.split('/').first;
    final idx = v.lastIndexOf(':');
    if (idx <= 0) return null;
    final port = int.tryParse(v.substring(idx + 1));
    if (port == null) return null;
    return (v.substring(0, idx), port);
  }

  Future<Socket> _connectVia(_Route route) async {
    final target = '$host:$port';

    Future<Socket> dial(Socket raw) async {
      if (!tls) return raw;
      return SecureSocket.secure(
        raw,
        host: host,
        onBadCertificate: (_) => true,
      );
    }

    if (route.host == null) {
      if (!tls) {
        return Socket.connect(host, port, timeout: connectTimeout);
      }
      return SecureSocket.connect(
        host,
        port,
        timeout: connectTimeout,
        onBadCertificate: (_) => true,
      );
    }
    final raw = await Socket.connect(route.host!, route.port,
        timeout: connectTimeout);
    try {
      raw.setOption(SocketOption.tcpNoDelay, true);
      raw.write('CONNECT $target HTTP/1.1\r\n'
          'Host: $target\r\n'
          'Proxy-Connection: keep-alive\r\n\r\n');
      await raw.flush();
      final head = _SocketReader(raw, ioTimeout);
      final statusLine = await head.readLine();
      String line;
      do {
        line = await head.readLine();
      } while (line.isNotEmpty);
      if (!statusLine.contains('200')) {
        raw.destroy();
        throw ApiException(
            CdndefendGate.kUnreachable, '代理隧道建立失败（$statusLine）');
      }
    } catch (_) {
      raw.destroy();
      rethrow;
    }
    return dial(raw);
  }

  /// 在**已建立的那条连接**上解析挑战并直接把 Cookie 记下来。
  /// 返回 false 表示页面结构不认识（站点换了校验方式）。
  Future<bool> _solveOnCurrentConn(String html) async {
    final arrM = RegExp(r'const a0_0x2a54=\[(.*?)\];').firstMatch(html);
    final rotM = RegExp(r'\}\(a0_0x2a54,0x([0-9a-fA-F]+)\)').firstMatch(html);
    if (arrM == null || rotM == null) return false;

    final items = RegExp(r"'([^']*)'")
        .allMatches(arrM.group(1)!)
        .map((m) => m.group(1)!)
        .toList();
    if (items.length < 3) return false;

    final rot = int.parse(rotM.group(1)!, radix: 16);
    final shift = rot % items.length;
    final rotated = [...items.skip(shift), ...items.take(shift)];
    final name = rotated[0].replaceAll(RegExp(r'=$'), '');
    final prefix = rotated[2];
    final n1 = int.parse(prefix[0], radix: 16);

    final i = CdndefendGate.proofOfWork(prefix, n1);
    debugPrintK('[GATE] solved i=$i prefix=$prefix');
    _cookie = '$name=$prefix$i';
    return true;
  }

  Future<_HttpResp> _send(String target, {String? referer}) async {
    final sock = _sock;
    final reader = _reader;
    if (sock == null || reader == null) {
      throw ApiException(CdndefendGate.kUnreachable, '连接未建立');
    }

    final head = StringBuffer()
      ..write('GET $target HTTP/1.1\r\n')
      ..write('Host: $host\r\n')
      ..write('User-Agent: $kSiteUserAgent\r\n')
      ..write('Accept: text/html,application/xhtml+xml,'
          'application/xml;q=0.9,*/*;q=0.8\r\n')
      ..write('Accept-Language: zh-CN,zh;q=0.9\r\n')
      // 只声明 gzip/deflate：br 与 zstd Dart 侧没有现成解码器
      ..write('Accept-Encoding: gzip, deflate\r\n')
      ..write('Connection: keep-alive\r\n');
    if (_cookie.isNotEmpty) head.write('Cookie: $_cookie\r\n');
    if (referer != null) head.write('Referer: $referer\r\n');
    head.write('\r\n');

    sock.add(utf8.encode(head.toString()));
    await sock.flush().timeout(ioTimeout);

    final statusLine = await reader.readLine();
    final parts = statusLine.split(' ');
    if (parts.length < 2) {
      throw ApiException(-1, '站点响应异常：$statusLine');
    }
    final status = int.tryParse(parts[1]) ?? -1;

    final headers = <String, String>{};
    while (true) {
      final line = await reader.readLine();
      if (line.isEmpty) break;
      final idx = line.indexOf(':');
      if (idx > 0) {
        headers[line.substring(0, idx).trim().toLowerCase()] =
            line.substring(idx + 1).trim();
      }
    }

    List<int> body;
    final te = (headers['transfer-encoding'] ?? '').toLowerCase();
    final cl = int.tryParse(headers['content-length'] ?? '');
    if (te.contains('chunked')) {
      final out = BytesBuilder();
      while (true) {
        final sizeLine = await reader.readLine();
        final semi = sizeLine.indexOf(';');
        final hex = semi >= 0 ? sizeLine.substring(0, semi) : sizeLine;
        final size = int.tryParse(hex.trim(), radix: 16) ?? 0;
        if (size == 0) {
          await reader.readLine(); // 末尾空行
          break;
        }
        out.add(await reader.readBytes(size));
        await reader.readBytes(2); // 每块结尾的 CRLF
      }
      body = out.takeBytes();
    } else if (cl != null) {
      body = await reader.readBytes(cl);
    } else {
      body = await reader.readToEnd();
    }

    // 连接被服务端关闭：下次请求需要重建
    final conn = (headers['connection'] ?? '').toLowerCase();
    if (conn.contains('close')) _drop();

    final text = _decodeBody(body, headers['content-encoding'] ?? '');
    return _HttpResp(status, text);
  }

  String _decodeBody(List<int> body, String encoding) {
    var bytes = body;
    final enc = encoding.toLowerCase();
    try {
      if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        bytes = gzip.decode(bytes);
      } else if (enc.contains('deflate') && bytes.isNotEmpty) {
        try {
          bytes = ZLibDecoder().convert(bytes);
        } catch (_) {
          bytes = ZLibDecoder(raw: true).convert(bytes);
        }
      }
    } catch (_) {
      // 解压失败就按原文处理，交给上层正则判断
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _drop() {
    try {
      _sock?.destroy();
    } catch (_) {}
    _sock = null;
    _reader = null;
    _cookie = '';
  }

  void close() {
    _drop();
  }
}

/// 从流里读 HTTP 报文的行与定长字节。
class _SocketReader {
  _SocketReader(Socket sock, this.timeout) {
    _it = StreamIterator<List<int>>(sock);
  }

  final Duration timeout;
  late final StreamIterator<List<int>> _it;
  final List<int> _buf = <int>[];
  int _start = 0;

  int get _len => _buf.length - _start;

  void _compact() {
    if (_start > 1 << 16) {
      _buf.removeRange(0, _start);
      _start = 0;
    }
  }

  Future<void> _fill() async {
    final ok = await _it.moveNext().timeout(timeout);
    if (!ok) throw const SocketException('connection closed');
    _buf.addAll(_it.current);
  }

  Future<String> readLine() async {
    while (true) {
      for (var i = _start; i + 1 < _buf.length; i++) {
        if (_buf[i] == 13 && _buf[i + 1] == 10) {
          final line = utf8.decode(_buf.sublist(_start, i), allowMalformed: true);
          _start = i + 2;
          _compact();
          return line;
        }
      }
      await _fill();
    }
  }

  Future<List<int>> readBytes(int n) async {
    while (_len < n) {
      await _fill();
    }
    final out = _buf.sublist(_start, _start + n);
    _start += n;
    _compact();
    return out;
  }

  Future<List<int>> readToEnd() async {
    try {
      while (true) {
        await _fill();
      }
    } on SocketException {
      // 读到连接关闭为止，这是「无长度」响应的正常结束方式
    } on TimeoutException {
      // 同上
    }
    final out = _buf.sublist(_start);
    _start = _buf.length;
    _compact();
    return out;
  }
}

class _HttpResp {
  const _HttpResp(this.status, this.body);
  final int status;
  final String body;
}

/// 一条候选线路。[host] 为 null 表示直连目标站，否则是 HTTP 代理地址。
class _Route {
  const _Route(this.host, this.port);
  final String? host;
  final int port;

  @override
  String toString() => host == null ? 'direct' : '$host:$port';
}

/// 准入过程的调试输出。只在 debug/测试构建里打印，
/// release 包完全静默，不会污染日志。
void debugPrintK(String msg) {
  assert(() {
    // ignore: avoid_print
    print(msg);
    return true;
  }());
}

// ---------------------------------------------------------------------------
// 准入闸门（对外接口）
// ---------------------------------------------------------------------------

/// cdndefend 反爬的准入闸门。
///
/// 挑战形态（2026-11-12 实测 keke1.app，与 11-11 相比未变）：
///   1. 首次请求返回 HTTP 850 + 一段混淆 JS，里面有 3 元素数组和旋转次数；
///   2. 旋转后取到 Cookie 名、`array` 方法名、40 位 hex 前缀 `c`；
///   3. 令 `n1 = parseInt('0x' + c[0])`，暴力找最小的 i 使
///      `sha1(c+i)` 的字节数组满足 `s[n1]==0xb0 && s[n1+1]==0x0b`；
///   4. 写 Cookie `cdndefend_js_cookie=<c><i>; path=/`，reload。
///
/// **最容易踩的坑：前缀绑定在同一条 TCP 连接上**，而且这个 Cookie 只在那条
/// 连接上有效。实测同一 Cookie 换新连接的通过率仅 1/4，延迟 1 秒即失效。
/// 所以所有请求都必须复用 [_PinnedChannel] 钉住的那一条连接，
/// 不能像以前那样「用 Cookie 让 Dio 另开连接」。
class CdndefendGate {
  /// 源站不可达的专用错误码。[SiteHttp.get] 见到它直接上抛、不重试：
  /// 连 TCP 都建不起来时，重试只会把 8s 放大成 24s 的转圈。
  static const int kUnreachable = -2;

  /// [proxy] 显式指定代理（`http://host:port` 或 `host:port`）。
  /// 不传则读环境变量；环境变量也没有就走直连。
  /// [port]/[tls] 只为本地回归测试准备的，线上不要传。
  CdndefendGate(
    this.host, {
    String? proxy,
    int port = 443,
    bool tls = true,
  }) : _channel = _PinnedChannel(
          host: host,
          port: port,
          tls: tls,
          proxy: _parseProxy(proxy),
        );

  final String host;
  final _PinnedChannel _channel;

  /// 在钉住的连接上抓一页。内部自动处理「收到挑战 → 解 PoW → 重发」。
  Future<String> get(String path,
      {Map<String, dynamic>? query, String? referer}) async {
    final q = query == null || query.isEmpty
        ? null
        : query.map((k, v) => MapEntry(k, '$v'));
    final resp = await _channel.request(path, query: q, referer: referer);
    if (resp.status != 200) {
      throw ApiException(resp.status, '站点返回 HTTP ${resp.status}');
    }
    return resp.body;
  }

  /// 兼容旧调用点：返回当前连接上解出的 Cookie（可能为空串）。
  Future<String> cookie() async => _channel.cookie;

  /// 丢弃当前连接，下次请求重新建连并重过准入。
  void invalidate() => _channel.close();

  /// 期望 1/65536 命中，实测毫秒级；上限 2000 万次防死循环。
  /// 抽成可见静态函数，方便离线回归验证算法没被改坏。
  static int proofOfWork(String prefix, int n1) {
    final sha = SHA1Digest();
    for (var i = 0; i < 20000000; i++) {
      final digest = sha.process(Uint8List.fromList(utf8.encode('$prefix$i')));
      if (digest[n1] == 0xb0 && digest[n1 + 1] == 0x0b) return i;
    }
    throw ApiException(-1, '准入挑战求解失败');
  }

  /// 把 `http://host:port` / `host:port` / WinINET 的 `PROXY host:port` 归一成元组。
  /// 只处理**显式传入**的代理；环境变量由 [_PinnedChannel] 自己按候选线路处理。
  static (String, int)? _parseProxy(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (v.toLowerCase().startsWith('proxy ')) v = v.substring(6).trim();
    v = v.split(';').first.trim();
    v = v.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    v = v.split('/').first;
    final idx = v.lastIndexOf(':');
    if (idx <= 0) return null;
    final port = int.tryParse(v.substring(idx + 1));
    if (port == null) return null;
    return (v.substring(0, idx), port);
  }
}

// ---------------------------------------------------------------------------
// 站点 HTTP 客户端
// ---------------------------------------------------------------------------

/// 一个站点的 HTTP 客户端。只读 HTML，不处理 JSON 协议源。
class SiteHttp {
  SiteHttp({required this.baseUrl, this.gate, this.referer});

  final String baseUrl;
  final CdndefendGate? gate;
  final String? referer;

  late final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
    headers: {
      'User-Agent': kSiteUserAgent,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    },
  ));

  /// 抓一页 HTML。
  ///
  /// 采集站的 5xx 大多是瞬时限流（实测 keke1 搜索页偶发 503，隔一次就好），
  /// 所以这里对 5xx 做 2 次退避重试，而不是直接把错误抛给用户。
  Future<String> get(
    String path, {
    Map<String, dynamic>? query,
    String? referer,
  }) async {
    // 总期限：见 api.dart / maccms_api_source.dart 的同类说明。
    // Dio 的 12s 连接 + 25s 接收再叠 3 次重试能拖到 110s 以上，而界面的
    // `.timeout()` 不会取消底层请求，它会一直占着连接池。反复换集/重刷
    // 之后连接池被占满，新请求只能排队 —— 表现就是永久转圈、重启才恢复。
    const total = Duration(seconds: 20);
    final deadline = DateTime.now().add(total);
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      // 每次尝试独立一个 token：共用的话，第一次 cancel 之后
      // 后续几轮请求会被 dio 直接拒掉，重试等于失效。
      final token = CancelToken();
      try {
        final remain = deadline.difference(DateTime.now());
        if (remain <= Duration.zero) break;
        return await _once(path, query: query, referer: referer, token: token)
            .timeout(remain);
      } on ApiException catch (e) {
        lastError = e;
        // 源站连不上：重试没有意义，立刻把错误交给界面
        if (e.code == CdndefendGate.kUnreachable) rethrow;
        // 准入失效：清掉旧 Cookie，下一轮重新解 PoW；4xx 重试无意义
        if (e.code == 850 || e.msg.contains('准入')) {
          gate?.invalidate();
          continue;
        }
        if (e.code >= 500 || e.code == -1) continue;
        rethrow;
      } on TimeoutException catch (e) {
        // ★ 关键：`.timeout()` 只让这里不再等，底层 Dio 请求和它的
        // socket 仍然活着。不 cancel 就会每次都留一条僵尸连接，反复
        // 换集/重刷把它攒满之后，新请求连不出去、只能杀进程重开。
        // 走钉住通道的分支（gate != null）不受影响：token 没传给它，
        // 那个通道自己有 ioTimeout，且不使用 Dio 连接池。
        if (!token.isCancelled) {
          token.cancel('attempt ${attempt + 1} timed out');
        }
        lastError = e;
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(
        -1, '站点 ${total.inSeconds} 秒无响应，请稍后重试或切换数据源');
  }

  /// [token] 只交给 Dio 分支用：超时后要真的掐断 socket。
  /// 走钉住通道的分支（gate != null）忽略它——那条通道不经过 Dio，
  /// 也不共享连接池，自有 ioTimeout 收尾。
  Future<String> _once(
    String path, {
    Map<String, dynamic>? query,
    String? referer,
    CancelToken? token,
  }) async {
    final g = gate;
    // 有准入闸门的站点走钉住的单连接通道：
    // Cookie 与 TCP 连接绑定，交给 Dio 另开连接必然被拒。
    if (g != null) {
      return g.get(path, query: query, referer: referer ?? this.referer);
    }

    final h = <String, String>{};
    final r = referer ?? this.referer;
    if (r != null) h['Referer'] = r;

    final resp = await _dio.get<String>(
      path,
      queryParameters: query,
      cancelToken: token,
      options: Options(headers: h),
    );
    final code = resp.statusCode ?? -1;
    final body = resp.data ?? '';

    if (code != 200) throw ApiException(code, '站点返回 HTTP $code');
    return body;
  }
}

/// 数据源通用的线路排序声明：采集站的线路顺序由 HTML 决定，
/// 保持站点自身顺序即可，不需要按「官方/直出」重排。
const LineOrderPolicy kSiteLineOrder = LineOrderPolicy.sourceOrder;