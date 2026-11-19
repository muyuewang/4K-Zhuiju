/// 剧踪影院插件在真实 QuickJS 里的离线验证。
///
/// 三段解析共用 5 份**真实抓包**夹具，其中 `juzong_search.html` 必须经过
/// 「403 → 收 Set-Cookie → 带 Cookie 重发」两步握手才拿得到（见
/// `plugin_cookie_jar.dart`），一份直连抓到的 160 字节挑战页说明不了任何问题。
///
/// 这里重点盯的几处，都是开发时真踩过、而且**错得不报错**的坑：
///
/// - 搜索页两块 `stui-vodlist__text` + 两块 `stui-vodlist__media active`
///   榜单会被当成搜索结果收进来（搜「色戒」混进「欢迎来龙餐馆」）
/// - 详情页第一张 `<img>` 是 `#topbanner` 里 `display:none` 的站方提示图
/// - 详情页 `主演` 是一串锚点，窗口给小了会匹配到推荐位里别的剧
/// - `en-` 票据线必须给出人话原因，而不是让播放器报格式错
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> baseCtx;

  String fixture(String n) {
    final f = File('test/fixtures/$n');
    expect(f.existsSync(), isTrue, reason: '缺少夹具 $n');
    return f.readAsStringSync();
  }

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final f = File('../../config/plugins/juzong.js');
    expect(f.existsSync(), isTrue, reason: '插件脚本不在 config/plugins/juzong.js');
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    baseCtx = <String, dynamic>{
      'vars': <String, dynamic>{
        'plainLineHints': 'XG,BF,DY,WJ,WS,蓝光,专线',
        'ticketLineHints': '独家,维护',
        'webLineNames': '鹅播,爱播,酷播,芒果,腾讯,爱奇艺,优酷,B站,搜狐',
        'detailLinkPattern': 'href="/voddetail/(\\d+)/"',
      },
      'baseUrl': 'https://www.juzong01.me',
      'sourceId': 'juzong',
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

  // ==================== 列表（JSON 接口） ====================

  test('parseList 吃 /ajax/data 的 JSON，字段齐全且已清洗', () async {
    final out = await call('parseList', [fixture('juzong_list.json'), baseCtx]);
    final items = out['items'] as List;
    expect(items, hasLength(20), reason: '接口 limit=20');

    for (final it in items) {
      final m = it as Map;
      expect(m['id'], matches(RegExp(r'^\d+$')), reason: 'id 必须是纯数字');
      expect((m['name'] as String), isNotEmpty);
    }

    final first = items.first as Map;
    expect(first['name'], '敦煌英雄');
    expect(first['pic'], startsWith('http'));
    expect(first['remark'], '完结');
    expect(first['area'], '大陆');
    expect(first['year'], 2026);
    // 视频站没图时填的是 `/`，那不是地址，必须是空串
    expect(items.every((e) => (e as Map)['pic'] != '/'), isTrue);
  });

  test('parseList 的 brief 已剥实体与换行（接口原样带 &nbsp; 和 \\r\\n）', () async {
    final out = await call('parseList', [fixture('juzong_list.json'), baseCtx]);
    final items = out['items'] as List;
    final dirty = items.where((e) {
      final b = (e as Map)['brief'] as String;
      return b.contains('&nbsp;') || b.contains('&#') || b.contains('\r');
    });
    expect(dirty, isEmpty, reason: 'brief 里的实体/回车没洗干净，界面会显示成字面 &nbsp;');
  });

  // ==================== 搜索（HTML 页 + Cookie 挑战） ====================

  test('parseList 解析搜索页，只留真实结果（剔除四块侧栏榜单）', () async {
    final out = await call('parseList', [fixture('juzong_search.html'), baseCtx]);
    final items = out['items'] as List;

    // 搜「色戒」站内只有 2 条。历史上因为没剔榜单，会拿回 4 条甚至 22 条。
    expect(items, hasLength(2), reason: '搜索页混入了侧栏榜单');

    final names = items.map((e) => (e as Map)['name']).toList();
    expect(names, contains('色，戒'));
    expect(names, contains('五十度黑'));
    // 这几个都在榜单里，与关键词毫不相关
    for (final noise in ['四渡', '欢迎来龙餐馆', '嫁金钗', '西西里的美丽传说']) {
      expect(names, isNot(contains(noise)), reason: '侧栏榜单噪声「$noise」漏进来了');
    }
  });

  test('parseList 搜索结果的封面取 data-original，且不认站标', () async {
    final out = await call('parseList', [fixture('juzong_search.html'), baseCtx]);
    final items = out['items'] as List;

    // 搜索页卡片根本没有 <img>，封面写在锚点的 data-original 上
    expect(items.every((e) => ((e as Map)['pic'] as String).startsWith('http')),
        isTrue, reason: '有卡片没取到封面');

    final bad = items.where((e) {
      final p = (e as Map)['pic'] as String;
      return p.contains('/statics/') || p.contains('icon_');
    });
    expect(bad, isEmpty, reason: '站标 icon_N.png 被当成封面了');
  });

  test('parseList 搜索结果读到地区/年份/备注', () async {
    final out = await call('parseList', [fixture('juzong_search.html'), baseCtx]);
    final items = (out['items'] as List).cast<Map>();
    final sejie = items.firstWhere((e) => e['name'] == '色，戒');
    expect(sejie['year'], 2007);
    expect(sejie['type'], isNotEmpty);
  });

  // ==================== 详情 ====================

  test('parseDetail 解析真实详情页，10 条线路 × 167 集', () async {
    final out = await call('parseDetail', [
      fixture('juzong_detail.html'),
      <String, dynamic>{...baseCtx, 'dramaId': '106'},
    ]);

    expect(out['name'], '仙逆');
    final lines = out['lines'] as List;
    expect(lines, hasLength(10), reason: '真实详情页有 10 个线路面板');
    for (final l in lines) {
      expect(((l as Map)['episodes'] as List), hasLength(167));
    }
    expect(
      lines.fold<int>(0, (a, l) => a + ((l as Map)['episodes'] as List).length),
      1670,
    );
  });

  test('parseDetail 线路按「能不能播」重排：明文线在前，票据线沉底', () async {
    final out = await call('parseDetail', [
      fixture('juzong_detail.html'),
      <String, dynamic>{...baseCtx, 'dramaId': '106'},
    ]);
    final lines = (out['lines'] as List).cast<Map>();
    final names = lines.map((e) => e['line'] as String).toList();

    // XG / BF / DY 是真能播的明文线，必须排在最前
    expect(names[0], contains('XG'));
    expect(names[1], contains('BF'));
    expect(names[2], contains('DY'));

    // 独家/维护 是票据线，要沉到最后三条
    final tail = names.sublist(names.length - 3).join('|');
    expect(tail, contains('独家'));
    expect(tail, contains('维护'));

    // 网页源（鹅播）排在明文之后、票据之前
    final ebb = names.indexWhere((n) => n.contains('鹅播'));
    expect(ebb, greaterThan(2));
    expect(ebb, lessThan(names.length - 3));
  });

  test('parseDetail 集数只收本剧，且按线路去重', () async {
    final out = await call('parseDetail', [
      fixture('juzong_detail.html'),
      <String, dynamic>{...baseCtx, 'dramaId': '106'},
    ]);
    final lines = (out['lines'] as List).cast<Map>();
    for (final l in lines) {
      final eps = (l['episodes'] as List).cast<Map>();
      // 串剧防御：url 里的剧号必须都是 106
      for (final e in eps) {
        expect(e['url'], startsWith('/vodplay/106-'));
      }
      final urls = eps.map((e) => e['url']).toSet();
      expect(urls, hasLength(eps.length), reason: '有重复集');
      expect(eps.first['name'], isNotEmpty);
    }
  });

  test('parseDetail 补齐 area/year/director/actor，简介剥掉站方模板话术', () async {
    final out = await call('parseDetail', [
      fixture('juzong_detail.html'),
      <String, dynamic>{...baseCtx, 'dramaId': '106'},
    ]);

    expect(out['area'], '大陆');
    expect(out['year'], 2023);
    expect(out['director'], contains('石头熊'));
    expect(out['actor'], contains('史泽鲲'));
    // 主演是 12 个人，必须都收到；窗口给小了会只匹配到别人的演员表
    expect(out['actor'], contains('张铎'));

    // 正文不能带着「欢迎在线观看由…祝你观片愉快！」这段广告
    final content = out['content'] as String;
    expect(content, isNotEmpty);
    expect(content, isNot(contains('欢迎在线观看')));
    expect(content, isNot(contains('祝你观片愉快')));
    expect(content, isNot(contains('剧情简介')));
    expect(content, startsWith('改编自耳根同名小说'));
    // 正文要完整，不能只取 detail-sketch 的截断版（54 字）
    expect(content.length, greaterThan(100));
  });

  test('parseDetail 封面不吃 #topbanner 里的隐藏提示图', () async {
    final out = await call('parseDetail', [
      fixture('juzong_detail.html'),
      <String, dynamic>{...baseCtx, 'dramaId': '106'},
    ]);
    final pic = out['pic'] as String;
    expect(pic, startsWith('http'));
    // 站点在页面顶部塞了一张 display:none 的优酷占位图（class=tip-img），
    // 它排在所有 <img> 的最前面
    expect(pic, isNot(contains('ykimg')));
    expect(pic, isNot(contains('tip-img')));
    expect(pic, isNot(contains('/statics/')));
    expect(pic, contains('126.net'));
  });

  test('parseDetail 拿不到剧号时不串出别的剧（防御生效即可）', () async {
    final out = await call('parseDetail', [
      fixture('juzong_detail.html'),
      <String, dynamic>{...baseCtx},
    ]);
    // ctx 没给 dramaId 时不做串剧过滤，但仍应能出线路
    expect(out['name'], '仙逆');
    expect((out['lines'] as List), isNotEmpty);
  });

  // ==================== 取址 ====================

  test('parseResolve 明文线直接给出 m3u8', () async {
    final out = await call('parseResolve', [
      fixture('juzong_play_plain.html'),
      <String, dynamic>{...baseCtx, 'line': '剧踪DY[海外]'},
    ]);
    expect(out['error'], anyOf(isNull, isEmpty));
    final url = out['url'] as String;
    expect(url, startsWith('http'));
    expect(url, contains('.m3u8'));
  });

  test('parseResolve 票据线给出人话原因而不是格式错误', () async {
    final out = await call('parseResolve', [
      fixture('juzong_play_ticket.html'),
      <String, dynamic>{...baseCtx, 'line': '剧踪独家[热播X]'},
    ]);
    expect(out['url'], '');
    final err = out['error'] as String;
    expect(err, isNotEmpty);
    // 要告诉用户「换哪条线」，而不是把一串票据甩出来
    expect(err, contains('解析'));
    expect(err, contains('XG'));
  });

  test('player_data 变量名取错会静默返回空地址（回归护栏）', () async {
    // 站点用的是 player_data；如果哪天有人改回 player_aaaa，
    // 这个用例会立刻红，而不是等到线上播放全挂
    final out = await call('parseResolve', [
      '<html><script>var player_data={"url":"https:\\/\\/x.cc\\/a.m3u8","from":"dyttm3u8","encrypt":0};</script></html>',
      baseCtx,
    ]);
    expect(out['url'], 'https://x.cc/a.m3u8');
  });
}