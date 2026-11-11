/// MacCMS / 苹果CMS 采集站的通用适配器（配置驱动）。
///
/// 用户以后「发现好网站就接进来」，绝大多数会是这一类：同一套路径约定
/// （voddetail / vodplay / vodsearch / vodtype）、同一套 `player_aaaa`
/// 播放配置，只是模板样式和域名不同。所以把请求与解析写成一份，
/// **接新站 = 填一份 [MacCmsConfig]，不改这里任何一行**。
///
/// 实测样本：4k01.pianku.online（2026-11-11 逐条验证）
///   搜索   /vodsearch/-------------.html?wd=沙海
///   分类   /vodtype/20.html
///   详情   /voddetail/15211.html
///          ├─ 线路名在 `<span class="source-tab-item"
///          │   data-target="playlist-N">备用线路</span>`
///          └─ 集数在 `<div id="playlist-N">` 里，形如
///             `<a href="/vodplay/15211-2-1.html" title="HD中字">`
///   播放   /vodplay/15211-2-1.html → `player_aaaa={"from":"wsym3u8",
///          "url":"https://…/index.m3u8"...}`
///
/// **线路能不能播，全看 `from` 字段**（实测）：
///   from=wsym3u8 / jlm3u8 / mjzy → 直出 m3u8（可播，实测 200 + 合法 HLS）
///   from=qq / qiyi / bilibili    → 返回的是网页地址（播放器打不开）
/// 详情页 HTML 里没有 `from`，只有线路名。所以这里不猜、也不按白名单
/// 硬编码：把「腾讯 / 奇异 / B站」这类**已知网页源**沉到底部
/// （[MacCmsConfig.webLineNames]），其余保持站点原顺序，
/// 播放时再按实际 URL 兜一层友好报错。
///
/// 项目没有引入 html 解析包，这里刻意用正则：采集站模板千奇百怪，
/// 依赖 DOM 结构反而更脆，正则只抓几个稳定锚点（href / title / data-target）。
library;

import '../api.dart';
import '../models.dart';
import 'data_source.dart';
import 'site_http.dart';

class MacCmsConfig {
  const MacCmsConfig({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.categories,
    this.searchPath = '/vodsearch/-------------.html',
    this.categoryPath = '/vodtype/{id}.html',
    this.detailPath = '/voddetail/{id}.html',
    this.searchKey = 'wd',
    this.detailLinkPattern = r'href="/voddetail/(\d+)\.html"',
    this.playLinkPattern = r'href="(/vodplay/(\d+)-(\d+)-(\d+)\.html)"',
    this.panePattern = r'id="(playlist-\d+)"',
    this.tabPattern = r'data-target="(playlist-\d+)"[^>]*>([^<]+)</span>',
    this.webLineNames = const <String>[],
    this.description = '分类齐全、无弹幕，网页源自动沉底',
    this.gate,
  });

  final String id;
  final String displayName;
  final String baseUrl;
  final List<SourceCategory> categories;

  final String searchPath;
  final String categoryPath;
  final String detailPath;
  final String searchKey;

  final String detailLinkPattern;
  final String playLinkPattern;
  final String panePattern;
  final String tabPattern;

  /// 已知「只能网页播放」的线路名关键字。
  ///
  /// 这类线路的 `from` 是 qq / qiyi / bilibili，`url` 给的是 iqiyi.com
  /// 这种网页，播放器放不了。它们在站点里通常排在前面，若不管，
  /// 用户第一次点播放必定失败。这里只做**沉底**，不改变其余线路顺序
  /// （站点自己的顺序通常已经把自营/直出排在前面）。
  final List<String> webLineNames;

  /// 设置页里的一句话说明（加新站时可自行覆盖）
  final String description;

  /// 可选的反爬准入闸门
  final CdndefendGate? gate;
}

class _Line {
  _Line(this.name, this.no, this.isWeb);
  final String name;
  final String no;
  final bool isWeb;
  final List<DramaVideo> videos = [];
}

/// 占位图 / 站标，抓封面时要跳过。
final RegExp _kPlaceholderCover =
    RegExp(r'logo_placeholder|noneCoverImg|favicon|/static/|noimg|nopic',
        caseSensitive: false);

