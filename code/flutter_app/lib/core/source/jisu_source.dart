/// 极速追剧（jisuzhuiju.com）适配器。
///
/// 和 [MacCmsSource] / [MacCmsApiSource] 都不是同一套程序：采集接口
/// `api.php/provide/vod/` 实测 404（四种路径全试过），只能走 HTML 解析。
///
/// ## 2026-11-12 逐条实测（每条都是跑出来的）
///
///   ✅ **必须带浏览器 UA**。用 curl 默认 UA 请求首页直接吃
///      `403 Forbidden`（nginx，146 字节）。换成 Chrome UA 立刻 200。
///      项目里的 [kSiteUserAgent] 正好是 Chrome 131 的完整 UA，直接可用。
///   ✅ 分类 `/filter?channel=N&sort=hot&page=M`，**真分页**：
///      channel=1 共 1689 页，每页 12 条，第 1/2 页零重叠。
///      channel 取值：1 电视剧 / 2 电影 / 3 动漫 / 4 综艺 / 5 短剧，
///      空串 = 全部（也可翻页）。
///   ✅ 搜索 `/search?keyword=<词>`。参数是 **`keyword`** 不是 `wd`——
///      这条是从站点自己的 schema.org `SearchAction.urlTemplate` 里读出来的，
///      猜 `wd`/`q` 都只能拿到「热门影片」推荐位（12 条固定内容，与关键词无关）。
///      搜索**不分页**：`&page=2` 返回「未找到」空结果。
///   ✅ 详情 `/detail/<id>.html`。选集按线路分成多个
///      `<div class="source-panel" id="source-N">`，每个面板一个 `.episode-grid`，
///      链接形如 `/vodplay/<vodId>-<prefix>-<ep>.html`。
///      线路中文名在同序号的 `<button class="source-tab" data-target="source-N">` 里。
///   ✅ 取址 `/api/play-url?vodId=&playFrom=<prefix>&index=<ep>` 返回
///      `{"mode":"native","code":200,"url":"...m3u8"}`，四条线路全部实测出真地址。
///
/// ## 两个必须写死的坑
///
/// 1. **`data-index` 是 0-based，不能拿去当 API 的 `index`**。选集锚点的
///    `data-index` 从 0 开始，而 `/api/play-url` 的 `index` 从 1 开始。
///    实测 `index=0` 一律回 `{"code":500,"msg":"未找到该集播放地址"}`。
///    正确做法是用 URL 里的集数 `<ep>`（1-based）。
///
/// 2. **各线路集数不一样**。同一部《灵境行者》：`qq` 有 15 集，
///    `covip`/`bfzym3u8`/`jsm3u8` 都只有 12 集。所以选集必须**逐线路**解析，
///    不能按某条线路的集数去生成所有线路的条目——那样会造出一堆必 500 的死链。
///
/// ## 播放地址会 302
///
/// `qq` 线路（「腾讯官方线路」）下发的地址是 `cibn-edge-5g.1ljx.com` 的
/// 中转页，**要再 302 一跳**才到真正的 m3u8。这是正常的，播放器会自己跟。
/// 但也遇到过某一集 302 到 `DEPLOYMENT_DISABLED`（402）的失效情况，
/// 这属于源站数据问题，客户端无法预判，只能在取址失败时给出可读错误。
///
/// ## 代理
///
/// 源站国内直连不通，必须走系统代理。本项目 [NetProxy] 用
/// `HttpOverrides.global` 全局注入，所以这里不单独处理。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../api.dart';
import '../models.dart';
import 'data_source.dart';
import 'site_http.dart';

/// 站点根地址。
const String kJisuBase = 'https://jisuzhuiju.com';

/// 取址接口路径。
const String kJisuPlayApi = '/api/play-url';

// ==================== 纯函数区（便于离线回归，不依赖网络） ====================

