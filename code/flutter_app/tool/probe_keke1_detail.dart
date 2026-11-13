/// 详情页模板结构 dump —— 现有解析全部失配，必须看清真实结构。
///
/// 现状：
///   分类页 /channel/6.html → 200，80 个 /detail/ 链接 ✅
///   详情页 /detail/{id}.html → 200，83861 B，但
///     `source-item-label">` 匹配 0 个
///     `href="/play/{id}-{line}-{ep}.html"` 匹配 0 个
///
/// 说明站方改了详情页模板。这个脚本把详情页里**所有**候选结构都列出来：
///   - 所有 href 形态统计（路径前缀归类）
///   - 线路标签的几种可能写法
///   - 选集容器的几种可能 class
///   - 内联 JS 里的 playSource / 播放地址
///
/// 目的不是猜，而是把真实 HTML 摆出来，据此重写解析。
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';

const String _host = 'www.keke1.app';
const (String, int) _proxy = ('127.0.0.1', 7897);
const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

class Conn {
  Socket? _sock;
  R? _r;
  String cookie = '';

  Future<void> open() async {
    final raw = await Socket.connect(_proxy.$1, _proxy.$2,
        timeout: const Duration(seconds: 10));
    raw.write('CONNECT $_host:443 HTTP/1.1\r\nHost: $_host:443\r\n'
        'Proxy-Connection: keep-alive\r\n\r\n');
    await raw.flush();
    final h = R(raw, const Duration(seconds: 15));
    final st = await h.readLine();
    String l;
    do {
      l = await h.readLine();
    } while (l.isNotEmpty);
    if (!st.contains('200')) throw StateError('隧道失败 $st');
    _sock = await SecureSocket.secure(raw, host: _host, onBadCertificate: (_) => true);
    _r = R(_sock!, const Duration(seconds: 25));
  }

  Future<({int status, String body})> get(String path) async {
    final s = _sock!, r = _r!;
    final sb = StringBuffer()
      ..write('GET $path HTTP/1.1\r\nHost: $_host\r\n')
      ..write('User-Agent: $_ua\r\n')
      ..write('Accept: text/html,*/*;q=0.8\r\n')
      ..write('Accept-Language: zh-CN,zh;q=0.9\r\n')
      ..write('Accept-Encoding: gzip, deflate\r\n')
      ..write('Connection: keep-alive\r\n');
    if (cookie.isNotEmpty) sb.write('Cookie: $cookie\r\n');
    sb.write('\r\n');
    s.add(utf8.encode(sb.toString()));
    await s.flush().timeout(const Duration(seconds: 15));

    final stl = await r.readLine();
    final p = stl.split(' ');
    final status = p.length > 1 ? (int.tryParse(p[1]) ?? -1) : -1;
    final hs = <String, String>{};
    while (true) {
      final x = await r.readLine();
      if (x.isEmpty) break;
      final i = x.indexOf(':');
      if (i > 0) hs[x.substring(0, i).trim().toLowerCase()] = x.substring(i + 1).trim();
    }
    List<int> b;
    final cl = int.tryParse(hs['content-length'] ?? '');
    if ((hs['transfer-encoding'] ?? '').toLowerCase().contains('chunked')) {
      final o = BytesBuilder();
      while (true) {
        final sl = await r.readLine();
        final se = sl.indexOf(';');
        final hx = se >= 0 ? sl.substring(0, se) : sl;
        final sz = int.tryParse(hx.trim(), radix: 16) ?? 0;
        if (sz == 0) {
          await r.readLine();
          break;
        }
        o.add(await r.readBytes(sz));
        await r.readBytes(2);
      }
      b = o.takeBytes();
    } else if (cl != null) {
      b = await r.readBytes(cl);
    } else {
      b = await r.readToEnd();
    }
    var body = b;
    try {
      if (body.length > 2 && body[0] == 0x1f && body[1] == 0x8b) body = gzip.decode(body);
    } catch (_) {}
    return (status: status, body: utf8.decode(body, allowMalformed: true));
  }

  void close() {
    try {
      _sock?.destroy();
    } catch (_) {}
    _sock = null;
    _r = null;
  }
}

class R {
  R(Socket s, this.timeout) {
    _it = StreamIterator<List<int>>(s);
  }
  final Duration timeout;
  late final StreamIterator<List<int>> _it;
  final List<int> _b = <int>[];
  int _s = 0;

  Future<void> _f() async {
    if (!await _it.moveNext().timeout(timeout)) throw const SocketException('closed');
    _b.addAll(_it.current);
  }

  Future<String> readLine() async {
    while (true) {
      for (var i = _s; i + 1 < _b.length; i++) {
        if (_b[i] == 13 && _b[i + 1] == 10) {
          final x = utf8.decode(_b.sublist(_s, i), allowMalformed: true);
          _s = i + 2;
          return x;
        }
      }
      await _f();
    }
  }

