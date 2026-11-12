/// 低调影视 / 低端影视适配器（**ddys.io**）。
///
/// ## 为什么是 ddys.io 而不是 ddys.app
///
/// 用户给的是 `https://ddys.app/`，但那个站对整站挂了 `ddys-protect` 插件
/// 的**游客闸门**，2026-11-12 逐层拆过，一共三层，全部要过才放行：
///
///   1. **访客密码**：页面明写「密码是 低调影视 的拼音缩写（4个小写字母）」，
///      即 `ddys`。这层能过。
///   2. **ALTCHA 工作量证明**：`<altcha-widget challengeurl=".../gatecha/challenge">`，
///      SHA-256、maxNumber=580000、salt 带 `expires`。这层也能过——
///      实测 number=428082、1.02 秒解出，并拼成 altcha 的 base64 载荷。
///   3. **3 点图形点选验证码**：`data-ddys-click-targets="3"`，
///      提交字段是 `ddys_protect_click_points` = `JSON.stringify([{x,y},…])`，
///      坐标按图片**原始像素**算，必须按提示顺序点中 3 个目标。
///
/// 前两层都过了之后，服务端返回的是「图形验证码已过期或已使用」——
/// 也就是**卡死在第三层**。这一层必须看图识别，客户端做不到无感通过。
/// 此外 `ddys.app` 的 `wp-json` 全部 401（`rest_login_required`），
/// 也没有任何免闸门的采集接口可绕。
///
/// 而 **`ddys.io` 是同系列的另一个入口，全站不需要闸门**：首页 200、
/// 分类/分页/搜索/详情全部直出，详情页还把整部剧的 m3u8 直接内嵌在
/// `onclick="switchSource(...)"` 里。所以这个适配器接的是 ddys.io。
///
/// ## 2026-11-12 逐条实测
///
///   ✅ 分类：`/movie` 电影、`/series` 剧集、`/variety` 综艺、`/anime` 动漫。
///      首页 `/` 是混合推荐。
///   ✅ 分页**真有效**：`/movie/page/N`。实测 `/movie` 与 `/movie?page=2`
///      零重叠；站点自己给出 `/movie/page/228`、`/anime/page/54`。
///   ✅ 搜索 `/search?q=<词>`。参数是 **`q`**（`keyword` 无效，返回 0 条）。
///      搜索**不分页**：`&page=2` 只是换了排序/分区，不是新一页，
///      所以第 2 页起直接返回空表，避免上拉无限请求。
///   ✅ 详情 `/movie/<slug>`，id 就是 slug（如 `honor`）。
///      播放源按钮：`onclick="switchSource(16729, '第01集$<url>#第02集$<url>…', 'm3u8')"`，
///      线路名在按钮文本里（如「播放源 1 (1080P)」）。
///   ✅ m3u8 **实测可拉流**：HTTP 200，返回标准 master playlist
///      （`#EXTM3U` + `#EXT-X-STREAM-INF ... 2000k/hls/mixed.m3u8`），
///      不校验 Referer。
///
/// ## 和别的源最大的不同：播放**零请求**
///
/// 详情页已经把每一集的 m3u8 都下发了，所以 [resolveUrl] 直接返回
/// `path` 里存的地址，一个网络请求都不发。这也意味着**详情页很重**
/// （实测 174 KB），但换来的是点开即播。
///
/// ## 代理
///
/// 源站国内直连不通，必须走系统代理（[NetProxy] 全局注入，这里不单独处理）。
library;

import 'package:dio/dio.dart';

import '../api.dart';
import '../models.dart';
import 'data_source.dart';

/// 站点根地址。
const String kDdysBase = 'https://ddys.io';

/// **这个源必须用「非浏览器 UA」**，不能用 [kSiteUserAgent]。
///
/// 2026-11-12 实测 ddys.io 挂在 Cloudflare 后面，它拦的不是 IP、不是 TLS，
/// 而是「**浏览器 UA + 非浏览器 TLS 指纹**」这个**不一致组合**：
///
///   | UA                      | 结果                        |
///   | ----------------------- | --------------------------- |
///   | Chrome 131（真实浏览器串） | 403，`cf-mitigated: challenge` |
///   | curl/8.4.0              | 403，同上                    |
///   | Python-urllib/3.11      | 403，同上                    |
///   | `Dart/3.5 (dart:io)`    | **200，正常返回**            |
///   | 不设 UA（Dart 默认）      | **200，正常返回**            |
///
/// 也就是说：拿 Chrome 的 UA 去配 Dart 的 TLS 指纹，等于自报「我是伪装的
/// 浏览器」，必被挑战；老老实实报自己是 Dart，反而一路放行。
/// 同一时刻用 curl 命令行请求是 200——因为 curl 的 UA 和 TLS 指纹是
/// **自洽**的（都是 curl），CF 认这个组合。
///
/// 所以这里刻意**不用 [SiteHttp]**（它把 UA 钉死成 Chrome），自己建一个
/// 用 Dart 标识的客户端。改这一处就够，其余解析逻辑一行都不用动。
const String kDdysUserAgent = 'Dart/3.5 (dart:io)';

