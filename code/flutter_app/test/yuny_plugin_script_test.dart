/// 云影插件脚本在**真实 QuickJS** 里能不能跑通。
///
/// ## 为什么要单独一个文件
///
/// [plugin_script_test] 验证的是 MacCMS 系脚本（`$$$` 分线路、`#` 分集）。
/// 云影是完全不同的一类：纯 JSON 接口、`resourceType` 判可播、
/// 线路中文名直接来自接口。两套解析逻辑没有复用关系，测试也不该混在一起。
///
/// ## 为什么必须在 QuickJS 里跑而不是 Node
///
/// 脚本是用 Node 调试的，但线上执行环境是 QuickJS（Emscripten 移植）。
/// 两者都是 JS，但**内置对象的实现细节有差异**——正则行为、
/// `String.prototype` 的边缘用法、`parseInt` 对异常输入的处理都可能不同。
/// 这类差异在 Node 里永远测不出来，只能靠真实引擎跑一遍。
///
/// ## 样本来源
///
/// 夹具是 2026-11-17 从线上真实抓的（`get-video-detail?videoInfoId=15307`），
/// 只截断了集数（每线路留 2 集）并去掉与本测试无关的字段。
/// **不是手写的假数据**——手写的样本只能验证「我以为的格式」，
/// 证不了「站方实际发的格式」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  String fixture(String name) {
    final f = File('test/fixtures/$name');
    expect(f.existsSync(), isTrue, reason: '找不到夹具：${f.absolute.path}');
    return f.readAsStringSync();
  }

  setUpAll(() {
    expect(
      ensureQuickJsLibrary(),
      isTrue,
      reason: 'quickjs_c_bridge.dll 不可用，无法在主机上验证 JS 执行',
    );

    final f = File('../../config/plugins/yuny.js');
    expect(f.existsSync(), isTrue, reason: '找不到插件脚本：${f.absolute.path}');
    script = f.readAsStringSync();

    // 宿主的静态死循环检查也要过：`while(true)` / `for(;;)` 一律拒绝装载
    expect(looksLikeInfiniteLoop(script), isFalse,
        reason: '云影脚本含疑似死循环，宿主会拒绝装载');

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://www.yuny.app',
      'finalUrl': 'https://www.yuny.app/app/video-home/today-updates',
      'sourceId': 'yuny',
    };
  });

  tearDownAll(() {
    PluginRuntime.instance.resetForTest();
  });

  test('脚本能在 QuickJS 里装载（无语法错误）', () async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode(['{"success":true,"data":{"list":[]}}', ctx]),
    );
    expect(r.ok, isTrue, reason: '装载或调用失败：${r.error}');
  });

  test('parseList 解析真实首页应答', () async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode([fixture('yuny_home.json'), ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);

    final out = jsonDecode(r.value) as Map;
    final items = out['items'] as List;
    expect(items.length, 2);

    final a = items[0] as Map;
    expect(a['id'], '15307');
    expect(a['name'], '风犬少年的天空');
    // 封面必须是完整的 https（站方给的就是绝对地址，不能被 abs() 改坏）
    expect(a['pic'], startsWith('https://static.yuny.bar/'));
    expect(a['remark'], '更新至16集');
    // tags 为 null 时不能变成字符串 "null"
    expect(a['type'], '');

    final b = items[1] as Map;
    expect(b['type'], '剧情');
    // `&nbsp;` 要被 strip 掉并折叠空白，否则简介开头有个空洞
    expect(b['brief'], isNot(startsWith(' ')));
    expect(b['brief'], isNot(contains('&nbsp;')));
  });

  test('parseDetail 逐线路铺自己的集数，并丢弃不可播线路', () async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseDetail',
      argsJson: jsonEncode([fixture('yuny_detail.json'), ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);

    final out = jsonDecode(r.value) as Map;
    expect(out['name'], '风犬少年的天空');
    expect(out['year'], 2020);
    expect(out['area'], '中国大陆');
    expect(out['remark'], '更新至16集');

    // tagList 是**人物列表**不是标签：tagType=1 导演、tagType=2 演员。
    // 夹具里 张一白/韩琰 是导演，彭昱畅/张婧仪 是演员，
    // 而 actorList 是 []、performer 是 null——演员只在 tagList 里。
    expect(out['director'], '张一白 / 韩琰');
    expect(out['actor'], '彭昱畅 / 张婧仪');
    // 真正的标签退回「类型 / 语言」
    expect(out['tag'], '剧集 / 国语');

    final lines = out['lines'] as List;
    // 夹具原本有 4 条线路，第 1 条「精品线路1」2 集全是 resourceType=2
    // （covip 编码，站方自己也修不好），必须被整条丢弃
    expect(lines.length, 3,
        reason: 'resourceType=2 的线路应该整条不出现，而不是留一个空 tab');

    for (final l in lines) {
      final m = l as Map;
      // 线路名直接来自 collectChannelName，不能是「线路1」
      expect(m['line'], anyOf('普通线路yz', '普通线路xg', '普通线路js'));
      final eps = m['episodes'] as List;
      expect(eps.length, 2, reason: '每线路各自的集数，不能互相补齐');
      for (final e in eps) {
        final url = (e as Map)['url'] as String;
        // 每条都必须是可播直链
        expect(url, startsWith('http'));
        expect(url, contains('.m3u8'));
      }
    }
  });

  test('坏响应不崩：空 body / HTML / 业务失败都返回空', () async {
    // 三种真实会遇到的失败形态。都必须返回空而不是抛异常——
    // 抛异常在界面上只有一句「解析失败」，看不出是源挂了还是插件写错了。
    const bad = <String>[
      '',
      '<html><body>502 Bad Gateway</body></html>',
      '{"success":false,"code":422,"msg":"暂时无法确认设备信息"}',
      '{"success":true}',
      '[]',
    ];
    for (final body in bad) {
      final rl = await PluginRuntime.instance.call(
        script: script,
        entry: 'parseList',
        argsJson: jsonEncode([body, ctx]),
      );
      expect(rl.ok, isTrue, reason: 'parseList 在 ${body.length} 字节输入上崩了：${rl.error}');
      expect((jsonDecode(rl.value) as Map)['items'], isEmpty);

      final rd = await PluginRuntime.instance.call(
        script: script,
        entry: 'parseDetail',
        argsJson: jsonEncode([body, ctx]),
      );
      expect(rd.ok, isTrue, reason: 'parseDetail 在 ${body.length} 字节输入上崩了：${rd.error}');
      expect((jsonDecode(rd.value) as Map)['lines'], isEmpty);
    }
  });

  test('全部选集都不可播时，返回空线路而不是空对象', () async {
    // 站方有时整部剧只挂 covip 编码。此时详情页会显示「没有可用线路」，
    // 但**结构必须完整**（name 等元信息仍在），否则详情页拿不到标题。
    const body = '{"success":true,"data":{"id":"9","name":"某剧","years":"2026",'
        '"tagList":[],"actorList":[],"videoChannelList":[{"collectChannelName":"线路A",'
        '"videoSelectResList":[{"id":"1","series":"第1集","resource":"covip_abc","resourceType":2}]}]}}';
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseDetail',
      argsJson: jsonEncode([body, ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);
    final out = jsonDecode(r.value) as Map;
    expect(out['name'], '某剧');
    expect(out['year'], 2026);
    expect(out['lines'], isEmpty);
  });

  test('性能：解析 40 集详情在 3 秒预算内绰绰有余', () async {
    // 造一份 4 线路 × 40 集
    final channels = <String>[];
    for (var li = 0; li < 4; li++) {
      final sels = List.generate(
        40,
        (i) => '{"id":"${li}_$i","series":"第${i + 1}集",'
            '"resource":"https://a$li.com/$i/index.m3u8","resourceType":1}',
      ).join(',');
      channels.add('{"collectChannelName":"线路$li","videoSelectResList":[$sels]}');
    }
    final body = '{"success":true,"data":{"id":"1","name":"压测",'
        '"years":"2026","tagList":[],"actorList":[],'
        '"videoChannelList":[${channels.join(',')}]}}';

    // 首次含脚本编译，先热身
    await PluginRuntime.instance.call(
      script: script,
      entry: 'parseDetail',
      argsJson: jsonEncode([body, ctx]),
    );

    final sw = Stopwatch()..start();
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseDetail',
      argsJson: jsonEncode([body, ctx]),
    );
    sw.stop();

    expect(r.ok, isTrue, reason: r.error);
    final lines = (jsonDecode(r.value) as Map)['lines'] as List;
    expect(lines.length, 4);
    expect((lines[0] as Map)['episodes'], hasLength(40));
    expect(sw.elapsedMilliseconds, lessThan(3000),
        reason: '解析 160 集用了 ${sw.elapsedMilliseconds}ms');
  });
}