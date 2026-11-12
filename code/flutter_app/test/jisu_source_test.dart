/// 极速追剧（jisuzhuiju.com）适配器的离线回归测试。
///
/// 这个源有两个「猜错就静默失效」的地方，所以测试必须盯死：
///
/// 1. **搜索参数是 `keyword`，不是 `wd`/`q`**。猜错不会报错，只会返回
///    12 条固定「热门影片」，界面上看起来"搜到东西了"，实际与关键词无关。
///
/// 2. **`data-index` 是 0-based，API 的 `index` 是 1-based**。
///    直接拿 `data-index` 去请求，`index=0` 一律 500「未找到该集播放地址」，
///    表现为"第一集永远播不了"，极难归因。
///
/// 下面的 HTML 片段全部截自线上真实响应，期望值也对着真实响应对过。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/jisu_source.dart';
import 'package:zhuiju/core/source/registry.dart';

// ==================== 真实样本（截自线上抓取，勿手改） ====================

/// 分类页一张卡片，来自 `/filter?channel=1`（id 561 兰香如故）。
///
/// 注意 `alt` 统一写成「XX封面图片」，直接拿来当剧名会带后缀。
const String _kCard = '''
<div class="col-4 col-md-2">
<a href="/detail/561.html" class="text-decoration-none">
<div class="vod-card">
<div class="vod-cover">
<img src="https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc00200803dr6b1788321761608/0" alt="兰香如故封面图片"
class="w-100 h-100" width="200" height="300"
loading="lazy" decoding="async" referrerpolicy="no-referrer">
<span class="vod-badge vod-badge-episodes">全1集</span>
</div>
<div class="vod-card-info">
<p class="vod-title mb-0">兰香如故</p>
<p class="vod-subtitle mb-0">古装爱情,女性成长,逆袭,内地剧</p>
</div>
</div>
</a>
</div>
''';

/// 搜索页一张卡片，来自 `/search?keyword=灵境`。
///
/// 结构与列表页**不同**（`.search-item` 不是 `.vod-card`），
/// 所以走单独的 `parseJisuSearchCards`。
const String _kSearchItem = '''
<div class="search-item">
<a href="/detail/702.html" class="search-item-poster">
<img src="https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc0020082u0tna1787815487790/0" alt="灵境行者封面图片"
width="120" height="160" loading="lazy" decoding="async" referrerpolicy="no-referrer">
</a>
<div class="search-item-info">
<div class="search-item-head">
<a href="/detail/702.html" class="search-item-title text-decoration-none">灵境行者</a>
<span class="search-item-type">动漫</span>
</div>
</div>
</div>
''';

/// 详情页的线路 tab。4 条线路，序号即 source-N。
const String _kTabs = '''
<div class="source-tabs">
<button class="source-tab active"
onclick="switchSource(this)" data-target="source-0">腾讯官方线路</button><button class="source-tab"
onclick="switchSource(this)" data-target="source-1">自建线路</button><button class="source-tab"
onclick="switchSource(this)" data-target="source-2">普通线路二</button><button class="source-tab"
onclick="switchSource(this)" data-target="source-3">普通线路一</button>
</div>
''';

/// 线路面板。**`class` 与 `id` 之间是换行 + 缩进，不是空格** ——
/// 这是真实结构，早先按同行的写法去匹配，一个面板都取不到，
/// 表现为「详情页 0 集，但首页/分类/搜索都正常」。
const String _kPanelQq = '''
<div class="source-panel"
id="source-0"
data-visible="1">
<div class="episode-grid">
<a href="/vodplay/702-qq-1.html"
class="episode-btn text-decoration-none"
data-index="0">第1集</a><a href="/vodplay/702-qq-2.html"
class="episode-btn text-decoration-none"
data-index="1">第2集</a><a href="/vodplay/702-qq-3.html"
class="episode-btn text-decoration-none"
data-index="2">第3集</a>
</div>
</div>
''';

