/// 极速追剧插件在真实 QuickJS 里的离线验证。
///
/// 夹具是 2026-11-12 从站点真实抓下来的：分类页、搜索页、详情页、
/// 取址接口应答。详情页《灵境行者》四条线路集数故意不同（15/12/12/12），
/// 正好用来验证「逐线路铺集数」没有退化成按最长补齐。
///
/// 站点当前直连不通，无法联网复测；这里只证明解析逻辑与真实应答匹配。
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
    final f = File('../../config/plugins/jisu.js');
    expect(f.existsSync(), isTrue);
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://jisuzhuiju.com',
      'finalUrl': 'https://jisuzhuiju.com/filter?channel=1',
      'sourceId': 'jisu',
    };
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  Future<Map> call(String entry, Object body,
      [Map<String, dynamic>? extra]) async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode([body, <String, dynamic>{...ctx, ...?extra}]),
    );
    expect(r.ok, isTrue, reason: '$entry 调用失败：${r.error}');
    return jsonDecode(r.value) as Map;
  }

  test('parseList 解析真实分类页', () async {
    final out = await call('parseList', fixture('jisu_list.html'));
    final items = out['items'] as List;
    expect(items.length, 12);
    expect(items.first['id'], isNotEmpty);
    expect(items.first['name'], isNotEmpty);
    expect(items.first['pic'], isNotEmpty);
  });

  test('parseList 解析真实搜索页，去掉 alt 的封面图片后缀', () async {
    final out = await call('parseList', fixture('jisu_search.html'));
    final items = out['items'] as List;
    expect(items.length, 3);
    for (final e in items) {
      expect((e as Map)['name'].toString().endsWith('封面图片'), isFalse);
      expect(e['pic'].toString().isNotEmpty, isTrue);
    }
  });

  test('parseDetail 逐线路集数：15/12/12/12，不互相补齐', () async {
    final out = await call('parseDetail', fixture('jisu_detail.html'),
        <String, dynamic>{'dramaId': '702'});
    expect(out['name'], '灵境行者');
    expect(out['pic'], isNotEmpty);

    final lines = out['lines'] as List;
    expect(lines.length, 4);
    expect((lines[0] as Map)['line'], '腾讯官方线路');
    expect((lines[1] as Map)['line'], '自建线路');
    expect((lines[2] as Map)['line'], '普通线路二');
    expect((lines[3] as Map)['line'], '普通线路一');

    final counts = lines.map((e) => ((e as Map)['episodes'] as List).length);
    expect(counts.toList(), <int>[15, 12, 12, 12]);

    final ep = ((lines[1] as Map)['episodes'] as List).first as Map;
    expect(ep['url'], '/vodplay/702-covip-1.html');
    expect(ep['token'], 'covip|1',
        reason: '取址接口要 playFrom=covip、index=1，token 必须两者都带');
  });

  test('parseResolve 解析真实取址应答', () async {
    final out = await call('parseResolve', fixture('jisu_api.json'));
    final url = out['url'].toString();
    expect(url.startsWith('https://'), isTrue);
    expect(url.contains('.m3u8'), isTrue);
  });

  test('parseResolve 把 code:500 未找到翻成人话', () async {
    final out = await call(
        'parseResolve', '{"mode":"native","code":500,"msg":"未找到该集播放地址"}');
    expect(out['url'], '');
    expect(out['error'], '这条线路没有这一集，换个线路试试');
  });

  test('parseResolve 坏应答不抛异常', () async {
    final out = await call('parseResolve', '<html>502</html>');
    expect(out['url'], '');
    expect(out['error'], isNotEmpty);
  });
}
