/// 4K影视（www.4kvm.net）适配器。
///
/// 和 [MacCmsSource] / [MacCmsApiSource] 都不是同一套程序：站点是 **Go 写的
/// 服务端渲染站**（`404 page not found` 是 Go 的默认 404 文案），路径形如
/// `/play/<base36>`、`/filter?classify=N`、`/search?q=`，没有 MacCMS 的
/// `api.php/provide/vod/` 采集接口（实测 404）。
///
/// ## 2026-11-12 逐条实测（下面每一条都是跑出来的，不是推测）
///
///   ✅ 列表页服务端渲染：卡片是 `data-vod-id="<slug>"` + `<a href="/play/<slug>">`
///   ✅ 搜索 `/search?q=<关键词>`，每页固定 20 条，**`page` 参数无效**
///      （page=2/3 返回与第 1 页完全相同的内容），所以第 2 页起直接返回空表
///   ✅ 分类 `/filter?classify=1|2|3`（电影/电视剧/动漫），`?page=N` **有效**，
///      每页 30 条；classify=4/5 无数据（站上综艺/其它分区是空的）
///   ✅ 详情 `/play/<slug>` 里，选集是
///      `<a href="/play/<slug>" ... data-line="1" data-episode="1" dataid="41860">`
///      集数标签在 `data-episode`，播放用的数字 id 在 `dataid`
///   ✅ 线路名在 `episodeManager(1, 1, [{ lineName: 'alists', episodeCount: 10 }])`
///
/// ## 播放地址：站点把取址逻辑编译成了 WASM，这里已完整还原
///
/// 前端不直出 m3u8，而是加载 `/static/wasm/nbmovie_wasm_bg.*.wasm`，调用
/// `build_play_url(dataid, secretKey, quality, playKey)` 生成
/// `/video/play?p=&v=&q=&s=&t=&k=`，再 `fetch` 它换 JSON。**WASM 只是障眼法**，
/// 两个参数都能纯 Dart 复现（已用 9 组样本对拍全部一致）：
///
///   - `k`（playKey → 令牌）：`base64(userlink 逐字节 XOR "nbmovie2024secretkey")`，
///     密钥取自 WASM 数据段 `nbmovie2024secretkey`，按索引循环异或。
///     空串或 `'0'` 时原样输出 `'0'`（未登录形态）。
///   - `s`（签名）：**HMAC-SHA256**，key = `v`（就是 slug 本身），
///     msg = `"<p>:<t>:<v>"`，取 hex 前 32 位。
///     还原过程：给 WASM 的 SHA-256 压缩函数插桩，抓到 4 次调用，
///     第 0/1 次的数据块分别用 0x36 / 0x5c 填充 —— 正是 HMAC 的 ipad/opad，
///     把 key 与 0x36 异或后得到 `ch4sn04yf`（= v），msg 块里是 `p:t:v`。
///
///   - `userlink` 由**详情页每次渲染时下发**，写在导航栏的
///     `x-data="{... userlink:'X1VUW0JQ...'}"` 里，然后用
///     `window.myuserlink = userlink` 挂到全局。所以取址前必须先抓一次详情页。
///     实测换一个页面的 userlink 也能过校验，说明它不是「一页一密」，
///     但仍带时间语义，因此这里按 [vodId] 缓存 [userlinkTtl] 就重取，
///     不做长期缓存（过期会被服务端判 401「请提供访问令牌」）。
///
/// ## 代理
///
/// 源站国内直连不通（`os error 11001 不知道这样的主机`），必须走系统代理。
/// 本项目的 [NetProxy] 用 `HttpOverrides.global` 全局注入，所以这里不用
/// 单独处理代理 —— 用户开了代理就能用，没开会得到「无法连接源站」。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:pointycastle/export.dart'
    show HMac, KeyParameter, SHA256Digest;

import '../api.dart';
import '../models.dart';
import 'data_source.dart';
import 'site_http.dart';

/// 站点根地址。
const String kKvm4kBase = 'https://www.4kvm.net';