/// 选集条目的播放标识：`<线路前缀>|<集数>`。
///
/// 为什么要把 prefix 也塞进 playToken：取址接口要 `playFrom=<prefix>`，
/// 而 `DramaVideo` 没有专门的线路字段能同时装下「线路枚举」和「线路前缀」
/// （`source` 存的是线路序号，`sourceCn` 存的是中文名）。
/// 用 `|` 分隔最省事，且解析失败时能明确区分「缺 prefix」和「缺集数」。
String jisuPlayToken(String prefix, int ep) => '$prefix|$ep';

/// 拆回 `(prefix, ep)`。格式不对时返回 `null`。
({String prefix, int ep})? jisuParsePlayToken(String token) {
  final i = token.lastIndexOf('|');
  if (i <= 0 || i == token.length - 1) return null;
  final prefix = token.substring(0, i).trim();
  final ep = int.tryParse(token.substring(i + 1).trim());
  if (prefix.isEmpty || ep == null || ep < 1) return null;
  return (prefix: prefix, ep: ep);
}

/// 从 `/vodplay/702-bfzym3u8-1.html` 里取线路前缀。
String? jisuPrefixOf(String path) {
  final m = RegExp(r'/vodplay/\d+-([A-Za-z0-9]+)-\d+\.html').firstMatch(path);
  return m?.group(1);
}

/// 从 `/vodplay/702-bfzym3u8-1.html` 里取集数（**1-based**，可直接喂给 API）。
int? jisuEpOf(String path) {
  final m = RegExp(r'/vodplay/\d+-[A-Za-z0-9]+-(\d+)\.html').firstMatch(path);
  return int.tryParse(m?.group(1) ?? '');
}

/// 解析搜索结果卡片。搜索页的结构和列表页不同：
/// 列表页是 `.vod-card`，搜索页是 `.search-item`（带主演/类型等元信息）。
List<Drama> parseJisuSearchCards(String html, {required String sourceId}) {
  final out = <Drama>[];
  final seen = <String>{};
  // 搜索结果块：a.search-item-poster -> img + a.search-item-title
  final re = RegExp(
    r'<a href="/detail/(\d+)\.html"[^>]*class="search-item-poster"[^>]*>'
    r'.*?<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"',
    dotAll: true,
  );
  for (final m in re.allMatches(html)) {
    final id = m.group(1)!;
    if (!seen.add(id)) continue;
    out.add(Drama(
      id: id,
      name: _jisuCleanTitle(m.group(3) ?? ''),
      cover: CoverImage(path: _jisuAbsUrl(m.group(2) ?? '')),
      sourceId: sourceId,
    ));
  }
  return out;
}

/// 解析列表页卡片（`.vod-card`，分类页与首页都用这套结构）。
///
/// 详情页里也有 24 个 `.vod-card`（推荐位），所以这个函数**只适合列表页**；
/// 详情页选集走 [parseJisuDetail]。
List<Drama> parseJisuCards(String html, {required String sourceId}) {
  final out = <Drama>[];
  final seen = <String>{};
  // 卡片是 <a href="/detail/561.html"> <div class="vod-card"> ...
  // 用「锚点 + 后面的 vod-card 块」整体匹配，块内取标题与封面。
  final re = RegExp(
    r'<a href="/detail/(\d+)\.html"[^>]*>\s*<div class="vod-card">'
    r'(.*?)</div>\s*</div>\s*</a>',
    dotAll: true,
  );
  for (final m in re.allMatches(html)) {
    final id = m.group(1)!;
    if (!seen.add(id)) continue;
    final block = m.group(2) ?? '';
    final name = _jisuCardTitle(block);
    if (name.isEmpty) continue;
    out.add(Drama(
      id: id,
      name: name,
      cover: CoverImage(path: _jisuCardCover(block)),
      sourceId: sourceId,
    ));
  }
  return out;
}

