/// 验证「现有 cdndefend 准入逻辑能否通过**当前**这道挑战」。
///
/// ## 为什么必须重测
///
/// 我前面几轮把「源站已下线」当成了结论，但那个结论建立在错误的网络路径上：
/// 一直在用环境变量里的 `127.0.0.1:14215`，那是**沙箱注入的出口代理**，
/// 它到 keke1.app 直接 502。用户浏览器能流畅打开，说明站是活的。
///
/// 换成用户机器上真实在监听的 `127.0.0.1:7897` 后：
///   CONNECT 200 established → GET / → HTTP 850 + cdndefend 挑战页（6499 B）
///
/// 所以现在的问题**不是「站死了」，而是「准入还能不能过」**。
///
/// ## 本脚本要回答的
///
///   1. 挑战页的结构是否还和 [site_http.dart] 里写的一致
///      （`const a0_0x2a54=[...]` + `}(a0_0x2a54,0x...)`）；
///      变量名若变了，说明模板升级，现有正则会**静默失配**，
///      现象就是「一直卡在准入」。
///   2. PoW 能否在合理时间内算出来。
///   3. 带上解出的 Cookie、在**同一条连接**上重发，能否拿到 200。
///   4. 拿到 200 后，列表页的 `/detail/` 链接与封面能否解析出来。
///
/// 全部用纯 Dart 复现 [site_http.dart] 的钉连接 + PoW 流程，不 import 那个文件
/// （它依赖 flutter/foundation，纯 dart 跑不起来），但算法与正则逐字对齐。
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';

const String _host = 'www.keke1.app';
const int _port = 443;
const (String, int) _proxy = ('127.0.0.1', 7897); // 用户真实代理
const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

// ---------------------------------------------------------------------------
// 钉住的单连接通道（与 site_http.dart 的 _PinnedChannel 同构，做了裁剪）
// ---------------------------------------------------------------------------

class PinnedConn {
  Socket? _sock;
  Reader? _reader;
  String cookie = '';

  Future<void> open() async {
    final raw = await Socket.connect(_proxy.$1, _proxy.$2,
        timeout: const Duration(seconds: 10));
    raw.setOption(SocketOption.tcpNoDelay, true);
    raw.write('CONNECT $_host:$_port HTTP/1.1\r\n'
        'Host: $_host:$_port\r\n'
        'Proxy-Connection: keep-alive\r\n\r\n');
    await raw.flush();
    final head = Reader(raw, const Duration(seconds: 15));
    final status = await head.readLine();
    String line;
    do {
      line = await head.readLine();
    } while (line.isNotEmpty);
    if (!status.contains('200')) {
      raw.destroy();
      throw StateError('代理隧道失败: $status');
    }
    _sock = await SecureSocket.secure(raw, host: _host, onBadCertificate: (_) => true);
    _reader = Reader(_sock!, const Duration(seconds: 20));
  }

