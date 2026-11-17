/// 「站方没开放搜索」这个能力的验证。
///
/// 这只 bug 的用户可见表现是「搜出来一片空白」，跟「真的没搜到」长得一模
/// 一样，所以必须证明两件事：标记后**一个请求都不发**（否则用户等超时），
/// 且给出的那句话能解释原因（而不是复读「没找到 xx」）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/pages/home_page.dart';
import 'package:zhuiju/theme.dart';

/// 指向必然连不上的地址：只要宿主真的发了请求，抛出的就会是连接错误，
/// 而不是我们要验证的那句解释——这样"没发请求"就被断言住了。
const _deadBase = 'http://127.0.0.1:1';

PluginManifest _manifest({required bool blocked}) =>
    PluginManifest.fromJson(<String, dynamic>{
      'id': 'suoni_demo',
      'name': '索尼资源',
      'baseUrl': _deadBase,
      'script': 'config/plugins/maccms-json.js',
      'categories': <Map<String, String>>[
        <String, String>{'id': '', 'name': '推荐'},
      ],
      'list': <String, dynamic>{
        'path': '/api.php/provide/vod/',
        'query': <String, String>{'ac': 'list'},
      },
      'search': <String, dynamic>{
        'path': '/api.php/provide/vod/',
        'query': <String, String>{'ac': 'list', 'wd': '{keyword}'},
      },
      'detail': <String, dynamic>{'path': '/api.php/provide/vod/'},
      if (blocked) 'searchUnsupported': true,
    })!;

void main() {
  test('标记后 search 直接抛解释，且不发出那次注定被拦的请求', () async {
    final src = RemoteJsSource(
      LoadedPlugin(manifest: _manifest(blocked: true), script: 'function parseList(){return [];}'),
    );
    expect(src, isA<SearchUnsupported>());

    await expectLater(
      src.search('庆余年'),
      throwsA(isA<PluginFetchException>().having(
        (e) => e.message,
        'message',
        allOf(contains('索尼资源'), contains('没有开放搜索')),
      )),
    );
  });

  test('没标记的源：hint 为空，搜索照常走网络', () async {
    final src = RemoteJsSource(
      LoadedPlugin(manifest: _manifest(blocked: false), script: 'function parseList(){return [];}'),
    );
    // 空串 = 页面不该拦。这里不校验请求细节，只守住"别把能搜的源关掉"。
    expect((src as SearchUnsupported).searchUnsupportedHint, '');

    // 真进了请求层（宿主对回环地址的拦截会先拦下），说明没被"不支持搜索"短路。
    await expectLater(
      src.search('庆余年'),
      throwsA(isA<PluginFetchException>().having(
        (e) => e.message,
        'message',
        allOf(isNot(contains('没有开放搜索')), contains('源站地址不可用')),
      )),
    );
  });

  test('searchUnsupported 能往返序列化（配置同步后不丢）', () {
    final m = _manifest(blocked: true);
    expect(m.searchUnsupported, isTrue);
    expect(PluginManifest.fromJson(m.toJson())!.searchUnsupported, isTrue);
    expect(_manifest(blocked: false).toJson().containsKey('searchUnsupported'), isFalse,
        reason: '没开的源不该在配置里留下噪音字段');
  });

  testWidgets('搜索页：不渲染成「没找到」，而是说明原因并给出路', (tester) async {
    SourceRegistry.replacePlugins([
      RemoteJsSource(
        LoadedPlugin(
          manifest: _manifest(blocked: true),
          script: 'function parseList(){return [];}',
        ),
      ),
    ]);
    addTearDown(() => SourceRegistry.replacePlugins(const []));

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const SearchPage(),
    ));
    await tester.enterText(find.byType(TextField), '庆余年');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    // 关键：不能出现「没找到 xx」——那是「搜过但没有结果」的语义，
    // 会让用户以为关键词打错了，而事实是这个源压根不提供搜索。
    expect(find.textContaining('没找到'), findsNothing);
    expect(find.text('这个源搜不了'), findsOneWidget);
    expect(find.textContaining('没有开放搜索'), findsOneWidget);
    // 空屏必须给出路，否则用户只能自己想到「返回去换源」。
    expect(find.text('返回首页换个源'), findsOneWidget);
  });
}
