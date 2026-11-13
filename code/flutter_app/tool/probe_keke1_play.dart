/// 可可影视：播放页是否还活着 + API 域名经代理能否通。
///
/// ## 为什么要测这两件事
///
/// 详情页 `/detail/{id}.html` 的选集容器是空的，数据走签名 API
/// （kkys.min.js 里用 HmacSHA1 + ciphertext，11 个 /vod/* 接口）。
/// 逆向这套签名成本很高，所以在下结论之前先看**有没有更省的路**：
///
///   A. `/play/{id}-{line}-{ep}.html` 这个旧路径还在不在？
///      在的话，只要拿到「线路数 × 集数」就能直接播，不必碰签名 API。
///      首页/分类页的卡片上常带「更新至N集」文案，或许能推出集数。
///
///   B. API 域名 `43.248.100.69:51080` 经代理是否可达？
///      直连是 101 B 的错误（不可达）。经代理通不通决定后续路线。
///
///   C. 详情页有没有别的门路拿到选集：`?page=`、`/detail/{id}-1-1.html`、
///      RSS、`/label/` 等。逐个试，别猜。
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

// ---------- 钉住连接（PoW 绑定 TCP） ----------

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
      ..write('Accept: text/html,application/json,*/*\r\n')
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

Future<({int code, String body})> plainGet(String url, {bool viaProxy = true}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = _ua
    ..badCertificateCallback = (_, __, ___) => true;
  client.findProxy = (_) => viaProxy ? 'PROXY ${_proxy.$1}:${_proxy.$2}' : 'DIRECT';
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', '*/*');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final b = await res.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
    return (code: res.statusCode, body: utf8.decode(b, allowMalformed: true));
  } catch (e) {
    final m = '$e'.split('\n').first;
    return (code: -1, body: 'ERR ${m.length > 90 ? m.substring(0, 90) : m}');
  } finally {
    client.close(force: true);
  }
}

void main() async {
  final c = Conn();
  String? id;
  List<String> ids = [];
  try {
    await c.open();
    if (!await gate(c)) {
      print('准入失败');
      return;
    }
    print('准入通过');
    final ch = await c.get('/channel/6.html');
    ids = RegExp(r'href="/detail/(\d+)\.html"')
        .allMatches(ch.body)
        .map((m) => m.group(1)!)
        .toList();
    id = ids.isNotEmpty ? ids.first : null;
    print('分类页 detail 链接 ${ids.length} 个，首个 $id');

    print('');
    print('══ A. 详情页其它门路 ══');
    print('');
    if (id != null) {
      for (final p in [
        '/detail/$id-1-1.html',
        '/detail/$id.html?page=1',
        '/detail/$id.html?tab=1',
      ]) {
        final r = await c.get(p);
        final src = RegExp(r'source-item-label').allMatches(r.body).length;
        final play = RegExp(r'/play/\d+-\d+-\d+\.html').allMatches(r.body).length;
        print('  $p');
        print('    HTTP ${r.status}  ${r.body.length} B  source-label=$src  /play/=$play');
      }

      print('');
      print('══ B. 播放页旧路径是否还在 ══');
      print('');
      for (final p in [
        '/play/$id-1-1.html',
        '/play/${id}_1_1.html',
        '/play/$id.html',
      ]) {
        final r = await c.get(p);
        final hasPlaySource = r.body.contains('playSource');
        final m3u8 = RegExp(r'\.m3u8').allMatches(r.body).length;
        final m = RegExp(r'src\s*:\s*"([^"]+)"').firstMatch(r.body);
        final src = (m?.group(1) ?? '').replaceAll(r'\/', '/');
        print('  $p');
        print('    HTTP ${r.status}  ${r.body.length} B  '
            'playSource=$hasPlaySource  m3u8=$m3u8');
        if (src.isNotEmpty) print('    src=$src');
      }
    }
  } catch (e) {
    print('异常 $e');
  } finally {
    c.close();
  }

  print('');
  print('══ C. API 域名经代理可达性 ══');
  print('');
  for (final u in [
    'https://43.248.100.69:51080/',
    'http://43.248.100.69:51080/',
  ]) {
    final r = await plainGet(u);
    final snip = r.body.replaceAll(RegExp(r'\s+'), ' ');
    print('  $u → HTTP ${r.code}  ${r.body.length} B');
    print('    ${snip.substring(0, snip.length > 110 ? 110 : snip.length)}');
  }
}