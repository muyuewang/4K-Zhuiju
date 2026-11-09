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
  final int id;
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
      id: pbInt(fs, 3) ?? 0,
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
  final int id;
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
  final int dramaId;
  final int priority;

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
    this.dramaId = 0,
    this.priority = 0,
  });

  factory DramaVideo.fromBytes(Uint8List b) {
    final fs = PbReader(b).readAll();
    return DramaVideo(
      id: pbInt(fs, 1) ?? 0,
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
      dramaId: pbInt(fs, 15) ?? 0,
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
    if (p.startsWith('/')) return true;
    return p.contains('.');
  }

  String get epLabel => episode > 0 ? '第$episode集' : title;
}

class DramaDetail {
  final int id;
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
      id: pbInt(fs, 4) ?? 0,
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
  Map<String, List<DramaVideo>> get sourcesByCn {
    final m = <String, List<DramaVideo>>{};
    for (final v in videos) {
      final key = v.sourceCn.isNotEmpty ? v.sourceCn : v.source;
      m.putIfAbsent(key, () => []).add(v);
    }
    for (final k in m.keys) {
      m[k]!.sort((a, b) => a.episode.compareTo(b.episode));
    }
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