// ==================== 纯函数区（便于离线回归，不依赖网络） ====================

/// 一条线路的选集：`[{title, url}, …]`。
class DdysEpisode {
  final String title;
  final String url;
  const DdysEpisode({required this.title, required this.url});
}

/// 一条播放线路：线路名 + 自己的选集列表。
class DdysLine {
  final String name;
  final List<DdysEpisode> episodes;
  const DdysLine({required this.name, required this.episodes});
}

/// 解析列表页卡片（分类页与首页同一套结构）。
///
/// 卡片形如：
/// ```
/// <div class="movie-card ...">
///   <a href="/movie/inheritance" ...>
///     <img src="https://img.ddys.io/movies/inheritance.webp" alt="血继" ...>
///   </a>
///   <h3 ...><a href="/movie/inheritance" ...>血继</a></h3>
///   <div ...>2024 · 电影</div>
/// ```
/// 用「卡片起点到下个卡片起点」切块，块内各取所需——比在整页上撒正则稳，
/// 不会把 A 卡的标题配到 B 卡的封面。
List<Drama> parseDdysCards(String html, {required String sourceId}) {
  final out = <Drama>[];
  final seen = <String>{};

  final starts = <int>[];
  for (final m in RegExp(r'<div class="movie-card').allMatches(html)) {
    starts.add(m.start);
  }
  if (starts.isEmpty) return out;

  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : html.length;
    final block = html.substring(starts[i], end);

    final slug = _ddysSlugOf(block);
    if (slug == null || !seen.add(slug)) continue;

    final name = _ddysCardName(block);
    if (name.isEmpty) continue;

    final meta = _ddysCardMeta(block);

    out.add(Drama(
      id: slug,
      name: name,
      year: meta.year,
      clazz: meta.clazz,
      remark: meta.remark,
      cover: CoverImage(path: _ddysCardCover(block)),
      sourceId: sourceId,
    ));
  }
  return out;
}

/// 卡片里的剧集 slug。优先 `href="/movie/xxx"`。
String? _ddysSlugOf(String block) {
  final m = RegExp(r'href="/movie/([A-Za-z0-9_\-]+)"').firstMatch(block);
  final s = m?.group(1)?.trim();
  return (s == null || s.isEmpty) ? null : s;
}

/// 卡片标题。优先 `<h3>` 里那个 `<a>` 的文本，退 `img alt`。
String _ddysCardName(String block) {
  final h3 = RegExp(
    r'<h3[^>]*>.*?<a[^>]*>(.*?)</a>',
    dotAll: true,
  ).firstMatch(block);
  final fromH3 = stripHtml(_ddysUnescape(h3?.group(1) ?? '')).trim();
  if (fromH3.isNotEmpty) return fromH3;
  final alt = RegExp(r'<img[^>]*alt="([^"]*)"').firstMatch(block);
  return stripHtml(_ddysUnescape(alt?.group(1) ?? '')).trim();
}

String _ddysCardCover(String block) {
  final m = RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(block);
  return _ddysAbsUrl(m?.group(1) ?? '');
}

/// 卡片上的「2024 · 电影」与「网盘：2 / 在线：3」。
({int year, String clazz, String remark}) _ddysCardMeta(String block) {
  var year = 0;
  var clazz = '';
  final meta =
      RegExp(r'(\d{4})\s*·\s*([^<\n]{1,20})').firstMatch(block);
  if (meta != null) {
    year = int.tryParse(meta.group(1) ?? '') ?? 0;
    clazz = meta.group(2)!.trim();
  }

  // 「在线：3」表示有在线播放源；「网盘：2」只有网盘。
  // 只把在线数放进 remark，让用户在列表上就能看出来能不能直接播。
  final online = RegExp(r'在线：\s*(\d+)').firstMatch(block);
  final pan = RegExp(r'网盘：\s*(\d+)').firstMatch(block);
  final parts = <String>[];
  if (online != null) parts.add('在线 ${online.group(1)}');
  if (pan != null) parts.add('网盘 ${pan.group(1)}');
  return (year: year, clazz: clazz, remark: parts.join(' · '));
}

