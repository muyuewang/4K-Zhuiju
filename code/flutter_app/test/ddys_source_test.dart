/// 低调影视（ddys.io）适配器的离线回归测试。
///
/// 样本取自 2026-11-12 的真实页面（HTML 结构原样保留，只截短无关部分）。
///
/// 重点钉住三条规则：
///   1. 卡片必须**按块切**，否则 A 卡的封面会配到 B 卡的标题；
///   2. 集数串是 `第01集$url#第02集$url`，分隔符是 `#`、字段分隔符是 `$`；
///   3. 播放**零请求**——m3u8 在详情页就已下发。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/ddys_source.dart';
import 'package:zhuiju/core/source/registry.dart';

// ------------------------------ 真实样本 ------------------------------

/// 真实卡片（/movie 页面第二张，slug=inheritance）。
const String _kCard = r'''
<div class="movie-card bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 shadow-sm">
        <a href="/movie/inheritance" target="_blank" class="block relative overflow-hidden aspect-[2/3] bg-gray-100">
                                    <img 
                src="https://img.ddys.io/movies/inheritance.webp" 
                alt="血继"
                class="w-full h-full object-cover"
                loading="lazy"
                onerror="this.onerror=null; this.style.display='none'; this.nextElementSibling.style.display='flex';"
            >
            <div class="w-full h-full flex items-center justify-center text-gray-400 text-xs" style="display:none;">
                暂无海报
            </div>
                        
                        <div class="poster-badge badge-top-left badge-new">
                新片            </div>
                        
                        
                    </a>
        
        <div class="p-4">
            <h3 class="text-sm font-medium text-gray-900 dark:text-gray-100 mb-2 line-clamp-1">
                <a href="/movie/inheritance" target="_blank" class="hover:text-gray-600 dark:hover:text-gray-300 transition-colors">
                    血继                </a>
            </h3>

            <div class="text-xs text-gray-500 dark:text-gray-400 font-light mb-3">
                2024 · 电影            </div>
            
                        
            <div class="flex items-center gap-3 text-xs text-gray-600 font-light">
                                                <span>网盘：2</span>
                            </div>
        </div>
    </div>
''';

/// 另一张真实卡片（带「在线」计数）。用于验证按块切不会串卡。
const String _kCard2 = r'''
<div class="movie-card bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 shadow-sm">
        <a href="/movie/a-frozen-rage" target="_blank" class="block relative overflow-hidden aspect-[2/3] bg-gray-100">
                                    <img 
                src="https://img.ddys.io/movies/a-frozen-rage.webp" 
                alt="一雪前耻"
                class="w-full h-full object-cover"
                loading="lazy"
            >
                        <div class="poster-badge badge-top-right">
                5.7            </div>
                    </a>
        
        <div class="p-4">
            <h3 class="text-sm font-medium text-gray-900 dark:text-gray-100 mb-2 line-clamp-1">
                <a href="/movie/a-frozen-rage" target="_blank" class="hover:text-gray-600 dark:hover:text-gray-300 transition-colors">
                    一雪前耻                </a>
            </h3>

            <div class="text-xs text-gray-500 dark:text-gray-400 font-light mb-3">
                2025 · 电影            </div>
            
                        
            <div class="flex items-center gap-3 text-xs text-gray-600 font-light">
                                <span>在线：3</span>
                                                <span>网盘：2</span>
                            </div>
        </div>
    </div>
''';

/// 真实播放源按钮（/movie/honor，共 10 集，线路名「播放源 1 (1080P)」）。
const String _kPlayBtn = r'''
<button
                    onclick="switchSource(16729, '第01集$https://v.lzcdn27.com/20260202/4397_9e04d6c6/index.m3u8#第02集$https://v.lzcdn27.com/20260203/4449_67a9929e/index.m3u8#第03集$https://v.lzcdn27.com/20260209/4924_3ef45404/index.m3u8', 'm3u8')"
                    class="px-3 md:px-4 py-1.5 md:py-2 text-xs md:text-sm border border-gray-200 dark:border-gray-700"
                    id="source-tab-16729"
                >
                    播放源 1 (1080P)
                </button>
''';