/// `k` 参数异或用的密钥。取自 WASM 数据段偏移 1048576 处，
/// 后面紧跟 `\xc3\x20` 是下一段数据的长度前缀，**不属于密钥**。
const String kKvmSecret = 'nbmovie2024secretkey';

/// 取址接口路径。完整地址是 `$kKvm4kBase$kKvmPlayPath?...`。
const String kKvmPlayPath = '/video/play';

// ==================== 纯函数区（便于离线回归，不依赖网络） ====================

/// 生成 `s` 签名：`HMAC-SHA256(key=vodId, msg="<dataid>:<ts>:<vodId>")` 的 hex 前 32 位。
///
/// 注意 key 是 **vodId（slug）而不是那个 `nbmovie2024secretkey`** —— 后者只用于
/// `k`。这一点很反直觉，实测 9 组样本（含空 vodId、含 p 变化、含 t 变化）
/// 全部对上才确认。
String kvmSign(String dataid, int tsMs, String vodId) {
  final mac = HMac(SHA256Digest(), 64)
    ..init(KeyParameter(Uint8List.fromList(utf8.encode(vodId))));
  final digest = mac.process(
    Uint8List.fromList(utf8.encode('$dataid:$tsMs:$vodId')),
  );
  final hex = StringBuffer();
  for (final b in digest) {
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString().substring(0, 32);
}

/// 生成 `k` 参数：`base64(userlink 逐字节 XOR 密钥)`。
///
/// 空串与 `'0'` 是「未登录」形态，服务端要的就是字面量 `0`，不能编码成
/// `base64("") == ""`（那会得到空参数，服务端回 400 缺少必要参数）。
String kvmKeyParam(String userlink) {
  if (userlink.isEmpty || userlink == '0') return '0';
  final key = utf8.encode(kKvmSecret);
  final buf = utf8.encode(userlink);
  for (var i = 0; i < buf.length; i++) {
    buf[i] = buf[i] ^ key[i % key.length];
  }
  return base64Encode(buf);
}

/// 拼出取址请求的查询参数（签名与时间戳每次现算）。
///
/// [quality] 传 `'1'` 表示「最高画质档位」——服务端会连 4K 一起下发，
/// 由客户端在 `quality_urls` 里挑能播的那条。传 `'1080'` / `'720'` / `'480'`
/// 则只给该档。实测 `q=1` 的返回最全，所以默认用它。
Map<String, String> kvmPlayQuery({
  required String dataid,
  required String vodId,
  required String userlink,
  required int tsMs,
  String quality = '1',
}) {
  return {
    'p': dataid,
    'v': vodId,
    'q': quality,
    's': kvmSign(dataid, tsMs, vodId),
    't': '$tsMs',
    'k': kvmKeyParam(userlink),
  };
}

/// 从 `quality_urls` 里挑一条能直接播的地址。
///
/// 规则按优先级：非 VIP、未锁定、`url` 是 http(s)。站点把 4K 标成
/// `isvip: true` 且 `url` 直接下发字符串 `"1"`（不是地址，是个占位标记），
/// 直接把 `"1"` 丢给播放器只会得到 UnrecognizedInputFormat，用户完全看不懂。
/// 宁可降一档给 1080P，也不能把占位符当地址。
String? kvmPickPlayableUrl(List<Map<String, dynamic>> qualityUrls) {
  String? fallback;
  for (final q in qualityUrls) {
    final url = (q['url'] ?? '').toString().trim();
    if (!url.startsWith('http')) continue;
    final vip = q['isvip'] == true;
    final locked = q['locked'] == true;
    if (!vip && !locked) return url;
    fallback ??= url;
  }
  return fallback;
}

/// 从导航栏 x-data 里取 `userlink:'...'`。
///
/// 必须匹配带引号的赋值形态：页面里还有 `window.myuserlink = userlink;`
/// 和 `||'0'` 两处，泛匹配会抓到字符串 `userlink` 本身。
String kvmUserlinkOf(String html) {
  final m = RegExp(r"userlink:'([^']*)'").firstMatch(html);
  return m?.group(1) ?? '';
}

/// 解析列表页卡片。同一个 id 在一页里会出现多次（首页有「最新上架」「热播」
/// 多个分区，还有卡片 hover 面板里的第二份链接），所以第一次出现就收，后面去重。
///
/// ## 2026-11-12 修正：锚点从 `data-vod-id` 改为 href 里的 slug
///
/// 早先只认外层 `<div ... data-vod-id="<slug>">`，**搜索结果页完全没有这个属性**
/// （实测 `q=凡人` / `q=无职` 的 `data-vod-id` 计数都是 0），所以搜索恒返回空表 ——
/// 用户报的「4k影视搜索功能异常、啥也是无结果」就是这个。首页同样漏抓：
/// 71 个唯一 slug 里有 3 个没有 `data-vod-id` 外壳。
///
/// 现在改认 `<a href="/play/<slug>" data-vod="...">` 里的 slug：
///   - 它是 `/play/` 的路径段，正是 [parseKvmDetail] / `detail()` 要拼的那个值；
///   - 实测它是 `data-vod-id` 的**严格超集**（首页 71 ⊃ 68，无一遗漏）。
///
/// **`data-vod` 不能当 id**：它和 slug 是两个不同的值
/// （同一个锚点上 `href="/play/cgzq7f3tf"` 而 `data-vod="cgzq7cao3"`），
/// 拿它去拼详情页地址必然 404。
///
/// 但「必须带 `data-vod`」这个约束要保留：详情页的选集锚点也是
/// `<a href="/play/<slug>" ...>`，只是带 `data-line` / `dataid` 而**不带
/// `data-vod`**。靠这个属性就能把选集从列表结果里排除掉。
List<Drama> parseKvmCards(String html, {required String sourceId}) {
  if (html.isEmpty) return const [];
  final re = RegExp(r'href="/play/([A-Za-z0-9]+)"\s+data-vod="');
  final matches = re.allMatches(html).toList();
  final out = <Drama>[];
  final seen = <String>{};
  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    final vid = m.group(1)!;
    if (!seen.add(vid)) continue;
    // 窗口右界取「下一张卡片起点」。**不能再用固定 2200 字节**：
    // 实测首页 `href` → `<h3>` 最远 3844 字节（卡片间的 hover 面板把它撑长了），
    // 固定窗口会把标题截在卡片外面，导致该剧被整条丢弃。
    final next = i + 1 < matches.length ? matches[i + 1].start : html.length;
    final end = next.clamp(m.start, m.start + 6000);
    final seg = html.substring(m.start, end);
    final name = _kvmCardTitle(seg);
    if (name.isEmpty) continue;
    out.add(Drama(
      id: vid,
      name: name,
      cover: CoverImage(path: _kvmCoverOf(seg)),
      sourceId: sourceId,
    ));
  }
  return out;
}

