/// 定位可可影视详情页的真实数据接口。
///
/// ## 已确认的事实（不是推测）
///
/// 1. 站点**在线**。走用户真实代理 `127.0.0.1:7897`：
///    CONNECT 200 → GET / → HTTP 850 挑战 → PoW 228ms → 200 / 227475 B。
///    用户浏览器截图也能流畅打开，两边一致。
///
/// 2. 分类页 `/channel/6.html` 正常：80 个 `/detail/{id}.html` 链接、
///    144 个 `v-item-title`、73 个封面 URL。
///
/// 3. **详情页 `/detail/{id}.html` 的选集是空的**：
///    ```html
///    <div class="source-list-box-main">
///    </div>
///    <div class="episode-list-box-main">
///    </div>
///    ```
///    页面里有 `.source-item` 的点击绑定 JS，但**元素本身不存在**。
///    `playSource` 0 次、`m3u8` 0 次、`episodes` 0 次、`playList` 0 次。
///
/// 所以现有 `keke1_source.dart` 的正则（`source-item-label">`、
/// `href="/play/{id}-{line}-{ep}.html"`）在当前模板下**必然 0 命中**。
/// 这就是「列表能出来、点进去加载不出来」的真正原因 —— 不是网络，
/// 是站方把详情页改成了 JS 异步加载。
///
/// ## 本脚本要做的
///
/// 抓 `service.min.js` / `kkdy.dl.js` / `Auth.min.js`（从 CDN，需 Referer），
/// 从中提取 API 路径与参数名，并**实际调用**候选接口验证是否返回选集 JSON。
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
const String _cdn = 'https://vf.wkcyvs.cn/vod_pc_static_kkdy';

// ---------- 极简 HTTP（走代理，自动 gzip） ----------

Future<({int code, String body})> httpGet(String url, {String? referer}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = _ua
    ..badCertificateCallback = (_, __, ___) => true;
  client.findProxy = (_) => 'PROXY ${_proxy.$1}:${_proxy.$2}';
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', '*/*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    if (referer != null) req.headers.set('Referer', referer);
    final res = await req.close().timeout(const Duration(seconds: 25));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return (code: res.statusCode, body: utf8.decode(bytes, allowMalformed: true));
  } catch (e) {
    return (code: -1, body: 'ERR ${'$e'.split('\n').first}');
  } finally {
    client.close(force: true);
  }
}

// ---------- 钉住连接过闸门（PoW 必须在同一条 TCP 上） ----------

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
      ..write('Accept: application/json, text/html, */*\r\n')
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

// ---------- 从 JS 里扒 API 路径 ----------

final Set<String> _apiPaths = {};

void harvest(String js, String label) {
  // 引号包起来的、以 / 开头的路径片段
  for (final m in RegExp(r'''["'`](/[a-zA-Z0-9_/\-{}.:]{3,80})["'`]''').allMatches(js)) {
    final p = m.group(1)!;
    if (p.startsWith('/api') ||
        p.contains('/vod') ||
        p.contains('/detail') ||
        p.contains('/play') ||
        p.contains('/episode') ||
        p.contains('/source')) {
      _apiPaths.add(p);
    }
  }
  // 拼接式："/api/" + xxx 这种
  for (final m in RegExp(r'''["'`](/api/[a-zA-Z0-9_/\-]{0,60})["'`]''').allMatches(js)) {
    _apiPaths.add(m.group(1)!);
  }
  print('  [$label] ${js.length} 字符，累计路径 ${_apiPaths.length} 条');
}

void main() async {
  print('══ 1. 过闸门，拿一个有效的详情页 id ══');
  final c = Conn();
  String? id;
  try {
    await c.open();
    if (!await gate(c)) {
      print('  准入失败');
      return;
    }
    print('  准入通过');
    final ch = await c.get('/channel/6.html');
    final ids = RegExp(r'href="/detail/(\d+)\.html"')
        .allMatches(ch.body)
        .map((m) => m.group(1)!)
        .toList();
    print('  分类页 detail 链接 ${ids.length} 个');
    id = ids.isNotEmpty ? ids.first : null;
  } finally {
    c.close();
  }

  print('');
  print('══ 2. 抓前端 JS（CDN，需 Referer）══');
  print('');
  for (final f in [
    'js/http/service.min.js',
    'js/dl/kkdy.dl.js',
    'js/Auth.min.js',
  ]) {
    final r = await httpGet('$_cdn/$f?ver=123456666',
        referer: 'https://www.keke1.app/');
    if (r.code != 200) {
      print('  $f → HTTP ${r.code}  ${r.body.length > 60 ? r.body.substring(0, 60) : r.body}');
      continue;
    }
    harvest(r.body, f);
  }

  print('');
  print('  提取到的候选路径：');
  final sorted = _apiPaths.toList()..sort();
  for (final p in sorted.take(40)) {
    print('    $p');
  }

  print('');
  print('══ 3. 实际调用候选接口，看谁返回选集 ══');
  print('');
  if (id == null) {
    print('  没有 id，跳过');
    return;
  }
  final candidates = [
    '/api/vod/detail?id=$id',
    '/api/detail?id=$id',
    '/api/vod/$id',
    '/api/play/source?id=$id',
    '/api/vod/source?id=$id',
    '/api/vod/episode?id=$id',
    '/api/vod/play?id=$id',
  ];
  final c2 = Conn();
  try {
    await c2.open();
    if (!await gate(c2)) {
      print('  准入失败');
      return;
    }
    for (final p in candidates) {
      final r = await c2.get(p);
      final snippet = r.body.replaceAll(RegExp(r'\s+'), ' ');
      final isJson = snippet.trimLeft().startsWith('{') || snippet.trimLeft().startsWith('[');
      print('  $p');
      print('    HTTP ${r.status}  ${r.body.length} B  ${isJson ? "JSON ✓" : "非JSON"}');
      if (r.status == 200 && isJson) {
        print('    ${snippet.substring(0, snippet.length > 300 ? 300 : snippet.length)}');
      }
    }
  } finally {
    c2.close();
  }
}