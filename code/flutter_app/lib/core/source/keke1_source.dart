/// 可可影视（keke1.app）适配器。
///
/// 和 [MacCmsSource] 不是同一套程序：路径是 /detail/ /play/ /search /channel/，
/// 而且门口挂了 cdndefend 的 SHA1 工作量证明反爬。准入逻辑已经抽到
/// [CdndefendGate]，这里只负责页面解析。
///
/// 2026-11-11 逐条实测结果（下面每一条都是跑出来的，不是推测）：
///   ✅ HTTP 850 挑战：同一 TCP 连接解 PoW → 200，Cookie 可跨连接复用
///   ✅ 搜索**必须带首页下发的 `t` 令牌**，否则任何关键词都返回
///      「找到 0 部影片」。这是最容易误判为「站点搜索坏了」的坑。
///   ✅ 详情 /play/{id}-{线路}-{集token}.html，
///      线路名在 `source-item-label`，选集在与之同序的 `episode-list` 里
///   ✅ 播放地址**可以静态拿到**：播放页里有
///      `const playSource = { src: "https://…/index.m3u8?appId=kkdy&sign=…" }`
///      实测该 m3u8 返回 200 且是合法 HLS（#EXTM3U + EXTINF 列表）。
///      早期版本误判为「必须执行混淆 JS 才能拿到」，已纠正。
///
/// 注意：`playSource.src` 带签名与 timestamp，**有时效**，不能缓存复用，
/// 每次播放都要重新抓播放页（这也是为什么 [resolveUrl] 必须现拉）。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../api.dart';
import '../models.dart';
import 'data_source.dart';
import 'site_http.dart';

/// 占位图 / 站标，抓封面时跳过。
final RegExp _kKekePlaceholder =
    RegExp(r'logo_placeholder|noneCoverImg|favicon|/static/', caseSensitive: false);

class Keke1Source implements DataSource {
  Keke1Source._()
      : _http = SiteHttp(
          baseUrl: 'https://www.keke1.app',
          gate: CdndefendGate('www.keke1.app'),
          referer: 'https://www.keke1.app/',
        );

  static final Keke1Source instance = Keke1Source._();
  final SiteHttp _http;

  /// 首页下发的搜索令牌。[SiteHttp] 只缓存 Cookie，不缓存页面，
  /// 所以这里自己记一份，避免每次搜索都重新拉首页。
  String? _searchToken;

  static const List<SourceCategory> _categories = [
    SourceCategory('', '推荐'),
    SourceCategory('1', '电影'),
    SourceCategory('2', '连续剧'),
    SourceCategory('3', '动漫'),
    SourceCategory('4', '综艺'),
  ];

  @override
  String get id => 'keke1';

  @override
  String get displayName => '可可影视（需源站在线）';

  @override
  String get description => '需通过源站准入校验，无弹幕；源站不可达时会提示切换';

  @override
  List<SourceCategory> get categories => _categories;

