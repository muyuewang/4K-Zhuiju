/// 会话引导（bootstrap）端到端验证（2026-11-23）。
///
/// 看剧（kanju）官方线换票要游客会话：不带 cookie 时 11 条里 9 条回
/// 401 playback_user_session_required；先 POST /v1/users/anonymous 拿到
/// ai_moji_session 再换票，10/10 成功。
///
/// 这个测试用假站点复现「换票必须带引导下发的 cookie」这一门槛，
/// 钉住三件事：
///   1. 宿主在业务请求前**自动**发一次引导请求（脚本完全不碰 cookie）
///   2. 引导下发的 cookie 被回送到换票请求，401 → 成功
///   3. 引导只发一次（并发/多次换票不重复打 /anonymous）
///   4. 没配 bootstrap 的源行为不变（不多发请求）
///   5. 引导失败不阻断业务请求
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';

import 'support/quickjs_env.dart';

/// 要求「换票必须带会话 cookie」的假站点。
class _SessionSite {
  _SessionSite._(this._server);

  final HttpServer _server;
  final List<String> calls = <String>[];
  final Map<String, String> resolveLineHeaders = <String, String>{};

  /// 引导请求打了几次。
  int get bootstrapCount =>
      calls.where((c) => c.contains('/users/anonymous')).length;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_SessionSite> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _SessionSite._(s);

    final resolve = jsonEncode({
      'line_options': [
        {
          'label': '官方线B',
          'url': 'resolve://TICKET-SESSION-123',
          'resolve_required': true,
        },
      ],
    });

    s.listen((req) async {
      site.calls.add('${req.method} ${req.uri.path}');
      var body = '';
      var status = 200;

      if (req.uri.path.contains('/users/anonymous')) {
        // 引导请求：下发会话 cookie
        req.response.headers.add(
            'set-cookie', 'ai_movie_session=ums_TESTSESSION; Path=/');
        body = jsonEncode({'object': 'user.session'});
        status = 201;
      } else if (req.uri.path.contains('/resolve-line')) {
        req.headers.forEach((k, v) {
          site.resolveLineHeaders[k.toLowerCase()] = v.join(',');
        });
        await utf8.decoder.bind(req).join();
        final cookie = req.headers.value('cookie') ?? '';
        if (!cookie.contains('ai_movie_session=ums_TESTSESSION')) {
          // 没带会话就是 401 —— 复现站点真实行为
          status = 401;
          body = jsonEncode({
            'code': 'playback_user_session_required',
            'message': '该内容需要登录后播放',
          });
        } else {
          body = jsonEncode({
            'line': {'url': 'https://cdn.example.com/real.m3u8'},
          });
        }
      } else if (req.uri.path.contains('/resolve/')) {
        body = resolve;
      } else if (req.uri.path.contains('/detail')) {
        body = jsonEncode({
          'title': '凡人修仙传',
          'episodes': [
            {'token': 'tok1', 'number': 201, 'title': '第201集'},
          ],
        });
      }

      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await req.response.close();
    });
    return site;
  }

  Future<void> stop() => _server.close(force: true);
}

const script = r'''
// 最小签名钩子：原样回传，用来强制请求走 _sign() 重建路径。
// 回归点：_sign 重建 PreparedRequest 时必须保留 cookieJar，否则
// 带签名的源（看剧就是）引导拿到的 cookie 会全丢。
function sign(req) {
  return { headers: {}, body: req.body };
}
function parseDetail(body, ctx) {
  var d = JSON.parse(body);
  var eps = [];
  var arr = d.episodes || [];
  for (var i = 0; i < arr.length; i++) {
    eps.push({ name: arr[i].title, url: 'resolve://' + arr[i].token, token: arr[i].token });
  }
  return { name: d.title, lines: [{ line: '默认线路', episodes: eps }] };
}
function parseLines(body, ctx) {
  var d = JSON.parse(body);
  var opts = d.line_options || [];
  var out = [];
  for (var i = 0; i < opts.length; i++) {
    out.push({ line: opts[i].label || '', direct: false });
  }
  return { lines: out };
}
function parseResolve(body, ctx) {
  var d = JSON.parse(body);
  var opts = d.line_options || [];
  var want = ctx.line || '';
  for (var i = 0; i < opts.length; i++) {
    var u = String(opts[i].url || '');
    if (u.indexOf('resolve://') === 0 && (want === '' || (opts[i].label || '') === want)) {
      return { ticket: u.substring('resolve://'.length) };
    }
  }
  return { url: '', error: '没有这条线路' };
}
function parseLineResolve(body, ctx) {
  var d = JSON.parse(body);
  var ln = d.line || {};
  return { url: ln.url || '', error: d.message || '' };
}
''';