/// 详情页头部元信息（取自 /movie/honor 真实结构）。
const String _kDetailHead = r'''
<h1 class="text-xl md:text-3xl font-light text-gray-900 dark:text-gray-100 mb-3 md:mb-4">
                    荣耀：她们的法庭                                        <span class="block text-sm md:text-base text-gray-500 dark:text-gray-400 font-light mt-1">荣耀(韩版) / Heder(韩版) / 荣耀 / 荣誉 / 아너 / Honor</span>
                                    </h1>
                <div class="text-xs md:text-sm text-gray-600 dark:text-gray-400 mb-3 md:mb-4 font-light">
                    2026 · 韩国 · 剧情 / 惊悚 / 犯罪                </div>
                                <div class="flex items-center gap-2 text-xs md:text-sm text-gray-600 dark:text-gray-400 font-light mb-3 md:mb-4">
                                        <span class="rating-display">豆瓣（6.7）</span>
                                    </div>
                                <div class="text-xs md:text-sm text-gray-700 dark:text-gray-300 mb-2 font-light">
                    <span class="text-gray-500 dark:text-gray-400">导演：</span>
                    <span>朴建浩</span>
                </div>
                                <div class="text-xs md:text-sm text-gray-700 dark:text-gray-300 mb-4 md:mb-6 font-light">
                    <span class="text-gray-500 dark:text-gray-400">主演：</span>
                    <span>李奈映 / 郑恩彩 / 李清娥 / 延宇振 / 徐现宇 / 崔英俊</span>
                </div>
''';

/// 详情页海报（alt 与剧名一致，页面无 og:image）。
const String _kDetailPoster = r'''
<img src="https://img.ddys.io/movies/honor.webp" alt="荣耀：她们的法庭" class="absolute inset-0 w-full h-full object-contain opacity-60">
''';

const String _kDescMeta = r'''
<meta name="description" content="《荣耀：她们的法庭》免费在线观看，那个浑身是血、蜷缩在豪华别墅书桌底下的女孩。">
''';

/// 第二条线路（单集，用来验证多线路独立）。
const String _kPlayBtn2 = r'''
<button onclick="switchSource(17000, 'HD中字$https://v2.example.com/20260301/9999_abc/index.m3u8', 'm3u8')"
        id="source-tab-17000"> 播放源 2 (720P) </button>
''';

