/// 真实插件脚本在 QuickJS 里能不能跑通。
///
/// 这条测试的意义：脚本是用 Node 写、用 Node 调试的，但实际执行环境是
/// QuickJS（Emscripten 移植版）。两者都是 JS，但**内置对象的实现细节
/// 有差异**——比如 QuickJS 对某些正则行为、`String.prototype` 的边缘
/// 用法可能不同。这类差异在 Node 里永远测不出来。
///
/// 所以这里直接把仓库里那个真实脚本喂进 PluginRuntime，用真实的
/// MacCMS 响应结构（字段名、`$$$` 分隔、相对封面地址）验证。
///
/// 响应体是**离线固定样本**，不是实时请求：测试要能重复跑、不依赖网络，
/// 也不能因为源站今天挂了就红。样本取自 2026-11-17 暴风接口的真实应答，
/// 保留了完整字段结构，只截了条目数。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

/// 真实 MacCMS `ac=list` 应答（截取 3 条，字段与线上一致）。
///
/// 注意 `vod_pic` 用的是真实域名——测试要验证 `abs()` 补全逻辑
/// 不会把一个已经是绝对地址的图片改坏。
const String _listBody = '''
{"code":1,"msg":"数据列表","page":1,"pagecount":9999,"limit":"20","total":173310,
"list":[
{"vod_id":173310,"vod_name":"男子气概","type_id":26,"type_name":"剧情片",
 "vod_en":"nanzhiqigai","vod_time":"2026-11-17 09:12:33","vod_remarks":"更新至HD",
 "vod_play_from":"bfzym3u8",
 "vod_pic":"https://p.bfp261112.com/upload/vod/20261117-1/e78e7834b6b63e.webp",
 "vod_area":"美国","vod_year":"2026","vod_lang":"英语",
 "vod_blurb":"一个男人的故事","vod_actor":"某人","vod_director":"某导"},
{"vod_id":173169,"vod_name":"寒鸦之冬","type_id":26,"type_name":"剧情片",
 "vod_remarks":"更新至HD","vod_pic":"/upload/vod/20261116-1/5bf7e57.webp",
 "vod_area":"英国 / 卢森堡 / 波兰","vod_year":"2025"},
{"vod_id":173049,"vod_name":"命线相牵","type_id":26,"type_name":"剧情片",
 "vod_remarks":"更新至HD","vod_pic":"//cdn.example.com/a.webp",
 "vod_area":"美国","vod_year":2027}
]}
''';