/// 卡片标题。模板里 `<h3>` 是标题，`<img alt>` 通常和它一致；
/// 先用 h3（更干净），拿不到再退 alt。
String _kvmCardTitle(String seg) {
  final h3 = RegExp(r'<h3[^>]*>([^<]+)</h3>').firstMatch(seg);
  final t1 = stripHtml(h3?.group(1) ?? '').trim();
  if (t1.isNotEmpty) return t1;
  final alt = RegExp(r'alt="([^"]*)"').firstMatch(seg);
  return stripHtml(alt?.group(1) ?? '').trim();
}

String _kvmCoverOf(String seg) {
  // 列表页封面是懒加载：`data-src` 才是真图，`src` 是站内占位 SVG。
  // 但首页顶部的轮播横幅与排行榜卡片**不走懒加载**，只有 `src`（真图），
  // 所以 `data-src` 缺失时要退到 `src`，并且必须排掉占位图 ——
  // 否则 6 条卡片（奥德赛 / 空枪 / 蜘蛛侠…）会变成无封面。
  final lazy = RegExp(r'data-src="([^"]+)"').firstMatch(seg);
  final fromLazy = _kvmAbsUrl(_kvmUnescape(lazy?.group(1) ?? ''));
  if (fromLazy.isNotEmpty) return fromLazy;

  final plain = RegExp(r'\ssrc="([^"]+)"').firstMatch(seg);
  final fromSrc = _kvmAbsUrl(_kvmUnescape(plain?.group(1) ?? ''));
  if (fromSrc.contains('placeholder')) return '';
  return fromSrc;
}

