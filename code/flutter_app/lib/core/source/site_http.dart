/// HTML 采集站的统一接入层。
///
/// 为什么要单独一层：新接入的影视站几乎都是「HTML 页面 + 若干固定路径」，
/// 但每家都有自己的反爬。把 UA、编码、Cookie、准入挑战、重试收在这里，
/// 具体源只负责「拼路径 + 解析 HTML」，不用各自造一套 HTTP 轮子。
///
/// 目前内置一种准入挑战：[CdndefendGate]（keke1.app 的 SHA1 工作量证明）。
/// 以后遇到别家挑战，实现同样的 `cookie()` 契约挂到 [SiteHttp.gate] 即可。
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

/// cdndefend 反爬的准入闸门。
///
/// 挑战形态（2026-11-11 实测 keke1.app）：
///   1. 首次请求返回 HTTP 850 + 一段混淆 JS，里面有个 3 元素数组和旋转次数；
///   2. 旋转后取到 Cookie 名、`array` 方法名、40 位 hex 前缀 `c`；
///   3. 令 `n1 = parseInt('0x' + c[0])`，暴力找最小的 i 使
///      `sha1(c+i)` 的字节数组满足 `s[n1]==0xb0 && s[n1+1]==0x0b`；
///   4. 写 Cookie `cdndefend_js_cookie=<c><i>; path=/`，reload。
///
/// **最容易踩的坑：前缀绑定在同一个 TCP 连接上。**
/// 用「新开一个连接带 Cookie」去验证，服务端一律再发一次 850，
/// 且每次前缀都不同，看起来就像 PoW 算错了。Python 用
/// `http.client.HTTPSConnection` 复用同一连接才返回 200。
/// 所以这里刻意用**单个 HttpClient 实例串行发两次请求**，让它复用
/// keep-alive 连接；验证通过后 Cookie 才缓存下来给后续任意连接复用。
class CdndefendGate {
  /// 源站不可达的专用错误码。[SiteHttp.get] 见到它直接上抛、不重试：
  /// 连 TCP 都建不起来时，重试只会把 8s 放大成 24s 的转圈。
  static const int kUnreachable = -2;

  CdndefendGate(this.host);

  final String host;
  String? _cookie;
  Future<String>? _pending;

  Future<String> cookie() {
    final cached = _cookie;
    if (cached != null) return Future.value(cached);
    // 并发只解一次，避免首屏几个请求同时触发 PoW
    return _pending ??= _solve().whenComplete(() => _pending = null);
  }

  void invalidate() => _cookie = null;

  Future<String> _solve() async {
    // 裸 HttpClient 默认没有连接超时：站点不可达时会一直挂到系统 TCP
    // 超时（Windows 实测 21s，errno 121「信号灯超时时间已到」），
    // 再叠加上层重试就是 endless spinner。这里把准入整体钉死在 15s 内。
    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      return await _solveWith(client).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw ApiException(kUnreachable,
            '源站准入超时，站点可能暂时不可达，请在设置里切换其它数据源'),
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      // SocketException / HandshakeException 都归到「不可达」，
      // 让上层立刻给出可见错误，而不是把它当 5xx 反复重试。
      throw ApiException(kUnreachable,
          '无法连接源站（${e.runtimeType}），请在设置里切换其它数据源');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _solveWith(HttpClient client) async {
      final first = await _get(client, '/', null);
      final html = first.body;
      if (first.status == 200 && !html.contains('cdndefend')) {
        // 站点这次没挂挑战：记住「无需 Cookie」，避免每次请求都重新探测
        _cookie = '';
        return '';
      }

      final arrM = RegExp(r'const a0_0x2a54=\[(.*?)\];').firstMatch(html);
      final rotM =
          RegExp(r'\}\(a0_0x2a54,0x([0-9a-fA-F]+)\)').firstMatch(html);
      if (arrM == null || rotM == null) {
        throw ApiException(first.status, '无法解析站点准入挑战');
      }
      final items = RegExp(r"'([^']*)'")
          .allMatches(arrM.group(1)!)
          .map((m) => m.group(1)!)
          .toList();
      if (items.length < 3) {
        throw ApiException(first.status, '准入挑战数组结构已变化');
      }
      final rot = int.parse(rotM.group(1)!, radix: 16);
      final shift = rot % items.length;
      final rotated = [...items.skip(shift), ...items.take(shift)];
      final name = rotated[0].replaceAll(RegExp(r'=$'), '');
      final prefix = rotated[2];
      final n1 = int.parse(prefix[0], radix: 16);

      final i = _proofOfWork(prefix, n1);
      final value = '$prefix$i';

      // 关键：同一个 client / 同一条 keep-alive 连接
      final second = await _get(client, '/', '$name=$value');
      if (second.status != 200 || second.body.contains('cdndefend')) {
        throw ApiException(second.status,
            '站点准入校验未通过（挑战解出 i=$i，服务器仍返回挑战页）');
      }
      _cookie = '$name=$value';
      return _cookie!;
  }

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

  static int _proofOfWork(String prefix, int n1) => proofOfWork(prefix, n1);

  Future<_Resp> _get(HttpClient client, String path, String? cookie) async {
    final req = await client.getUrl(Uri.https(host, path));
    req.headers
      ..add('User-Agent', kSiteUserAgent)
      ..add('Accept', 'text/html,application/xhtml+xml,*/*;q=0.8')
      ..add('Accept-Language', 'zh-CN,zh;q=0.9')
      ..add('Accept-Encoding', 'identity')
      ..add('Connection', 'keep-alive');
    if (cookie != null) req.headers.add('Cookie', cookie);
    final resp = await req.close();
    final chunks = await resp.toList();
    final bytes = chunks.expand((c) => c).toList();
    return _Resp(resp.statusCode, utf8.decode(bytes, allowMalformed: true));
  }
}

class _Resp {
  final int status;
  final String body;
  const _Resp(this.status, this.body);
}

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
      try {
        final remain = deadline.difference(DateTime.now());
        if (remain <= Duration.zero) break;
        return await _once(path, query: query, referer: referer).timeout(remain);
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
        lastError = e;
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(
        -1, '站点 ${total.inSeconds} 秒无响应，请稍后重试或切换数据源');
  }

  Future<String> _once(
    String path, {
    Map<String, dynamic>? query,
    String? referer,
  }) async {
    final h = <String, String>{};
    if (gate != null) {
      final ck = await gate!.cookie();
      if (ck.isNotEmpty) h['Cookie'] = ck;
    }
    final r = referer ?? this.referer;
    if (r != null) h['Referer'] = r;

    final resp = await _dio.get<String>(
      path,
      queryParameters: query,
      options: Options(headers: h),
    );
    final code = resp.statusCode ?? -1;
    final body = resp.data ?? '';

    if (gate != null && (code == 850 || body.contains('cdndefend'))) {
      gate!.invalidate();
      throw ApiException(code, '站点准入已失效，请重试');
    }
    if (code != 200) throw ApiException(code, '站点返回 HTTP $code');
    return body;
  }
}

/// 数据源通用的线路排序声明：采集站的线路顺序由 HTML 决定，
/// 保持站点自身顺序即可，不需要按「官方/直出」重排。
const LineOrderPolicy kSiteLineOrder = LineOrderPolicy.sourceOrder;