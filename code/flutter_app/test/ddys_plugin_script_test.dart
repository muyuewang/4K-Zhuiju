/// 低调影视（ddys.io）插件在真实 QuickJS 里的离线验证。
///
/// 夹具是真实抓包。重点覆盖两个实测坑：
///   - 选集参数既有 `第01集$url#…` 的多集串，也有**纯 URL** 的单集形态；
///   - 详情页推荐位也有 movie-card，但不能混进列表解析。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  String fixture(String n) => File('test/fixtures/$n').readAsStringSync();

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final f = File('../../config/plugins/ddys.js');
    expect(f.existsSync(), isTrue);
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://ddys.io',
      'finalUrl': 'https://ddys.io/',
      'sourceId': 'ddys',
    };
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  Future<Map> call(String entry, Object body) async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode([body, ctx]),
    );
    expect(r.ok, isTrue, reason: '$entry 调用失败：${r.error}');
    return jsonDecode(r.value) as Map;
  }

  test('parseList 解析真实首页卡片', () async {
    final out = await call('parseList', fixture('ddys_home.html'));
    final items = out['items'] as List;
    expect(items.length, greaterThanOrEqualTo(20));
    expect(items.first['id'], isNotEmpty);
    expect(items.first['name'], isNotEmpty);
  });

  test('parseDetail 解析真实详情页的多集串', () async {
    final out = await call('parseDetail', fixture('ddys_detail.html'));
    final lines = out['lines'] as List;
    expect(lines.isNotEmpty, isTrue);

    final first = lines.first as Map;
    expect(first['line'], isNotEmpty);
    final eps = first['episodes'] as List;
    expect(eps.length, greaterThan(1));
    final ep = eps.first as Map;
    expect(ep['name'], contains('第'));
    expect(ep['url'].toString().startsWith('https://'), isTrue);
    expect(ep['url'].toString().contains('.m3u8'), isTrue);
  });

  test('parseDetail 认得纯 URL 形态（电影单集）', () async {
    const html = r'''
<button onclick="switchSource(42, 'https://vip.example.com/2022/movie/index.m3u8', 'm3u8')" id="source-tab-42"> 播放源 1 (1080P) </button>
''';
    final out = await call('parseDetail', html);
    final lines = out['lines'] as List;
    expect(lines.length, 1);
    final eps = ((lines.first as Map)['episodes'] as List);
    expect(eps.length, 1);
    expect((eps.first as Map)['name'], '正片');
    expect((eps.first as Map)['url'],
        'https://vip.example.com/2022/movie/index.m3u8');
  });

  test('parseDetail 认得协议相对的纯 URL', () async {
    const html = r'''
<button onclick="switchSource(43, '//cdn.example.com/a/index.m3u8', 'm3u8')" id="source-tab-43">备用</button>
''';
    final out = await call('parseDetail', html);
    final eps = (((out['lines'] as List).first as Map)['episodes'] as List);
    expect((eps.first as Map)['url'], 'https://cdn.example.com/a/index.m3u8');
  });

  test('非 m3u8 线路被跳过，不产生空 tab', () async {
    const html = r'''
<button onclick="switchSource(44, 'https://pan.example.com/s/abc', 'pan')" id="source-tab-44">网盘</button>
''';
    final out = await call('parseDetail', html);
    expect(out['lines'], isEmpty);
  });
}
