/// 修正网络路径后重新验证可可影视。
///
/// ## 之前为什么测错了（必须记下来）
///
/// 前几轮探测我一直在用「系统环境变量里 http_proxy 指向的代理」，也就是
/// `127.0.0.1:14215` —— 那是 **WorkBuddy 沙箱自己注入的出口代理**，
/// 不是用户机器上真实在用的科学上网客户端。它到 keke1.app 直接回
/// `502 Bad Gateway`（CONNECT 隧道都建不起来）。
///
/// 而本机真正在监听的是 `127.0.0.1:7897`（用户自己的客户端）。
/// curl 走 7897 时：`CONNECT www.keke1.app:443 → HTTP/1.1 200 established`，
/// 隧道是通的。用户浏览器打开 `/channel/6.html` 也确实流畅。
///
/// 所以「TCP 不通 / 整机下线」的结论**是错的**，错在把沙箱代理的失败
/// 当成了源站的失败。这个教训写在这里，避免以后再用同一条错路径判断源站死活。
///
/// ## 本轮要验证的
///
///   1. 走 7897 能否完整拿到首页 / 分类页 / 详情页（含 cdndefend PoW 准入）
///   2. 列表页的封面能否解析出来（用户截图里每张卡都有封面）
///   3. 详情页 → 播放地址链路是否还在
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const String _proxy = 'PROXY 127.0.0.1:7897';

Future<({int code, String body, int ms, String? loc})> _get(
  String url, {
  String? referer,
  Map<String, String>? cookies,
}) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = _ua
    ..badCertificateCallback = (_, __, ___) => true;
  client.findProxy = (_) => _proxy;
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Accept', 'text/html,application/xhtml+xml,*/*');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    if (referer != null) req.headers.set('Referer', referer);
    if (cookies != null && cookies.isNotEmpty) {
      req.headers.set('Cookie',
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    final res = await req.close().timeout(const Duration(seconds: 25));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return (
      code: res.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      ms: sw.elapsedMilliseconds,
      loc: res.headers.value('location'),
    );
  } catch (e) {
    final m = '$e'.split('\n').first;
    return (code: -1, body: 'ERR ${m.length > 110 ? m.substring(0, 110) : m}', ms: sw.elapsedMilliseconds, loc: null);
  } finally {
    client.close(force: true);
  }
}

/// 从首页 HTML 抓 cdndefend 的 PoW 参数
void _dump(url, r, {int limit = 200}) {
  final flat = r.body.replaceAll(RegExp(r'\s+'), ' ');
  print('  $url');
  print('    HTTP ${r.code}  ${r.ms}ms  ${r.body.length} B'
      '${r.loc != null ? "  → ${r.loc}" : ""}');
  print('    ${flat.substring(0, flat.length > limit ? limit : flat.length)}');
}

void main() async {
  const base = 'https://www.keke1.app';
  print('══ 走 127.0.0.1:7897 重新验证 ══');
  print('');

  final home = await _get('$base/');
  _dump('$base/', home, limit: 300);

  // cdndefend 挑战页特征
  if (home.code == 200) {
    final isChallenge = home.body.contains('cdndefend') ||
        home.body.contains('sha1') ||
        home.body.contains('__cdn');
    print('    cdndefend 挑战页: ${isChallenge ? "是（需要解 PoW）" : "否（直接给了内容）"}');
  }
  print('');

  // 分类页：用户截图里打开的就是 /channel/6.html
  print('── 分类页 /channel/6.html（用户截图那一页）──');
  final ch = await _get('$base/channel/6.html', referer: '$base/');
  _dump('/channel/6.html', ch, limit: 200);
  if (ch.code == 200) {
    final details = RegExp(r'href="/detail/(\d+)\.html"').allMatches(ch.body).length;
    final vTitles = RegExp(r'class="v-item-title"').allMatches(ch.body).length;
    // 封面：模板用 data-original / data-src / src
    final covers = RegExp(
      r'(?:data-original|data-src|src)="(https?://[^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"',
      caseSensitive: false,
    ).allMatches(ch.body).map((m) => m.group(1)!).toList();
    final uniqCovers = covers.toSet();
    print('    /detail/ 链接 ${details} 个');
    print('    v-item-title ${vTitles} 个');
    print('    封面 URL ${covers.length} 个（去重 ${uniqCovers.length}）');
    for (final c in uniqCovers.take(3)) {
      print('      $c');
    }
  }
  print('');

  // 详情页
  final ids = RegExp(r'href="/detail/(\d+)\.html"')
      .allMatches(ch.body)
      .map((m) => m.group(1)!)
      .toList();
  if (ids.isNotEmpty) {
    final id = ids.first;
    print('── 详情页 /detail/$id.html ──');
    final d = await _get('$base/detail/$id.html', referer: '$base/channel/6.html');
    _dump('/detail/$id.html', d, limit: 160);
    if (d.code == 200) {
      final labels = RegExp(r'source-item-label">([^<]*)<')
          .allMatches(d.body)
          .map((m) => m.group(1)!)
          .toList();
      final plays = RegExp(r'href="(/play/(\d+)-(\d+)-(\d+)\.html)"').allMatches(d.body).length;
      print('    线路标签: $labels');
      print('    /play/ 链接 ${plays} 个');

      // 播放页
      final playPath = RegExp(r'href="(/play/\d+-\d+-\d+\.html)"')
          .firstMatch(d.body)
          ?.group(1);
      if (playPath != null) {
        print('');
        print('── 播放页 $playPath ──');
        final p = await _get('$base$playPath', referer: '$base/detail/$id.html');
        _dump(playPath, p, limit: 100);
        final m = RegExp(r'src\s*:\s*"([^"]+)"').firstMatch(p.body);
        final src = (m?.group(1) ?? '').replaceAll(r'\/', '/');
        print('    playSource.src = ${src.isEmpty ? "<未找到>" : src}');
      }
    }
  } else {
    print('分类页没解析出 /detail/ 链接');
  }
}