/// 播放页结构 dump —— 这是可可影视能否救活的关键。
///
/// ## 刚刚拿到的决定性事实
///
/// ```
/// /detail/{id}.html        → 200 / 83861 B，选集容器为空（走签名 API）
/// /detail/{id}-1-1.html    → 404
/// /play/{id}-1-1.html      → 200 / 106305 B，playSource=true  ✅
/// /play/{id}_1_1.html      → 404
/// /play/{id}.html          → 404
/// ```
///
/// 也就是说：**播放页还活着，而且里面有 `playSource`**。
/// 详情页只是把选集列表搬走了，播放页这个「真正取地址」的入口没变。
///
/// 所以路线很明确：
///   - 只要能确定「线路数 × 集数」，就能直接拼 `/play/{id}-{line}-{ep}.html` 取地址，
///     **完全绕开那套 HmacSHA1 签名 API**。
///   - 而播放页本身很可能就带着完整的选集列表（播放页通常都有选集栏），
///     那样连「集数」都不用另外求。
///
/// 这个脚本要把播放页里三件事挖出来：
///   1. `playSource` 的完整内容（含真实 m3u8 地址）
///   2. 选集列表（`/play/{id}-{line}-{ep}.html` 链接）在不在，有多少条
///   3. 线路标签在不在
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
  Socket? _s;
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
    if (!st.contains('200')) throw StateError('隧道 $st');
    _s = await SecureSocket.secure(raw, host: _host, onBadCertificate: (_) => true);
    _r = R(_s!, const Duration(seconds: 25));
  }

  Future<({int status, String body})> get(String path) async {
    final s = _s!, r = _r!;
    final sb = StringBuffer()
      ..write('GET $path HTTP/1.1\r\nHost: $_host\r\n')
      ..write('User-Agent: $_ua\r\n')
      ..write('Accept: text/html,*/*\r\n')
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
      _s?.destroy();
    } catch (_) {}
    _s = null;
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

int powSolve(String prefix, int n1) {
  final sha = SHA1Digest();
  for (var i = 0; i < 20000000; i++) {
    final d = sha.process(Uint8List.fromList(utf8.encode('$prefix$i')));
    if (d[n1] == 0xb0 && d[n1 + 1] == 0x0b) return i;
  }
  throw StateError('pow');
}

Future<bool> gate(Conn c) async {
  final f = await c.get('/');
  if (f.status == 200 && !f.body.contains('cdndefend')) return true;
  final arr = RegExp(r'const a0_0x2a54=\[(.*?)\];').firstMatch(f.body);
  final rotM = RegExp(r'\}\(a0_0x2a54,0x([0-9a-fA-F]+)\)').firstMatch(f.body);
  if (arr == null || rotM == null) return false;
  final items = RegExp(r"'([^']*)'")
      .allMatches(arr.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
  final sh = int.parse(rotM.group(1)!, radix: 16) % items.length;
  final r = [...items.skip(sh), ...items.take(sh)];
  final name = r[0].replaceAll(RegExp(r'=$'), '');
  final prefix = r[2];
  c.cookie = '$name=$prefix${powSolve(prefix, int.parse(prefix[0], radix: 16))}';
  final s = await c.get('/');
  return s.status == 200 && !s.body.contains('cdndefend');
}

void main() async {
  final c = Conn();
  try {
    await c.open();
    if (!await gate(c)) {
      print('准入失败');
      return;
    }
    print('准入通过');
    final ch = await c.get('/channel/6.html');
    final ids = RegExp(r'href="/detail/(\d+)\.html"')
        .allMatches(ch.body)
        .map((m) => m.group(1)!)
        .toList();
    final id = ids.first;
    print('测试 id = $id');

    print('');
    print('══ 播放页 /play/$id-1-1.html ══');
    print('');
    final p = await c.get('/play/$id-1-1.html');
    final html = p.body;
    print('HTTP ${p.status}  ${html.length} B');
    await File('C:/tmp/keke_play.html').writeAsString(html);
    print('已存 C:/tmp/keke_play.html');

    print('');
    print('── 1. playSource 完整内容 ──');
    final ps = RegExp(r'playSource\s*=\s*\{').firstMatch(html);
    if (ps != null) {
      final a = (ps.start - 60).clamp(0, html.length);
      final b = (ps.start + 700).clamp(0, html.length);
      print(html.substring(a, b).replaceAll(RegExp(r'\s+'), ' '));
    } else {
      print('未找到 playSource');
      // 退一步：找所有 m3u8 / mp4
      for (final m in RegExp(r'''["'](https?://[^"']+?\.(?:m3u8|mp4)[^"']*)["']''')
          .allMatches(html)) {
        print('  ${m.group(1)}');
      }
    }

    print('');
    print('── 2. 选集列表：/play/{id}-{line}-{ep}.html ──');
    final eps = RegExp(r'/play/(\d+)-(\d+)-(\d+)\.html').allMatches(html).toList();
    print('  链接总数 ${eps.length}');
    final byLine = <String, Set<String>>{};
    for (final m in eps) {
      byLine.putIfAbsent(m.group(2)!, () => <String>{}).add(m.group(3)!);
    }
    for (final e in byLine.entries) {
      final list = e.value.map(int.tryParse).whereType<int>().toList()..sort();
      print('  线路 ${e.key}: ${list.length} 集  ${list.take(8).toList()}...');
    }

    print('');
    print('── 3. 线路标签 ──');
    for (final pat in [
      r'source-item-label">([^<]*)<',
      r'source-item[^>]*>([^<]{1,40})<',
      r'class="[^"]*source[^"]*"[^>]*>([^<]{1,30})<',
    ]) {
      final ms = RegExp(pat).allMatches(html).map((m) => m.group(1)!.trim()).toList();
      print('  $pat → ${ms.length} 个 ${ms.take(6).toList()}');
    }

    print('');
    print('── 4. 关键 class 统计 ──');
    final cls = <String, int>{};
    for (final m in RegExp(r'class="([^"]+)"').allMatches(html)) {
      for (final t in m.group(1)!.split(RegExp(r'\s+'))) {
        if (t.isEmpty) continue;
        cls[t] = (cls[t] ?? 0) + 1;
      }
    }
    final sorted = cls.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted.take(18)) {
      print('  ${e.key.padRight(28)} ${e.value}');
    }
  } catch (e) {
    print('异常 $e');
  } finally {
    c.close();
  }
}