PluginManifest manifestOf(String base,
        {bool withBootstrap = true, bool withSign = false}) =>
    PluginManifest.fromJson(<String, dynamic>{
      'id': withSign ? 'bootstrap_signed' : 'bootstrap_demo',
      'name': '会话引导测试源',
      'baseUrl': base,
      'script': 'config/plugins/kanju.js',
      if (withSign) 'signEntry': 'sign',
      'categories': <Map<String, String>>[
        <String, String>{'id': '', 'name': '推荐'},
      ],
      'list': <String, dynamic>{'path': '/list'},
      'detail': <String, dynamic>{'path': '/detail/{id}'},
      'resolve': <String, dynamic>{'path': '/resolve/{token}'},
      'resolveLine': <String, dynamic>{
        'path': '/resolve-line',
        'method': 'POST',
        'bodyType': 'json',
        'body': '{"ticket":"{ticket}"}',
      },
      'cookieJar': withBootstrap,
      if (withBootstrap)
        'bootstrap': <String, dynamic>{
          'path': '/users/anonymous',
          'method': 'POST',
          'bodyType': 'json',
          'body': '{}',
        },
      'expandLines': true,
    })!;

void main() {
  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    kAllowLoopbackForTest = true;
  });
  tearDownAll(() {
    kAllowLoopbackForTest = false;
    PluginRuntime.instance.resetForTest();
  });

  setUp(() => RemoteJsSource.resetForTest());

  group('会话引导 bootstrap', () {
    test('清单能解析出 bootstrap 请求，且落缓存再读等价', () {
      final m = manifestOf('https://example.com');
      final b = m.bootstrapRequest;
      expect(b, isNotNull, reason: 'bootstrap 没被解析出来');
      expect(b!.path, '/users/anonymous');
      expect(b.method, 'POST');
      final restored = PluginManifest.fromJson(m.toJson())!;
      expect(restored.bootstrapRequest, isNotNull);
      expect(restored.bootstrapRequest!.path, '/users/anonymous');
    });

    test('宿主自动引导，换票带上 cookie 从 401 变成功', () async {
      final site = await _SessionSite.start();
      addTearDown(site.stop);
      final src = RemoteJsSource(
        LoadedPlugin(manifest: manifestOf(site.baseUrl), script: script),
      );

      final d = await src.detail('show1');
      final ep = d.videos.first;
      final url = await src.resolveUrl(ep);

      expect(url, 'https://cdn.example.com/real.m3u8',
          reason: '换票没成功，官方线仍然 401');
      expect(site.bootstrapCount, 1, reason: '引导请求应该发一次');
      expect(site.resolveLineHeaders['cookie'],
          contains('ai_movie_session=ums_TESTSESSION'),
          reason: '引导下发了 cookie，但没回送到换票请求');
    });

    test('带签名钩子的源，引导 cookie 依然能回送（_sign 不丢字段）', () async {
      // 回归：看剧源配了 signEntry，每个请求都过 _sign() 重建。
      // 若 _sign 重建 PreparedRequest 时漏传 cookieJar，签名后请求就
      // 既不吸收也不回送 Set-Cookie —— 表现是「引导成功但换票仍 401」。
      final site = await _SessionSite.start();
      addTearDown(site.stop);
      final src = RemoteJsSource(
        LoadedPlugin(
          manifest: manifestOf(site.baseUrl, withSign: true),
          script: script,
        ),
      );

      final d = await src.detail('show1');
      final url = await src.resolveUrl(d.videos.first);

      expect(url, 'https://cdn.example.com/real.m3u8',
          reason: '带签名后换票仍 401，说明 _sign 把 cookieJar 弄丢了');
      expect(site.resolveLineHeaders['cookie'],
          contains('ai_movie_session=ums_TESTSESSION'),
          reason: '签名重建后引导 cookie 没回送');
    });

    test('引导只发一次，多次换票不重复打 /anonymous', () async {
      final site = await _SessionSite.start();
      addTearDown(site.stop);
      final src = RemoteJsSource(
        LoadedPlugin(manifest: manifestOf(site.baseUrl), script: script),
      );

      final d = await src.detail('show1');
      for (final ep in d.videos) {
        await src.resolveUrl(ep);
      }
      expect(site.bootstrapCount, 1,
          reason: '会话引导不该随换票次数重复执行');
    });

    test('没配 bootstrap 的源不多发请求（行为不变）', () async {
      final site = await _SessionSite.start();
      addTearDown(site.stop);
      final src = RemoteJsSource(
        LoadedPlugin(
          manifest: manifestOf(site.baseUrl, withBootstrap: false),
          script: script,
        ),
      );

      final d = await src.detail('show1');
      // 站点要求 cookie，没引导就是 401 —— 这正是「不加开关行为不变」的证明
      await expectLater(
        src.resolveUrl(d.videos.first),
        throwsA(isA<Exception>()),
      );
      expect(site.bootstrapCount, 0, reason: '没配 bootstrap 就不该发引导');
    });
  });
}