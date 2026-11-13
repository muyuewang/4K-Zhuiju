/// HLS 代理「直连优先」回归（不联网，本地起 HTTP 服务模拟源站）。
///
/// ## 锁的是什么
///
/// 用户实测（2026-11-13）报 PC 版播放 m3u8 慢到超时，而浏览器、雷电模拟器
/// 都很快。三者唯一的差别是：**只有桌面端多绕了这一层中转**。
///
/// 中转层本身是为「libmpv 不读系统代理」加的，但它把本来不需要代理的源也
/// 一起接管了，代价是串行转发：实测电影天堂《凡人修仙传》同一批分片经中转
/// 只有 208 KB/s，而该流码率约 375 KB/s —— 低于码率就必然一直转圈。
///
/// 修法不是把中转优化到极致，而是**能直连就不进中转**，把取流交还给
/// libmpv 自己的并行预读。
///
/// 这组断言锁三件事：
///   1. 源站可直连  → `wrap` 原样返回地址（不进中转）
///   2. 源站不可直连 → `wrap` 返回代理地址（进中转，代理源靠这条活）
///   3. 同一 host 不同端口分别判定（缓存按 origin 分，不按 host 串味）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/hls_proxy.dart';

void main() {
  late HttpServer server;
  late String origin;

  /// 该服务上是否返回一份合法清单。改它就能模拟「这个源能不能用」。
  var servePlaylist = true;

  setUp(() async {
    // 每个用例都从「直连优先开着」的干净状态开始
    HlsProxy.debugForceProxy = false;
    servePlaylist = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/v/index.m3u8' && servePlaylist) {
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n'
            '#EXTINF:3.0,\n'
            '0.ts\n'
            '#EXT-X-ENDLIST\n');
        await res.close();
        return;
      }
      // 非清单：模拟「这个地址取不到东西」的源站
      res.statusCode = HttpStatus.notFound;
      await res.close();
    });
  });

  tearDown(() async {
    HlsProxy.debugForceProxy = false;
    await HlsProxy.instance.shutdown();
    await server.close(force: true);
  });

  /// 代理地址的形态是 `http://127.0.0.1:<port>/hls/<token>/index.m3u8`，
  /// 而源站也在 127.0.0.1 上，光看 host 分辨不出来，必须看路径。
  bool isProxied(String url) => url.contains('/hls/');

  group('直连优先', () {
    test('源站能直连时，wrap 原样返回地址（不进中转）', () async {
      final src = '$origin/v/index.m3u8';
      final wrapped = await HlsProxy.instance.wrap(src);
      expect(wrapped, src,
          reason: '能直连还进中转，就会重新落回 208KB/s 的串行瓶颈');
      expect(isProxied(wrapped), isFalse);
    });

    test('源站取不到清单时，wrap 返回代理地址（继续走中转）', () async {
      servePlaylist = false;
      final src = '$origin/v/index.m3u8';
      final wrapped = await HlsProxy.instance.wrap(src);
      expect(isProxied(wrapped), isTrue,
          reason: '直连判定太激进会让四个必须走代理的源全部失效');
    });

    test('地址压根连不上时，wrap 返回代理地址而不是抛异常', () async {
      // 127.0.0.1:1 在本机不会有服务在听，连接会被立刻拒绝。
      // 这里要的是「探测失败走预期分支」，不是错误处理。
      const src = 'http://127.0.0.1:1/v/index.m3u8';
      final wrapped = await HlsProxy.instance.wrap(src);
      expect(isProxied(wrapped), isTrue);
    });

    test('debugForceProxy 打开时，能直连也强制进中转', () async {
      // 三组代理内部行为的回归（AES 解密 / 302 基准 / 多级展开）
      // 全靠这个开关才有意义，必须单独锁住。
      HlsProxy.debugForceProxy = true;
      final src = '$origin/v/index.m3u8';
      final wrapped = await HlsProxy.instance.wrap(src);
      expect(isProxied(wrapped), isTrue);
    });

    test('非 m3u8 与非法地址一律原样返回', () async {
      const mp4 = 'https://a.com/v/movie.mp4';
      expect(await HlsProxy.instance.wrap(mp4), mp4);
      const notUrl = 'ftp://a.com/x.m3u8';
      expect(await HlsProxy.instance.wrap(notUrl), notUrl,
          reason: '非 http(s) 不该被接管');
      expect(await HlsProxy.instance.wrap(''), '');
    });
  });

  group('直连判定缓存', () {
    test('同一 host 不同端口分别判定，不会互相串味', () async {
      // 先用一个必然连不上的端口把「127.0.0.1 不可直连」写进缓存，
      // 再探一个真的可直连的端口。若缓存键只按 host，
      // 第二个会被前一次的结论污染，误判成「不能直连」。
      const dead = 'http://127.0.0.1:1/v/index.m3u8';
      expect(isProxied(await HlsProxy.instance.wrap(dead)), isTrue);

      final alive = '$origin/v/index.m3u8';
      expect(await HlsProxy.instance.wrap(alive), alive,
          reason: '缓存按 origin 分，同 host 不同端口不得共享结论');
    });

    test('同一 origin 第二次不再重复探测（判定结果被复用）', () async {
      final src = '$origin/v/index.m3u8';
      expect(await HlsProxy.instance.wrap(src), src);
      // 第二次把源站改成 404：若还在探测就会改判成「不可直连」，
      // 没探测则继续用缓存里的结论。
      servePlaylist = false;
      expect(await HlsProxy.instance.wrap(src), src);
    });

    test('shutdown 之后缓存被清空，会重新探测', () async {
      final src = '$origin/v/index.m3u8';
      expect(await HlsProxy.instance.wrap(src), src);
      await HlsProxy.instance.shutdown();
      servePlaylist = false;
      expect(isProxied(await HlsProxy.instance.wrap(src)), isTrue,
          reason: '用户开关代理后可达性会变，结论不能跨会话留存');
    });
  });

  group('分片转发（经中转时）', () {
    test('源站第一次直接掐断连接，重试一次后仍能取到分片', () async {
      // _relay 的重试只对「还没写响应体」的失败生效。源站一个字节都不给
      // 就断开，正是这种情况——这是实测里最常见的一次性故障
      // （`Connection closed before full header was received`）。
      var hits = 0;
      final flaky = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final flakyOrigin = 'http://127.0.0.1:${flaky.port}';
      final ts = <int>[0x47, 0x40, 0x11, 0x10, ...List<int>.filled(184, 0)];

      flaky.listen((req) async {
        final res = req.response;
        if (req.uri.path == '/v/index.m3u8' || req.uri.path == '/v/hd.m3u8') {
          res.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          res.write('#EXTM3U\n#EXTINF:3.0,\n0.ts\n#EXT-X-ENDLIST\n');
          await res.close();
          return;
        }
        if (req.uri.path == '/v/0.ts') {
          hits++;
          if (hits == 1) {
            // 不写任何响应头就断：客户端拿不到状态行，
            // bodyStarted 仍为 false，重试是安全的。
            final s = await res.detachSocket(writeHeaders: false);
            s.destroy();
            return;
          }
          res.headers.contentType = ContentType('video', 'mp2t');
          res.add(ts);
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.notFound;
        await res.close();
      });

      // 直连探测会成功（清单能取到），所以必须强制走中转才能测到 _relay
      HlsProxy.debugForceProxy = true;
      final wrapped = await HlsProxy.instance.wrap('$flakyOrigin/v/index.m3u8');
      expect(isProxied(wrapped), isTrue);

      final playlist = await _getText(wrapped);
      final segUrl = RegExp(r'http://127\.0\.0\.1:\d+/hls/\S+')
          .firstMatch(playlist)
          ?.group(0);
      expect(segUrl, isNotNull, reason: '清单里必须出现代理分片地址');

      List<int> bytes;
      try {
        bytes = await _getBytes(segUrl!);
      } catch (e) {
        fail('取分片失败（服务端 hits=$hits）：$e');
      }
      expect(hits, 2, reason: '第一次被掐断后必须重试一次');
      expect(bytes.length, ts.length);
      expect(bytes.first, 0x47, reason: '取回的内容要和源站一致');

      await flaky.close(force: true);
    });
  });
}

Future<String> _getText(String url) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final rq = await c.getUrl(Uri.parse(url));
    final rp = await rq.close();
    final bytes = await rp.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
    return String.fromCharCodes(bytes);
  } finally {
    c.close(force: true);
  }
}

Future<List<int>> _getBytes(String url) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final rq = await c.getUrl(Uri.parse(url));
    final rp = await rq.close();
    final bytes = await rp.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
    return bytes;
  } finally {
    c.close(force: true);
  }
}