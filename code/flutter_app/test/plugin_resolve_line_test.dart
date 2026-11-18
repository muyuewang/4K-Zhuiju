/// 两阶段取址的端到端验证：第一次 resolve 只给票据，宿主必须再 POST 一次
/// 换票才拿得到真地址。
///
/// ## 为什么必须端到端
///
/// 这个 bug 的表现是「线路面板里没有官方线」。单测 parseLines 只能证明
/// 脚本返回了数组，证明不了宿主会不会：
///   1. 把 `{ticket}` 真的填进 POST body 发出去；
///   2. 从 `{"line":{"url":...}}` 里正确取地址；
///   3. 在该线路不需要换票时**不**多发一次请求。
///
/// 三条里任何一条错，用户看到的现象都是「点官方线播不了」，而日志
/// 里只有一句「没能解析出播放地址」——离真正的原因很远。
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

/// 一个会记录「收到哪些请求、body 是什么」的假站点。
class _TwoPhaseSite {
  _TwoPhaseSite._(this._server);

  final HttpServer _server;

  /// 每条请求的 `METHOD path`，用来断言「有没有多发请求」。
  final List<String> calls = <String>[];

  /// 换票接口收到的 ticket，用来断言占位符真的被替换了。
  final List<String> tickets = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_TwoPhaseSite> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _TwoPhaseSite._(s);

    final detail = jsonEncode({
      'title': '沙海',
      'episodes': [
        {'token': 'tok1', 'number': 1, 'title': '第1集'},
      ],
    });

    final resolve = jsonEncode({
      'line_options': [
        {
          // 普通线：直出 m3u8，不需要换票
          'label': '普通线A', 'play_from': 'p1',
          'url': 'https://cdn.example.com/p1/index.m3u8',
          'resolve_required': false,
        },
        {
          // 官方线：给票据，要 POST 换票
          'label': '官方线B', 'play_from': 'off',
          'url': 'resolve://TICKET-ABC-123',
          'resolve_required': true,
        },
      ],
    });