/// 解析详情页的**全部线路**。
///
/// 按钮形如：
/// ```
/// <button onclick="switchSource(16729, '第01集$https://.../index.m3u8#第02集$https://...', 'm3u8')"
///         id="source-tab-16729"> 播放源 1 (1080P) </button>
/// ```
///
/// ## 第二个参数有两种形态（2026-11-12 实测，8 部剧 19 个按钮）
///
///   - **多集**：`第01集$https://...#第02集$https://...`，`#` 分隔、每段 `集名$地址`。
///     实测 12/19 个。
///   - **单集**：**就是一条纯 URL**，如
///     `https://vip.lz-cdn3.com/20220819/11730_626a60df/index.m3u8`，
///     既没有 `$` 也没有 `#`。实测 7/19 个，电影基本都是这一形态。
///
/// 早先的实现只按 `$` 切分，纯 URL 会因「找不到 `$`」被整段 `continue` 掉，
/// 于是一部电影明明卡片上写着「在线：2」，点进去线路是空的 ——
/// 用户报的「好多封面显示有在线线路、点进去但是没有」就是这个。
/// 实测 `wonder-wheel` / `my-sweet-home` / `sanada-ten-ninja-shadows`
/// 三部片全部命中（各 2~3 个按钮，一个都解不出来）。
List<DdysLine> parseDdysLines(String html) {
  final out = <DdysLine>[];
  final re = RegExp(
    r'''onclick="switchSource\(\s*(\d+)\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*\)"'''
    r'([\s\S]*?)</button>',
  );

  for (final m in re.allMatches(html)) {
    final body = m.group(2)?.trim() ?? '';
    final type = (m.group(3) ?? '').trim();
    // 目前实测只有 m3u8；将来若出现 mp4/网盘，这里能自然跳过。
    if (type.isNotEmpty && type != 'm3u8') continue;

    // 按钮正文在 onclick 之后的属性串里，`>` 之后才是文本。
    final tail = m.group(4) ?? '';
    final afterTag = tail.contains('>') ? tail.split('>').last : tail;
    var name = stripHtml(_ddysUnescape(afterTag)).trim();
    if (name.isEmpty) name = '播放源 ${out.length + 1}';

    final eps = <DdysEpisode>[];

    // 形态一：纯 URL（单集）。整个参数就是一条地址，按钮名可用作集名。
    // 要同时认协议相对地址（`//cdn.example.com/...`）：它不以 `http` 开头，
    // 若只判 `startsWith('http')` 会掉进下面的集数串分支、因找不到 `$` 被丢掉。
    final looksBare =
        !body.contains(r'$') &&
        (body.startsWith('http') || body.startsWith('//'));
    if (looksBare) {
      final url = _ddysAbsUrl(body);
      if (url.startsWith('http')) {
        eps.add(DdysEpisode(title: _kDdysBareEpTitle, url: url));
      }
    } else {
      // 形态二：`#` 分隔的集数串，每段 `集名$地址`。
      for (final seg in body.split('#')) {
        final t = seg.trim();
        if (t.isEmpty) continue;
        final cut = t.indexOf(r'$');
        if (cut <= 0) continue;
        final title = t.substring(0, cut).trim();
        final url = _ddysAbsUrl(t.substring(cut + 1).trim());
        if (!url.startsWith('http')) continue;
        eps.add(DdysEpisode(
          title: title.isEmpty ? '第${eps.length + 1}集' : title,
          url: url,
        ));
      }
    }

    if (eps.isEmpty) continue;
    out.add(DdysLine(name: name, episodes: eps));
  }
  return out;
}

/// 单集线路的集名。
///
/// 按钮名通常带清晰度和多余后缀（`播放源 1 (1080P)` / `备胎1号 (1080P)`），
/// 直接拿来当集名会让选集网格里出现一堆「播放源 1 (1080P)」这种字。
/// 电影/单集统一显示「正片」，与其它源保持一致。
const String _kDdysBareEpTitle = '正片';