  @override
  bool get supportsDanmaku => false;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    if (keyword.trim().isEmpty) return _cards(await _http.get('/'));
    final token = await _token();
    final q = <String, dynamic>{'k': keyword.trim()};
    if (token.isNotEmpty) q['t'] = token;
    if (page > 1) q['page'] = page;
    return _cards(await _http.get('/search', query: q));
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty) return _cards(await _http.get('/'));
    final q = page > 1 ? <String, dynamic>{'page': page} : null;
    return _cards(await _http.get('/channel/$categoryId.html', query: q));
  }

  /// 取搜索令牌。拿不到不算致命：不带 `t` 只是搜不到结果，
  /// 首页/分类/详情都还能用，所以这里静默降级为空串。
  Future<String> _token() async {
    final cached = _searchToken;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final home = await _http.get('/');
      final m = RegExp(r'name="t"\s+value="([^"]+)"').firstMatch(home);
      final t = m?.group(1) ?? '';
      if (t.isNotEmpty) _searchToken = t;
      return t;
    } catch (e) {
      debugPrint('[KK] token failed: $e');
      return '';
    }
  }

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final path = '/detail/$dramaId.html';
    final html = await _http.get(path, referer: 'https://www.keke1.app$path');
    return _detail(dramaId, html);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final html = await _http.get(
      video.path,
      referer: 'https://www.keke1.app/detail/${video.dramaId}.html',
    );
    // 主路径：const playSource = { src: "...", type: "application/x-mpegURL" }
    final blockM = RegExp(r'playSource\s*=\s*\{').firstMatch(html);
    if (blockM != null) {
      final scope =
          html.substring(blockM.end, (blockM.end + 900).clamp(0, html.length));
      final m = RegExp(r'src\s*:\s*"([^"]+)"').firstMatch(scope);
      final u = (m?.group(1) ?? '').replaceAll(r'\/', '/');
      if (u.startsWith('http')) return u;
    }
    // 兜底：万一模板改成别处内联，直接在全页找 m3u8
    final fallback = RegExp(r'(https?://[^"\s<]+?\.m3u8[^"\s<]*)')
        .firstMatch(html)
        ?.group(1)
        ?.replaceAll(r'\/', '/');
    if (fallback != null && fallback.startsWith('http')) return fallback;

    throw ApiException(200, '该集没有解析出播放地址，请换一条线路或换一集试试');
  }

  // ---------------- HTML 解析 ----------------

  List<Drama> _cards(String html) {
    final out = <Drama>[];
    final seen = <String>{};
    for (final m in RegExp(r'href="/detail/(\d+)\.html"').allMatches(html)) {
      final id = m.group(1);
      if (id == null || !seen.add(id)) continue;
      var end = m.start + 2600;
      if (end > html.length) end = html.length;
      final seg = html.substring(m.start, end);
      final name = _cardTitle(seg);
      if (name.isEmpty) continue;
      out.add(Drama(
        id: id,
        name: name,
        cover: CoverImage(path: _coverOf(seg)),
        sourceId: this.id,
      ));
    }
    return out;
  }

  /// 卡片标题。模板里同一个位置会出现三个 `.v-item-title`，
  /// 首尾两个是 `style="display: none"` 的站名占位，中间那个才是剧名；
  /// 搜索结果页则用 `<div class="title">`。
  String _cardTitle(String seg) {
    for (final m in RegExp(r'<div class="v-item-title"([^>]*)>([^<]*)</div>')
        .allMatches(seg)) {
      final attrs = m.group(1) ?? '';
      if (attrs.contains('display: none') || attrs.contains('display:none')) {
        continue;
      }
      final t = stripHtml(m.group(2) ?? '').trim();
      if (t.isNotEmpty && !_isJunkTitle(t)) return t;
    }
    final titleDiv =
        RegExp(r'<div class="title">([^<]*)</div>').firstMatch(seg);
    final t2 = stripHtml(titleDiv?.group(1) ?? '').trim();
    if (t2.isNotEmpty && !_isJunkTitle(t2)) return t2;
    final attr = stripHtml(RegExp(r'title="([^"]+)"').firstMatch(seg)?.group(1) ?? '')
        .trim();
    if (attr.isNotEmpty && !_isJunkTitle(attr)) return attr;
    final alt = stripHtml(RegExp(r'alt="([^"]+)"').firstMatch(seg)?.group(1) ?? '')
        .trim();
    if (alt.isNotEmpty && !_isJunkTitle(alt)) return alt;
    return '';
  }

  bool _isJunkTitle(String s) =>
      s.contains('可可影视') || s.contains('kekys') || s.length > 60;

  String _coverOf(String seg) {
    final re = RegExp(
      r'(?:data-original|data-src|src)="([^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"',
      caseSensitive: false,
    );
    for (final m in re.allMatches(seg)) {
      final p = m.group(1)!;
      if (_kKekePlaceholder.hasMatch(p)) continue;
      if (p.startsWith('//')) return 'https:$p';
      if (p.startsWith('/')) return 'https://www.keke1.app$p';
      return p;
    }
    return '';
  }

  DramaDetail _detail(String dramaId, String html) {
    final raw = RegExp(r'<title>([^<]+)</title>').firstMatch(html)?.group(1) ?? '';
    var name = raw.split(RegExp(r'[-_]')).first.trim();
    if (name.isEmpty) name = dramaId;

    // 线路标签：source-item-label（顺序 = 选集分块顺序）
    final labels = RegExp(r'source-item-label">([^<]*)<')
        .allMatches(html)
        .map((m) => stripHtml(m.group(1) ?? '').trim())
        .toList();

    // 选集分块：每个 div.episode-list 对应一条线路（站点 JS 用 .eq(idx) 切）
    final blocks =
        RegExp(r'<div class="episode-list"[^>]*>').allMatches(html).toList();
    final videos = <DramaVideo>[];
    for (var i = 0; i < blocks.length; i++) {
      final start = blocks[i].end;
      final end = i + 1 < blocks.length ? blocks[i + 1].start : html.length;
      if (end <= start) continue;
      final seg = html.substring(start, end);
      final label = i < labels.length ? labels[i] : '线路${i + 1}';

      var epNo = 0;
      for (final m
          in RegExp(r'href="(/play/(\d+)-(\d+)-(\d+)\.html)"').allMatches(seg)) {
        final link = m.group(1)!;
        final lineNo = m.group(3)!;
        epNo++;
        // data-index 是集序号，缺省时用出现顺序兜底
        final tail = seg.substring(
            m.start, (m.start + 400).clamp(0, seg.length));
        final idxM = RegExp(r'data-index="(\d+)"').firstMatch(tail);
        final ep = int.tryParse(idxM?.group(1) ?? '') ?? epNo;
        final epLabel = stripHtml(
                RegExp(r'<span>([^<]*)</span>').firstMatch(tail)?.group(1) ?? '')
            .trim();
        videos.add(DramaVideo(
          id: 'kk_${dramaId}_${lineNo}_$ep',
          title: epLabel.isEmpty ? '第$ep集' : epLabel,
          path: link,
          source: lineNo,
          sourceCn: label,
          episode: ep,
          dramaId: dramaId,
        ));
      }
    }

    return DramaDetail(
      id: dramaId,
      name: name,
      intro: stripHtml(_intro(html)),
      cover: CoverImage(path: _coverOf(html)),
      videos: videos,
      sourceId: id,
    );
  }

  String _intro(String html) {
    final m = RegExp(r'<div class="detail-desc"[^>]*>(.*?)</div>',
            dotAll: true, caseSensitive: false)
        .firstMatch(html);
    return m?.group(1) ?? '';
  }
}