/// expandLines 的端到端验证：详情只给一条占位线路 + 每集 token，
/// 宿主必须先 resolve 第一集拿线路模板，再展开成多条可切换的线路。
///
/// 为什么必须端到端：这只_bug 的表现是「用户只看到一个默认线路」，
/// 单测 parseLines 只能证明脚本返回了数组，证明不了宿主真的调用了它、
/// 也证明不了展开后的线路在取址时会选中对应那条。
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

class _LineSite {
  _LineSite._(this._server);

  final HttpServer _server;
  final List<String> paths = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_LineSite> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _LineSite._(s);
    final detail = jsonEncode({
      'title': '沙海',
      'episodes': [
        {'token': 'tok1', 'number': 1, 'title': '第1集'},
        {'token': 'tok2', 'number': 2, 'title': '第2集'},
      ],
    });
    final resolve = jsonEncode({
      'line_options': [
        {
          'label': '红牛资源', 'play_from': 'hn',
          'url': 'https://cdn.example.com/hn/index.m3u8',
          'resolve_required': false,
        },
        {
          'label': '西瓜资源', 'play_from': 'xg',
          'url': 'https://cdn.example.com/xg/index.m3u8',
          'resolve_required': false,
        },
        {
          // 官方线：需二次换票，不该被展开
          'label': '官方V', 'play_from': 'huo',
          'url': 'resolve://ticket', 'resolve_required': true,
        },
      ],
    });
    s.listen((req) async {
      site.paths.add(req.uri.path);
      final body = req.uri.path.contains('/resolve/') ? resolve : detail;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(body);
      await req.response.close();
    });
    return site;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    kAllowLoopbackForTest = true;
  });
  tearDownAll(() {
    kAllowLoopbackForTest = false;
    PluginRuntime.instance.resetForTest();
  });

  const script = r'''
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
    if (opts[i].resolve_required === true) continue;
    if (String(opts[i].url).indexOf('http') !== 0) continue;
    out.push({ line: opts[i].label, label: opts[i].label });
  }
  return { lines: out };
}
function parseResolve(body, ctx) {
  var d = JSON.parse(body);
  var opts = d.line_options || [];
  var want = ctx.line || '';
  for (var i = 0; i < opts.length; i++) {
    if ((opts[i].label || '') === want && String(opts[i].url).indexOf('http') === 0) {
      return { url: opts[i].url };
    }
  }
  return { url: '' };
}
''';

  PluginManifest manifestOf(String base) => PluginManifest.fromJson(<String, dynamic>{
        'id': 'expand_demo',
        'name': '线路展开测试源',
        'baseUrl': base,
        'script': 'config/plugins/kanju.js',
        'categories': <Map<String, String>>[
          <String, String>{'id': '', 'name': '推荐'},
        ],
        'list': <String, dynamic>{
          'path': '/list',
          'query': <String, String>{'pg': '{page}'},
        },
        'detail': <String, dynamic>{'path': '/detail/{id}'},
        'resolve': <String, dynamic>{'path': '/resolve/{token}'},
        'expandLines': true,
      })!;

  test('详情展开成多条直出线路，官方线被跳过', () async {
    final site = await _LineSite.start();
    addTearDown(site.stop);
    final src = RemoteJsSource(
      LoadedPlugin(manifest: manifestOf(site.baseUrl), script: script),
    );

    final d = await src.detail('show1');
    // 2 条直出线 × 2 集 = 4 条视频；官方线不展开
    expect(d.videos.length, 4,
        reason: '期望 2 条线路 × 2 集，实际 ${d.videos.length}');
    final lines = d.videos.map((v) => v.sourceCn).toSet();
    expect(lines, {'红牛资源', '西瓜资源'});
    expect(lines, isNot(contains('官方V')));
    // 真实发过 resolve 请求（第一集）
    expect(site.paths.any((p) => p.contains('/resolve/')), isTrue,
        reason: '宿主没调 resolve 接口拿线路模板');
  });

  test('取址按选中的线路精确返回对应地址', () async {
    final site = await _LineSite.start();
    addTearDown(site.stop);
    final src = RemoteJsSource(
      LoadedPlugin(manifest: manifestOf(site.baseUrl), script: script),
    );

    final d = await src.detail('show1');
    final red = d.videos.firstWhere((v) => v.sourceCn == '红牛资源');
    final melon = d.videos.firstWhere((v) => v.sourceCn == '西瓜资源');
    expect(await src.resolveUrl(red), 'https://cdn.example.com/hn/index.m3u8');
    expect(await src.resolveUrl(melon), 'https://cdn.example.com/xg/index.m3u8');
  });

  test('dropIndirectLines 隐藏网页分享线，只留可播的直出线', () async {
    final site = await _LineSite.start();
    addTearDown(site.stop);
    // 用一个「详情给一条 m3u8 + 一条网页线、无 resolve」的脚本
    const mixedScript = r'''
function parseDetail(body, ctx) {
  return {
    name: '测试',
    lines: [
      { line: '网页线', episodes: [{ name: '第1集', url: 'https://x.com/share/abc' }] },
      { line: '直出线', episodes: [{ name: '第1集', url: 'https://x.com/a.m3u8' }] },
    ]
  };
}
''';
    final m = PluginManifest.fromJson(<String, dynamic>{
      'id': 'mixed',
      'name': '混合线路源',
      'baseUrl': site.baseUrl,
      'script': 'config/plugins/kanju.js',
      'categories': <Map<String, String>>[
        <String, String>{'id': '', 'name': '推荐'},
      ],
      'list': <String, dynamic>{'path': '/list'},
      'detail': <String, dynamic>{'path': '/detail/{id}'},
      'dropIndirectLines': true,
    })!;
    final src = RemoteJsSource(LoadedPlugin(manifest: m, script: mixedScript));
    final d = await src.detail('show1');
    expect(d.videos.length, 1, reason: '网页分享线应被隐藏');
    expect(d.videos.first.sourceCn, '直出线');
  });
}
