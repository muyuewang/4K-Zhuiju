/// 实测四件事，全是这次改动的判据，不靠推测：
///
///   1. `ac=list`（列表页用的接口）到底带不带 `vod_pic`？
///      代码里 `_drama()` 已经读了 `it['vod_pic']`。如果列表不带这个字段，
///      那封面必然是空的 —— 但「空」和「字段存在但值为空」是两回事，
///      后者补不了，前者可能是被 `ac=list` 精简掉了。
///
///   2. 如果列表不带封面，`ac=detail&ids=1,2,3…` 能不能**批量**取？
///      这决定补封面是「20 次请求」还是「1 次请求」。差别巨大：
///      单条 detail 实测约 540 KB，20 条就是 10 MB，绝不能按条拉。
///
///   3. 批量 detail 的实际体积和耗时。
///
///   4. 可可影视首页当前能不能通（用户报「经常加载不出来」）。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua =
    'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<({int code, String body, int ms, int bytes})> _get(String url) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = _ua;
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
    return (code: -1, body: 'ERR $e', ms: sw.elapsedMilliseconds, bytes: 0);
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

void main() async {
  print('需求① 列表接口是否带封面 —— 逐站实测 ac=list');
  print('');

  final firstIds = <String, String>{};

  for (final e in _sites.entries) {
    final name = e.key;
    final base = e.value;
    final r = await _get('${base}?ac=list&pg=1');
    if (r.code != 200) {
      print('$name: HTTP ${r.code}  (${r.ms}ms)');
      continue;
    }
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      print('$name: 返回不是 JSON');
      continue;
    }
    final list = (j['list'] as List?) ?? const [];
    if (list.isEmpty) {
      print('$name: 列表为空');
      continue;
    }
    final first = list.first as Map<String, dynamic>;
    final keys = first.keys.toList()..sort();
    final pic = (first['vod_pic'] ?? '').toString();
    final picCount =
        list.where((x) => ((x as Map)['vod_pic'] ?? '').toString().trim().isNotEmpty).length;

    print('$name  (${r.ms}ms, ${(r.bytes / 1024).toStringAsFixed(1)} KB, ${list.length} 条)');
    print('  字段数 ${keys.length}: ${keys.join(", ")}');
    print('  第 1 条 vod_pic = ${pic.isEmpty ? "<空>" : pic}');
    print('  有封面的条数: $picCount / ${list.length}');
    if (picCount == 0) {
      print('  → 列表不带封面，必须另取');
    }
    final id = (first['vod_id'] ?? '').toString();
    if (id.isNotEmpty) firstIds[name] = id;
    print('');
  }

  print('');
  print('需求② 批量 detail 能不能一次取多个 id');
  print('');
  for (final e in _sites.entries) {
    final id = firstIds[e.key];
    if (id == null) continue;
    final ids3 = '$id,$id,$id';
    final r1 = await _get('${e.value}?ac=detail&ids=$id');
    final r2 = await _get('${e.value}?ac=detail&ids=$ids3');
    String n1 = '?', n2 = '?';
    try {
      n1 = '${(jsonDecode(r1.body)['list'] as List).length}';
      n2 = '${(jsonDecode(r2.body)['list'] as List).length}';
    } catch (_) {}
    print('${e.key}');
    print('  单 id : HTTP ${r1.code} ${(r1.bytes / 1024).toStringAsFixed(1)} KB → $n1 条');
    print('  三 id : HTTP ${r2.code} ${(r2.bytes / 1024).toStringAsFixed(1)} KB → $n2 条');
    print('  结论 : ${n2 == '3' ? '支持批量 ✅' : '不支持批量（复用 id 只回 $n2 条，需换不同 id 再测）'}');
  }

  print('');
  print('需求③ 可可影视当前可达性（用户报「经常加载不出来」）');
  print('');
  for (var i = 1; i <= 3; i++) {
    final r = await _get('https://www.keke1.app/');
    final snippet = r.body.replaceAll(RegExp(r'\s+'), ' ').substring(
        0, r.body.length > 160 ? 160 : r.body.length);
    print('  第 $i 次: HTTP ${r.code}  ${r.ms}ms  ${r.bytes} B');
    print('          $snippet');
  }
}