/// 详情页封面。
///
/// **和列表页不是同一个字段**：详情页 5 个样本（`d_ch4sn04yf` / `d_ch4slr6s8`
/// / `tv_ch4rt1ctb` / `tv_ch4ry15i3` / `detail_cgzkv4x7h`）实测 `data-src`
/// 出现次数全是 **0**，海报只在 `og:image` 里。早先这里复用 `_kvmCoverOf(html)`
/// 导致详情页封面恒为空。
String _kvmDetailCoverOf(String html) {
  final og = RegExp(r'property="og:image"\s+content="([^"]*)"').firstMatch(html);
  final fromOg = _kvmAbsUrl(_kvmUnescape(og?.group(1) ?? ''));
  if (fromOg.isNotEmpty) return fromOg;
  return _kvmCoverOf(html);
}

/// 百度图床地址里带 `&amp;`，转义没还原会 404；协议相对的补 `https:`。
String _kvmAbsUrl(String p) {
  final t = p.trim();
  if (t.isEmpty) return '';
  if (t.startsWith('//')) return 'https:$t';
  return t;
}

/// 解析详情页的选集列表与元信息。
///
/// [dramaId] 是 slug（URL 里的 `/play/<slug>`），会原样回填到每一条
/// [DramaVideo.dramaId]，播放时用它拼 Referer 与 `v` 参数。
DramaDetail parseKvmDetail(
  String dramaId,
  String html, {
  required String sourceId,
}) {
  var name = '';
  // og:title 形如「深情触摸 - 第1集」，去掉集数后缀最准。
  final og =
      RegExp(r'property="og:title"\s+content="([^"]*)"').firstMatch(html);
  if (og != null) {
    name = _kvmUnescape(og.group(1) ?? '').split(' - 第').first.trim();
  }
  if (name.isEmpty) {
    final t = RegExp(r'<title>([^<]*)</title>').firstMatch(html)?.group(1) ?? '';
    name = t.split(' - ').first.trim();
  }
  if (name.isEmpty) name = dramaId;

  // 线路名：episodeManager(1, 1, [{ lineName: 'alists', episodeCount: 10 }])
  final lineNames = RegExp(r"lineName:\s*'([^']*)'")
      .allMatches(html)
      .map((m) => m.group(1) ?? '')
      .toList();

  // 选集：属性顺序固定为 data-line -> data-episode -> dataid，
  // 用非贪婪逐段吃，避免把整个标签吃掉。
  final videos = <DramaVideo>[];
  final re = RegExp(
    r'<a href="/play/([A-Za-z0-9]+)"[^>]*?'
    r'data-line="(\d+)"[^>]*?'
    r'data-episode="(\d+)"[^>]*?'
    r'dataid="(\d+)"[^>]*>(.*?)</a>',
    dotAll: true,
  );
  for (final m in re.allMatches(html)) {
    final slug = m.group(1)!;
    final line = int.tryParse(m.group(2) ?? '') ?? 1;
    final ep = int.tryParse(m.group(3) ?? '') ?? 0;
    final dataid = m.group(4)!;
    final inner = m.group(5) ?? '';
    // 集数标签在最后一个 <span> 里（前面是「播放中」三条竖条的 div）。
    final spans = RegExp(r'<span[^>]*>([^<]*)</span>').allMatches(inner);
    var label =
        spans.isEmpty ? '' : stripHtml(spans.last.group(1) ?? '').trim();
    if (label.isEmpty) label = ep > 0 ? '第$ep集' : '正片';
    final lineName =
        (line - 1) < lineNames.length ? lineNames[line - 1] : '线路$line';

    videos.add(DramaVideo(
      id: 'kvm_${dramaId}_${line}_$ep',
      title: label,
      path: '/play/$slug',
      source: '$line',
      sourceCn: lineName,
      episode: ep,
      dramaId: dramaId,
      playToken: dataid,
    ));
  }

  return DramaDetail(
    id: dramaId,
    name: name,
    intro: parseKvmIntro(html),
    cover: CoverImage(path: _kvmDetailCoverOf(html)),
    videos: videos,
    sourceId: sourceId,
  );
}