  Future<({int status, String body})> get(String path) async {
    final sock = _sock;
    final reader = _reader;
    if (sock == null || reader == null) throw StateError('未连接');
    final sb = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: $_host\r\n')
      ..write('User-Agent: $_ua\r\n')
      ..write('Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n')
      ..write('Accept-Language: zh-CN,zh;q=0.9\r\n')
      ..write('Accept-Encoding: gzip, deflate\r\n')
      ..write('Connection: keep-alive\r\n');
    if (cookie.isNotEmpty) sb.write('Cookie: $cookie\r\n');
    sb.write('\r\n');
    sock.add(utf8.encode(sb.toString()));
    await sock.flush().timeout(const Duration(seconds: 15));

    final statusLine = await reader.readLine();
    final parts = statusLine.split(' ');
    final status = parts.length > 1 ? (int.tryParse(parts[1]) ?? -1) : -1;
    final headers = <String, String>{};
    while (true) {
      final l = await reader.readLine();
      if (l.isEmpty) break;
      final i = l.indexOf(':');
      if (i > 0) headers[l.substring(0, i).trim().toLowerCase()] = l.substring(i + 1).trim();
    }
    List<int> bytes;
    final cl = int.tryParse(headers['content-length'] ?? '');
    final chunked = (headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked');
    if (chunked) {
      final out = BytesBuilder();
      while (true) {
        final sizeLine = await reader.readLine();
        final semi = sizeLine.indexOf(';');
        final hex = semi >= 0 ? sizeLine.substring(0, semi) : sizeLine;
        final size = int.tryParse(hex.trim(), radix: 16) ?? 0;
        if (size == 0) {
          await reader.readLine();
          break;
        }
        out.add(await reader.readBytes(size));
        await reader.readBytes(2);
      }
      bytes = out.takeBytes();
    } else if (cl != null) {
      bytes = await reader.readBytes(cl);
    } else {
      bytes = await reader.readToEnd();
    }
    var body = bytes;
    try {
      if (body.length > 2 && body[0] == 0x1f && body[1] == 0x8b) {
        body = gzip.decode(body);
      }
    } catch (_) {}
    if ((headers['connection'] ?? '').toLowerCase().contains('close')) close();
    return (status: status, body: utf8.decode(body, allowMalformed: true));
  }

  void close() {
    try {
      _sock?.destroy();
    } catch (_) {}
    _sock = null;
    _reader = null;
    cookie = '';
  }
}

class Reader {
  Reader(Socket s, this.timeout) {
    _it = StreamIterator<List<int>>(s);
  }
  final Duration timeout;
  late final StreamIterator<List<int>> _it;
  final List<int> _buf = <int>[];
  int _start = 0;
  int get _len => _buf.length - _start;

  Future<void> _fill() async {
    final ok = await _it.moveNext().timeout(timeout);
    if (!ok) throw const SocketException('closed');
    _buf.addAll(_it.current);
  }

