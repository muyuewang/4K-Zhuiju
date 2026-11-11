/// 数据模型：严格对应 APK 内的 proto 定义
///
/// DramaBean          (Drama.proto)
/// DramaCoverImageBean(DramaCoverImage.proto)
/// DramaDetailBean    (DramaDetail.proto)
/// DramaVideoBean     (DramaVideo.proto)
/// ParsePlayUrlBean   (ParsePlayUrl.proto)
library;

import 'dart:typed_data';

import 'protocol.dart';

/// 原版播放器专用令牌：`<纯数字>&<集数>`，例如 `7512797350914444313&1`。
///
/// 这是唯一「接口也换不出地址」的 path 形态。橘汁其它令牌
/// （`v0d5aag…`、`vod_1080-…`）都能经 videoUsableUrl 换成真实地址。
final RegExp _kPlayerOnlyToken = RegExp(r'^\d+&\d+$');

/// 把接口里带 HTML 标记的文本转成纯文本。
///
/// 接口的简介字段（intro）实测返回的是 `&lt;p&gt;该剧根据...&lt;/p&gt;` 这种
/// 二次转义过的 HTML 片段，直接丢进 Text 就会在界面上看到 `<p>` 字样。
/// 这里做三件事：
///   1. 还原被二次转义的实体（&lt; &gt; &amp; &quot; &#39; &nbsp;）
///   2. 去掉 <br> / </p> 这类换行语义标签，替换成换行而不是删掉，
///      否则整段会粘成一行
///   3. 剥掉剩余标签，压缩多余空白
String stripHtml(String s) {
  if (s.isEmpty) return s;
  var t = s;
  // 可能被转义多层，循环到稳定为止（最多 3 层，防止构造的死循环输入）
  for (var i = 0; i < 3; i++) {
    final before = t;
    t = t
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
    if (t == before) break;
  }
  // 块级/换行标签换成换行，避免段落黏连
  t = t.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  t = t.replaceAll(RegExp(r'</(p|div|li|h[1-6])\s*>', caseSensitive: false), '\n');
  // 剥掉剩余标签
  t = t.replaceAll(RegExp(r'<[^>]*>'), '');
  // 行内连续空白压缩成单空格，但保留换行
  t = t
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
  return t.trim();
}

/// 统一 id 为字符串。
///
/// 两套数据源的 id 形态完全不同，展示层与持久化层不该关心来源：
///   - 橘汁（旧源）：protobuf 里的 int，如 `12345`
///   - kanju（新源）：`av_` 前缀的长串，如 `av_nH2ZeKZ0Ft4q...`
///
/// 旧本地数据存的是 int，读回来必须能安全转换；判空的语义也从
/// 「== 0」变成「isEmpty」，所以 int 0 一律归一成空串。
String idToStr(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is int) return v == 0 ? '' : '$v';
  if (v is num) {
    final i = v.toInt();
    return i == 0 ? '' : '$i';
  }
  return v.toString();
}

class CoverImage {
  final String path;
  final String thumbnail;

  CoverImage({this.path = '', this.thumbnail = ''});

  factory CoverImage.fromBytes(Uint8List b) {
    final fs = PbReader(b).readAll();
    return CoverImage(
      path: pbString(fs, 1) ?? '',
      thumbnail: pbString(fs, 2) ?? '',
    );
  }

  /// 优先缩略图，其次原图
  String get best => thumbnail.isNotEmpty ? thumbnail : path;
}

class Drama {
  final String id;
  final String name;
  final String area;
  final String brief;
  final double stars;
  final String director;
  final String actor;
  final String remark;
  final int year;
  final int type;
  final String clazz;
  final int updateTime;
  final String vodPubdate;
  final CoverImage cover;

  /// 该条目来自哪个数据源（`zhuiju` / `kanju`）。
  ///
  /// 空串表示老数据，按 `zhuiju` 处理。列表不展示它，但「详情页回跳」
  /// 与「换源」必须知道去哪取，否则跨源切换时会用错 id 去查。
  final String sourceId;

