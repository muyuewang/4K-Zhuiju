/// 三角洲影视插件的离线验证：RC4 解密 + 三段解析。
///
/// 夹具是 2026-11-18 从 `43.248.117.149:5656` 抓的真实响应，
/// 原样保存（列表/搜索是 RC4 密文的 hex 串，详情是明文 JSON）。
/// 不打网络：这个源的响应 key 由服务端下发，线上会变，但**解密逻辑**
/// 和**字段提取**不该跟着变——那才是这里要守住的东西。
///
/// 重点复现两个坑：
///   1. 列表/搜索响应体是 hex 字符串不是 JSON，直接 `jsonDecode` 会得到 0 条；
///   2. 站点不提供 `vod_id`，只有 `nextlink="?ac=detail&ids=630934"`，
///      不抠 ids 的话每一条都会被当成「无 id」丢掉，列表永远空。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  // 与服务端当前下发的 `pg` 字段一致。key 换了这个源就整站失效，
  // 改 index.json 的 vars.rc4Key 即可 —— 这里用真实值才验得出解密对不对。
  const rc4Key = '520720ygq';
  const clientUrl = 'http://43.248.117.45:5001/Client/';

  String fixture(String name) {
    final f = File('test/fixtures/$name');
    expect(f.existsSync(), isTrue, reason: '缺少夹具 $name');
    return f.readAsStringSync();
  }

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final f = File('../../config/plugins/sanjiaozhou.js');
    expect(f.existsSync(), isTrue);
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{'rc4Key': rc4Key, 'clientUrl': clientUrl},
      'baseUrl': 'http://43.248.117.149:5656',
      'finalUrl': 'http://43.248.117.149:5656/api.php/localhost1/vod/',
      'sourceId': 'sanjiaozhou',
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

  test('列表：RC4 解出 20 条，id 从 nextlink 抠出来，封面齐全', () async {
    final out = await call('parseList', [fixture('sjz_list.hex'), ctx]);
    final items = (out['items'] as List).cast<Map>();
    expect(items.length, 20, reason: '首页应解出 20 条');

    // 每一条都必须有纯数字 id，否则详情点不进去
    for (final it in items) {
      expect(RegExp(r'^\d+$').hasMatch('${it['id']}'), isTrue,
          reason: 'id 不是纯数字：${it['id']}');
    }
    // 这个站的列表带封面，缺了就是解错了（不是站点问题）
    final noPic = items.where((m) => '${m['pic']}'.isEmpty).length;
    expect(noPic, 0, reason: '$noPic 条没有封面');

    final first = items.first;
    expect(first['id'], '630934');
    expect(first['name'], '十万狂花入梦来');
    expect(first['pic'], startsWith('http'));
    expect(first['remark'], '(9/30)');
  });

  test('搜索：真实关键词命中 17 条且都带 id', () async {
    final out = await call('parseList', [fixture('sjz_search.hex'), ctx]);
    final items = (out['items'] as List).cast<Map>();
    expect(items.length, 17);
    expect(items.every((m) => RegExp(r'^\d+$').hasMatch('${m['id']}')), isTrue);
    expect(items.any((m) => '${m['name']}'.contains('火影')), isTrue);
  });

  test('列表：垃圾输入不抛异常，返回空列表', () async {
    for (final bad in <String>['', 'not hex', '{}', '<html>502</html>']) {
      final out = await call('parseList', [bad, ctx]);
      expect((out['items'] as List), isEmpty, reason: '输入 $bad 应得空列表');
    }
  });

  test('详情：5 条线路，集数与线路名都对', () async {
    final out = await call('parseDetail', [fixture('sjz_detail.json'), ctx]);
    expect(out['name'], '十万狂花入梦来');
    expect(out['id'], '630934');
    expect(out['area'], '内地');
    expect(out['year'], 2026);
    expect(out['remark'], '更新至第07集');
    expect('${out['content']}', isNotEmpty);
    expect('${out['director']}', '钟青');
    expect('${out['actor']}', contains('孙珍妮'));

    final lines = (out['lines'] as List).cast<Map>();
    expect(lines.length, 5, reason: '这部片站点给了 5 条线路');

    // 线路名来自 player 字段的 show 映射，不是键名
    expect(lines.map((l) => l['line']).toList(),
        ['线路P1', '线路K+', '高清B+', '线路JP', '线路QS+']);

    // 集数：首条线路只有 5 集，其余各 9 集 —— 这是真实数据，不是均分
    expect((lines[0]['episodes'] as List).length, 5);
    for (var i = 1; i < lines.length; i++) {
      expect((lines[i]['episodes'] as List).length, 9, reason: '第 $i 条线路应 9 集');
    }
  });

  test('详情：每集地址已是可直接播的代理地址，不是内部 token', () async {
    final out = await call('parseDetail', [fixture('sjz_detail.json'), ctx]);
    final lines = (out['lines'] as List).cast<Map>();

    for (final line in lines) {
      for (final ep in (line['episodes'] as List).cast<Map>()) {
        final url = '${ep['url']}';
        expect(url, startsWith('$clientUrl?url='),
            reason: '${line['line']} / ${ep['name']} 没拼代理地址');
        // 留裸 token 的表现是播放器把 `PAN1-3-xxx` 当 URL 去解析（无 scheme），
        // token 出现在 query 里是正常的，出现在开头才是错的。
        expect(url.startsWith('PAN1-') || url.startsWith('aksp-'), isFalse,
            reason: 'token 被当成最终地址：$url');
      }
    }

    // token 里的 `=` `+` `/` 必须整体百分号编码，否则 query 会被 `=` 截断
    final firstUrl = '${(lines[0]['episodes'] as List).first['url']}';
    expect(firstUrl, contains('%3D'));
  });

  test('parseResolve 对已是 http 的输入不二次包装', () async {
    final url = '${clientUrl}?url=PAN1-3-abc%3D';
    final out = await call('parseResolve', [url, ctx]);
    expect(out['url'], url, reason: '代理地址被重复包了一层');
  });

  test('解析对 ctx.vars 缺失 key 时安全退化', () async {
    final noKey = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'http://43.248.117.149:5656',
    };
    final out = await call('parseList', [fixture('sjz_list.hex'), noKey]);
    expect((out['items'] as List), isEmpty);
  });
}
