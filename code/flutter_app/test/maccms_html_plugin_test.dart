/// MacCMS 网页模板插件（pianku）在**真实 QuickJS** 里的离线验证。
///
/// 样本来源：
///   - `fixtures/pianku_home.html` 是 2026-11-11 从 4k01.pianku.online
///     首页真实抓下来的完整 HTML（68 个详情链接），不是手写假数据。
///   - 详情页样本按站点模板的真实锚点构造（`source-tab-item` /
///     `playlist-N` / `player_aaaa`），重点验证的是**锚点对齐与排序规则**。
///
/// 站点当前 TCP/TLS 层不通，无法联网复测；因此这里只能证明
/// 「按真实响应格式解析正确」，不声称线上可用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue,
        reason: 'quickjs_c_bridge.dll 不可用，无法在主机上验证 JS 执行');

    final f = File('../../config/plugins/maccms-html.js');
    expect(f.existsSync(), isTrue, reason: '找不到脚本：${f.absolute.path}');
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse,
        reason: '脚本含疑似死循环，宿主会拒绝装载');

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{
        'webLineNames': '腾讯,奇异,爱奇艺,优酷,B站,芒果,搜狐',
      },
      'baseUrl': 'https://4k01.pianku.online',
      'finalUrl': 'https://4k01.pianku.online/',
      'sourceId': 'pianku',
    };
  });

  tearDownAll(() {
    PluginRuntime.instance.resetForTest();
  });

  Future<Map> call(String entry, Object body,
      [Map<String, dynamic>? override]) async {
    final c = <String, dynamic>{...ctx, ...?override};
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode([body, c]),
    );
    expect(r.ok, isTrue, reason: '$entry 调用失败：${r.error}');
    return jsonDecode(r.value) as Map;
  }

  test('脚本能在 QuickJS 里装载', () async {
    final out = await call('parseList', '');
    expect(out['items'], isEmpty);
  });

  test('parseList 解析真实首页：无扩展名封面必须取到', () async {
    final f = File('test/fixtures/pianku_home.html');
    expect(f.existsSync(), isTrue);
    final out = await call('parseList', f.readAsStringSync());
    final items = out['items'] as List;

    expect(items.length, greaterThanOrEqualTo(20),
        reason: '真实首页 68 个详情链接，解析结果不可能是个位数');

    final first = items.first as Map;
    expect(first['id'], '118681');
    expect(first['name'], '师兄太稳健');
    // 这条封面是 CDN 直链、没有 .jpg 后缀 —— 旧版就漏在这里
    expect(first['pic'],
        'http://m.ykimg.com/050E00006A85293BC7AFFF141AD91378');
    expect(first['remark'], '全剧集');

    // 同一页里带 .jpg 的封面也要正常
    expect(items.any((e) => (e as Map)['pic'].toString().contains('.jpg')),
        isTrue);
    // 不能把 onerror 里的 /load.gif 当封面
    expect(items.every((e) => !(e as Map)['pic'].toString().contains('load.gif')),
        isTrue);
  });

  test('parseDetail 先收线路名表，再按 pane 分段', () async {
    const html = r'''
<title>测试影片详情介绍-测试影片在线观看-片库</title>
<meta name="description" content="这是一段简介">
<span class="source-tab-item" data-target="playlist-0">备用线路</span>
<span class="source-tab-item" data-target="playlist-1">腾讯</span>
<span class="source-tab-item" data-target="playlist-2">高清线路</span>
<div id="playlist-0">
<a href="/vodplay/15211-1-1.html" title="HD中字">1</a>
<a href="/vodplay/15211-1-2.html" title="HD中字">2</a>
</div>
<div id="playlist-1">
<a href="/vodplay/15211-2-1.html" title="腾讯">1</a>
</div>
<div id="playlist-2">
<a href="/vodplay/15211-3-1.html" title="第1集">1</a>
<a href="/vodplay/15211-3-2.html" title="第2集">2</a>
<a href="/vodplay/15211-3-3.html" title="第3集">3</a>
</div>
''';

    final out = await call('parseDetail', html);
    expect(out['name'], '测试影片');
    expect(out['content'], '这是一段简介');

    final lines = out['lines'] as List;
    expect(lines.length, 3);
    // 网页源沉底，但**其余线路的相对顺序不变**
    expect((lines[0] as Map)['line'], '备用线路');
    expect((lines[1] as Map)['line'], '高清线路');
    expect((lines[2] as Map)['line'], '腾讯');

    // 逐线路铺自己的集数：不能按最长线路补齐（会造死链）
    expect(((lines[0] as Map)['episodes'] as List).length, 2);
    expect(((lines[1] as Map)['episodes'] as List).length, 3);
    expect(((lines[2] as Map)['episodes'] as List).length, 1);
    final ep = ((lines[1] as Map)['episodes'] as List).first as Map;
    expect(ep['url'], '/vodplay/15211-3-1.html');
    expect(ep['name'], '第1集');
  });

  test('parseResolve 还原 \\/ 转义并直出 m3u8', () async {
    const html = r'''
<script>var player_aaaa={"from":"wsym3u8","url":"https:\/\/v.example.com\/2026\/index.m3u8","id":"15211"};</script>
''';
    final out = await call('parseResolve', html);
    expect(out['url'], 'https://v.example.com/2026/index.m3u8');
    expect(out['error'] ?? '', isEmpty);
  });

  test('parseResolve 对网页源给出可操作的原因', () async {
    const html = r'''
<script>var player_aaaa={"from":"qq","url":"https://v.qq.com/x/cover/abc.html"};</script>
''';
    final out = await call('parseResolve', html,
        <String, dynamic>{'line': '腾讯'});
    expect(out['url'], '');
    expect(out['error'], contains('网页源'));
    expect(out['error'], contains('腾讯'));
  });

  test('parseResolve 空播放页不抛异常', () async {
    final out = await call('parseResolve', '');
    expect(out['url'], '');
    expect(out['error'], isNotEmpty);
  });
}