/// 从一段 HTML 里挑出第一张像样的封面图。
///
/// **不能要求图片带 .jpg/.png 后缀**：片库首页实测有一大半封面是无扩展名的
/// CDN 直链，例如
///   `https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc00200…/0`
///   `http://m.ykimg.com/050E00006A85293BC7AFFF141AD91378`
/// 早期版本正则里写死了 `\.(jpg|png|webp)`，结果这些卡片全部没封面，
/// 只有恰好带 .jpg 的能显示，界面上就是「隔一个空一个」。
///
/// 改成先圈出 `<img>` 标签再取图片属性：既放宽了扩展名，又天然排除了
/// `<script src="…jquery.min.js">` 这类同样带 src 的标签。
/// 抽成顶层纯函数是为了能用真实 HTML 片段写离线回归测试。
String parseSiteCover(String html, String baseUrl) {
  final attrRe = RegExp(
    r'(?:data-original|data-src|src)\s*=\s*"([^"]+)"',
    caseSensitive: false,
  );
  for (final tag
      in RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(html)) {
    for (final m in attrRe.allMatches(tag.group(0)!)) {
      final p = m.group(1)!.trim();
      if (p.isEmpty || _kPlaceholderCover.hasMatch(p)) continue;
      // 脚本 / 样式 / loading 占位不是封面
      if (RegExp(r'\.(?:js|css|gif)(?:\?|$)', caseSensitive: false)
          .hasMatch(p)) {
        continue;
      }
      if (p.startsWith('//')) return 'https:$p';
      if (p.startsWith('/')) return '$baseUrl$p';
      if (p.startsWith('http://') || p.startsWith('https://')) return p;
    }
  }
  return '';
}

class MacCmsSource implements DataSource {
  MacCmsSource(this.cfg)
      : _http = SiteHttp(
          baseUrl: cfg.baseUrl,
          gate: cfg.gate,
          referer: '${cfg.baseUrl}/',
        );

  final MacCmsConfig cfg;
  final SiteHttp _http;

  @override
  String get id => cfg.id;

  @override
  String get displayName => cfg.displayName;

  @override
  String get description => cfg.description;

  @override
  List<SourceCategory> get categories => cfg.categories;

