/// 4K影视（www.4kvm.net）适配器的离线回归测试。
///
/// 这个源的特殊性在于**取址算法是站点编译进 WASM 的**，一旦算错，服务端只会
/// 回 401（要么「不好意思，请稍后再试」= 签名错，要么「请提供访问令牌」= 缺
/// token），跟「站点改版」「网络不通」用肉眼完全分不出来。所以这里把逆向出来
/// 的算法对着**真实抓到的样本**钉死，改坏了立刻红，而不是等线上播不出来才排查。
///
/// 下面所有 HTML 片段都是从真实响应里截出来的（见各 group 注释），期望值也用
/// Python 独立复算过一遍，不是从别处抄来的。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/kvm4k_source.dart';
import 'package:zhuiju/core/source/registry.dart';

// ==================== 真实样本（截自线上抓取，勿手改） ====================

/// 列表页一张完整卡片，来自 `/filter?classify=2` 第 1 页（vodId `ch4rt1ctb`）。
///
/// 注意两个坑：
///   - 封面真图在 `data-src`，`src` 是站内占位 SVG（`placeholder-dark.svg`）
///   - 百度图床 URL 里的 `&` 是转义过的 `&amp;`
const String _kCard = '''
<div class="relative group movie-card cursor-pointe" data-vod-id="ch4rt1ctb">
<div class="block transition-opacity duration-300 ease-out md:group-hover:opacity-0">
<a href="/play/ch4rt1ctb" data-vod="ch4rsyjnz" class="block">
<div class="relative w-full aspect-[2/3] rounded-xl overflow-hidden bg-dark-800">
<img data-src="https://gimg0.baidu.com/gimg/app=2001&amp;n=0&amp;g=0n&amp;fmt=jpeg&amp;src=4kvm.staticimgjs.org/uploads/2026/10/douban_1793369964-300x450.jpg"
src="/static/images/placeholder-dark.svg"
alt="伟大的长征"
class="lazy w-full h-full object-cover">
<span class="absolute top-2 right-2 px-1.5 py-0.5 rounded text-xs font-bold">
4k
</span>
<span class="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent px-2 py-1.5 text-xs text-gray-200 text-right">
全60集
</span>
</div>
<h3 class="text-white text-sm font-medium truncate mt-2 text-center">伟大的长征</h3>
</a>
</div>
''';

/// 详情页一个选集锚点，来自 `/play/ch4sn04yf`（电影，只有「正片」）。
///
/// 集数标签在**最后一个** `<span>` 里，前面的三条竖条是「播放中」动画的
/// `<div class="playing-bar">`，很容易误抓。
///
/// 用 raw string（`r'''`）：片段里有 Alpine 的 `$el`，普通字符串会被 Dart
/// 当成变量插值，直接编译不过。
const String _kEpMovie = r'''
<a href="/play/ch4sn04yf" @click.prevent="handleEpisodeClick($el.getAttribute('href'), '42058', 1, 1)"
   x-show="showEpisode(1)" data-line="1" data-episode="1" dataid="42058" x-effect="if (isEpisodeActive(1, 1)) { }"
   class="episode-link relative px-2 py-3 rounded-lg text-sm font-medium transition text-center block">
    <div x-show="isEpisodeActive(1, 1)" class="playing-bars">
        <div class="playing-bar"></div>
        <div class="playing-bar"></div>
        <div class="playing-bar"></div>
    </div>
    <span x-show="!isEpisodeActive(1, 1)">
        正片
    </span>
</a>
''';