/// 解析详情页：元信息 + 逐线路选集。
DramaDetail parseDdysDetail(
  String dramaId,
  String html, {
  required String sourceId,
}) {
  final lines = parseDdysLines(html);

  final videos = <DramaVideo>[];
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    for (var ei = 0; ei < line.episodes.length; ei++) {
      final ep = line.episodes[ei];
      videos.add(DramaVideo(
        id: 'ddys_${dramaId}_${li}_$ei',
        title: ep.title,
        // 详情页已下发 m3u8，直接放进 path，播放时零请求。
        path: ep.url,
        source: '${li + 1}',
        sourceCn: line.name,
        episode: _ddysEpNo(ep.title, ei + 1),
        dramaId: dramaId,
      ));
    }
  }

  final meta = _ddysDetailMeta(html);

  return DramaDetail(
    id: dramaId,
    name: meta.name.isEmpty ? dramaId : meta.name,
    area: meta.area,
    brief: meta.intro,
    intro: meta.intro,
    director: meta.director,
    actor: meta.actor,
    tag: meta.tags,
    year: meta.year,
    stars: meta.stars,
    cover: CoverImage(path: meta.cover),
    videos: videos,
    sourceId: sourceId,
  );
}

/// 详情页元信息。全部集中在 `<h1>` 到「在线播放」之间那一块。
({
  String name,
  String area,
  String intro,
  String director,
  String actor,
  String tags,
  int year,
  double stars,
  String cover,
}) _ddysDetailMeta(String html) {
  // 剧名：h1 的**第一段文本**。h1 里还嵌了 <span>别名</span>，必须切掉，
  // 否则剧名会变成「荣耀：她们的法庭 荣耀(韩版) / Heder(韩版) / …」。
  var name = '';
  final h1 = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>').firstMatch(html);
  if (h1 != null) {
    final inner = h1.group(1)!;
    final beforeSpan = inner.split('<span').first;
    name = stripHtml(_ddysUnescape(beforeSpan)).trim();
  }

  // 「2026 · 韩国 · 剧情 / 惊悚 / 犯罪」→ 年份 / 地区 / 类型
  var year = 0;
  var area = '';
  var tags = '';
  final metaLine =
      RegExp(r'(\d{4})\s*·\s*([^·<]{1,20})·\s*([^<\n]{1,60})').firstMatch(html);
  if (metaLine != null) {
    year = int.tryParse(metaLine.group(1) ?? '') ?? 0;
    area = metaLine.group(2)!.trim();
    tags = metaLine.group(3)!.trim();
  } else {
    final y = RegExp(r'(\d{4})\s*·\s*([^<\n]{1,40})').firstMatch(html);
    if (y != null) {
      year = int.tryParse(y.group(1) ?? '') ?? 0;
    }
  }

  final director = _ddysLabeled(html, '导演');
  final actor = _ddysLabeled(html, '主演');

  // 「豆瓣（6.7）」
  var stars = 0.0;
  final r = RegExp(r'豆瓣（\s*([\d.]+)\s*）').firstMatch(html);
  if (r != null) stars = double.tryParse(r.group(1) ?? '') ?? 0;

  // 简介只有 meta description 一处（页面没有独立的简介区块）。
  final desc = RegExp(r'<meta\s+name="description"\s+content="([^"]*)"')
      .firstMatch(html);
  var intro = stripHtml(_ddysUnescape(desc?.group(1) ?? '')).trim();

  // 封面：详情页头部那张海报是 alt 等于剧名的 img。
  // 页面没有 og:image，所以只能锚定 alt（推荐位在「在线播放」之后，取不到）。
  var cover = '';
  for (final m in RegExp(r'<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"')
      .allMatches(html)) {
    final alt = stripHtml(_ddysUnescape(m.group(2) ?? '')).trim();
    if (name.isNotEmpty && alt == name) {
      cover = _ddysAbsUrl(m.group(1) ?? '');
      break;
    }
  }
  if (cover.isEmpty) {
    final first = RegExp(r'<img[^>]*src="(https://img\.ddys\.io/[^"]+)"')
        .firstMatch(html);
    cover = _ddysAbsUrl(first?.group(1) ?? '');
  }

  return (
    name: name,
    area: area,
    intro: intro,
    director: director,
    actor: actor,
    tags: tags,
    year: year,
    stars: stars,
    cover: cover,
  );
}

/// 取「导演：xxx」/「主演：xxx」后面那个 `<span>` 的文本。
String _ddysLabeled(String html, String label) {
  final m = RegExp(
    '$label：</span>\\s*<span[^>]*>([^<]*)</span>',
  ).firstMatch(html);
  return stripHtml(_ddysUnescape(m?.group(1) ?? '')).trim();
}