/// 卡片标题在 `<p class="vod-title">`；拿不到退 `img alt`（去掉「封面图片」后缀）。
String _jisuCardTitle(String block) {
  final t = RegExp(r'<p class="vod-title[^"]*"[^>]*>([^<]*)</p>')
      .firstMatch(block);
  final v = _jisuCleanTitle(t?.group(1) ?? '');
  if (v.isNotEmpty) return v;
  final alt = RegExp(r'alt="([^"]*)"').firstMatch(block);
  return _jisuCleanTitle(alt?.group(1) ?? '');
}

String _jisuCardCover(String block) {
  final m = RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(block);
  return _jisuAbsUrl(m?.group(1) ?? '');
}

/// 站点 alt 统一写成「XX封面图片」，去掉后缀才像剧名。
String _jisuCleanTitle(String s) {
  var t = stripHtml(_jisuUnescape(s)).trim();
  for (final suf in const ['封面图片', '海报', '封面']) {
    if (t.endsWith(suf)) {
      t = t.substring(0, t.length - suf.length).trim();
      break;
    }
  }
  return t;
}

/// 解析详情页：元信息 + 按线路分组的选集。
///
/// 结构（实测）：
/// ```
/// <button class="source-tab active" data-target="source-0">腾讯官方线路</button>
/// ...
/// <div class="source-panel" id="source-0" data-visible="1">
///   <div class="episode-grid">
///     <a href="/vodplay/702-qq-1.html" data-index="0">第1集</a>
/// ```
/// `source-tab` 与 `source-panel` 顺序一一对应（都是 source-0、source-1…），
/// 所以先按顺序收线路名，再按顺序收面板。
DramaDetail parseJisuDetail(
  String dramaId,
  String html, {
  required String sourceId,
}) {
  final name = _jisuDetailName(html, dramaId);

  // 线路名：按 data-target 的序号排列，保证与面板顺序对齐。
  final lineNames = <int, String>{};
  for (final m in RegExp(
    r'data-target="source-(\d+)"[^>]*>([^<]*)</button>',
  ).allMatches(html)) {
    lineNames[int.parse(m.group(1)!)] = m.group(2)!.trim();
  }

  // 面板：每个面板一个线路。切到下一个 panel 起点作为本面板的结束。
  //
  // 注意 `<div class="source-panel"` 与 `id="source-N"` 之间是**换行 + 缩进**，
  // 不是空格。早先写成 `class="source-panel" id="source-` 一个也匹配不到，
  // 结果是详情页 52 集全部丢失（首页/分类/搜索都正常，只有详情空）。
  final panelStarts = <({int at, int idx})>[];
  for (final m in RegExp(r'<div class="source-panel"\s+id="source-(\d+)"')
      .allMatches(html)) {
    panelStarts.add((at: m.start, idx: int.parse(m.group(1)!)));
  }

  final videos = <DramaVideo>[];
  for (var i = 0; i < panelStarts.length; i++) {
    final start = panelStarts[i].at;
    final end = i + 1 < panelStarts.length ? panelStarts[i + 1].at : html.length;
    final seg = html.substring(start, end);
    final panelIdx = panelStarts[i].idx;

    // 线路前缀：取本面板第一个选集链接里的那个。
    final firstHref = RegExp(r'href="(/vodplay/[^"]+)"').firstMatch(seg);
    final prefix = firstHref == null ? null : jisuPrefixOf(firstHref.group(1)!);
    if (prefix == null) continue;

    final lineName = lineNames[panelIdx] ?? prefix;

    // 同一面板内按出现顺序收集（站点已按集数排好）。
    final seenEp = <int>{};
    for (final m in RegExp(
      r'href="/vodplay/\d+-[A-Za-z0-9]+-(\d+)\.html"[^>]*>([^<]*)<',
    ).allMatches(seg)) {
      final ep = int.tryParse(m.group(1) ?? '');
      if (ep == null || ep < 1) continue;
      if (!seenEp.add(ep)) continue;
      final label = stripHtml(_jisuUnescape(m.group(2) ?? '')).trim();
      videos.add(DramaVideo(
        id: 'jisu_${dramaId}_${prefix}_$ep',
        title: label.isEmpty ? '第$ep集' : label,
        path: '/vodplay/$dramaId-$prefix-$ep.html',
        source: '${panelIdx + 1}',
        sourceCn: lineName,
        episode: ep,
        dramaId: dramaId,
        playToken: jisuPlayToken(prefix, ep),
      ));
    }
  }

  return DramaDetail(
    id: dramaId,
    name: name,
    intro: parseJisuIntro(html),
    cover: CoverImage(path: _jisuDetailCover(html)),
    videos: videos,
    sourceId: sourceId,
  );
}