/// 简介优先用 `<meta name="description">`：站点把正文简介放在这里，
/// 页面里的「剧情简介」区块是前端按需展开的，HTML 里反而没有全文。
String parseKvmIntro(String html) {
  final m = RegExp(r'<meta\s+name="description"\s+content="([^"]*)"')
      .firstMatch(html);
  final t = stripHtml(_kvmUnescape(m?.group(1) ?? '')).trim();
  if (t.isNotEmpty) return t;
  final kw = RegExp(r'<meta\s+name="keywords"\s+content="([^"]*)"')
      .firstMatch(html);
  return stripHtml(_kvmUnescape(kw?.group(1) ?? '')).trim();
}

String _kvmUnescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

// ============================== 适配器 ==============================

class Kvm4kSource implements DataSource {
  Kvm4kSource._()
      : _http = SiteHttp(baseUrl: kKvm4kBase, referer: '$kKvm4kBase/');

  static final Kvm4kSource instance = Kvm4kSource._();

  /// 只读 HTML。取址接口单独用 [_api]。
  final SiteHttp _http;

  /// 取址接口用独立 Dio：`SiteHttp` 固定发 `Accept: text/html`，
  /// 而这里要 JSON；另外 Referer 必须指向**当前这一部剧**的详情页
  /// （服务端会校验来源页），`SiteHttp` 只能给一个固定 Referer。
  late final Dio _api = Dio(BaseOptions(
    baseUrl: kKvm4kBase,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
    headers: {
      'User-Agent': kSiteUserAgent,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    },
  ));

  /// `userlink` 缓存：slug -> (值, 取得时刻)。
  ///
  /// 为什么要缓存：一部 60 集的剧，用户在选集页连点 5 集，每集 resolveUrl
  /// 都要 userlink。不缓存就是 5 次多余的详情页请求（每次 ~110KB）。
  ///
  /// 为什么又要过期：userlink 带时间语义，实测放久了服务端回 401
  /// 「请提供访问令牌」。2 分钟足够覆盖一轮连续操作，又能自然刷新。
  static const Duration userlinkTtl = Duration(minutes: 2);
  final Map<String, ({String value, DateTime at})> _userlinkCache = {};

  static const List<SourceCategory> _categories = [
    SourceCategory('', '推荐'),
    SourceCategory('1', '电影'),
    SourceCategory('2', '电视剧'),
    SourceCategory('3', '动漫'),
  ];

  @override
  String get id => 'kvm4k';

  @override
  String get displayName => '4K影视';