  Drama({
    required this.id,
    required this.name,
    this.area = '',
    this.brief = '',
    this.stars = 0,
    this.director = '',
    this.actor = '',
    this.remark = '',
    this.year = 0,
    this.type = 0,
    this.clazz = '',
    this.updateTime = 0,
    this.vodPubdate = '',
    CoverImage? cover,
    this.sourceId = '',
  }) : cover = cover ?? CoverImage();

  factory Drama.fromBytes(Uint8List b) {
    final fs = PbReader(b).readAll();
    CoverImage cover = CoverImage();
    final coverBytes = pbBytesAll(fs, 2);
    if (coverBytes.isNotEmpty) {
      try {
        cover = CoverImage.fromBytes(coverBytes.first);
      } catch (_) {}
    }
    return Drama(
      area: pbString(fs, 1) ?? '',
      cover: cover,
      id: idToStr(pbInt(fs, 3)),
      brief: stripHtml(pbString(fs, 4) ?? ''),
      name: pbString(fs, 5) ?? '',
      stars: _readFloat(fs, 6),
      director: pbString(fs, 7) ?? '',
      type: pbInt(fs, 8) ?? 0,
      updateTime: pbInt(fs, 10) ?? 0,
      vodPubdate: pbString(fs, 11) ?? '',
      actor: pbString(fs, 12) ?? '',
      remark: pbString(fs, 13) ?? '',
      year: pbInt(fs, 14) ?? 0,
      clazz: pbString(fs, 15) ?? '',
    );
  }

  /// float 字段走 wiretype=5，PbReader 目前跳过，这里退化为 0
  static double _readFloat(List<PbField> fs, int num) => 0;

  String get displaySub {
    final parts = <String>[];
    if (year > 0) parts.add('$year');
    if (area.isNotEmpty) parts.add(area);
    if (remark.isNotEmpty) parts.add(remark);
    return parts.join(' · ');
  }
}

/// 剧集（单集视频条目）
class DramaVideo {
  final String id;
  final String title;
  final String titleOld;
  final String path;
  final int size;
  final String format;
  final int type;
  final String source;
  final String sourceCn;
  final int season;
  final int episode;
  final bool isVip;
  final String dramaId;
  final int priority;

  /// kanju 专用：本条目对应的「播放标识」，播放时必须用它去 resolve。
  ///
  /// 橘汁的 path 本身就是地址或令牌，kanju 的 path 只是占位，
  /// 真正的地址要 `episode.token` 换两次才拿到。空串表示不需要。
  final String playToken;

  /// kanju 专用：该线路是否需要第二阶段解析（官方线）。
  final bool needsResolve;

  DramaVideo({
    required this.id,
    required this.title,
    this.titleOld = '',
    required this.path,
    this.size = 0,
    this.format = '',
    this.type = 0,
    required this.source,
    this.sourceCn = '',
    this.season = 0,
    this.episode = 0,
    this.isVip = false,
    this.dramaId = '',
    this.priority = 0,
    this.playToken = '',
    this.needsResolve = false,
  });

  factory DramaVideo.fromBytes(Uint8List b) {
    final fs = PbReader(b).readAll();
    return DramaVideo(
      id: idToStr(pbInt(fs, 1)),
      title: pbString(fs, 2) ?? '',
      titleOld: pbString(fs, 3) ?? '',
      path: pbString(fs, 4) ?? '',
      size: pbInt(fs, 5) ?? 0,
      format: pbString(fs, 7) ?? '',
      type: pbInt(fs, 8) ?? 0,
      source: pbString(fs, 9) ?? '',
      sourceCn: pbString(fs, 10) ?? '',
      season: pbInt(fs, 12) ?? 0,
      episode: pbInt(fs, 13) ?? 0,
      isVip: (pbInt(fs, 14) ?? 0) == 1,
      dramaId: idToStr(pbInt(fs, 15)),
      priority: pbInt(fs, 16) ?? 0,
    );
  }