void main() {
  // ---------------------------- 卡片解析 ----------------------------

  group('parseDdysCards', () {
    test('解析单张卡片', () {
      final list = parseDdysCards(_kCard, sourceId: 'ddys');
      expect(list.length, 1);
      expect(list[0].id, 'inheritance');
      expect(list[0].name, '血继');
      expect(list[0].year, 2024);
      expect(list[0].clazz, '电影');
      expect(list[0].cover.path, 'https://img.ddys.io/movies/inheritance.webp');
      expect(list[0].sourceId, 'ddys');
    });

    test('「网盘：2」进 remark，让用户知道只有网盘', () {
      final list = parseDdysCards(_kCard, sourceId: 'ddys');
      expect(list[0].remark, '网盘 2');
    });

    test('「在线：3 + 网盘：2」两个都记下来', () {
      final list = parseDdysCards(_kCard2, sourceId: 'ddys');
      expect(list[0].remark, contains('在线 3'));
      expect(list[0].remark, contains('网盘 2'));
    });

    test('回归：多卡不串——A 卡封面不能配到 B 卡标题', () {
      // 早期实现用整页正则，会把第一张卡的封面配到最后一张的标题。
      const html = '$_kCard$_kCard2';
      final list = parseDdysCards(html, sourceId: 'ddys');
      expect(list.length, 2);
      final a = list.firstWhere((e) => e.id == 'a-frozen-rage');
      expect(a.name, '一雪前耻');
      expect(a.cover.path, contains('a-frozen-rage'));
      final b = list.firstWhere((e) => e.id == 'inheritance');
      expect(b.name, '血继');
      expect(b.cover.path, contains('inheritance'));
    });

    test('同一 slug 出现两次只保留一条', () {
      final list = parseDdysCards('$_kCard$_kCard', sourceId: 'ddys');
      expect(list.length, 1);
    });

    test('空页面返回空表', () {
      expect(parseDdysCards('<html></html>', sourceId: 'ddys'), isEmpty);
    });

    test('卡片缺 slug 时跳过', () {
      const broken = '<div class="movie-card"><h3><a>无链接</a></h3></div>';
      expect(parseDdysCards(broken, sourceId: 'ddys'), isEmpty);
    });
  });

  // ---------------------------- 线路解析 ----------------------------

  group('parseDdysLines', () {
    test('解析线路名与选集', () {
      final lines = parseDdysLines(_kPlayBtn);
      expect(lines.length, 1);
      expect(lines[0].name, '播放源 1 (1080P)');
      expect(lines[0].episodes.length, 3);
      expect(lines[0].episodes[0].title, '第01集');
      expect(lines[0].episodes[0].url,
          'https://v.lzcdn27.com/20260202/4397_9e04d6c6/index.m3u8');
      expect(lines[0].episodes[2].title, '第03集');
    });

    test('多条线路各自独立', () {
      final lines = parseDdysLines('$_kPlayBtn$_kPlayBtn2');
      expect(lines.length, 2);
      expect(lines[0].episodes.length, 3);
      expect(lines[1].name, '播放源 2 (720P)');
      expect(lines[1].episodes.length, 1);
      expect(lines[1].episodes[0].title, 'HD中字');
    });

    test('非 m3u8 类型跳过（防止把网盘当在线播）', () {
      const pan = r'''<button onclick="switchSource(1, '文件$https://pan.example.com/f', 'quark')">网盘</button>''';
      expect(parseDdysLines(pan), isEmpty);
    });

    test('没有集数串时跳过整条线路', () {
      const empty = r'''<button onclick="switchSource(1, '', 'm3u8')">空线路</button>''';
      expect(parseDdysLines(empty), isEmpty);
    });

    test('URL 里带 & 也能完整取出', () {
      const q = r'''<button onclick="switchSource(1, '第01集$https://x.com/a/index.m3u8?sign=1&t=2', 'm3u8')">L</button>''';
      final lines = parseDdysLines(q);
      expect(lines.single.episodes.single.url, contains('sign=1&t=2'));
    });

    // ===== 回归：用户报「好多封面显示有在线线路、点进去但是没有」 =====

    test('纯 URL 形态（没有美元符也没有井号）也要解出线路', () {
      // 电影基本都是这个形态：第二个参数就是一条完整 m3u8 地址。
      // 实测 8 部剧 19 个按钮里有 7 个是纯 URL，早先只按 `$` 切分会全部丢掉，
      // 于是卡片写着「在线：2」、点进去线路是空的。
      const bare = r'''
<button
    onclick="switchSource(75400, 'https://vip.lz-cdn3.com/20220819/11730_626a60df/index.m3u8', 'm3u8')"
    id="source-tab-75400"
>
    备胎1号 (1080P)
</button>
''';
      final lines = parseDdysLines(bare);
      expect(lines.length, 1);
      expect(lines.single.name, '备胎1号 (1080P)');
      expect(lines.single.episodes.length, 1);
      expect(
        lines.single.episodes.single.url,
        'https://vip.lz-cdn3.com/20220819/11730_626a60df/index.m3u8',
      );
    });

    test('纯 URL 形态的集名统一为「正片」，不把清晰度当集名', () {
      // 按钮名带 (1080P)，直接当集名会让选集网格出现「备胎1号 (1080P)」这种字。
      const bare = r'''
<button onclick="switchSource(71534, 'https://v.lzcdn27.com/20261101/20902_9f43b412/index.m3u8', 'm3u8')"> 播放源 1 (1080P) </button>
''';
      final lines = parseDdysLines(bare);
      expect(lines.single.episodes.single.title, '正片');
    });

    test('真实影片：纯 URL 与集数串可以共存，线路数要对得上', () {
      // wonder-wheel 实测 2 个按钮全是纯 URL，早先解出 0 条线路。
      const wonderWheel = r'''
<button onclick="switchSource(75400, 'https://vip.lz-cdn3.com/20220819/11730_626a60df/index.m3u8', 'm3u8')" id="source-tab-75400"> 备胎1号 (1080P) </button>
<button onclick="switchSource(75401, 'https://c1.rrcdnbf2.com/video/motianlun/HD中字/index.m3u8', 'm3u8')" id="source-tab-75401"> 备胎2号 (1080P) </button>
''';
      final lines = parseDdysLines(wonderWheel);
      expect(lines.length, 2, reason: '两个按钮两条线路，一条都不能少');
      expect(lines[0].episodes.single.url, contains('lz-cdn3.com'));
      expect(lines[1].episodes.single.url, contains('rrcdnbf2.com'));
    });

    test('纯 URL 但协议相对（//开头）也能补成 https', () {
      const proto = r'''
<button onclick="switchSource(1, '//cdn.example.com/a/index.m3u8', 'm3u8')">L</button>
''';
      final lines = parseDdysLines(proto);
      expect(lines.single.episodes.single.url, 'https://cdn.example.com/a/index.m3u8');
    });

    test('纯 URL 但不是 http(s) 的（如 covip 编码）要跳过', () {
      const junk = r'''
<button onclick="switchSource(1, 'covip_abc123', 'm3u8')">L</button>
''';
      expect(parseDdysLines(junk), isEmpty);
    });
  });

  // ---------------------------- 详情解析 ----------------------------

  group('parseDdysDetail', () {
    const html =
        '$_kDescMeta$_kDetailPoster$_kDetailHead$_kPlayBtn$_kPlayBtn2';
    final d = parseDdysDetail('honor', html, sourceId: 'ddys');

    test('剧名只取 h1 第一段，不带别名', () {
      // h1 里嵌了 <span>别名</span>，直接取整段会变成
      // 「荣耀：她们的法庭 荣耀(韩版) / Heder(韩版) / …」。
      expect(d.name, '荣耀：她们的法庭');
      expect(d.name.contains('Heder'), isFalse);
    });

    test('年份 / 地区 / 类型', () {
      expect(d.year, 2026);
      expect(d.area, '韩国');
      expect(d.tag, '剧情 / 惊悚 / 犯罪');
    });

    test('导演与主演', () {
      expect(d.director, '朴建浩');
      expect(d.actor, contains('李奈映'));
      expect(d.actor, contains('郑恩彩'));
    });

    test('豆瓣评分', () {
      expect(d.stars, 6.7);
    });

    test('简介来自 meta description', () {
      expect(d.intro, contains('荣耀'));
      expect(d.brief, isNotEmpty);
    });

    test('封面锚定 alt=剧名 的那张海报', () {
      expect(d.cover.path, 'https://img.ddys.io/movies/honor.webp');
    });

    test('选集按线路展开，共 4 条', () {
      expect(d.videos.length, 4);
      expect(d.videos.where((v) => v.sourceCn == '播放源 1 (1080P)').length, 3);
      expect(d.videos.where((v) => v.sourceCn == '播放源 2 (720P)').length, 1);
    });

    test('集号从标题抠出来（HD中字无集号则用序号）', () {
      final ep1 = d.videos.firstWhere((v) => v.title == '第01集');
      expect(ep1.episode, 1);
      final hd = d.videos.firstWhere((v) => v.title == 'HD中字');
      expect(hd.episode, 1);
    });

    test('path 就是 m3u8（播放零请求）', () {
      for (final v in d.videos) {
        expect(v.path, startsWith('http'));
        expect(v.path, contains('.m3u8'));
      }
    });

    test('剧集 id 带源前缀且唯一', () {
      final ids = d.videos.map((v) => v.id).toSet();
      expect(ids.length, d.videos.length);
      expect(d.videos.first.id, startsWith('ddys_honor_'));
    });

    test('没有播放源时 videos 为空但不崩', () {
      final only = parseDdysDetail('x', _kDetailHead, sourceId: 'ddys');
      expect(only.videos, isEmpty);
      expect(only.name, '荣耀：她们的法庭');
    });
  });

  // ---------------------------- 契约 ----------------------------

  group('DdysSource 契约', () {
    final s = DdysSource.instance;

    test('基本声明', () {
      expect(s.id, 'ddys');
      expect(s.displayName, '低调影视');
      expect(s.description, isNotEmpty);
      expect(s.supportsDanmaku, isFalse);
      expect(s.lineOrderPolicy, LineOrderPolicy.sourceOrder);
    });

    test('分类首位是推荐，其余是站点真实路径段', () {
      expect(s.categories.first.id, '');
      final ids = s.categories.map((c) => c.id).toList();
      expect(ids, containsAll(<String>['movie', 'series', 'variety', 'anime']));
    });
  });

  group('注册表', () {
    test('低调影视已登记在册', () {
      final registry = SourceRegistry.instance;
      expect(registry.byId('ddys').id, 'ddys');
      expect(SourceRegistry.all.any((e) => e.id == 'ddys'), isTrue);
    });

    // 名字里不写死数量：源在持续增加（10 → 15），写死会变成每加一个源
    // 就得改一次测试名，而测试要守的是「互不重复」这件事本身。
    test('所有源的 id 互不重复', () {
      final ids = SourceRegistry.all.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
      // 顺带守住「id 不能为空串」：空 id 会互相撞成同一个 key，
      // 但 toSet().length 依然等于 length，上面的断言抓不到。
      expect(ids.every((id) => id.trim().isNotEmpty), isTrue);
    });
  });
}