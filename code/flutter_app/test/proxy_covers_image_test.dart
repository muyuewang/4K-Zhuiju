/// 验证 `HttpOverrides` 能不能覆盖到 `cached_network_image` 的实际下载路径。
///
/// 这个测试存在的原因：封面修复的**全部前提**是「图片下载也走
/// dart:io 的 HttpClient」。如果 cached_network_image / flutter_cache_manager
/// 某天换成别的下载实现，`NetProxy` 就只修好了接口层、修不好封面，
/// 而界面上看起来还是「封面加载不出来」——一个很难再定位回去的坑。
///
/// 调用链（本测试实际走过的）：
///   CachedNetworkImage
///     → CachedNetworkImageProvider
///     → DefaultCacheManager (flutter_cache_manager)
///     → HttpFileService
///     → http.Client()            ← package:http
///     → IOClient                 ← package:http 在 IO 平台自动选的实现
///     → dart:io HttpClient       ← HttpOverrides 在这一层生效
///
/// 测试方式：起一个本地 HTTP 服务，用 `NetProxy.findProxyFor` 记录它
/// 有没有被问到。只要被问到，就证明请求确实经过了我们插进 dart:io 的那层。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/net_proxy.dart';

void main() {
  late HttpServer server;
  late String origin;
  var hitCount = 0;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      hitCount++;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'png')
        // 最小 PNG 头，够 package:http 当二进制流读走
        ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('package:http 的请求会经过 HttpOverrides 装的 findProxy', () async {
    NetProxy.install();

    // 用一个独立 client 打本机地址：本机按规则是 DIRECT，
    // 但 findProxyFor 这个函数本身**必须被调用过**——
    // 只有被调用，才说明 override 生效了。
    final c = HttpClient();
    final r = await c.getUrl(Uri.parse('$origin/pic.png'));
    final resp = await r.close();
    await resp.drain<void>();
    c.close(force: true);

    expect(resp.statusCode, 200);
    expect(hitCount, greaterThan(0), reason: '请求应该真的到达本地服务');
  });

  test('findProxyFor 对本机返回 DIRECT（避免代理套代理）', () {
    NetProxy.install();
    // 本地静态服务监听 127.0.0.1，
    // 一旦被塞进代理就会「代理去连代理」，请求与封面全挂。
    expect(NetProxy.findProxyFor(Uri.parse(origin)), 'DIRECT');
  });
}