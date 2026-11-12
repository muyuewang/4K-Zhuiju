/// HLS 代理「清单 302 跳转」回归（不联网，本地起 HTTP 服务模拟源站）。
///
/// ## 锁的是什么
///
/// 直播源普遍是「一个接口 302 到真实清单」的形态，实测橘汁直播：
///
/// ```
/// /zb/cctv.php?token=...&id=cctv1&zy.m3u8
///   --302--> http://live-play-hls.cctvnews.cctv.com/CCTVChannel/channel_cctv1_mbd.m3u8?auth_key=...
///                 └─ 分片是相对地址：live-play.cctvnews..._mbd-xxx.ts?auth_key=...
/// ```
///
/// 旧实现的 `_playlist` 拿**重定向前的原始地址**当基准去 `resolve`
/// 那些相对分片，于是拼出 `http://110.42.52.180:6688/zb/live-play...ts`
/// —— 源站上根本没有这个路径，恒 404，播放器一直转圈。
/// 改成用**重定向后的最终地址**做基准，同一个分片立刻 200（实测 1.6MB、
/// 首字节 0x47）。
///
/// 这不是直播独有的问题：凡是「接口跳 CDN 真清单」的源都会踩，
/// 所以回归测试盯的是「基准必须是最终地址」这一条，而不是直播本身。
///
/// ## 为什么用本地服务
///
/// 真实源站的 token / auth_key 有时效，写进测试必然过期；CI 也无网。
/// 本地服务能精确构造「302 + 相对分片」这两个关键特征。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/hls_proxy.dart';

/// 最小的 .ts 假分片：magic 用真的 MPEG-TS 同步字节 0x47，
/// 这样万一哪天顺手加了格式校验也不会误判。
final List<int> _fakeTs = <int>[
  0x47, 0x40, 0x11, 0x10, ...List<int>.filled(184, 0),
];

void main() {
  late HttpServer server;
  late String origin;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';

    server.listen((req) async {
      final p = req.uri.path;
      final res = req.response;

      // 「接口」：302 跳到 CDN 上的真清单（真清单不在本服务上，
      // 这里用同服务不同路径模拟，关键是**路径变了**）
      if (p == '/zb/cctv.php') {
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader, '/cdn/CCTVChannel/ch.m3u8');
        await res.close();
        return;
      }

      // 真清单：分片是**相对地址**，且带 query
      if (p == '/cdn/CCTVChannel/ch.m3u8') {
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-MEDIA-SEQUENCE:962385\n'
            '#EXT-X-TARGETDURATION:5\n'
            '#EXTINF:4.840,\n'
            'seg-0.ts?auth_key=abc123\n'
            '#EXTINF:4.000,\n'
            'seg-1.ts?auth_key=def456\n');
        await res.close();
        return;
      }

      // 分片只存在于真清单所在目录下
      if (p.startsWith('/cdn/CCTVChannel/') && p.endsWith('.ts')) {
        res.headers.contentType = ContentType('video', 'mp2t');
        res.add(_fakeTs);
        await res.close();
        return;
      }

      res.statusCode = HttpStatus.notFound;
      await res.close();
    });
  });

  tearDown(() async {
    await HlsProxy.instance.shutdown();
    await server.close(force: true);
  });

  Future<(int, List<int>)> getBytes(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final r = await c.getUrl(Uri.parse(url));
      final resp = await r.close();
      final bytes =
          await resp.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
      return (resp.statusCode, bytes);
    } finally {
      c.close(force: true);
    }
  }

  Future<List<String>> segsOf(String wrapped) async {
    final (_, bytes) = await getBytes(wrapped);
    return String.fromCharCodes(bytes)
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith('http'))
        .toList();
  }

  /// 入口地址必须与生产形态一致：**查询串里带 `zy.m3u8`**。
  ///
  /// `HlsProxy.wrap` 靠 [_looksLikeM3u8] 判断要不要接管，判据是
  /// 「路径以 .m3u8 结尾 或 URL 里含 .m3u8」。橘汁直播的真实地址形如
  /// `/zb/cctv.php?token=...&id=cctv1&zy.m3u8` —— 后缀挂在 query 上，
  /// 所以能被认出来。夹具若只写 `/zb/cctv.php` 就不会被接管，
  /// 测的就不是重定向逻辑了。
  const entry = '/zb/cctv.php?token=abc&id=cctv1&zy.m3u8';

  test('302 跳转后要能取到分片字节（基准必须是最终地址）', () async {
    final wrapped = await HlsProxy.instance.wrap('$origin$entry');
    expect(wrapped, contains('/hls/'), reason: 'm3u8 应该被代理接管');

    final segs = await segsOf(wrapped);
    expect(segs.length, 2, reason: '真清单里 2 个分片都要改写成代理地址');

    // 关键断言：经代理取分片必须 200 + 真分片字节。
    // 旧实现会拼成 /zb/seg-0.ts（不存在）→ 404。
    final (st, bytes) = await getBytes(segs.first);
    expect(st, 200, reason: '相对分片必须以重定向后的地址为基准，否则恒 404');
    expect(bytes.first, 0x47, reason: 'MPEG-TS 分片第一个字节应为 0x47');
    expect(bytes.length, _fakeTs.length);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('带 query 的相对分片要保留 auth_key', () async {
    // 直播分片几乎都带 auth_key，丢了就 403。
    final wrapped = await HlsProxy.instance.wrap('$origin$entry');
    final segs = await segsOf(wrapped);
    expect(segs, isNotEmpty);
    final (st, _) = await getBytes(segs.last);
    expect(st, 200, reason: '第二个分片同样要能取到');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('不跳转的普通清单行为不变', () async {
    // 回归保护：加了重定向处理之后，原本直连的清单不能被搞坏。
    final wrapped =
        await HlsProxy.instance.wrap('$origin/cdn/CCTVChannel/ch.m3u8');
    final segs = await segsOf(wrapped);
    expect(segs.length, 2);
    final (st, bytes) = await getBytes(segs.first);
    expect(st, 200);
    expect(bytes.first, 0x47);
  }, timeout: const Timeout(Duration(minutes: 1)));
}