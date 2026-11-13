/// HLS 代理「多级清单展开」回归（不联网，本地起 HTTP 服务模拟源站）。
///
/// ## 锁的是什么
///
/// 视频站的 HLS 几乎都是 **两级** 结构：
///
/// ```
/// master.m3u8                     ← 只有码率列表，条目是「子清单」不是分片
///   └─ 2000k_1080/index.m3u8      ← 真正的分片清单
///        ├─ seg0.ts
///        └─ seg1.ts
/// ```
///
/// 旧实现的 `_playlist` 把 master 里的**每个条目都当分片**转发，
/// 于是子清单被原样回给播放器；而子清单里是相对地址（`yWHIK20hUu.ts`），
/// 播放器会以 `http://127.0.0.1:port/hls/<tok>/seg/0/` 为基址去拼，
/// 请求必然落到一个不存在的位置 —— 表现就是**点了播放一直转圈**。
///
/// 片库 4K 的电影线路正是这个形态（实测 master 仅 101 字节、1 个条目，
/// 子清单 451 KB、2679 个分片）。所以这个测试用的是同样的形状。
///
/// ## 为什么用本地服务而不是真实源站
///
/// 真实源站的签名分片有时效，写进测试必然过期；而且 CI 无网。
/// 本地服务能精确构造「相对地址 + 多级」这两个关键特征，
/// 跑得快、结果稳定，能真正当回归用。
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
    // 本文件测的是**代理内部**的多级清单展开，而本地服务天然可直连。
    // 不关掉直连优先，wrap() 会原样返回地址，代理不介入，断言全落空。
    HlsProxy.debugForceProxy = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';

    server.listen((req) async {
      final p = req.uri.path;
      final res = req.response;
      if (p == '/master.m3u8') {
        // 刻意用相对地址，和片库真实形态一致
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n'
            '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=128,'
            'RESOLUTION=1920x800\n'
            'hd/index.m3u8\n');
        await res.close();
        return;
      }
      if (p == '/hd/index.m3u8') {
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2.000,\n'
            'seg-a.ts\n'
            '#EXTINF:2.000,\n'
            'seg-b.ts\n'
            '#EXTINF:2.000,\n'
            'seg-c.ts\n'
            '#EXT-X-ENDLIST\n');
        await res.close();
        return;
      }
      if (p.startsWith('/hd/') && p.endsWith('.ts')) {
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

  /// 直接用 dart:io 拉一遍代理地址，返回 (状态码, 文本)
  Future<(int, String)> get(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final r = await c.getUrl(Uri.parse(url));
      final resp = await r.close();
      final bytes = await resp.fold<List<int>>(
          <int>[], (a, d) => a..addAll(d));
      return (resp.statusCode, String.fromCharCodes(bytes));
    } finally {
      c.close(force: true);
    }
  }

  test('master 里的子清单要被展开，而不是当分片转发', () async {
    final wrapped = await HlsProxy.instance.wrap('$origin/master.m3u8');
    expect(wrapped, contains('127.0.0.1'), reason: 'm3u8 应该被代理接管');

    // 第一层：master 只有 1 个条目，指向代理自己的 seg/0
    final (st1, body1) = await get(wrapped);
    expect(st1, 200);
    final l1 = body1
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith('http'))
        .toList();
    expect(l1.length, 1, reason: 'master 只有一个码率条目');

    // 关键断言：请求那个「条目」时，拿回来的必须还是一份清单
    // （旧实现会把它当 .ts 转发，于是这里拿到的是二进制分片内容）
    final (st2, body2) = await get(l1.first);
    expect(st2, 200);
    expect(body2, startsWith('#EXTM3U'),
        reason: '子清单必须被展开后返回，不能把子清单原文当分片转发');

    final segs = body2
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith('http'))
        .toList();
    expect(segs.length, 3, reason: '子清单里 3 个分片都要改写成代理地址');

    // 每个分片地址都必须是代理自己的绝对地址，不能再有相对路径
    for (final s in segs) {
      expect(s, startsWith('http://127.0.0.1:'),
          reason: '分片必须改写为代理绝对地址，否则播放器会拿代理当基址拼错');
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('展开后能真正取到分片字节', () async {
    final wrapped = await HlsProxy.instance.wrap('$origin/master.m3u8');
    final (_, body1) = await get(wrapped);
    final variant = body1
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.startsWith('http'));
    final (_, body2) = await get(variant);
    final seg = body2
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.startsWith('http'));

    // 拿原始字节，确认是 MPEG-TS 同步字节而不是文本
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final r = await c.getUrl(Uri.parse(seg));
      final resp = await r.close();
      final bytes =
          await resp.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
      expect(resp.statusCode, 200);
      expect(bytes.first, 0x47, reason: 'MPEG-TS 分片第一个字节应为 0x47');
      expect(bytes.length, _fakeTs.length);
    } finally {
      c.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('重复请求同一子清单不会让分片表无限增长', () async {
    final wrapped = await HlsProxy.instance.wrap('$origin/master.m3u8');
    final (_, body1) = await get(wrapped);
    final variant = body1
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.startsWith('http'));

    // 反复展开同一份子清单：去重生效时，序号应保持稳定
    final (_, first) = await get(variant);
    final (_, second) = await get(variant);
    final (_, third) = await get(variant);

    List<String> segsOf(String b) => b
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith('http'))
        .toList();

    expect(segsOf(second), segsOf(first),
        reason: '同一份子清单再展开一次，分片地址（含序号）必须完全一致');
    expect(segsOf(third), segsOf(first),
        reason: '多次展开不能让序号漂移，否则会话里的 segments 会无限膨胀');
  }, timeout: const Timeout(Duration(minutes: 1)));
}