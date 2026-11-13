/// 第三轮探针。前两轮已确认：四站 `ac=list` 全部 0/20 带封面，
/// `ac=detail&pg=1` 一次返回整页且 20/20 带封面，`ids=` 支持真批量。
///
/// 但还不能拍方案，缺两块事实：
///
///   ① **其他采集站（暴风 / 量子）的 `ac=list` 带不带封面？**
///      带 → 说明这是这四站特有的数据缺失，修法应是「按站点开关」；
///      不带 → 说明是整个 MacCMS 采集生态的共性，修法应做成默认行为。
///      这个结论直接决定配置项要不要加、默认值是什么。
///
///   ② **detail 的体积里，`vod_play_url` 占多少？**
///      列表页根本不需要播放地址，如果它占了 80% 的体积，那「整页切 detail
///      换封面」就等于为了封面多传 4 倍的垃圾数据。必须量化，不能只说
///      「459 KB 有点大」。
///
///   ③ 可可影视到底是「域名解析不了」「443 不通」还是「站没了」。
///      前两轮：代理 502、直连 443 超时。两种都挂，需要分辨层次：
///      DNS 有没有结果 → 80 端口通不通 → 无 www 的裸域通不通。
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
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = _ua;
  if (direct) client.findProxy = (_) => 'DIRECT';
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return (
      code: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      ms: sw.elapsedMilliseconds,
      bytes: bytes.length,
    );
  } catch (e) {
    final s = '$e';
    final short = s.split('\n').first;
    return (
      code: -1,
      body: 'ERR ${short.length > 90 ? short.substring(0, 90) : short}',
      ms: sw.elapsedMilliseconds,
      bytes: 0,
    );
  } finally {
    client.close(force: true);
  }
}

void main() async {
  print('══ ① 其他采集站 ac=list 是否带封面（决定「按站开关」还是「全局默认」）══');
  print('');
  const others = <String, String>{
    '暴风(BF)': 'https://bfzyapi.com/api.php/provide/vod/',
    '量子(LZ)': 'https://cj.lziapi.com/api.php/provide/vod/',
  };
  for (final e in others.entries) {
    final r = await _get('${e.value}?ac=list&pg=1');
    if (r.code != 200) {
      print('${e.key}: HTTP ${r.code}  ${r.body}');
      continue;
    }
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final list = (j['list'] as List?) ?? const [];
      final pics = list
          .where((x) => ((x as Map)['vod_pic'] ?? '').toString().trim().isNotEmpty)
          .length;
      final keys = list.isEmpty
          ? <String>[]
          : (list.first as Map).keys.map((e) => e.toString()).toList()..sort();
      print('${e.key}  ${r.ms}ms  ${(r.bytes / 1024).toStringAsFixed(1)} KB  ${list.length} 条');
      print('  有封面: $pics / ${list.length}');
      print('  字段: ${keys.join(", ")}');
      if (list.isNotEmpty) {
        final first = list.first as Map;
        final pic = (first['vod_pic'] ?? '').toString();
        print('  第 1 条 vod_pic = ${pic.isEmpty ? "<空>" : pic}');
      }
    } catch (err) {
      print('${e.key}: 解析失败 $err');
    }
    print('');
  }

  print('══ ② detail 体积构成：vod_play_url 到底占多少 ══');
  print('');
  const four = <String, String>{
    '电影天堂': 'http://caiji.dyttzyapi.com/api.php/provide/vod/',
    '光速资源': 'https://api.guangsuapi.com/api.php/provide/vod/',
    '非凡资源': 'http://cj.ffzyapi.com/api.php/provide/vod/',
    '猫眼资源': 'https://api.maoyanapi.top/api.php/provide/vod/',
  };
  for (final e in four.entries) {
    final r = await _get('${e.value}?ac=detail&pg=1');
    if (r.code != 200) {
      print('${e.key}: HTTP ${r.code}');
      continue;
    }
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      print('${e.key}: 非 JSON');
      continue;
    }
    final list = (j['list'] as List?) ?? const [];
    if (list.isEmpty) {
      print('${e.key}: 空');
      continue;
    }
    // 逐字段累计 JSON 体积，找出真正的体积大头
    final sizeByKey = <String, int>{};
    for (final x in list) {
      final m = x as Map;
      for (final en in m.entries) {
        final v = en.value;
        final s = v == null ? '' : jsonEncode(v);
        sizeByKey[en.key.toString()] = (sizeByKey[en.key.toString()] ?? 0) + s.length;
      }
    }
    final total = sizeByKey.values.fold<int>(0, (a, b) => a + b);
    final sorted = sizeByKey.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final pic = sizeByKey['vod_pic'] ?? 0;
    final playUrl = sizeByKey['vod_play_url'] ?? 0;
    final content = (sizeByKey['vod_content'] ?? 0) + (sizeByKey['vod_blurb'] ?? 0);

    print('${e.key}  ${list.length} 条  ${(r.bytes / 1024).toStringAsFixed(1)} KB  ${r.ms}ms');
    print('  字符总量 ${(total / 1024).toStringAsFixed(1)} K');
    for (final s in sorted.take(5)) {
      final pct = total == 0 ? 0 : (s.value * 100 / total).round();
      print('    ${s.key.padRight(16)} ${(s.value / 1024).toStringAsFixed(1)} K  $pct%');
    }
    print('  → 封面 $pic 字符 / 播放地址 $playUrl 字符 / 简介类 $content 字符');
    if (total > 0) {
      print('  → 播放地址占比 ${(playUrl * 100 / total).round()}%，是列表页完全用不到的部分');
    }
    print('');
  }

  print('══ ③ 可可影视故障分层：DNS / 80 / 裸域 ══');
  print('');
  for (final host in ['www.keke1.app', 'keke1.app']) {
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 8));
      print('DNS $host → ${addrs.map((a) => a.address).join(", ")}');
    } catch (e) {
      print('DNS $host → 解析失败 ${"$e".split("\n").first}');
    }
  }
  print('');
  for (final u in [
    'http://www.keke1.app/',
    'https://keke1.app/',
    'http://keke1.app/',
  ]) {
    final r = await _get(u, direct: true);
    final body = r.body.replaceAll(RegExp(r'\s+'), ' ');
    print('直连 $u');
    print('  HTTP ${r.code}  ${r.ms}ms  ${r.bytes} B');
    print('  ${body.substring(0, body.length > 110 ? 110 : body.length)}');
  }
}