  /// path 本身就是完整 URL（bfzym3u8 / qq 两类源）
  bool get isDirectPath => path.startsWith('http');

  /// path 是否「可能是地址」。
  ///
  /// 独家短剧（source=hgdj）这类源返回的 path 是
  /// `7512797350914444313&1` —— 原版播放器的内部令牌，既不是 URL，
  /// 也不是站内路径。直接丢给 VideoPlayerController 只会得到
  /// UnrecognizedInputFormat，用户根本看不懂。而它偏偏集数最多
  /// （90 集），一旦被选成默认源，点任何一集都放不出来。
  ///
  /// 判据刻意保守：地址要么带 scheme、要么以 / 开头、要么含「.」
  /// （xxx.m3u8 / xxx.mp4 / index.php）。令牌形态三者都不满足。
  /// 判错的代价只是「多试一次接口」，判漏的代价是整部剧不能播。
  bool get pathLooksPlayable {
    final p = path.trim();
    if (p.isEmpty) return false;
    if (p.startsWith('http://') || p.startsWith('https://')) return true;
    // kanju 的官方线给的是 `resolve://<ticket>`，它确实能解析出地址，
    // 只是要多走一次接口。判成不可播会让这类线路被 source_picker 整条丢弃，
    // 用户就永远看不到「1080P-官方」这些线路。
    if (p.startsWith('resolve://')) return true;
    if (p.startsWith('/')) return true;
    if (p.contains('.')) return true;

    // 橘汁绝大多数线路下发的**不是地址，而是令牌**，例如：
    //   自建蓝光 pylg     → v0d5aag10002dbk6tdvog65q84mufc70
    //   自建4K-4 tocyyds → tos-cn-i-3jr8j4ixpe/90372116c2a748f0a86465b484e837
    //   NN蓝光 vod_1080  → vod_1080-2d5eea94b50490bccb4af14ab14dd83e
    // ZhuijuSource.resolveUrl 会拿 source + path 调 videoUsableUrl 换出
    // 真实地址，所以它们是**能播的**，只是要多一次请求。
    //
    // 旧实现只认 URL，实测「走马上任」12 条线路里 10 条被判成
    // kRankDead 整条沉底，换源时也被直接过滤 —— 用户能选的只剩
    // QQ 和 B蓝光这两条画质最差的采集线。
    //
    // 真正不能播的只有原版播放器专用令牌 `<纯数字>&<集数>`（独家短剧），
    // 这种令牌没有任何接口能换成地址。
    if (_kPlayerOnlyToken.hasMatch(p)) return false;
    return true;
  }

  /// 选集栏 / 标题栏用的集名。
  ///
  /// 直播频道这类条目比较特殊：接口把 `title` 下成纯序号（"1"），
  /// 真正的频道名放在 `titleOld`（"CCTV1综合" / "浙江卫视"）。
  /// 直接走 `第N集` 会让 26 个频道长得一模一样，用户没法选台。
  /// 只在这个特征成立时才用 titleOld，普通剧集不受影响。
  String get epLabel {
    if (titleOld.isNotEmpty && RegExp(r'^\d+$').hasMatch(title.trim())) {
      return titleOld;
    }
    return episode > 0 ? '第$episode集' : title;
  }
}

class DramaDetail {
  final String id;
  final String name;
  final String area;
  final String brief;
  final String intro;
  final String director;
  final String actor;
  final String remark;
  final String tag;
  final int year;
  final int type;
  final int hits;
  final bool isEnd;
  final double stars;
  final CoverImage cover;
  final List<DramaVideo> videos;

  /// 该详情来自哪个数据源，回传给详情页用于后续取流
  final String sourceId;