/// 真实 MacCMS `ac=detail` 应答（含 `$$$` 多线路与 `#` 多集）。
const String _detailBody = '''
{"code":1,"list":[
{"vod_id":173310,"vod_name":"男子气概","type_id":26,"type_name":"剧情片",
 "vod_pic":"https://p.bfp261112.com/upload/vod/20261117-1/e78e.webp",
 "vod_area":"美国","vod_year":"2026","vod_remarks":"更新至HD",
 "vod_content":"<p>简介正文</p>","vod_blurb":"一句话简介",
 "vod_director":"某导","vod_actor":"某人",
 "vod_play_from":"bfzym3u8\$\$\$lzm3u8",
 "vod_play_url":"HD\$https://v.fengbao14.com/video/nanziqigai/abc/index.m3u8#第2集\$https://v.fengbao14.com/video/nanziqigai/def/index.m3u8\$\$\$HD\$https://v.lz.com/x/index.m3u8"}
]}
''';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  setUpAll(() {
    // 主机上跑 flutter test 时没人把 quickjs 的 dll 拷到 cwd，
    // 这里现取一次（打包产物由 CMake install 负责，不受影响）
    expect(
      ensureQuickJsLibrary(),
      isTrue,
      reason: 'quickjs_c_bridge.dll 不可用，无法在主机上验证 JS 执行',
    );

    final f = File('../../config/plugins/maccms-json.js');
    expect(f.existsSync(), isTrue, reason: '找不到插件脚本：${f.absolute.path}');
    script = f.readAsStringSync();

    // 脚本不能含宿主会拒绝的死循环写法
    expect(looksLikeInfiniteLoop(script), isFalse,
        reason: '插件脚本含疑似死循环，宿主会拒绝装载');

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://bfzyapi.com',
      'finalUrl': 'https://bfzyapi.com/api.php/provide/vod/',
      'sourceId': 'js_bofeng',
    };
  });

  tearDownAll(() {
    PluginRuntime.instance.resetForTest();
  });

  test('脚本能在 QuickJS 里装载（无语法错误）', () async {
    // 装载就是 evaluate 整段脚本。这里用一个最轻的调用确认它不报错
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode(['{"list":[]}', ctx]),
    );
    expect(r.ok, isTrue, reason: '装载或调用失败：${r.error}');
  });

  test('parseList 解析真实应答，字段全部正确', () async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode([_listBody, ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);

    final out = jsonDecode(r.value) as Map;
    final items = out['items'] as List;

    // 第 1 条：字段齐全，pic 是绝对地址
    expect(items.length, 3);
    final a = items[0] as Map;
    expect(a['id'], '173310');
    expect(a['name'], '男子气概');
    expect(a['pic'], startsWith('https://p.bfp'));
    expect(a['remark'], '更新至HD');
    expect(a['area'], '美国');
    expect(a['year'], 2026);
    expect(a['type'], '剧情片');

    // 第 2 条：相对封面 → 补成 https://bfzyapi.com/upload/...
    final b = items[1] as Map;
    expect(b['pic'], 'https://bfzyapi.com/upload/vod/20261116-1/5bf7e57.webp',
        reason: '相对地址必须拼上 baseUrl 的协议+主机');

    // 第 3 条：协议相对 + year 是数字（不是字符串）
    final c = items[2] as Map;
    expect(c['pic'], 'https://cdn.example.com/a.webp',
        reason: '// 开头要补 https:');
    expect(c['year'], 2027, reason: '数字 year 要能正常取到');
  });

  test('parseDetail 解析真实应答，多线路 + 多集正确', () async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseDetail',
      argsJson: jsonEncode([_detailBody, ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);

    final out = jsonDecode(r.value) as Map;
    expect(out['name'], '男子气概');
    expect(out['content'], '<p>简介正文</p>');
    expect(out['year'], 2026);

    final lines = out['lines'] as List;
    expect(lines.length, 2, reason: '\$\$\$ 应拆成两条线路');

    // 线路名必须来自 vod_play_from，不能是「线路1」
    final l1 = lines[0] as Map;
    expect(l1['line'], 'bfzym3u8');
    final eps1 = l1['episodes'] as List;
    expect(eps1.length, 2, reason: '# 应拆成两集');
    expect((eps1[0] as Map)['name'], 'HD');
    expect((eps1[0] as Map)['url'],
        'https://v.fengbao14.com/video/nanziqigai/abc/index.m3u8');
    expect((eps1[1] as Map)['name'], '第2集');

    final l2 = lines[1] as Map;
    expect(l2['line'], 'lzm3u8');
    expect((l2['episodes'] as List).length, 1);
  });

  test('坏响应不崩，返回空列表', () async {
    // 采集站被 WAF 拦时会返回 HTML 错误页而不是 JSON。
    // 这时必须返回空列表（→ 界面显示空态），而不是抛异常
    // （→ 界面只显示一句「解析失败」，没法判断是源挂了还是插件写错了）。
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode(['<html><body>503 Service Unavailable</body></html>', ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);
    final out = jsonDecode(r.value) as Map;
    expect((out['items'] as List), isEmpty);
  });

  test('parseResolve 能从 HTML 里抠出 m3u8', () async {
    const html = '<html><script>var main = "https://a.com/x/index.m3u8?sign=1";</script></html>';
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseResolve',
      argsJson: jsonEncode([html, ctx]),
    );
    expect(r.ok, isTrue, reason: r.error);
    final out = jsonDecode(r.value) as Map;
    expect(out['url'], 'https://a.com/x/index.m3u8?sign=1');
  });

  test('性能：解析一次 20 条应在 3 秒预算内绰绰有余', () async {
    // 造一份 20 条的应答
    final items = List.generate(
      20,
      (i) => '{"vod_id":$i,"vod_name":"剧$i","vod_pic":"/u/$i.webp",'
          '"vod_remarks":"更新至HD","vod_year":"2026"}',
    ).join(',');
    final body = '{"code":1,"list":[$items]}';

    // 首次包含脚本编译，所以先跑一次热身
    await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode([body, ctx]),
    );

    final sw = Stopwatch()..start();
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: 'parseList',
      argsJson: jsonEncode([body, ctx]),
    );
    sw.stop();

    expect(r.ok, isTrue, reason: r.error);
    expect((jsonDecode(r.value) as Map)['items'], hasLength(20));
    // 预算 3 秒，实测应在几十毫秒内
    expect(sw.elapsedMilliseconds, lessThan(3000),
        reason: '解析 20 条用了 ${sw.elapsedMilliseconds}ms，超出用户可感知范围');
  });
}