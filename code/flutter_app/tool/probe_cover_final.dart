/// 最后一轮封面探针：只差两条判据就能定方案。
///
/// ## 已确认（不再重复验证）
///
/// | 判据 | 结果 |
/// | --- | --- |
/// | 四站 `ac=list` 带不带 `vod_pic` | **0/20，全不带**（暴风/量子 20/20 带，说明是这四站精简了） |
/// | `fields=` / `field=` 裁剪 | **不支持**，仍回 83 字段、504.9 KB |
/// | `ac=detail&pg=1` | 200，20 条，20/20 带封面，**506 KB** |
/// | `ac=detail&ids=a,b,c` | 真批量，3 个 id 回 3 条，但**不比整页省** |
/// | `pagesize=N` | **有效**（5 条 = 198.8 KB） |
///
/// ## 还差的两条
///
///   A. `ac=detail&pg=2` 的分页语义是否和 `ac=list&pg=2` 一致？
///      如果第 2 页确实是第 21~40 条，那 detail 就能**直接替换** list，
///      改动最小、翻页不会错位。
///
///   B. `ac=list` 加上 `t=` / 换手机 UA / 加 `at=json` 后，
///      这四个站会不会**多回** `vod_pic`？（不同模板分支可能给不同字段集）
///      若某组合能拿到封面，就不用付 506 KB 的代价。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _desktopUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const String _mobileUa = 'Mozilla/5.0 (Linux; Android 9; SM-N9700) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<({int code, int bytes, String body})> get(String url, {String? ua}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = ua ?? _desktopUa;
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final b = await res.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
    return (code: res.statusCode, bytes: b.length,
        body: utf8.decode(b, allowMalformed: true));
  } catch (e) {
    return (code: -1, bytes: 0, body: '${'$e'.split('\n').first}');
  } finally {
    client.close(force: true);
  }
}

({int n, int pics, List<String> ids}) inspect(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return (n: 0, pics: 0, ids: const []);
    final list = (j['list'] as List?) ?? const [];
    final ids = <String>[];
    var pics = 0;
    for (final x in list) {
      if (x is! Map) continue;
      if ((x['vod_pic'] ?? '').toString().trim().isNotEmpty) pics++;
      final id = (x['vod_id'] ?? '').toString();
      if (id.isNotEmpty) ids.add(id);
    }
    return (n: list.length, pics: pics, ids: ids);
  } catch (_) {
    return (n: 0, pics: 0, ids: const []);
  }
}

const _sites = <String, String>{
  '电影天堂': 'http://caiji.dyttzyapi.com/api.php/provide/vod/',
  '光速资源': 'https://api.guangsuapi.com/api.php/provide/vod/',
  '非凡资源': 'http://cj.ffzyapi.com/api.php/provide/vod/',
  '猫眼资源': 'https://api.maoyanapi.top/api.php/provide/vod/',
};

void main() async {
  print('══ A. detail 的翻页语义是否与 list 一致 ══');
  print('');
  for (final e in _sites.entries) {
    final l1 = await get('${e.value}?ac=list&pg=1');
    final l2 = await get('${e.value}?ac=list&pg=2');
    final d1 = await get('${e.value}?ac=detail&pg=1');
    final d2 = await get('${e.value}?ac=detail&pg=2');
    final i1 = inspect(l1.body), i2 = inspect(l2.body);
    final j1 = inspect(d1.body), j2 = inspect(d2.body);

    // 关键：detail 第 2 页的首条 id 是否等于 list 第 2 页的首条 id
    final sameHead = i2.ids.isNotEmpty && j2.ids.isNotEmpty && i2.ids.first == j2.ids.first;
    // 相邻页是否有重叠（重叠说明分页不对）
    final overlap = j1.ids.toSet().intersection(j2.ids.toSet()).length;

    print('${e.key}');
    print('  list  p1=${i1.n}条 p2=${i2.n}条');
    print('  detail p1=${j1.n}条(${j1.pics}封面) p2=${j2.n}条(${j2.pics}封面)');
    print('  p2 首条 list=${i2.ids.isEmpty ? "-" : i2.ids.first} '
        'detail=${j2.ids.isEmpty ? "-" : j2.ids.first}  ${sameHead ? "一致 ✅" : "不一致 ❌"}');
    print('  detail p1∩p2 重叠 $overlap 条  ${overlap == 0 ? "无重叠 ✅" : "有重叠 ❌"}');
    print('');
  }

  print('══ B. list 换参数/UA 能否逼出 vod_pic ══');
  print('');
  for (final e in _sites.entries) {
    print('${e.key}');
    final variants = <String, String>{
      'list&pg=1（基线）': '${e.value}?ac=list&pg=1',
      'list&pg=1&t=6': '${e.value}?ac=list&pg=1&t=6',
      'list&pg=1&at=json': '${e.value}?ac=list&pg=1&at=json',
      'list&pg=1&h=1': '${e.value}?ac=list&pg=1&h=1',
    };
    for (final v in variants.entries) {
      final r = await get(v.value);
      final i = inspect(r.body);
      print('  ${v.key.padRight(22)} HTTP ${r.code}  ${(r.bytes / 1024).toStringAsFixed(1)} KB  '
          '${i.n} 条  封面 ${i.pics}');
    }
    // 手机 UA 再试一次基线
    final m = await get('${e.value}?ac=list&pg=1', ua: _mobileUa);
    final mi = inspect(m.body);
    print('  ${"list&pg=1（手机UA）".padRight(22)} HTTP ${m.code}  ${(m.bytes / 1024).toStringAsFixed(1)} KB  '
        '${mi.n} 条  封面 ${mi.pics}');
    print('');
  }
}