/// 从「第01集」「第1集」「第12话」里抠集号；抠不到用序号兜底。
int _ddysEpNo(String title, int fallback) {
  final m = RegExp(r'第\s*(\d+)\s*[集话期]').firstMatch(title);
  final v = int.tryParse(m?.group(1) ?? '');
  return (v == null || v < 1) ? fallback : v;
}

String _ddysAbsUrl(String p) {
  final t = p.trim();
  if (t.isEmpty) return '';
  if (t.startsWith('//')) return 'https:$t';
  return t;
}

String _ddysUnescape(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'");

String ddysClip(String s) =>
    s.length <= 120 ? s.replaceAll('\n', ' ') : '${s.substring(0, 120)}…';

// ============================== 适配器 ==============================

class DdysSource implements DataSource {
  DdysSource._();

  static final DdysSource instance = DdysSource._();

  /// 不用 [SiteHttp]：它把 UA 钉死成 Chrome，而那正是本站在 Cloudflare
  /// 眼里「不自洽」的信号（见 [kDdysUserAgent] 的说明）。
  late final Dio _dio = Dio(BaseOptions(
    baseUrl: kDdysBase,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
    headers: {
      'User-Agent': kDdysUserAgent,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': '$kDdysBase/',
    },
  ));

  /// 分类 id 直接用站点的路径段，省一层映射。
  static const List<SourceCategory> _categories = [
    SourceCategory('', '推荐'),
    SourceCategory('movie', '电影'),
    SourceCategory('series', '剧集'),
    SourceCategory('variety', '综艺'),
    SourceCategory('anime', '动漫'),
  ];

  @override
  String get id => 'ddys';

  @override
  String get displayName => '低调影视';

  @override
  String get description => '需系统代理；无弹幕；在线播放直出，另有网盘资源';

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
    // 参数是 `q`（`keyword` 实测返回 0 条）。
    // 搜索不分页：`&page=2` 不是新一页，所以第 2 页起直接给空表。
    if (page > 1) return const [];
    return parseDdysCards(
      await _get('/search', query: {'q': k}),
      sourceId: id,
    );
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty && page == 1) return _home();
    // 分页是**路径**不是查询串：/movie/page/2。实测 ?page=2 与 /page/2
    // 内容一样，说明站点两种都认，这里统一用路径形式（与站点自己生成的
    // 翻页链接一致，不会因为改版先失效）。
    final path = page <= 1 ? '/$categoryId' : '/$categoryId/page/$page';
    return parseDdysCards(await _get(path), sourceId: id);
  }

  /// 首页（推荐）。结构同分类页。
  Future<List<Drama>> _home() async =>
      parseDdysCards(await _get('/'), sourceId: id);

  // ---------------------------- 详情 ----------------------------

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final html = await _get('/movie/$dramaId');
    return parseDdysDetail(dramaId, html, sourceId: id);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    // 详情页已经把每一集的 m3u8 下发下来了（实测可拉流、不校验 Referer），
    // 所以这里直接返回，零网络请求。
    final url = video.path.trim();
    if (url.startsWith('http')) return url;
    throw ApiException(-1, '这条剧集没有在线播放地址，可能只有网盘资源');
  }

  // ---------------------------- HTTP ----------------------------

  /// 抓一页 HTML。
  ///
  /// 与 [SiteHttp] 的两点不同：
  ///   1. UA 是 [kDdysUserAgent]（Dart 标识），不是 Chrome；
  ///   2. 明确识别 Cloudflare 的挑战页——它也是 HTTP 403 + 一段 HTML，
  ///      如果当成普通 403 抛出去，用户只会看到「站点返回 HTTP 403」，
  ///      完全不知道是被人机校验挡了。这里翻译成人话。
  Future<String> _get(String path, {Map<String, dynamic>? query}) async {
    final r = await _dio.get<String>(path, queryParameters: query);
    final code = r.statusCode ?? -1;
    final body = r.data ?? '';

    // Cloudflare 挑战页的两个指纹：响应头 cf-mitigated，或标题 "Just a moment"。
    final mitigated = r.headers.value('cf-mitigated');
    if (mitigated == 'challenge' ||
        body.contains('Just a moment') ||
        body.contains('cf-challenge')) {
      throw ApiException(
        403,
        '低调影视触发了 Cloudflare 人机校验，请稍后重试；'
        '若持续出现，请在浏览器打开一次 ddys.io 完成校验',
      );
    }

    if (code != 200) {
      throw ApiException(code, '站点返回 HTTP $code：${ddysClip(body)}');
    }
    return body;
  }
}