/// 封面方案的最后一次实测。
///
/// 已确认的事实：
///   1. 四站 `ac=list` 只返回 8~9 字段，**没有 vod_pic**（0/20）；
///      而暴风/量子的 `ac=list` 返回 19 字段，**20/20 有封面**。
///      → 这是四站特意精简了 list 输出，属于按站差异，只能按站配置。
///   2. `ac=detail&pg=1` 整页 20 条全部带封面，但体积 459 KB（电影天堂）。
///   3. `ac=detail&ids=a,b,c` 真批量，3 个 id 返回 3 条。
///
/// 现在唯一还没试的、能显著省流量的路径：
///
///   A. **字段裁剪**：`&fields=vod_id,vod_pic` 或 `&field=`，看能否只回封面。
///      若支持 → 完美方案，几十字节解决问题。
///
///   B. **pagesize 控制**：`&pagesize=N` / `&limit=N` 对 detail 是否有效。
///      若有效 → 按首屏可见条数分批，减少单次体积。
///
///   C. **`ac=detail&ids=` 传 20 个 id 的体积**，与整页 detail 对比，
///      判断批量接口是否比整页更省（有些不带 total 统计）。
///
/// 这三条全部失败的话，方案就定为「整页 detail + 进程内缓存」。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua =
    'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<({int code, String body, int bytes})> _get(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = _ua;
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return (
      code: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      bytes: bytes.length,
    );
  } catch (e) {
    final m = '$e'.split('\n').first;
    return (code: -1, body: 'ERR ${m.length > 80 ? m.substring(0, 80) : m}', bytes: 0);
  } finally {
    client.close(force: true);
  }
}

/// 返回 (条数, 带封面数, 首条字段名集合)
({int n, int pics, Set<String> keys}) _probe(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return (n: 0, pics: 0, keys: <String>{});
    final list = (j['list'] as List?) ?? const [];
    var pics = 0;
    final keys = <String>{};
    for (final x in list) {
      if (x is! Map) continue;
      if ((x['vod_pic'] ?? '').toString().trim().isNotEmpty) pics++;
      keys.addAll(x.keys.map((e) => e.toString()));
    }
    return (n: list.length, pics: pics, keys: keys);
  } catch (_) {
    return (n: 0, pics: 0, keys: <String>{});
  }
}

const _base = 'http://caiji.dyttzyapi.com/api.php/provide/vod/';

void main() async {
  print('══ A. 字段裁剪：能否只回封面字段 ══');
  print('');
  // 不同采集站模板认的参数名不一样，常见的几种都试一遍
  const fieldParams = [
    'fields=vod_id,vod_pic',
    'field=vod_id,vod_pic',
    'ac=detail&fields=vod_id,vod_pic',
    'ac=detail&field=vod_id,vod_pic',
  ];
  for (final p in fieldParams) {
    final url = p.startsWith('ac=') ? '$_base?$p&pg=1' : '$_base?ac=detail&pg=1&$p';
    final r = await _get(url);
    final info = _probe(r.body);
    print('  $p');
    print('    HTTP ${r.code}  ${(r.bytes / 1024).toStringAsFixed(1)} KB  '
        '${info.n} 条  带封面 ${info.pics}  字段数 ${info.keys.length}');
    if (info.keys.isNotEmpty && info.keys.length <= 4) {
      print('    → 字段被裁剪：${info.keys.join(", ")}');
    }
  }

  print('');
  print('══ B. pagesize / limit 对 detail 是否有效 ══');
  print('');
  for (final p in ['pagesize=5', 'limit=5', 'num=5']) {
    final r = await _get('$_base?ac=detail&pg=1&$p');
    final info = _probe(r.body);
    print('  $p → HTTP ${r.code}  ${(r.bytes / 1024).toStringAsFixed(1)} KB  ${info.n} 条');
  }

  print('');
  print('══ C. 整页 detail vs 批量 ids 的体积对比 ══');
  print('');
  final listR = await _get('$_base?ac=list&pg=1');
  final ids = _probe(listR.body);
  print('  ac=list 20 条  ${(listR.bytes / 1024).toStringAsFixed(1)} KB');

  final whole = await _get('$_base?ac=detail&pg=1');
  print('  ac=detail 整页  ${(whole.bytes / 1024).toStringAsFixed(1)} KB  '
      '${_probe(whole.body).n} 条');

  // 取 list 的真实 id
  List<String> idList = const [];
  try {
    final j = jsonDecode(listR.body) as Map<String, dynamic>;
    idList = ((j['list'] as List?) ?? const [])
        .map((x) => ((x as Map)['vod_id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
  } catch (_) {}

  if (idList.isNotEmpty) {
    final all = await _get('$_base?ac=detail&ids=${idList.join(",")}');
    final info = _probe(all.body);
    print('  ac=detail ${idList.length} 个 id  ${(all.bytes / 1024).toStringAsFixed(1)} KB  '
        '${info.n} 条  带封面 ${info.pics}');
    print('  → 批量 ${all.bytes < whole.bytes ? "更省" : "不省"} '
        '(${((all.bytes - whole.bytes) / 1024).toStringAsFixed(1)} KB 差)');
    print('  → 每反填 1 条封面需 ${(all.bytes / info.pics.clamp(1, 999) / 1024).toStringAsFixed(1)} KB');
  }
}