  Future<String> readLine() async {
    while (true) {
      for (var i = _start; i + 1 < _buf.length; i++) {
        if (_buf[i] == 13 && _buf[i + 1] == 10) {
          final s = utf8.decode(_buf.sublist(_start, i), allowMalformed: true);
          _start = i + 2;
          return s;
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
    return out;
  }

  Future<List<int>> readToEnd() async {
    try {
      while (true) {
        await _fill();
      }
    } catch (_) {}
    final out = _buf.sublist(_start);
    _start = _buf.length;
    return out;
  }
}

// ---------------------------------------------------------------------------
// PoW：与 CdndefendGate.proofOfWork 逐字一致
// ---------------------------------------------------------------------------

int proofOfWork(String prefix, int n1) {
  final sha = SHA1Digest();
  for (var i = 0; i < 20000000; i++) {
    final d = sha.process(Uint8List.fromList(utf8.encode('$prefix$i')));
    if (d[n1] == 0xb0 && d[n1 + 1] == 0x0b) return i;
  }
  throw StateError('PoW 未命中');
}

void main() async {
  final conn = PinnedConn();
  try {
    print('══ 1. 建连 → 首次请求 ══');
    await conn.open();
    print('  CONNECT $_host:$_port via ${_proxy.$1}:${_proxy.$2} → 隧道已建立');

    final first = await conn.get('/');
    print('  GET / → HTTP ${first.status}  ${first.body.length} B');
    print('  含 cdndefend: ${first.body.contains('cdndefend')}');

    final html = first.body;
    // 存一份原始挑战页，便于人工核对模板
    final f = File('/tmp/keke_challenge.html');
    await f.writeAsString(html);
    print('  原始挑战页已存 /tmp/keke_challenge.html');

    print('');
    print('══ 2. 挑战页结构识别（对照 site_http.dart 的现有正则）══');
    print('');

    // 现有实现用的固定变量名
    final hardArr = RegExp(r'const a0_0x2a54=\[(.*?)\];').firstMatch(html);
    final hardRot = RegExp(r'\}\(a0_0x2a54,0x([0-9a-fA-F]+)\)').firstMatch(html);
    print('  硬编码 a0_0x2a54 数组: ${hardArr == null ? "❌ 失配" : "✅ 命中"}');
    print('  硬编码 旋转参数      : ${hardRot == null ? "❌ 失配" : "✅ 命中 (0x${hardRot.group(1)})"}');

    // 通用匹配：变量名任意
    final genArr = RegExp(r'const\s+(\w+)\s*=\s*\[(.*?)\];', dotAll: true).firstMatch(html);
    print('  通用 const 数组匹配  : ${genArr == null ? "❌ 无" : "✅ 变量名 = ${genArr.group(1)}"}');
    if (genArr != null) {
      final items = RegExp(r"'([^']*)'")
          .allMatches(genArr.group(2)!)
          .map((m) => m.group(1)!)
          .toList();
      print('  数组元素 ${items.length} 个: ${items.take(6).toList()}');
    }
    final genRot = RegExp(r'\}\(\s*(\w+)\s*,\s*0x([0-9a-fA-F]+)\s*\)').firstMatch(html);
    print('  通用 旋转参数匹配    : ${genRot == null ? "❌ 无" : "✅ ${genRot.group(1)}, 0x${genRot.group(2)}"}');

    if (hardArr == null || hardRot == null) {
      print('');
      print('  ⚠️ 固定变量名失配 —— 说明模板已升级，site_http.dart 那两条正则');
      print('     在真机上会「静默失配」，表现就是永远卡在准入、看不到列表。');
      print('     这正是用户反馈「经常加载不出来列表」的可能原因之一。');
      print('');
      print('  挑战页片段（前 600 字符）：');
      print('  ${html.substring(0, html.length > 600 ? 600 : html.length).replaceAll(RegExp(r"\s+"), " ")}');
      return;
    }

    print('');
    print('══ 3. 解 PoW ══');
    print('');
    final items = RegExp(r"'([^']*)'")
        .allMatches(hardArr.group(1)!)
        .map((m) => m.group(1)!)
        .toList();
    final rot = int.parse(hardRot.group(1)!, radix: 16);
    final shift = rot % items.length;
    final rotated = [...items.skip(shift), ...items.take(shift)];
    final name = rotated[0].replaceAll(RegExp(r'=$'), '');
    final prefix = rotated[2];
    final n1 = int.parse(prefix[0], radix: 16);
    print('  Cookie 名 = $name');
    print('  前缀      = $prefix  (n1=$n1)');

    final sw = Stopwatch()..start();
    final i = proofOfWork(prefix, n1);
    print('  PoW 解出  i=$i  耗时 ${sw.elapsedMilliseconds}ms');
    conn.cookie = '$name=$prefix$i';

    print('');
    print('══ 4. 同一连接上带 Cookie 重发 ══');
    print('');
    final second = await conn.get('/');
    print('  GET / → HTTP ${second.status}  ${second.body.length} B');
    print('  含 cdndefend: ${second.body.contains('cdndefend')}');

    if (second.status != 200 || second.body.contains('cdndefend')) {
      print('  ❌ 未通过准入');
      return;
    }
    print('  ✅ 准入通过');

    print('');
    print('══ 5. 分类页 /channel/6.html（用户截图那一页）══');
    print('');
    final ch = await conn.get('/channel/6.html');
    print('  HTTP ${ch.status}  ${ch.body.length} B');
    final ids = RegExp(r'href="/detail/(\d+)\.html"')
        .allMatches(ch.body)
        .map((m) => m.group(1)!)
        .toList();
    print('  /detail/ 链接 ${ids.length} 个  ${ids.take(6).toList()}');
    final titles = RegExp(r'class="v-item-title"').allMatches(ch.body).length;
    print('  v-item-title ${titles} 个');
    final covers = RegExp(
      r'(?:data-original|data-src|src)="([^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"',
      caseSensitive: false,
    ).allMatches(ch.body).map((m) => m.group(1)!).toSet().toList();
    print('  封面 ${covers.length} 个（去重）');
    for (final c in covers.take(3)) {
      print('    $c');
    }

    if (ids.isNotEmpty) {
      print('');
      print('══ 6. 详情页 /detail/${ids.first}.html ══');
      print('');
      final d = await conn.get('/detail/${ids.first}.html');
      print('  HTTP ${d.status}  ${d.body.length} B');
      final labels = RegExp(r'source-item-label">([^<]*)<')
          .allMatches(d.body)
          .map((m) => m.group(1)!)
          .toList();
      final plays = RegExp(r'href="(/play/\d+-\d+-\d+\.html)"').allMatches(d.body).length;
      print('  线路标签: $labels');
      print('  /play/ 链接 $plays 个');
    }
  } catch (e) {
    print('异常: $e');
  } finally {
    conn.close();
  }
}