/// 电视剧详情页的选集锚点（`/play/ch4rt1ctb` 第 1 集）。
///
/// 站点对集数用纯数字标签（`1` / `2` / ...），**不带「第N集」前缀**；
/// 所以 `label` 应该原样是 `1`，而不是被兜底逻辑改成「第1集」。
const String _kEpTv = r'''
<a href="/play/ch4rt1ctb" @click.prevent="handleEpisodeClick($el.getAttribute('href'), '41755', 1, 1)"
   x-show="showEpisode(1)" data-line="1" data-episode="1" dataid="41755" x-effect="if (isEpisodeActive(1, 1)) { }"
   class="episode-link relative px-2 py-3 rounded-lg text-sm font-medium transition text-center block">
    <span x-show="!isEpisodeActive(1, 1)">
        1
    </span>
</a>
''';

/// 详情页的线路声明。`episodeManager` 是多行的，正则不能假设单行。
const String _kManager = '''
<div x-data="episodeManager(1, 1, [
            { lineName: 'alists', episodeCount: 60 }
        ])">
''';

/// 详情页 <head> 片段。**关键点：详情页没有 `data-src`，封面只在 `og:image`。**
const String _kDetailHead = '''
<title>伟大的长征 - 第1集 -4k影视</title>
<meta name="keywords" content="伟大的长征,电视剧,战争,历史">
<meta name="description" content="这是一部讲述长征历程的电视剧，全景式再现了那段艰苦卓绝的岁月。">
<meta property="og:title" content="伟大的长征 - 第1集">
<meta property="og:image" content="https://gimg0.baidu.com/gimg/app=2001&amp;n=0&amp;g=0n&amp;fmt=jpeg&amp;src=4kvm.staticimgjs.org/uploads/2026/11/douban_1794373831-300x450.jpg">
''';

/// 导航栏的 x-data，`userlink` 就从这里下发。
///
/// 同一段里还有 `window.myuserlink = userlink;` 和 `|| '0'`，泛匹配会抓到
/// 字符串 `userlink` 本身，所以必须钉住 `userlink:'...'` 这个形态。
const String _kNav = '''
<nav x-data="{ open: false, userlink:'X1VUW0JQXQQFBA4FCgc7IUleUEte' }">
<script>
  window.myuserlink = userlink || '0';
</script>
''';