  Future<List<int>> readBytes(int n) async {
    while (_b.length - _s < n) {
      await _f();
    }
    final o = _b.sublist(_s, _s + n);
    _s += n;
    return o;
  }

  Future<List<int>> readToEnd() async {
    try {
      while (true) {
        await _f();
      }
    } catch (_) {}
    final o = _b.sublist(_s);
    _s = _b.length;
    return o;
  }
}

int pow(String prefix, int n1) {
  final sha = SHA1Digest();
  for (var i = 0; i < 20000000; i++) {
    final d = sha.process(Uint8List.fromList(utf8.encode('$prefix$i')));
    if (d[n1] == 0xb0 && d[n1 + 1] == 0x0b) return i;
  }
  throw StateError('pow');
}

Future<bool> passGate(Conn c) async {
  final f = await c.get('/');
  if (f.status == 200 && !f.body.contains('cdndefend')) return true;
  final arr = RegExp(r'const a0_0x2a54=\[(.*?)\];').firstMatch(f.body);
  final rotM = RegExp(r'\}\(a0_0x2a54,0x([0-9a-fA-F]+)\)').firstMatch(f.body);
  if (arr == null || rotM == null) return false;
  final items = RegExp(r"'([^']*)'")
      .allMatches(arr.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
  final rot = int.parse(rotM.group(1)!, radix: 16);
  final sh = rot % items.length;
  final r = [...items.skip(sh), ...items.take(sh)];
  final name = r[0].replaceAll(RegExp(r'=$'), '');
  final prefix = r[2];
  final n1 = int.parse(prefix[0], radix: 16);
  c.cookie = '$name=$prefix${pow(prefix, n1)}';
  final s = await c.get('/');
  return s.status == 200 && !s.body.contains('cdndefend');
}

void main() async {
  final c = Conn();
  try {
    await c.open();
    if (!await passGate(c)) {
      print('准入失败');
      return;
    }
    print('准入通过');

    final ch = await c.get('/channel/6.html');
    final ids = RegExp(r'href="/detail/(\d+)\.html"')
        .allMatches(ch.body)
        .map((m) => m.group(1)!)
        .toList();
    print('分类页 detail 链接 ${ids.length} 个，首个 ${ids.first}');

    final id = ids.first;
    final d = await c.get('/detail/$id.html');
    final html = d.body;
    print('详情页 /detail/$id.html  HTTP ${d.status}  ${html.length} B');
    await File('/tmp/keke_detail.html').writeAsString(html);

    print('');
    print('══ A. href 路径前缀归类 ══');
    final prefixes = <String, int>{};
    for (final m in RegExp(r'href="([^"]+)"').allMatches(html)) {
      final h = m.group(1)!;
      final seg = h.split('/');
      final key = h.startsWith('/')
          ? '/${seg.length > 1 ? seg[1] : ""}/'
          : (h.startsWith('http') ? '<http>' : h);
      prefixes[key] = (prefixes[key] ?? 0) + 1;
    }
    final sorted = prefixes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted.take(14)) {
      print('  ${e.key.padRight(28)} ${e.value}');
    }

    print('');
    print('══ B. 含 /play 或 -1- 形态的链接样本 ══');
    final samples = RegExp(r'href="([^"]*(?:play|-\d+-\d+)[^"]*)"')
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toSet()
        .toList();
    for (final s2 in samples.take(10)) {
      print('  $s2');
    }
    if (samples.isEmpty) print('  （无）');

    print('');
    print('══ C. class 名统计（找线路/选集容器）══');
    final classes = <String, int>{};
    for (final m in RegExp(r'class="([^"]+)"').allMatches(html)) {
      for (final t in m.group(1)!.split(RegExp(r'\s+'))) {
        if (t.isEmpty) continue;
        classes[t] = (classes[t] ?? 0) + 1;
      }
    }
    final cls = classes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in cls.take(30)) {
      print('  ${e.key.padRight(30)} ${e.value}');
    }

    print('');
    print('══ D. 内联 JS 里的播放地址线索 ══');
    for (final kw in ['playSource', 'm3u8', 'source-item', 'episode', 'playUrl', 'player_']) {
      final n = RegExp(kw, caseSensitive: false).allMatches(html).length;
      print('  $kw → $n 次');
    }
    // 印出 playSource 附近 400 字符
    final ps = RegExp(r'playSource', caseSensitive: false).firstMatch(html);
    if (ps != null) {
      final a = (ps.start - 100).clamp(0, html.length);
      final b = (ps.start + 500).clamp(0, html.length);
      print('');
      print('  playSource 上下文：');
      print('  ${html.substring(a, b).replaceAll(RegExp(r"\s+"), " ")}');
    }
  } catch (e) {
    print('异常 $e');
  } finally {
    c.close();
  }
}