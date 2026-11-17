/// 4K影视插件在真实 QuickJS 里的离线验证。
///
/// 最关键的测试是**签名对拍**：用固定时间戳让脚本算 s / k，
/// 与 Dart 内置实现（`kvmPlayQuery`）逐字段比对。签名差一个字节，
/// 线上就是 401「请提供访问令牌」，而报错离真正的原因很远。
///
/// 列表/详情/取址响应都来自 2026-11-12 的真实抓包。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/source/kvm4k_source.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  String fixture(String n) => File('test/fixtures/$n').readAsStringSync();

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final f = File('../../config/plugins/kvm4k.js');
    expect(f.existsSync(), isTrue);
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://www.4kvm.net',
      'finalUrl': 'https://www.4kvm.net/filter?classify=2',
      'sourceId': 'kvm4k',
    };
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  Future<Map> call(String entry, List<Object?> args) async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode(args),
    );
    expect(r.ok, isTrue, reason: '$entry 调用失败：${r.error}');
    return jsonDecode(r.value) as Map;
  }

  test('parseList 解析真实分类页（data-vod 超集锚点）', () async {
    final out = await call('parseList', [fixture('kvm4k_list.html'), ctx]);
    final items = out['items'] as List;
    expect(items.length, greaterThanOrEqualTo(20));
    expect(items.first['id'], matches(RegExp(r'^[A-Za-z0-9]+$')));
    expect(items.first['name'], isNotEmpty);
    expect(items.first['pic'], isNotEmpty);
    // data-vod 不是 slug，不能被当成 id
    expect(items.first['id'], isNot('cgzq7cao3'));
  });

  test('parseDetail 解析真实详情页，token 带 dataid 与 userlink', () async {
    final out = await call('parseDetail', [
      fixture('kvm4k_detail.html'),
      <String, dynamic>{...ctx, 'dramaId': 'ch4rt1ctb'},
    ]);
    expect(out['name'], isNotEmpty);
    expect(out['pic'], isNotEmpty);

    final lines = out['lines'] as List;
    expect(lines.isNotEmpty, isTrue);
    expect((lines.first as Map)['line'], 'alists');
    final eps = (lines.first as Map)['episodes'] as List;
    expect(eps.length, 60, reason: '真实详情页有 60 集');
    final ep = eps.first as Map;
    expect(ep['url'], '/play/ch4rt1ctb');
    expect(ep['token'], contains('|'));
    expect(ep['token'].toString().split('|').first, matches(RegExp(r'^\d+$')),
        reason: 'token0 必须是 dataid');
  });

  test('签名与 Dart 内置实现逐字段对拍', () async {
    const dataid = '41860';
    const vodId = 'ch4rt1ctb';
    const userlink = 'X1VUW0NZVQAJAQ4FCgc7IUleUUBY';
    const ts = 1763370000123;

    final js = await call('buildPlayQuery', [dataid, '$ts', vodId, userlink]);
    final dart = kvmPlayQuery(
      dataid: dataid,
      vodId: vodId,
      userlink: userlink,
      tsMs: ts,
    );

    for (final key in dart.keys) {
      expect(js[key], dart[key], reason: '签名字段 $key 与内置实现不一致');
    }
    // s 是 hex 前 32 位，不是完整摘要
    expect(js['s'].toString().length, 32);
    // userlink 不应发给服务端
    expect(js['userlink'], '');
  });

  test('sign 钩子只签取址请求，列表请求原样放行', () async {
    final plain = await call('sign', [
      <String, dynamic>{
        'url': 'https://www.4kvm.net/filter?classify=2',
        'query': <String, dynamic>{'classify': '2'},
        'method': 'GET',
        'headers': <String, dynamic>{},
        'body': '',
        'vars': <String, dynamic>{},
        'ctx': <String, dynamic>{},
      }
    ]);
    expect(plain.isEmpty, isTrue);

    final signed = await call('sign', [
      <String, dynamic>{
        'url': 'https://www.4kvm.net/video/play',
        'query': <String, dynamic>{
          'p': '41860', 'v': 'ch4rt1ctb',
          'userlink': 'X1VUW0NZVQAJAQ4FCgc7IUleUUBY',
        },
        'method': 'GET',
        'headers': <String, dynamic>{},
        'body': '',
        'vars': <String, dynamic>{},
        'ctx': <String, dynamic>{},
      }
    ]);
    final q = signed['query'] as Map;
    expect(q['s'], isNotEmpty);
    expect(q['k'], isNotEmpty);
  });

  test('parseResolve 用真实应答，跳过 VIP 占位地址', () async {
    final out = await call('parseResolve', [
      fixture('kvm4k_play.json'),
      <String, dynamic>{...ctx, 'dramaId': 'ch4rt1ctb'},
    ]);
    expect(out['url'].toString().startsWith('https://'), isTrue);
    expect(out['url'].toString().contains('.m3u8'), isTrue);
  });

  test('parseResolve 遇到 4K VIP 占位符 "1" 时降级到 1080P', () async {
    const body = '{"code":200,"data":{"quality_urls":['
        '{"isvip":true,"locked":false,"url":"1"},'
        '{"isvip":false,"locked":false,"url":"https://x/1080.m3u8"}]}}';
    final out = await call('parseResolve', [body, ctx]);
    expect(out['url'], 'https://x/1080.m3u8');
  });
}
