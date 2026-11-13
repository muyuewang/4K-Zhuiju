/// 关键验证：`www.kekeys.com` 是不是可可影视迁移后的新域名？
///
/// 背景（前几轮实测）：
///   www.keke1.app → 185.216.116.26，80/443/8080 TCP 全不通（整机不可达）
///   www.kekys.com → 185.216.116.56，443 同样不通（同网段一起挂了）
///   www.kekeys.com → 203.161.33.22，443 **通，243ms**
///
/// 光「能连上」不算数 —— 必须证明它是**同一个程序**。判据是模板指纹，
/// 而不是域名像不像。可可影视的模板特征（见 keke1_source.dart）：
///
///   1. 详情链接形如 `/detail/{数字}.html`
///   2. 卡片标题用 `<div class="v-item-title">`
///   3. 播放页有 `playSource = { src: "..." }`
///   4. 分类页 `/channel/{n}.html`
///   5. 门口挂 cdndefend 的 SHA1 工作量证明
///
/// 五个里命中 4 个以上，才能确认是同一个站，而不是同名马甲。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua =
    'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

Future<({int code, String body, int ms})> _get(
  String url, {
  String? referer,
}) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = _ua
    ..badCertificateCallback = (_, __, ___) => true;
  client.findProxy = (_) => 'DIRECT';
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', 'text/html,application/xhtml+xml,*/*');
    if (referer != null) req.headers.set('Referer', referer);
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return (
      code: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      ms: sw.elapsedMilliseconds,
    );
  } catch (e) {
    final m = '$e'.split('\n').first;
    return (code: -1, body: 'ERR ${m.length > 100 ? m.substring(0, 100) : m}', ms: sw.elapsedMilliseconds);
  } finally {
    client.close(force: true);
  }
}

void main() async {
  const host = 'https://www.kekeys.com';
  print('══ 指纹验证 $host ══');
  print('');

  final home = await _get('$host/');
  print('首页  HTTP ${home.code}  ${home.ms}ms  ${home.body.length} B');
  if (home.code != 200) {
    print('  body: ${home.body.replaceAll(RegExp(r"\s+"), " ").substring(0, 160)}');
    print('');
    print('→ 首页都打不开，无法确认身份');
    return;
  }
  final html = home.body;

  // 判据 1：/detail/{id}.html 链接
  final detailIds = RegExp(r'href="/detail/(\d+)\.html"')
      .allMatches(html)
      .map((m) => m.group(1)!)
      .toList();
  print('  [1] /detail/{id}.html 链接数: ${detailIds.length}  ${detailIds.take(5).toList()}');

  // 判据 2：v-item-title
  final vTitle = RegExp(r'class="v-item-title"').allMatches(html).length;
  print('  [2] class="v-item-title" 出现: $vTitle 次');

  // 判据 3：/channel/{n}.html
  final channels = RegExp(r'/channel/(\d+)\.html')
      .allMatches(html)
      .map((m) => m.group(1)!)
      .toSet()
      .toList();
  print('  [3] /channel/{n}.html 分类: ${channels.length} 个  $channels');

  // 判据 4：搜索表单的 t 令牌
  final tokenM = RegExp(r'name="t"\s+value="([^"]+)"').firstMatch(html);
  print('  [4] 搜索令牌 name="t": ${tokenM == null ? "无" : "有 → ${tokenM.group(1)!.substring(0, (tokenM.group(1)!.length).clamp(0, 16))}…"}');

  // 判据 5：cdndefend 工作量证明
  final cdn = RegExp(r'cdndefend|__cdn|sha1', caseSensitive: false).allMatches(html).length;
  print('  [5] cdndefend/sha1 指纹: $cdn 次');

  // 标题
  final title = RegExp(r'<title>([^<]*)</title>').firstMatch(html)?.group(1) ?? '';
  print('  页面标题: $title');

  print('');
  print('══ 详情页验证（取首个 id）══');
  print('');
  if (detailIds.isNotEmpty) {
    final id = detailIds.first;
    final d = await _get('$host/detail/$id.html', referer: '$host/');
    print('  /detail/$id.html  HTTP ${d.code}  ${d.ms}ms  ${d.body.length} B');
    final playLinks = RegExp(r'href="(/play/(\d+)-(\d+)-(\d+)\.html)"')
        .allMatches(d.body)
        .length;
    final labels = RegExp(r'source-item-label">([^<]*)<')
        .allMatches(d.body)
        .map((m) => m.group(1)!)
        .toList();
    final epLists = RegExp(r'class="episode-list"').allMatches(d.body).length;
    print('  /play/{id}-{line}-{ep}.html 链接: $playLinks');
    print('  线路标签: $labels');
    print('  episode-list 分块: $epLists');
  } else {
    print('  首页没有 /detail/ 链接，无法继续');
  }
}