/// 详情页剧名。`og:title` 形如「《灵境行者》动漫高清完整版免费在线观看」，
/// 书名号里那段就是剧名；没有书名号时用 `<title>` 去掉站点后缀。
String _jisuDetailName(String html, String fallback) {
  final og = RegExp(r'property="og:title"\s+content="([^"]*)"').firstMatch(html);
  final raw = _jisuUnescape(og?.group(1) ?? '').trim();
  final book = RegExp(r'《([^》]+)》').firstMatch(raw);
  if (book != null) {
    final n = book.group(1)!.trim();
    if (n.isNotEmpty) return n;
  }
  if (raw.isNotEmpty) {
    final n = raw.split('高清').first.trim();
    if (n.isNotEmpty) return n;
  }
  final t = RegExp(r'<title>([^<]*)</title>').firstMatch(html)?.group(1) ?? '';
  final cleaned = _jisuUnescape(t).split(' - ').first.trim();
  if (cleaned.isNotEmpty) return cleaned;
  return fallback;
}

/// 详情页封面：优先 `.detail-poster-wrapper` 里的 img，退 `og:image`。
///
/// 详情页推荐位也有 24 个 `.vod-card`，直接搜第一个 `img` 会抓到推荐位的图，
/// 所以必须先锚定海报容器。
String _jisuDetailCover(String html) {
  final p = RegExp(
    r'class="detail-poster-wrapper"[^>]*>\s*<img[^>]*src="([^"]+)"',
    dotAll: true,
  ).firstMatch(html);
  final fromPoster = _jisuAbsUrl(p?.group(1) ?? '');
  if (fromPoster.isNotEmpty) return fromPoster;
  final og = RegExp(r'property="og:image"\s+content="([^"]*)"').firstMatch(html);
  return _jisuAbsUrl(og?.group(1) ?? '');
}

/// 简介取 `meta[name=description]`：详情页没有独立的简介区块
/// （找过 `detail-intro` 等类名，全都不存在），正文只在这里。
String parseJisuIntro(String html) {
  final m = RegExp(r'<meta\s+name="description"\s+content="([^"]*)"')
      .firstMatch(html);
  final t = stripHtml(_jisuUnescape(m?.group(1) ?? '')).trim();
  if (t.isNotEmpty) return t;
  final kw = RegExp(r'<meta\s+name="keywords"\s+content="([^"]*)"')
      .firstMatch(html);
  return stripHtml(_jisuUnescape(kw?.group(1) ?? '')).trim();
}

String _jisuAbsUrl(String p) {
  final t = p.trim();
  if (t.isEmpty) return '';
  if (t.startsWith('//')) return 'https:$t';
  return t;
}

String _jisuUnescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'");

// ============================== 适配器 ==============================

class JisuSource implements DataSource {
  JisuSource._()
      : _http = SiteHttp(baseUrl: kJisuBase, referer: '$kJisuBase/');

  static final JisuSource instance = JisuSource._();

  /// 只读 HTML。取址接口单独用 [_api]（要 JSON）。
  final SiteHttp _http;

  late final Dio _api = Dio(BaseOptions(
    baseUrl: kJisuBase,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
    headers: {
      // 站点对非浏览器 UA 直接 403，这里必须和 SiteHttp 用同一个 UA。
      'User-Agent': kSiteUserAgent,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    },
  ));