void main() {
  group('kvmSign —— s 参数是 HMAC-SHA256(key=slug, msg="p:t:v")', () {
    // 期望值：Python hmac 独立复算，且与线上 WASM 的 build_play_url 输出一致。
    test('真实样本对拍', () {
      expect(
        kvmSign('42058', 1794455847849, 'ch4sn04yf'),
        '6376c553755437d87f76933b79885b0c',
      );
      expect(
        kvmSign('41755', 1794455847849, 'ch4rt1ctb'),
        '7ad39fae9b1ba777e7cd2e7f2009c4ae',
      );
    });

    test('时间戳差 1ms 就必须变（证明 t 进了消息体）', () {
      final a = kvmSign('42058', 1794455847849, 'ch4sn04yf');
      final b = kvmSign('42058', 1794455847850, 'ch4sn04yf');
      expect(a, isNot(b));
      expect(b, '02ca4e464baec8fbdd748ce359a6d4d7');
    });

    test('dataid 为空也照算（服务端自己会拦）', () {
      expect(
        kvmSign('', 1794455847849, 'ch4sn04yf'),
        '134b3a90ea770e8a6fc360c9c65d984f',
      );
    });

    test('输出恒为 32 位小写 hex（是全长 64 位的前半截）', () {
      final s = kvmSign('1', 1, 'x');
      expect(s.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(s), isTrue);
    });

    test('key 是 slug 而不是那个 nbmovie 密钥', () {
      // 用 kKvmSecret 当 key 会得到一个不同的值；这条断言防的是
      // 「把两个密钥搞混」——这是最容易犯且最难查的错。
      expect(kvmSign('1', 1, kKvmSecret), isNot(kvmSign('1', 1, 'x')));
    });
  });

  group('kvmKeyParam —— k 参数是 base64(userlink XOR 密钥)', () {
    test('真实 userlink 对拍', () {
      expect(
        kvmKeyParam('X1VUW0JQXQQFBA4FCgc7IUleUEte'),
        'NlM7OiFZL2NoY2U1JyJGIzcMBk4nNwEKIywRVw==',
      );
      expect(
        kvmKeyParam('X1VUW0JQXAICBg4FCgc7IUleUEte'),
        'NlM7OiFZL2Noc30wJwRGIzcMBk4nNwEKIywRVw==',
      );
    });

    test('密钥按索引循环取（长度不整除也能异或完）', () {
      // 密钥 19 字节，'AAAA'(4) 与 'AB'(2) 都应正常出结果且互不相同。
      expect(kvmKeyParam('AB'), 'LyA=');
      expect(kvmKeyParam('AAAA'), 'LyMsLg==');
    });

    test('空串与 "0" 都原样返回 "0"（未登录形态）', () {
      // 不能编码成 base64("") == ""，空参数会被服务端判 400 缺少必要参数。
      expect(kvmKeyParam(''), '0');
      expect(kvmKeyParam('0'), '0');
    });

    test('解回来能还原 userlink（XOR 自反）', () {
      const ul = 'X1VUW0NZVQAJAQ4FCgc7IUleUUBY';
      final back = base64Decode(kvmKeyParam(ul));
      final key = utf8.encode(kKvmSecret);
      for (var i = 0; i < back.length; i++) {
        back[i] = back[i] ^ key[i % key.length];
      }
      expect(utf8.decode(back), ul);
    });
  });

  group('kvmPlayQuery —— 取址参数拼装', () {
    test('六个参数齐全，s 与 t 同源', () {
      final q = kvmPlayQuery(
        dataid: '42058',
        vodId: 'ch4sn04yf',
        userlink: 'X1VUW0JQXQQFBA4FCgc7IUleUEte',
        tsMs: 1794455847849,
      );
      expect(q.keys.toSet(), {'p', 'v', 'q', 's', 't', 'k'});
      expect(q['p'], '42058');
      expect(q['v'], 'ch4sn04yf');
      expect(q['q'], '1');
      expect(q['t'], '1794455847849');
      expect(q['s'], '6376c553755437d87f76933b79885b0c');
      // s 必须是用同一个 t 算的，否则服务端会判签名错。
      expect(q['s'], kvmSign(q['p']!, int.parse(q['t']!), q['v']!));
    });

    test('默认画质档是 1（返回最全，4K 一起下发）', () {
      final q = kvmPlayQuery(
        dataid: '1',
        vodId: 'x',
        userlink: '0',
        tsMs: 0,
      );
      expect(q['q'], '1');
      expect(q['k'], '0');
    });

    test('可指定档位', () {
      final q = kvmPlayQuery(
        dataid: '1',
        vodId: 'x',
        userlink: '',
        tsMs: 0,
        quality: '1080',
      );
      expect(q['q'], '1080');
    });
  });

  group('kvmPickPlayableUrl —— 跳过 VIP 占位符', () {
    test('4K 是 isvip 且 url 是占位符 "1"，必须降级到 1080P', () {
      // 真实响应形态：4K 那档 url 就是字符串 "1"，把它丢给播放器只会得到
      // UnrecognizedInputFormat。
      final picked = kvmPickPlayableUrl([
        {
          'quality': '蓝光/4K',
          'url': '1',
          'isvip': true,
          'locked': true,
        },
        {
          'quality': '超清/1080p',
          'url': 'https://oss.douyinbit.com/m3u8/b49270ca0cf588e4acba659209a6c8bf.m3u8',
          'isvip': false,
          'locked': false,
        },
      ]);
      expect(
        picked,
        'https://oss.douyinbit.com/m3u8/b49270ca0cf588e4acba659209a6c8bf.m3u8',
      );
    });

    test('url 不是 http 开头的一律跳过（"1" / 空串 / null）', () {
      final picked = kvmPickPlayableUrl([
        {'url': '1'},
        {'url': ''},
        {'url': null},
        {'url': '   '},
        {'url': 'https://a.com/x.m3u8'},
      ]);
      expect(picked, 'https://a.com/x.m3u8');
    });

    test('只有 VIP 档时给出 VIP 地址兜底（有地址总比没有强）', () {
      final picked = kvmPickPlayableUrl([
        {'url': 'https://vip.com/a.m3u8', 'isvip': true},
      ]);
      expect(picked, 'https://vip.com/a.m3u8');
    });

    test('locked 也算不可直接播', () {
      final picked = kvmPickPlayableUrl([
        {'url': 'https://a.com/1.m3u8', 'locked': true},
        {'url': 'https://a.com/2.m3u8'},
      ]);
      expect(picked, 'https://a.com/2.m3u8');
    });

    test('优先返回第一个可播的（保持服务端给的画质顺序）', () {
      final picked = kvmPickPlayableUrl([
        {'url': 'https://a.com/first.m3u8'},
        {'url': 'https://a.com/second.m3u8'},
      ]);
      expect(picked, 'https://a.com/first.m3u8');
    });

    test('一条都没有时返回 null', () {
      expect(kvmPickPlayableUrl([]), isNull);
      expect(kvmPickPlayableUrl([{'url': '1', 'isvip': true}]), isNull);
    });

    test('url 两端空白会被 trim', () {
      final picked = kvmPickPlayableUrl([
        {'url': '  https://a.com/x.m3u8  '},
      ]);
      expect(picked, 'https://a.com/x.m3u8');
    });
  });

  group('kvmUserlinkOf —— 从导航栏 x-data 取令牌', () {
    test('真实 x-data 形态', () {
      expect(kvmUserlinkOf(_kNav), 'X1VUW0JQXQQFBA4FCgc7IUleUEte');
    });

    test('不会误抓 window.myuserlink = userlink 里的裸标识符', () {
      // 泛匹配 /userlink:?'?([^']*)'?/ 之类会抓到字符串 'userlink' 本身，
      // 那个值拿去异或后服务端直接回 401。
      const onlyAssign = '<script>window.myuserlink = userlink || \'0\';</script>';
      expect(kvmUserlinkOf(onlyAssign), '');
    });

    test('没有 userlink 时返回空串', () {
      expect(kvmUserlinkOf('<html></html>'), '');
      expect(kvmUserlinkOf(''), '');
    });

    test('空值形态 userlink:\'\' 返回空串', () {
      expect(kvmUserlinkOf("x-data=\"{ userlink:'' }\""), '');
    });
  });

  group('parseKvmCards —— 列表页卡片', () {
    test('真实卡片：标题取 h3、封面取 data-src 并还原 &amp;', () {
      final list = parseKvmCards(_kCard, sourceId: 'kvm4k');
      expect(list.length, 1);
      expect(list.first.id, 'ch4rt1ctb');
      expect(list.first.name, '伟大的长征');
      // src 是 placeholder-dark.svg，绝不能取它
      expect(list.first.cover.path, isNot(contains('placeholder')));
      expect(list.first.cover.path, contains('douban_1793369964-300x450.jpg'));
      // &amp; 没还原会 404
      expect(list.first.cover.path, contains('&n=0'));
      expect(list.first.cover.path, isNot(contains('&amp;')));
      expect(list.first.sourceId, 'kvm4k');
    });

    test('同一 id 重复出现只收一次（首页有多个分区）', () {
      const html = '$_kCard $_kCard';
      expect(parseKvmCards(html, sourceId: 'kvm4k').length, 1);
    });

    test('h3 缺失时退到 img alt', () {
      const noH3 = '''
<div data-vod-id="abc123">
<a href="/play/abc123" data-vod="zzz999" class="block">
<img data-src="https://x.com/a.jpg" alt="备用标题">
</a>
</div>
''';
      final list = parseKvmCards(noH3, sourceId: 'kvm4k');
      expect(list.single.name, '备用标题');
    });

    test('标题与封面都拿不到就丢弃（不生成空壳条目）', () {
      const junk = '''
<div data-vod-id="abc123">
<a href="/play/abc123" data-vod="zzz999" class="block"></a>
</div>
''';
      expect(parseKvmCards(junk, sourceId: 'kvm4k'), isEmpty);
    });

    test('协议相对地址补 https:', () {
      const proto = '''
<a href="/play/abc123" data-vod="zzz999" class="block">
<img data-src="//img.example.com/a.jpg" alt="某剧">
</a>
''';
      final list = parseKvmCards(proto, sourceId: 'kvm4k');
      expect(list.single.cover.path, 'https://img.example.com/a.jpg');
    });

    test('空页面返回空表而不是抛异常', () {
      expect(parseKvmCards('', sourceId: 'kvm4k'), isEmpty);
    });

    // ===== 回归：用户报「4k影视搜索功能异常、啥也是无结果」 =====

    test('搜索页卡片没有 data-vod-id，仍要能解出结果', () {
      // 实测 https://www.4kvm.net/search?q=凡人 里 `data-vod-id` 计数为 0，
      // 外层只是 `<div class="group relative">`，标识只在锚点上。
      // 早先按 data-vod-id 找锚点 → 搜索恒返回空表。
      const searchPage = '''
<div class="grid grid-cols-3 sm:grid-cols-3 md:grid-cols-4 gap-4">
  <div class="group relative">
    <a href="/play/cgzq7f3tf" data-vod="cgzq7cao3" class="block">
      <div class="relative aspect-[2/3]">
        <img data-src="https://gimg0.baidu.com/a.jpg" src="/static/images/placeholder-dark.svg" alt="凡人修仙传">
      </div>
      <div class="mt-2">
        <h3 class="text-sm font-medium">凡人修仙传</h3>
      </div>
    </a>
  </div>
</div>
''';
      expect(searchPage.contains('data-vod-id'), isFalse,
          reason: '夹具必须复现「搜索页无 data-vod-id」这一点，否则测不到 bug');
      final list = parseKvmCards(searchPage, sourceId: 'kvm4k');
      expect(list.single.id, 'cgzq7f3tf',
          reason: 'id 必须取 href 里的 slug，不能取 data-vod（那是另一个值）');
      expect(list.single.name, '凡人修仙传');
    });

    test('id 取 href 的 slug 而不是 data-vod（两者不同值）', () {
      // 同一个锚点上 href="/play/cgzq7f3tf" 而 data-vod="cgzq7cao3"。
      // 拿 data-vod 去拼 /play/<id> 必然 404，详情页打不开。
      const html = '''
<a href="/play/aaa111" data-vod="bbb222" class="block">
<img data-src="https://x.com/a.jpg" alt="某剧">
</a>
''';
      final list = parseKvmCards(html, sourceId: 'kvm4k');
      expect(list.single.id, 'aaa111');
      expect(list.single.id, isNot('bbb222'));
    });

    test('详情页选集锚点不带 data-vod，不会被误当列表卡片', () {
      // 选集也是 <a href="/play/<slug>" ...>，但属性是 data-line/dataid，
      // 没有 data-vod。若解析器只认 href，详情页 HTML 会被解析出一堆「剧集」。
      const detail = '''
<a href="/play/ch4sn04yf" @click.prevent="handleEpisodeClick(...)"
   data-line="1" data-episode="1" dataid="42058" class="episode-link">
    <span>正片</span>
</a>
''';
      expect(parseKvmCards(detail, sourceId: 'kvm4k'), isEmpty);
    });

    test('相邻卡片间距远大于固定窗口时，标题仍要被抓到', () {
      // 首页卡片带 hover 面板，实测 href → <h3> 最远 3844 字节。
      // 旧实现用固定 2200 字节窗口，会把标题截在窗口外 → 整条被丢弃。
      final padding = 'x' * 3500;
      final html = '''
<a href="/play/far001" data-vod="zzz" class="block">
<img data-src="https://x.com/a.jpg" alt="">
$padding
<h3>远处标题</h3>
</a>
<a href="/play/far002" data-vod="zzz2" class="block">
<img data-src="https://x.com/b.jpg" alt="第二部">
</a>
''';
      final list = parseKvmCards(html, sourceId: 'kvm4k');
      expect(list.length, 2, reason: '两张卡片都要在');
      expect(list.first.name, '远处标题');
      expect(list.first.cover.path, 'https://x.com/a.jpg');
    });

    test('首页多个分区的重复卡片去重后数量正确', () {
      const card = '''
<a href="/play/dup001" data-vod="zzz" class="block">
<img data-src="https://x.com/a.jpg" alt="重复剧">
</a>
''';
      const html = '$card$card$card';
      expect(parseKvmCards(html, sourceId: 'kvm4k').length, 1);
    });

    test('无 data-src 时退到 src（首页轮播/排行榜不懒加载）', () {
      // 首页顶部轮播与排行榜卡片只有 src 且是真图，没有 data-src。
      // 只认 data-src 会让这 6 条变成无封面（实测奥德赛/空枪/蜘蛛侠…）。
      const banner = '''
<a href="/play/ch4se9hr2" data-vod="ch4se6olq" class="block">
<div class="slide-inner" data-title="奥德赛">
<img src="https://gimg0.baidu.com/gimg/app=2001&amp;n=0.jpg" alt="奥德赛">
</div>
</a>
''';
      final list = parseKvmCards(banner, sourceId: 'kvm4k');
      expect(list.single.cover.path, contains('gimg0.baidu.com'));
      expect(list.single.cover.path, isNot(contains('&amp;')));
    });

    test('只有占位 SVG 时封面留空，不把 placeholder 当地址', () {
      const onlyPlaceholder = '''
<a href="/play/ph001" data-vod="zzz" class="block">
<img src="/static/images/placeholder-dark.svg" alt="某剧">
<h3>某剧</h3>
</a>
''';
      final list = parseKvmCards(onlyPlaceholder, sourceId: 'kvm4k');
      expect(list.single.cover.path, '');
    });
  });

  group('parseKvmDetail —— 详情页', () {
    test('电影只有一个「正片」，dataid 进 playToken', () {
      final d = parseKvmDetail(
        'ch4sn04yf',
        _kDetailHead + _kEpMovie,
        sourceId: 'kvm4k',
      );
      expect(d.id, 'ch4sn04yf');
      expect(d.videos.length, 1);
      final v = d.videos.single;
      expect(v.title, '正片');
      expect(v.path, '/play/ch4sn04yf');
      expect(v.episode, 1);
      expect(v.source, '1');
      // playToken 存的就是取址用的 dataid —— 丢了就取不到地址
      expect(v.playToken, '42058');
      expect(v.dramaId, 'ch4sn04yf');
      expect(d.sourceId, 'kvm4k');
    });

    test('剧名取 og:title 并去掉「第N集」后缀', () {
      final d = parseKvmDetail(
        'ch4rt1ctb',
        _kDetailHead + _kManager + _kEpTv,
        sourceId: 'kvm4k',
      );
      expect(d.name, '伟大的长征');
    });

    test('og:title 缺失时退到 <title>', () {
      const html = '''
<title>某剧名 - 第3集 -4k影视</title>
$_kEpTv
''';
      final d = parseKvmDetail('ch4rt1ctb', html, sourceId: 'kvm4k');
      expect(d.name, '某剧名');
    });

    test('两个标题都没有就用 dramaId 兜底', () {
      final d = parseKvmDetail('ch4rt1ctb', _kEpTv, sourceId: 'kvm4k');
      expect(d.name, 'ch4rt1ctb');
    });

    test('电视剧的纯数字标签原样保留，不被改成「第N集」', () {
      final d = parseKvmDetail(
        'ch4rt1ctb',
        _kDetailHead + _kManager + _kEpTv,
        sourceId: 'kvm4k',
      );
      expect(d.videos.single.title, '1');
    });

    test('线路名从 episodeManager 的 lineName 取', () {
      // episodeManager 是多行的，正则假设单行就取不到，线路名会退化成「线路1」。
      final d = parseKvmDetail(
        'ch4rt1ctb',
        _kDetailHead + _kManager + _kEpTv,
        sourceId: 'kvm4k',
      );
      expect(d.videos.single.sourceCn, 'alists');
    });

    test('lineName 缺失时退化成「线路N」', () {
      final d = parseKvmDetail(
        'ch4sn04yf',
        _kDetailHead + _kEpMovie,
        sourceId: 'kvm4k',
      );
      expect(d.videos.single.sourceCn, '线路1');
    });

    test('选集 id 形如 kvm_<slug>_<line>_<ep>（多线路不撞车）', () {
      final d = parseKvmDetail(
        'ch4sn04yf',
        _kDetailHead + _kEpMovie,
        sourceId: 'kvm4k',
      );
      expect(d.videos.single.id, 'kvm_ch4sn04yf_1_1');
    });

    test('简介取 meta description', () {
      final d = parseKvmDetail(
        'ch4rt1ctb',
        _kDetailHead + _kEpTv,
        sourceId: 'kvm4k',
      );
      expect(d.intro, contains('长征'));
    });

    test('封面取 og:image —— 详情页根本没有 data-src', () {
      // 回归：早先这里复用了列表页的 _kvmCoverOf(html)，而详情页 5 个样本
      // 的 data-src 出现次数全是 0，导致详情页封面恒为空。
      final d = parseKvmDetail(
        'ch4rt1ctb',
        _kDetailHead + _kEpTv,
        sourceId: 'kvm4k',
      );
      expect(d.cover.path, isNotEmpty);
      expect(d.cover.path, contains('douban_1794373831-300x450.jpg'));
      expect(d.cover.path, isNot(contains('&amp;')));
    });

    test('空页面不抛异常，只返回空选集', () {
      final d = parseKvmDetail('abc', '', sourceId: 'kvm4k');
      expect(d.videos, isEmpty);
      expect(d.id, 'abc');
    });
  });

  group('parseKvmIntro', () {
    test('优先 description', () {
      expect(parseKvmIntro(_kDetailHead), contains('长征历程'));
    });

    test('description 缺失时退到 keywords', () {
      const html =
          '<meta name="keywords" content="某剧,悬疑,推理">';
      expect(parseKvmIntro(html), '某剧,悬疑,推理');
    });

    test('两者都没有返回空串', () {
      expect(parseKvmIntro('<html></html>'), '');
    });

    test('还原 HTML 实体', () {
      const html = '<meta name="description" content="A &amp; B &quot;引号&quot;">';
      expect(parseKvmIntro(html), 'A & B "引号"');
    });
  });

  group('注册表登记', () {
    final registry = SourceRegistry.instance;

    test('kvm4k 已注册且能被 byId 找到', () {
      final s = registry.byId('kvm4k');
      expect(s.id, 'kvm4k');
      expect(s.displayName, '4K影视');
      // 站点没有弹幕接口，开着开关只会让播放页等一个永远不来的响应。
      expect(s.supportsDanmaku, isFalse);
    });

    test('分类齐全：推荐 + 电影 + 电视剧 + 动漫', () {
      final ids = registry.byId('kvm4k').categories.map((c) => c.id).toList();
      expect(ids, ['', '1', '2', '3']);
    });

    test('描述里写清了「需代理」与「自动降级」（用户选源能看见）', () {
      final desc = registry.byId('kvm4k').description;
      expect(desc, contains('代理'));
      expect(desc, contains('1080'));
    });
  });
}