/// 第二条线路，集数比第一条少 —— 真实情况：qq 15 集，其余各 12 集。
const String _kPanelBfzy = '''
<div class="source-panel"
id="source-2"
data-visible="0">
<div class="episode-grid">
<a href="/vodplay/702-bfzym3u8-1.html"
class="episode-btn text-decoration-none"
data-index="0">第1集</a><a href="/vodplay/702-bfzym3u8-2.html"
class="episode-btn text-decoration-none"
data-index="1">第2集</a>
</div>
</div>
''';

/// 详情页 <head>。剧名裹在书名号里，`og:image` 是海报。
const String _kDetailHead = '''
<title>《灵境行者》动漫高清完整版免费在线观看 - 极速追剧</title>
<meta name="description" content="《灵境行者》是2023年起点头部同名小说改编动画，作者卖报小郎君。">
<meta name="keywords" content="灵境行者,,,中国大陆">
<meta property="og:title" content="《灵境行者》动漫高清完整版免费在线观看">
<meta property="og:image" content="https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc0020082u0tna1787815487790/0">
''';

void main() {
  group('jisuPlayToken —— 线路前缀 + 集数打包', () {
    test('打包与拆包往返一致', () {
      expect(jisuPlayToken('bfzym3u8', 7), 'bfzym3u8|7');
      final t = jisuParsePlayToken('bfzym3u8|7')!;
      expect(t.prefix, 'bfzym3u8');
      expect(t.ep, 7);
    });

    test('前缀里带数字也不拆错（用最后一个 | 切）', () {
      final t = jisuParsePlayToken('line2|13')!;
      expect(t.prefix, 'line2');
      expect(t.ep, 13);
    });

    test('格式不对一律 null（宁可报错，也不要发出非法请求）', () {
      expect(jisuParsePlayToken(''), isNull);
      expect(jisuParsePlayToken('abc'), isNull); // 没有分隔符
      expect(jisuParsePlayToken('|5'), isNull); // 缺前缀
      expect(jisuParsePlayToken('abc|'), isNull); // 缺集数
      expect(jisuParsePlayToken('abc|0'), isNull); // index 必须 >= 1
      expect(jisuParsePlayToken('abc|-3'), isNull);
    });

    test('集数是 1-based，第 1 集不会被当成 0 丢掉', () {
      // 这是本适配器最容易踩的坑：data-index 从 0 开始，但 API index 从 1 开始。
      expect(jisuParsePlayToken(jisuPlayToken('qq', 1))!.ep, 1);
    });
  });

  group('从播放页路径提取前缀与集数', () {
    test('真实路径', () {
      expect(jisuPrefixOf('/vodplay/702-jsm3u8-3.html'), 'jsm3u8');
      expect(jisuEpOf('/vodplay/702-jsm3u8-3.html'), 3);
    });

    test('前缀含数字（covip / bfzym3u8）', () {
      expect(jisuPrefixOf('/vodplay/702-bfzym3u8-12.html'), 'bfzym3u8');
      expect(jisuEpOf('/vodplay/702-bfzym3u8-12.html'), 12);
      expect(jisuPrefixOf('/vodplay/702-covip-1.html'), 'covip');
    });

    test('不匹配的路径返回 null', () {
      expect(jisuPrefixOf('/detail/702.html'), isNull);
      expect(jisuEpOf(''), isNull);
    });
  });

  group('parseJisuCards —— 列表页卡片', () {
    test('真实卡片：标题取 vod-title，去掉「封面图片」后缀', () {
      final list = parseJisuCards(_kCard, sourceId: 'jisu');
      expect(list.length, 1);
      expect(list.single.id, '561');
      expect(list.single.name, '兰香如故');
      expect(list.single.name, isNot(contains('封面图片')));
      expect(list.single.cover.path, startsWith('https://'));
      expect(list.single.sourceId, 'jisu');
    });

    test('同一 id 只收一次', () {
      expect(parseJisuCards('$_kCard $_kCard', sourceId: 'jisu').length, 1);
    });

    test('空页面返回空表而不是抛异常', () {
      expect(parseJisuCards('', sourceId: 'jisu'), isEmpty);
    });

    test('没有标题的卡片直接丢弃（不生成空壳）', () {
      const junk = '''
<a href="/detail/999.html"><div class="vod-card">
<div class="vod-cover"><img src="https://x.com/a.jpg"></div>
</div></a>
''';
      // alt 缺失时退到空串，标题为空即丢弃
      expect(parseJisuCards(junk, sourceId: 'jisu'), isEmpty);
    });
  });

  group('parseJisuSearchCards —— 搜索页卡片', () {
    test('真实搜索项：结构与列表页不同，走单独解析', () {
      final list = parseJisuSearchCards(_kSearchItem, sourceId: 'jisu');
      expect(list.length, 1);
      expect(list.single.id, '702');
      expect(list.single.name, '灵境行者');
      expect(list.single.name, isNot(contains('封面图片')));
      expect(list.single.cover.path, startsWith('https://'));
    });

    test('列表页解析器读不出搜索页卡片（两者结构确实不同）', () {
      // 反向锁住：如果哪天有人把两个解析器合并，这条会红。
      expect(parseJisuCards(_kSearchItem, sourceId: 'jisu'), isEmpty);
    });

    test('空页面返回空表', () {
      expect(parseJisuSearchCards('', sourceId: 'jisu'), isEmpty);
    });
  });

  group('parseJisuDetail —— 详情页', () {
    test('跨行属性也能解析出线路面板（回归：曾因此 0 集）', () {
      // 真实 HTML 里 class 与 id 之间是换行 + 缩进。早先按同行匹配，
      // 结果详情页 0 集，而首页/分类/搜索全都正常，很难归因。
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelQq,
        sourceId: 'jisu',
      );
      expect(d.videos.length, 3);
    });

    test('剧名取书名号内内容', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelQq,
        sourceId: 'jisu',
      );
      expect(d.name, '灵境行者');
      expect(d.name, isNot(contains('高清完整版')));
    });

    test('线路中文名按 source-N 顺序对齐到面板', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelBfzy,
        sourceId: 'jisu',
      );
      // source-2 对应「普通线路二」
      expect(d.videos.first.sourceCn, '普通线路二');
    });

    test('playToken 带上线路前缀，且集数是 1-based', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelQq,
        sourceId: 'jisu',
      );
      expect(d.videos.first.playToken, 'qq|1');
      expect(d.videos.first.episode, 1);
      expect(d.videos.last.playToken, 'qq|3');
      // 每一条都必须能拆回来，否则播放必失败
      for (final v in d.videos) {
        final t = jisuParsePlayToken(v.playToken);
        expect(t, isNotNull, reason: '${v.id} token=${v.playToken}');
        expect(t!.ep, v.episode);
      }
    });

    test('path 用线路自己的前缀，与 playToken 一致', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelBfzy,
        sourceId: 'jisu',
      );
      expect(d.videos.first.path, '/vodplay/702-bfzym3u8-1.html');
      expect(jisuPrefixOf(d.videos.first.path), 'bfzym3u8');
    });

    test('多条线路一起解析，同 id 不撞车', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelQq + _kPanelBfzy,
        sourceId: 'jisu',
      );
      expect(d.videos.length, 5); // qq 3 集 + bfzym3u8 2 集
      expect(d.videos.map((e) => e.id).toSet().length, 5);
      final lines = d.videos.map((e) => e.sourceCn).toSet();
      expect(lines, {'腾讯官方线路', '普通线路二'});
    });

    test('封面优先海报容器，不被推荐位图干扰', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelQq,
        sourceId: 'jisu',
      );
      expect(d.cover.path, contains('mzc0020082u0tna'));
    });

    test('简介取 meta description', () {
      final d = parseJisuDetail(
        '702',
        _kDetailHead + _kTabs + _kPanelQq,
        sourceId: 'jisu',
      );
      expect(d.intro, contains('灵境行者'));
    });

    test('空页面不抛异常，只返回空选集', () {
      final d = parseJisuDetail('999', '', sourceId: 'jisu');
      expect(d.videos, isEmpty);
      expect(d.id, '999');
    });
  });

  group('parseJisuIntro', () {
    test('优先 description', () {
      expect(parseJisuIntro(_kDetailHead), contains('卖报小郎君'));
    });

    test('description 缺失退 keywords', () {
      const html = '<meta name="keywords" content="A剧,B剧">';
      expect(parseJisuIntro(html), 'A剧,B剧');
    });

    test('都没有返回空串', () {
      expect(parseJisuIntro('<html></html>'), '');
    });

    test('还原 HTML 实体', () {
      const html = '<meta name="description" content="A &amp; B &quot;引号&quot;">';
      expect(parseJisuIntro(html), 'A & B "引号"');
    });
  });

  group('注册表登记', () {
    final registry = SourceRegistry.instance;

    test('jisu 已注册且能被 byId 找到', () {
      final s = registry.byId('jisu');
      expect(s.id, 'jisu');
      expect(s.displayName, '极速追剧');
      expect(s.supportsDanmaku, isFalse);
    });

    test('分类齐全：推荐 + 5 个 channel', () {
      final ids = registry.byId('jisu').categories.map((c) => c.id).toList();
      // channel 实测 1-5 全部有数据（不像某些源存在空分区）
      expect(ids, ['', '1', '2', '3', '4', '5']);
    });

    test('描述里写清了「需代理」（用户选源能看见）', () {
      expect(registry.byId('jisu').description, contains('代理'));
    });
  });

  group('真实完整 HTML 复验', () {
    // 样本是逆向时抓的完整响应，放在 .workbuddy/tmp（不入仓库，体积大）。
    // 有样本就真跑，没有就跳过 —— 不能写死 skip，否则在有样本的机器上
    // 这段等于没测（真实 HTML 与内联片段的结构差异正是坑的来源）。
    const dir = r'C:\Users\fengxin\WorkBuddy\vivos7\.workbuddy\tmp\jisu';
    final detailFile = File('$dir\\detail.html');
    final chFile = File('$dir\\ch1.html');
    final hasSamples = detailFile.existsSync() && chFile.existsSync();

    test('详情页：4 条线路共 51 集，集数与线路一一对应', () {
      final d = parseJisuDetail(
        '702',
        detailFile.readAsStringSync(),
        sourceId: 'jisu',
      );
      final byLine = <String, int>{};
      for (final v in d.videos) {
        byLine[v.sourceCn] = (byLine[v.sourceCn] ?? 0) + 1;
      }
      // 真实分布：腾讯官方线路 15 集，其余三条各 12 集
      expect(byLine['腾讯官方线路'], 15);
      expect(byLine['自建线路'], 12);
      expect(byLine['普通线路二'], 12);
      expect(byLine['普通线路一'], 12);
      expect(d.videos.length, 51);
      expect(d.name, '灵境行者');
      for (final v in d.videos) {
        expect(jisuParsePlayToken(v.playToken), isNotNull);
      }
    }, skip: hasSamples ? false : '样本不存在（.workbuddy/tmp/jisu 未保留）');

    test('分类页首页 12 张卡全部有标题和封面', () {
      final list = parseJisuCards(chFile.readAsStringSync(), sourceId: 'jisu');
      expect(list.length, 12);
      expect(list.every((e) => e.name.isNotEmpty), isTrue);
      expect(list.every((e) => e.cover.path.startsWith('http')), isTrue);
    }, skip: hasSamples ? false : '样本不存在（.workbuddy/tmp/jisu 未保留）');
  });
}