    s.listen((req) async {
      site.calls.add('${req.method} ${req.uri.path}');
      var body = detail;
      if (req.uri.path.contains('/resolve-line')) {
        final raw = await utf8.decoder.bind(req).join();
        try {
          final m = jsonDecode(raw) as Map;
          site.tickets.add('${m['ticket']}');
        } catch (_) {
          site.tickets.add('<unparsable:$raw>');
        }
        body = jsonEncode({
          'object': 'playback.line.resolve',
          // 站点真实结构：地址埋在 line.url 里
          'line': {
            'label': '官方线B',
            'url': 'https://v26-custom0009.onewsvod.com/real.mp4?a=1',
            'resolved': true,
            'resolve_required': false,
          },
        });
      } else if (req.uri.path.contains('/resolve/')) {
        body = resolve;
      }
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

  // 极简脚本：模拟「官方线给票据、普通线给地址」的最小心智模型。
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
    out.push({ line: opts[i].label });
  }
  return { lines: out };
}
function parseResolve(body, ctx) {
  var d = JSON.parse(body);
  var opts = d.line_options || [];
  var want = ctx.line || '';
  for (var i = 0; i < opts.length; i++) {
    if ((opts[i].label || '') !== want) continue;
    var u = String(opts[i].url);
    if (u.indexOf('resolve://') === 0) {
      return { ticket: u.substring('resolve://'.length) };
    }
    return { url: u };
  }
  return { url: '', error: '没有这条线路' };
}
function parseLineResolve(body, ctx) {
  var d = JSON.parse(body);
  var ln = d.line || {};
  return { url: ln.url || '' };
}
''';

  PluginManifest manifestOf(String base, {bool withResolveLine = true}) =>
      PluginManifest.fromJson(<String, dynamic>{
        'id': 'twophase_demo',
        'name': '两阶段测试源',
        'baseUrl': base,
        'script': 'config/plugins/kanju.js',
        'categories': <Map<String, String>>[
          <String, String>{'id': '', 'name': '推荐'},
        ],
        'list': <String, dynamic>{'path': '/list'},
        'detail': <String, dynamic>{'path': '/detail/{id}'},
        'resolve': <String, dynamic>{'path': '/resolve/{token}'},
        if (withResolveLine)
          'resolveLine': <String, dynamic>{
            'path': '/resolve-line',
            'method': 'POST',
            'bodyType': 'json',
            'query': <String, String>{'view': 'compact'},
            'body': '{"ticket":"{ticket}"}',
          },
        'expandLines': true,
      })!;

  test('清单能解析出 resolveLine 端点，方法/body 都保留', () {
    final m = manifestOf('https://example.com');
    final rl = m.resolveLineRequest;
    expect(rl, isNotNull, reason: 'resolveLine 没被解析出来，换票永远发不出去');
    expect(rl!.method, 'POST');
    expect(rl.isJsonBody, isTrue, reason: 'JSON 体不能退化成表单');
    expect(rl.query['view'], 'compact');
    expect(rl.body, contains('{ticket}'));
    // 落缓存再读回来必须等价，否则重启后换票就失效了
    final restored = PluginManifest.fromJson(m.toJson())!;
    expect(restored.resolveLineRequest, isNotNull);
    expect(restored.resolveLineRequest!.method, 'POST');
    expect(restored.resolveLineRequest!.body, contains('{ticket}'));
  });

  test('官方线：宿主自动 POST 换票，占位符被真实 ticket 替换', () async {
    final site = await _TwoPhaseSite.start();
    addTearDown(site.stop);
    final src = RemoteJsSource(
      LoadedPlugin(manifest: manifestOf(site.baseUrl), script: script),
    );

    final d = await src.detail('show1');
    // 修复后两条线路都要在线路面板里出现
    expect(d.videos.map((v) => v.sourceCn).toSet(), {'普通线A', '官方线B'},
        reason: '官方线必须出现在线路面板里，否则用户看不到它');

    final official = d.videos.firstWhere((v) => v.sourceCn == '官方线B');
    final url = await src.resolveUrl(official);

    expect(url, 'https://v26-custom0009.onewsvod.com/real.mp4?a=1',
        reason: '没从 {"line":{"url":...}} 里取到地址');
    expect(site.tickets, ['TICKET-ABC-123'],
        reason: 'POST body 里的 {ticket} 没被替换成真实票据');
    expect(site.calls.where((c) => c.contains('/resolve-line')).length, 1);
  });

  test('普通线：一步到位，不多发换票请求', () async {
    final site = await _TwoPhaseSite.start();
    addTearDown(site.stop);
    final src = RemoteJsSource(
      LoadedPlugin(manifest: manifestOf(site.baseUrl), script: script),
    );

    final d = await src.detail('show1');
    final normal = d.videos.firstWhere((v) => v.sourceCn == '普通线A');
    final url = await src.resolveUrl(normal);

    expect(url, 'https://cdn.example.com/p1/index.m3u8');
    // 多一次 POST 就是多 300~800ms，普通线不该付这个代价
    expect(site.calls.where((c) => c.contains('/resolve-line')), isEmpty,
        reason: '普通线不需要换票，不该发第二次请求');
    expect(site.tickets, isEmpty);
  });

  test('清单没配 resolveLine 时，票据要报错而不是塞给播放器', () async {
    final site = await _TwoPhaseSite.start();
    addTearDown(site.stop);
    final src = RemoteJsSource(
      LoadedPlugin(
        manifest: manifestOf(site.baseUrl, withResolveLine: false),
        script: script,
      ),
    );

    final d = await src.detail('show1');
    final official = d.videos.firstWhere((v) => v.sourceCn == '官方线B');
    // resolve:// 直接进播放器会崩，必须在宿主这层拦住
    await expectLater(
      () => src.resolveUrl(official),
      throwsA(isA<PluginFetchException>()),
    );
  });
}