  @override
  String get description =>
      '需系统代理（源站国内直连不通）；无弹幕；4K 线路需站点 VIP，会自动降级到 1080P';

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
      return parseKvmCards(await _http.get('/'), sourceId: id);
    }
    // 站点搜索不分页：page=2/3 返回的内容与第 1 页逐字节相同。
    // 这里必须显式返回空表，否则上拉加载会无限追加同一批 20 条。
    if (page > 1) return const [];
    return parseKvmCards(
      await _http.get('/search', query: {'q': k}),
      sourceId: id,
    );
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty) {
      // 「推荐」复用首页。首页内容最全，且是站点自己编排的。
      if (page > 1) return const [];
      return parseKvmCards(await _http.get('/'), sourceId: id);
    }
    return parseKvmCards(
      await _http.get('/filter', query: {
        'classify': categoryId,
        if (page > 1) 'page': page,
      }),
      sourceId: id,
    );
  }

  // ---------------------------- 详情 ----------------------------

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final path = '/play/$dramaId';
    final html = await _http.get(path, referer: '$kKvm4kBase$path');
    // 顺手把这一页的 userlink 存起来，播放时就不用再抓一次详情页。
    final ul = kvmUserlinkOf(html);
    if (ul.isNotEmpty) {
      _userlinkCache[dramaId] = (value: ul, at: DateTime.now());
    }
    return parseKvmDetail(dramaId, html, sourceId: id);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final vodId =
        video.dramaId.isNotEmpty ? video.dramaId : _slugOf(video.path);
    if (vodId.isEmpty) {
      throw ApiException(-1, '这条剧集缺少剧集标识，无法取址');
    }
    final dataid = video.playToken.trim();
    if (dataid.isEmpty) {
      throw ApiException(-1, '这条剧集缺少播放 id，请返回重新进入详情页');
    }

    final userlink = await _userlink(vodId);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp = await _api.get<String>(
      kKvmPlayPath,
      queryParameters: kvmPlayQuery(
        dataid: dataid,
        vodId: vodId,
        userlink: userlink,
        tsMs: ts,
      ),
      options: Options(headers: {'Referer': '$kKvm4kBase/play/$vodId'}),
    );

    final code = resp.statusCode ?? -1;
    final body = resp.data ?? '';
    if (code == 401) {
      // userlink 过期（或没带上）。清缓存，让下一次重新抓详情页。
      _userlinkCache.remove(vodId);
      throw ApiException(401, '取址令牌已过期，请重试（已自动清除缓存）');
    }
    if (code != 200) {
      throw ApiException(code, '取址接口返回 HTTP $code：${_clip(body)}');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(code, '取址接口返回的不是 JSON：${_clip(body)}');
    }
    if (json['code'] != 200) {
      throw ApiException(
        (json['code'] as num?)?.toInt() ?? -1,
        (json['message'] ?? '取址失败').toString(),
      );
    }

    final data = json['data'];
    final list = <Map<String, dynamic>>[];
    if (data is Map && data['quality_urls'] is List) {
      for (final e in data['quality_urls'] as List) {
        if (e is Map) list.add(e.cast<String, dynamic>());
      }
    }
    final url = kvmPickPlayableUrl(list);
    if (url == null) {
      throw ApiException(-1, '该集没有可直接播放的地址，可能只在站点 VIP 线路上');
    }
    return url;
  }

  /// 取 `userlink`。缓存过期或未命中时抓一次详情页。
  Future<String> _userlink(String vodId) async {
    final hit = _userlinkCache[vodId];
    if (hit != null && DateTime.now().difference(hit.at) < userlinkTtl) {
      return hit.value;
    }
    try {
      final html = await _http.get(
        '/play/$vodId',
        referer: '$kKvm4kBase/play/$vodId',
      );
      final ul = kvmUserlinkOf(html);
      if (ul.isNotEmpty) {
        _userlinkCache[vodId] = (value: ul, at: DateTime.now());
      }
      return ul;
    } catch (e) {
      // 拿不到不算致命：未登录形态 `k=0` 也能取到非 VIP 的地址。
      // 这里降级成 '0'，让播放先试一把，而不是把错误直接抛给用户。
      debugPrint('[KVM] userlink failed: $e');
      return '0';
    }
  }

  // ---------------------------- 小工具 ----------------------------

  /// `/play/ch4sn04yf` -> `ch4sn04yf`
  String _slugOf(String path) {
    final p = path.trim();
    if (p.isEmpty) return '';
    final seg = p.split('/').where((s) => s.isNotEmpty).toList();
    return seg.isEmpty ? '' : seg.last;
  }

  String _clip(String s) =>
      s.length <= 120 ? s.replaceAll('\n', ' ') : '${s.substring(0, 120)}…';
}