  DramaDetail({
    required this.id,
    required this.name,
    this.area = '',
    this.brief = '',
    this.intro = '',
    this.director = '',
    this.actor = '',
    this.remark = '',
    this.tag = '',
    this.year = 0,
    this.type = 0,
    this.hits = 0,
    this.isEnd = false,
    this.stars = 0,
    CoverImage? cover,
    this.videos = const [],
    this.sourceId = '',
  }) : cover = cover ?? CoverImage();

  factory DramaDetail.fromBytes(Uint8List b) {
    final fs = PbReader(b).readAll();
    CoverImage cover = CoverImage();
    final cb = pbBytesAll(fs, 2);
    if (cb.isNotEmpty) {
      try {
        cover = CoverImage.fromBytes(cb.first);
      } catch (_) {}
    }
    final videos = <DramaVideo>[];
    for (final seg in pbBytesAll(fs, 29)) {
      try {
        videos.add(DramaVideo.fromBytes(seg));
      } catch (_) {}
    }
    return DramaDetail(
      area: pbString(fs, 1) ?? '',
      cover: cover,
      id: idToStr(pbInt(fs, 4)),
      intro: stripHtml(pbString(fs, 6) ?? ''),
      brief: stripHtml(pbString(fs, 7) ?? ''),
      name: pbString(fs, 9) ?? '',
      director: pbString(fs, 12) ?? '',
      tag: pbString(fs, 13) ?? '',
      type: pbInt(fs, 14) ?? 0,
      year: pbInt(fs, 18) ?? 0,
      hits: pbInt(fs, 19) ?? 0,
      actor: pbString(fs, 25) ?? '',
      remark: pbString(fs, 26) ?? '',
      isEnd: (pbInt(fs, 27) ?? 0) == 1,
      videos: videos,
    );
  }

  /// 按 source 分组：sourceCn -> 该源下的剧集
  ///
  /// 结果做惰性缓存：本类字段全是 final，内容不会变，分组结果可以复用。
  ///
  /// 为什么必须缓存：kanju 一部 54 集的剧有 14 条线路 = 756 条记录，
  /// 每次调用都要建 Map + 对 14 个列表各排序一次。而详情页里有 6 处
  /// 调用 sourcesByCn（构建体、续播、下载索引、线路面板…），任一
  /// setState（切源、展开简介、收藏）都会让这 6 处全部重算。
  /// 实测在低端机上是可见的掉帧。
  Map<String, List<DramaVideo>>? _sourcesCache;

  Map<String, List<DramaVideo>> get sourcesByCn {
    final cached = _sourcesCache;
    if (cached != null) return cached;

    final m = <String, List<DramaVideo>>{};
    for (final v in videos) {
      final key = v.sourceCn.isNotEmpty ? v.sourceCn : v.source;
      m.putIfAbsent(key, () => []).add(v);
    }
    for (final k in m.keys) {
      m[k]!.sort((a, b) => a.episode.compareTo(b.episode));
    }
    _sourcesCache = m;
    return m;
  }
}

class PlayInfo {
  final String playUrl;
  final int fitMode;
  final int mirrorMode;
  final int timeout;
  final int direct;
  final Map<String, String> headers;
  final String msg;

  PlayInfo({
    required this.playUrl,
    this.fitMode = 0,
    this.mirrorMode = 0,
    this.timeout = 0,
    this.direct = 0,
    this.headers = const {},
    this.msg = '',
  });

  factory PlayInfo.fromBytes(Uint8List b) {
    final fs = PbReader(b).readAll();
    return PlayInfo(
      playUrl: pbString(fs, 1) ?? '',
      fitMode: pbInt(fs, 2) ?? 0,
      mirrorMode: pbInt(fs, 3) ?? 0,
      timeout: pbInt(fs, 4) ?? 0,
      direct: pbInt(fs, 5) ?? 0,
      msg: pbString(fs, 9) ?? '',
    );
  }
}