  @override
  bool get supportsDanmaku => false;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    if (keyword.trim().isEmpty) return _cards(await _http.get('/'));
    final q = <String, dynamic>{cfg.searchKey: keyword.trim()};
    if (page > 1) q['page'] = page;
    return _cards(await _http.get(cfg.searchPath, query: q));
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty) return _cards(await _http.get('/'));
    final path = cfg.categoryPath.replaceAll('{id}', categoryId);
    final q = page > 1 ? <String, dynamic>{'page': page} : null;
    return _cards(await _http.get(path, query: q));
  }

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final path = cfg.detailPath.replaceAll('{id}', dramaId);
    final html = await _http.get(path, referer: '${cfg.baseUrl}$path');
    return _detail(dramaId, html);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final html = await _http.get(
      video.path,
      referer: '${cfg.baseUrl}${cfg.detailPath.replaceAll('{id}', video.dramaId)}',
    );
    // player_aaaa 是一段 JSON 字符串，字段顺序不固定，逐字段取更稳
    final cfgM =
        RegExp(r'player_aaaa\s*=\s*\{').firstMatch(html);
    final scope = cfgM == null
        ? html
        : html.substring(cfgM.end, (cfgM.end + 1200).clamp(0, html.length));

    String pick(String key) {
      final m = RegExp('"$key"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"').firstMatch(scope);
      return (m?.group(1) ?? '').replaceAll(r'\/', '/');
    }

    final url = pick('url');
    final from = pick('from');
    if (!url.startsWith('http')) {
      throw ApiException(200, '该线路没有返回播放地址，请切换其它线路');
    }
    if (!url.contains('.m3u8') && !url.contains('.mp4')) {
      // qq / qiyi / bilibili 这类线路给的是网页，播放器打不开。
      throw ApiException(
        200,
        '「${video.sourceCn.isEmpty ? from : video.sourceCn}」是网页源，'
        '播放器放不了，请在「选集」上方切到自营/备用线路',
      );
    }
    return url;
  }

  // ---------------- HTML 解析 ----------------

  List<Drama> _cards(String html) {
    final out = <Drama>[];
    final seen = <String>{};
    final linkRe = RegExp(cfg.detailLinkPattern, dotAll: true);
    for (final m in linkRe.allMatches(html)) {
      final id = m.group(1);
      if (id == null || !seen.add(id)) continue;
      var end = m.start + 900;
      if (end > html.length) end = html.length;
      final seg = html.substring(m.start, end);
      final name = _cardTitle(seg);
      if (name.isEmpty) continue;
      out.add(Drama(
        id: id,
        name: name,
        cover: CoverImage(path: _coverOf(seg)),
        sourceId: cfg.id,
      ));
    }
    return out;
  }

  /// 卡片标题：优先 `title="..."`，退而求其次取第一个像样的 `alt`。
  String _cardTitle(String seg) {
    final t = stripHtml(RegExp(r'title="([^"]+)"').firstMatch(seg)?.group(1) ?? '')
        .trim();
    if (t.isNotEmpty && !_kPlaceholderCover.hasMatch(t) && !t.contains('可可影视')) {
      return t;
    }
    final alt = stripHtml(RegExp(r'alt="([^"]+)"').firstMatch(seg)?.group(1) ?? '')
        .trim();
    if (alt.isNotEmpty && !alt.contains('可可影视')) return alt;
    return '';
  }

  /// 抓封面。实现见 [parseSiteCover]（抽成纯函数供离线回归测试）。
  String _coverOf(String seg) => parseSiteCover(seg, cfg.baseUrl);

  DramaDetail _detail(String dramaId, String html) {
    final titleM = RegExp(r'<title>([^<]+)</title>').firstMatch(html);
    final rawTitle = titleM?.group(1) ?? '';
    // 形如「依然的喜事详情介绍-依然的喜事在线观看-…」
    var name = rawTitle.split(RegExp(r'详情介绍|在线观看|-')).first.trim();
    if (name.isEmpty) name = dramaId;

    // 线路名：data-target="playlist-N" > 备用线路
    final tabNames = <String, String>{};
    for (final m in RegExp(cfg.tabPattern, dotAll: true).allMatches(html)) {
      tabNames[m.group(1)!] = stripHtml(m.group(2)!).trim();
    }

    // 按 pane 分段，段内抓 /vodplay/{id}-{line}-{ep}.html
    final panes = RegExp(cfg.panePattern).allMatches(html).toList();
    final lines = <_Line>[];
    for (var i = 0; i < panes.length; i++) {
      final paneId = panes[i].group(1)!;
      final end = i + 1 < panes.length ? panes[i + 1].start : html.length;
      if (end <= panes[i].end) continue;
      final seg = html.substring(panes[i].end, end);
      final lineName = tabNames[paneId] ?? paneId;
      final line = _Line(lineName, '', _isWebLine(lineName));

      for (final pm in RegExp(cfg.playLinkPattern, dotAll: true).allMatches(seg)) {
        final link = pm.group(1)!;
        final lineNo = pm.groupCount >= 3 ? (pm.group(3) ?? '') : '';
        final ep =
            int.tryParse(pm.groupCount >= 4 ? (pm.group(4) ?? '') : '') ?? 0;
        var segEnd = pm.start + 260;
        if (segEnd > seg.length) segEnd = seg.length;
        final tail = seg.substring(pm.start, segEnd);
        final epTitle = stripHtml(
                RegExp(r'title="([^"]+)"').firstMatch(tail)?.group(1) ?? '')
            .trim();
        line.videos.add(DramaVideo(
          id: '${cfg.id}_${dramaId}_${lineNo}_$ep',
          title: epTitle.isEmpty
              ? '第${ep > 0 ? ep : (line.videos.length + 1)}集'
              : epTitle,
          path: link,
          source: lineNo.isEmpty ? paneId : lineNo,
          sourceCn: lineName,
          episode: ep > 0 ? ep : line.videos.length + 1,
          dramaId: dramaId,
        ));
      }
      if (line.videos.isNotEmpty) {
        lines.add(_Line(line.name, line.videos.first.source, line.isWeb)
          ..videos.addAll(line.videos));
      }
    }

    // 网页源沉底，其余保持站点原顺序：sourcesByCn 按 videos 首次出现
    // 顺序建 key，sourceOrder 策略下第一组就是默认选中项。
    final ordered = <_Line>[
      ...lines.where((l) => !l.isWeb),
      ...lines.where((l) => l.isWeb),
    ];

    return DramaDetail(
      id: dramaId,
      name: name,
      intro: stripHtml(_intro(html)),
      cover: CoverImage(path: _coverOf(html)),
      videos: <DramaVideo>[
        for (final l in ordered) ...l.videos,
      ],
      sourceId: cfg.id,
    );
  }

  bool _isWebLine(String lineName) {
    for (final k in cfg.webLineNames) {
      if (lineName.contains(k)) return true;
    }
    return false;
  }

  String _intro(String html) {
    final m = RegExp(
            r'<div[^>]*class="[^"]*(?:detail-content|vod-content|detail-desc|desc)[^"]*"[^>]*>(.*?)</div>',
            dotAll: true,
            caseSensitive: false)
        .firstMatch(html);
    return m?.group(1) ?? '';
  }
}