  /// 分类：channel 1-5。空串走「全部」。
  ///
  /// 实测五个 channel 都有数据（各 12 条/页），没有像 4K影视那样存在空分区。
  static const List<SourceCategory> _categories = [
    SourceCategory('', '推荐'),
    SourceCategory('1', '电视剧'),
    SourceCategory('2', '电影'),
    SourceCategory('3', '动漫'),
    SourceCategory('4', '综艺'),
    SourceCategory('5', '短剧'),
  ];

  @override
  String get id => 'jisu';

  @override
  String get displayName => '极速追剧';

  @override
  String get description =>
      '需系统代理；无弹幕；线路较多，各线路集数可能不同';

  @override
  List<SourceCategory> get categories => _categories;

  @override
  bool get supportsDanmaku => false;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  // ---------------------------- 列表 ----------------------------

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    final k = keyword.trim();
    if (k.isEmpty) {
      if (page > 1) return const [];
      return _home();
    }
    // 搜索不分页：&page=2 返回「未找到」空结果（实测 0 张卡片）。
    // 不显式拦的话，上拉加载会不断请求、不断得到空表。
    if (page > 1) return const [];
    return parseJisuSearchCards(
      await _http.get('/search', query: {'keyword': k}),
      sourceId: id,
    );
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty && page == 1) return _home();
    final q = <String, String>{
      'channel': categoryId,
      'sort': 'hot',
      'page': '$page',
    };
    return parseJisuCards(
      await _http.get('/filter', query: q),
      sourceId: id,
    );
  }

  /// 首页（推荐）。首页是站点自己编排的多个分区，卡片结构与分类页一致。
  Future<List<Drama>> _home() async =>
      parseJisuCards(await _http.get('/'), sourceId: id);

  // ---------------------------- 详情 ----------------------------

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final html = await _http.get(
      '/detail/$dramaId.html',
      referer: '$kJisuBase/',
    );
    return parseJisuDetail(dramaId, html, sourceId: id);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final vodId = video.dramaId.trim();
    if (vodId.isEmpty) {
      throw ApiException(-1, '这条剧集缺少剧集标识，无法取址');
    }
    final token = jisuParsePlayToken(video.playToken);
    if (token == null) {
      throw ApiException(-1, '这条剧集缺少线路标识，请返回重新进入详情页');
    }

    final resp = await _api.get<String>(
      kJisuPlayApi,
      queryParameters: {
        'vodId': vodId,
        'playFrom': token.prefix,
        'index': '${token.ep}',
      },
      options: Options(headers: {
        // 不带 Referer 也能通，但带上更稳（与浏览器行为一致）。
        'Referer': '$kJisuBase/vodplay/$vodId-${token.prefix}-${token.ep}.html',
      }),
    );

    final code = resp.statusCode ?? -1;
    final body = resp.data ?? '';
    if (code != 200) {
      throw ApiException(code, '取址接口返回 HTTP $code：${_clip(body)}');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(code, '取址接口返回的不是 JSON：${_clip(body)}');
    }

    // 站点用 code:500 + msg 表示「这一集没有地址」（常见于线路集数不足），
    // 原文「未找到该集播放地址」对用户没意义，翻译一下。
    if (json['code'] != 200) {
      final msg = (json['message'] ?? json['msg'] ?? '').toString();
      if (msg.contains('未找到')) {
        throw ApiException(
          (json['code'] as num?)?.toInt() ?? -1,
          '这条线路没有这一集，换个线路试试',
        );
      }
      throw ApiException(
        (json['code'] as num?)?.toInt() ?? -1,
        msg.isEmpty ? '取址失败' : msg,
      );
    }

    final url = (json['url'] ?? '').toString().trim();
    if (!url.startsWith('http')) {
      throw ApiException(-1, '该集没有可播放的地址');
    }
    return url;
  }

  String _clip(String s) =>
      s.length <= 120 ? s.replaceAll('\n', ' ') : '${s.substring(0, 120)}…';
}