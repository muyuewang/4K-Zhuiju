/// 第二轮探针。上一轮已确认「`ac=list` 四站全部不带 `vod_pic`」，
/// 所以补封面只能另取。这一轮要回答的是**怎么取最省**：
///
///   A. `ac=detail&pg=1&pagesize=20`（不带 ids）会不会直接返回 20 条详情？
///      —— 如果能，那就是 1 次请求拿到整页封面，完胜任何并发方案。
///
///   B. `ac=detail&ids=a,b,c` 用**三个不同的真实 id** 重测。
///      上一轮我用了 `$id,$id,$id`（同一个 id 重复三遍），返回 1 条完全说明不了
///      问题 —— 去重也好、取首个也好，都会得到 1 条。那次测试无效。
///
///   C. 老版 maccms 的 `ac=videolist` 是否还在（某些站保留兼容）。
///
///   D. 可可影视直连可达性。上一轮三次全挂在
///      `Proxy failed to establish tunnel (502)`，那是**本机代理**连不到
///      keke1.app:443，不是源站的问题。必须绕开代理才能判断源站死活。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua =
    'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<({int code, String body, int ms, int bytes})> _get(
  String url, {
  bool direct = false,
}) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = _ua;
  if (direct) client.findProxy = (_) => 'DIRECT';
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', 'application/json, text/plain, */*');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return (
      code: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      ms: sw.elapsedMilliseconds,
      bytes: bytes.length,
    );
  } catch (e) {
    final s = '$e';
    return (
      code: -1,
      body: 'ERR ${s.length > 120 ? s.substring(0, 120) : s}',
      ms: sw.elapsedMilliseconds,
      bytes: 0,
    );
  } finally {
    client.close(force: true);
  }
}

const _sites = <String, String>{
  '电影天堂': 'http://caiji.dyttzyapi.com/api.php/provide/vod/',
  '光速资源': 'https://api.guangsuapi.com/api.php/provide/vod/',
  '非凡资源': 'http://cj.ffzyapi.com/api.php/provide/vod/',
  '猫眼资源': 'https://api.maoyanapi.top/api.php/provide/vod/',
};

/// 从一段 JSON 里读出 list 长度 / 带封面的条数 / 前两条 id
({int n, int pics, List<String> ids}) _inspect(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return (n: 0, pics: 0, ids: const []);
    final list = (j['list'] as List?) ?? const [];
    var pics = 0;
    final ids = <String>[];
    for (final x in list) {
      final m = x as Map;
      if ((m['vod_pic'] ?? '').toString().trim().isNotEmpty) pics++;
      final id = (m['vod_id'] ?? '').toString();
      if (id.isNotEmpty) ids.add(id);
    }
    return (n: list.length, pics: pics, ids: ids);
  } catch (_) {
    return (n: 0, pics: 0, ids: const []);
  }
}

String _kb(int b) => '${(b / 1024).toStringAsFixed(1)} KB';

void main() async {
  print('══ A. ac=detail 不带 ids，能否整页返回（1 次请求换 20 个封面）══');
  print('');
  for (final e in _sites.entries) {
    final r = await _get('${e.value}?ac=detail&pg=1');
    final info = _inspect(r.body);
    print('${e.key}  HTTP ${r.code}  ${r.ms}ms  ${_kb(r.bytes)}');
    print('  条数 ${info.n}，带封面 ${info.pics}');
    if (r.code != 200 || info.n == 0) {
      print('  body: ${r.body.replaceAll(RegExp(r"\s+"), " ").substring(0, 120)}');
    }
    print('');
  }

  print('══ B. ac=detail&ids= 用三个【不同】真实 id 重测 ══');
  print('');
  for (final e in _sites.entries) {
    // 先拿一页 list 的真实 id 池
    final listResp = await _get('${e.value}?ac=list&pg=1');
    final pool = _inspect(listResp.body).ids;
    if (pool.length < 3) {
      print('${e.key}: id 池不足（${pool.length}），跳过');
      continue;
    }
    final three = pool.take(3).toList();
    final r = await _get('${e.value}?ac=detail&ids=${three.join(",")}');
    final info = _inspect(r.body);
    print('${e.key}  ids=${three.join(",")}');
    print('  HTTP ${r.code}  ${r.ms}ms  ${_kb(r.bytes)}  → ${info.n} 条，带封面 ${info.pics}');
    print('  ${info.n >= 2 ? "支持批量 ✅" : "不支持批量 ❌（仍只回 1 条）"}');
    print('');
  }

  print('══ C. 老版 ac=videolist 是否还在 ══');
  print('');
  for (final e in _sites.entries) {
    final r = await _get('${e.value}?ac=videolist&pg=1');
    final info = _inspect(r.body);
    print('${e.key}  HTTP ${r.code}  ${_kb(r.bytes)}  → 条数 ${info.n}，带封面 ${info.pics}');
  }

  print('');
  print('══ D. 可可影视：绕开本机代理直连 ══');
  print('');
  for (var i = 1; i <= 3; i++) {
    final r = await _get('https://www.keke1.app/', direct: true);
    print('  第 $i 次: HTTP ${r.code}  ${r.ms}ms  ${r.bytes} B');
    final body = r.body.replaceAll(RegExp(r'\s+'), ' ');
    print('          ${body.substring(0, body.length > 140 ? 140 : body.length)}');
  }
}