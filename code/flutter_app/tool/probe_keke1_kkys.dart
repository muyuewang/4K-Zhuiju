/// 抓 kkys.min.js 并提取真实接口，然后直连 API 域名试调用。
///
/// ## 已确认的链路（全部实测，不是推断）
///
/// ```
/// www.keke1.app  ──HTTP 850 挑战──> PoW(228ms) ──> 200 / 227475 B
///   ├─ /channel/6.html  → 200 / 193964 B，80 个 /detail/ 链接、73 封面  ✅
///   └─ /detail/{id}.html → 200 / 83861 B，但：
///        <div class="source-list-box-main"></div>      ← 空
///        <div class="episode-list-box-main"></div>     ← 空
///        playSource / m3u8 / episodes / playList 全 0 次
/// ```
///
/// 页面内联脚本给出真实数据层：
/// ```js
/// window.whatTMDwhatTMDKey        = "kkdy";
/// window.whatTMDwhatTMDApiDomain  = "https://43.248.100.69:51080";
/// window.whatTMDwhatTMDUserChannel= "c1";
/// import {KKYS} from ".../js/kkys.min.js";
/// ```
///
/// 所以选集数据走的是 **API 域名 + kkdy key**，不在 HTML 里。
/// 现有 `keke1_source.dart` 用正则啃 HTML 拿播放地址，模板改后必然失效。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const String _cdn = 'https://vf.wkcyvs.cn/vod_pc_static_kkdy';
const String _apiBase = 'https://43.248.100.69:51080';

Future<({int code, String body})> get(
  String url, {
  String? referer,
  bool direct = false,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = _ua
    ..badCertificateCallback = (_, __, ___) => true;
  // 代理与直连分开：CDN 要走代理，API 那台裸 IP 也可能直连就通
  client.findProxy = (_) => direct ? 'DIRECT' : 'PROXY 127.0.0.1:7897';
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', '*/*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    if (referer != null) req.headers.set('Referer', referer);
    final res = await req.close().timeout(const Duration(seconds: 25));
    final b = await res.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
    return (code: res.statusCode, body: utf8.decode(b, allowMalformed: true));
  } catch (e) {
    final m = '$e'.split('\n').first;
    return (code: -1, body: 'ERR ${m.length > 100 ? m.substring(0, 100) : m}');
  } finally {
    client.close(force: true);
  }
}

void main() async {
  print('══ 1. 抓 kkys.min.js ══');
  print('');
  final r = await get('$_cdn/js/kkys.min.js?ver=123456666',
      referer: 'https://www.keke1.app/');
  print('  HTTP ${r.code}  ${r.body.length} 字符');
  if (r.code != 200) {
    print('  ${r.body}');
    return;
  }
  final js = r.body;
  // 注意：不要写成 `/c/tmp/...`。那是 Git Bash 的 MSYS 路径，Dart 的 dart:io
  // 按 Windows 路径解释，会直接报 PathNotFound。要写就写 `C:/tmp/...`。
  try {
    await File('C:/tmp/kkys.js').writeAsString(js);
    print('  已存 C:/tmp/kkys.js');
  } catch (e) {
    print('  存盘失败（不影响后续分析）：$e');
  }

  print('');
  print('══ 2. 提取接口路径 ══');
  print('');
  final paths = <String>{};
  for (final m in RegExp(r'''["'`]([/][a-zA-Z0-9_/\-]{2,60})["'`]''').allMatches(js)) {
    final p = m.group(1)!;
    if (RegExp(r'vod|detail|play|source|episode|channel|search|list', caseSensitive: false)
        .hasMatch(p)) {
      paths.add(p);
    }
  }
  final sorted = paths.toList()..sort();
  print('  共 ${sorted.length} 条候选：');
  for (final p in sorted.take(50)) {
    print('    $p');
  }

  print('');
  print('══ 3. API 关键拼接片段 ══');
  print('');
  for (final kw in ['ApiDomain', 'whatTMD', 'baseURL', 'kkdy', 'c1']) {
    final ms = RegExp(kw).allMatches(js).toList();
    print('  $kw → ${ms.length} 次');
    for (final m in ms.take(2)) {
      final a = (m.start - 100).clamp(0, js.length);
      final b = (m.start + 150).clamp(0, js.length);
      print('    …${js.substring(a, b).replaceAll(RegExp(r"\s+"), " ")}…');
    }
  }

  print('');
  print('══ 4. 直连 API 域名探活 ══');
  print('');
  for (final base in ['https://43.248.100.69:51080', 'http://43.248.100.69:51080']) {
    for (final p in ['/', '/api', '/api/vod/detail?vodId=394802']) {
      final x = await get('$base$p', direct: true);
      final snip = x.body.replaceAll(RegExp(r'\s+'), ' ');
      print('  ${base.split(":").first}://…:51080$p → HTTP ${x.code}  ${x.body.length} B');
      if (x.code != -1) {
        print('    ${snip.substring(0, snip.length > 120 ? 120 : snip.length)}');
      }
    }
  }
}