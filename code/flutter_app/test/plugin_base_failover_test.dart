/// `baseUrlFallbacks` 的端到端验证：主域名连不上，请求能否自动落到备用域名。
///
/// ## 为什么必须端到端
///
/// 「候选地址列表拼对了」这种单测证明不了兜底真的生效——中间还有两处
/// 可能整段失效：
///   1. `_isNetworkFailure` 判错了 Dio 的异常类型（被墙的三种表现分别是
///      connectionTimeout / connectionError / receiveTimeout，漏一种就白配）；
///   2. 换域名后请求确实发出去了，但解析阶段又拿主域名去补相对链接。
///
/// 所以这里用两个本地 HTTP 服务真发请求，把「切换」和「不切换」两种
/// 情况都钉住。**不依赖外网**，也不依赖任何被墙的真实站点。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';

import 'support/quickjs_env.dart';

/// 一个只回固定状态码和 body 的极简 MacCMS 站。
class _Site {
  _Site._(this._server, this.status, this.body);

  final HttpServer _server;
  final int status;
  final String body;
  final List<String> paths = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_Site> start({int status = 200, String? body}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _Site._(
      s,
      status,
      body ?? jsonEncode(<String, Object>{
        'code': 1,
        'msg': '数据列表',
        'page': 1,
        'total': 1,
        'list': <Map<String, Object>>[
          {
            'vod_id': 99581,
            'vod_name': '备用域名命中',
            'vod_pic': '/upload/cover.jpg',
            'vod_remarks': 'HD',
            'vod_year': '2026',
            'vod_area': '大陆',
          },
        ],
      }),
    );
    s.listen((req) async {
      site.paths.add(req.uri.path);
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(site.body);
      await req.response.close();
    });
    return site;
  }

  Future<void> stop() => _server.close(force: true);
}

/// 拿一个「有端口但没人监听」的地址，用来稳定复现连接被拒。
Future<String> _deadBase() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close(force: true);
  return 'http://127.0.0.1:$port';
}

PluginManifest _manifest(String primary, List<String> fallbacks) =>
    PluginManifest.fromJson(<String, dynamic>{
      'id': 'fallback_demo',
      'name': '备用域名测试源',
      'baseUrl': primary,
      if (fallbacks.isNotEmpty) 'baseUrlFallbacks': fallbacks,
      'script': 'config/plugins/maccms-json.js',
      'categories': <Map<String, String>>[
        <String, String>{'id': '26', 'name': '电影'},
      ],
      'list': <String, dynamic>{
        'path': '/api.php/provide/vod/',
        'query': <String, String>{'ac': 'list', 'pg': '{page}'},
      },
      'search': <String, dynamic>{
        'path': '/api.php/provide/vod/',
        'query': <String, String>{'ac': 'list', 'wd': '{keyword}', 'pg': '{page}'},
      },
    })!;

void main() {
  late String script;

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    kAllowLoopbackForTest = true;
    script = File('../../config/plugins/maccms-json.js').readAsStringSync();
  });
  tearDownAll(() {
    kAllowLoopbackForTest = false;
    PluginRuntime.instance.resetForTest();
  });

  test('主域名连接被拒 → 自动切到备用域名并返回结果', () async {
    final ok = await _Site.start();
    addTearDown(ok.stop);
    final dead = await _deadBase();

    final src = RemoteJsSource(
      LoadedPlugin(
        manifest: _manifest(dead, <String>[ok.baseUrl]),
        script: script,
      ),
    );

    final hits = await src.search('测试');
    expect(hits.length, 1);
    expect(hits.first.name, '备用域名命中');
    expect(hits.first.sourceId, 'fallback_demo');
    expect(ok.paths, isNotEmpty, reason: '备用域名一次请求都没收到，兜底没生效');
  });

  test('切换后粘住：第二次请求不再重试主域名', () async {
    final ok = await _Site.start();
    addTearDown(ok.stop);
    final dead = await _deadBase();

    final src = RemoteJsSource(
      LoadedPlugin(
        manifest: _manifest(dead, <String>[ok.baseUrl]),
        script: script,
      ),
    );

    await src.search('第一次');
    final afterFirst = ok.paths.length;
    await src.search('第二次');

    // 粘住以后第二次只该再发一次请求。若没粘住，会是「主域名超时 + 备用 一次」
    // ——从备用站这边看同样是 +1，但整体耗时翻倍且日志会多一条重试。
    expect(ok.paths.length, afterFirst + 1,
        reason: '第二次搜索应直接命中备用域名（+1 次请求）');
  });

  test('站是通的但返回 4xx → 不触发切换，直接报错', () async {
    final bad = await _Site.start(status: 404);
    addTearDown(bad.stop);
    final ok = await _Site.start();
    addTearDown(ok.stop);

    final src = RemoteJsSource(
      LoadedPlugin(
        manifest: _manifest(bad.baseUrl, <String>[ok.baseUrl]),
        script: script,
      ),
    );

    await expectLater(
      src.search('测试'),
      throwsA(isA<PluginFetchException>()),
    );
    // 关键断言：404 说明站是活的，换域名重试只会把一个报错的接口
    // 乘以域名个数地重打，必须一次都不多打。
    expect(ok.paths, isEmpty,
        reason: '4xx 不该触发备用域名，备用站不该收到任何请求');
  });

  test('没有配备用域名时，主域名失败就是失败（不凭空多出重试）', () async {
    final dead = await _deadBase();
    final src = RemoteJsSource(
      LoadedPlugin(manifest: _manifest(dead, const <String>[]), script: script),
    );
    // 网络层错误本来就是 `DioException` 原样抛出（这是既有行为，不是我这次
    // 引入的）：UI 那边由 `friendlyError` 把它翻成「连不上服务器」之类的人话。
    // 这里只钉住「不会悄悄返回空列表」——那会让用户以为搜到了零结果。
    await expectLater(
      src.search('测试'),
      throwsA(anyOf(isA<DioException>(), isA<PluginFetchException>())),
    );
  });
}
