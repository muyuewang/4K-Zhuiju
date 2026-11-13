/// 金牌影院（m.hellorlgzf7sn.com）适配器。
///
/// 这个源来自「凝幕影视（爱影视）2.0.9」内置解析脚本里的 `jplink`。
/// 凝幕原本只把它当**播放解析器**用（bootstrap 的 `local_parse.items[1]`，
/// prepare 是 `split(url, "JP-<id>-<nid>")`），片库由凝幕后端提供。
///
/// 但凝幕后端全站开了 `api.crypto` 请求加密层（未带加密头一律回 4011），
/// 而它的加密设置页写明「主密钥留空 = 服务端运行时派生、不落盘」——
/// 密钥不在任何静态文件里，静态分析拿不到，这条路是封死的。
///
/// 于是反过来做：**直接对接金牌影院自己的站点**。它是独立完整的片库，
/// 电影 / 电视剧 / 综艺 / 动漫四类齐全（另有短剧、体育直播），
/// 比凝幕那层壳更直接。下面每一条都是实测跑出来的：
///
///   | 项 | 值 |
///   | --- | --- |
///   | 站点 | Next.js（App Router），页面数据全部走 XHR |
///   | 网关 | `https://m.hellorlgzf7sn.com`（`www` 上这些路径是 404） |
///   | 签名 | `sha1(md5(参数串 + "&key=<signKey>&t=<毫秒时间戳>"))` |
///   | signKey | `cb808529bae6b6be45ecfab29a4889bc`（前端明文，见下） |
///   | 请求头 | `sign` / `t` / `deviceId` / `accept: application/json` |
///
/// **签名算法是怎么来的**：站点的 `_next/static/chunks/5055-*.js` 里
/// 直接写着 `signKey:"cb8085..."`，同文件 2844-*.js 里有构造函数：
///
/// ```js
/// h = "key=" + signKey + "&t=" + Date.now()
/// g = GET ? Object.keys(t).sort().map(k => k+"="+t[k]).join("&")
///         : JSON.stringify(t)
/// return { sign: sha1(md5(g ? g+"&"+h : h).toString()).toString() }
/// ```
///
/// 两个细节容易踩，都写在实现里：
///   1. **参数串按 key 排序**，且值是**原文**——不 URL 编码、不做大小写变换。
///      把 `%E7%8B%82%E9%A3%99` 编进签名串会得到 122001「应用签名失败」。
///   2. `md5` 的输出是**小写 hex 字符串**，再拿这个字符串去算 sha1。
///      不是 md5 的原始字节。搞错同样是 122001。
///
/// 取流实测：`episode/url` 一次返回三档，1080P 蓝光 / 720P 高清 / 480P 标清，
/// 三个 m3u8 全部 HTTP 200（约 75KB，是真清单不是错误页）。
/// `needLogin: true` 只表示「登录能看更高码率」，地址本身可直接播放，
/// 所以这里按清晰度从高到低试，不因为 needLogin 就丢掉最高画质。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:pointycastle/digests/sha1.dart';

import '../api.dart';
import '../models.dart';
import 'data_source.dart';

/// 前端硬编码的签名密钥。换站时先重新扒 `_next/static/chunks/*.js`
/// 里的 `signKey`，别猜。
const String _kSignKey = 'cb808529bae6b6be45ecfab29a4889bc';

/// 设备标识。站点只要求格式合法（uuid），不绑账号，随便换也不掉权限。
const String _kDeviceId = 'a29abf4e-cc25-4a86-8ffa-1e8aa985dc3a';

const String _kBase = 'https://m.hellorlgzf7sn.com';

/// 主分类。`id` 是 `type1`，直接喂给 `video/list`。
///
/// 站点的分类树实际有 6 项：电影(1) / 电视剧(2) / 综艺(3) / 动漫(4) /
/// 短剧(88) / 体育直播(7)。
///
/// **体育直播故意不进分类**：它的 `typeJumpurl` 是 `/sports`，走的是另一套
/// 直播接口，用 `video/list&type1=7` 查出来是 `totalCount: 0`。放进来会让用户
/// 点进去看到一片空白。真要做直播，得单独接 `/sports` 那套流，不在本次范围。
///
/// 短剧(88) 实测 1651 条，接入。
const List<SourceCategory> _kCategories = <SourceCategory>[
  SourceCategory('', '推荐'),
  SourceCategory('1', '电影'),
  SourceCategory('2', '电视剧'),
  SourceCategory('3', '综艺'),
  SourceCategory('4', '动漫'),
  SourceCategory('88', '短剧'),
];

class JplinkSource implements DataSource, SectionedFeed {
  JplinkSource._();

  static final JplinkSource instance = JplinkSource._();

  late final Dio _dio = Dio(BaseOptions(
    baseUrl: _kBase,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
  ));

  @override
  String get id => 'jplink';

  @override
  String get displayName => '金牌影院';

  @override
  String get description => '电影/电视剧/综艺/动漫四类齐全，支持搜索与三级清晰度；无弹幕';

  @override
  List<SourceCategory> get categories => _kCategories;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  bool get supportsDanmaku => false;

  // ───────────────────────────── 签名 ─────────────────────────────

  static String _hex(List<int> bytes) {
    final b = StringBuffer();
    for (final x in bytes) {
      b.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  /// 按站点前端的原始逻辑算签名。
  ///
  /// [params] 为实际要发的查询参数；值是原文（未编码），这里只按 key 排序拼接。
  /// 空值 / null 一律剔除 —— 前端在发请求前会先 `H()` 过一遍把空值洗干净，
  /// 签名串和查询串必须用**同一份**过滤后的参数，否则必错。
  static Map<String, String> _sign(Map<String, dynamic> raw, {int? tsMs}) {
    final filtered = <String, dynamic>{};
    raw.forEach((k, v) {
      if (v == null) return;
      final s = '$v';
      if (s.isEmpty || s == 'null' || s == 'undefined') return;
      filtered[k] = v;
    });

    final t = tsMs ?? DateTime.now().millisecondsSinceEpoch;
    return <String, String>{
      'sign': computeSign(filtered, t),
      't': '$t',
      ...filtered.map((k, v) => MapEntry(k, '$v')),
    };
  }

  /// 签名算法的纯函数形态（不碰网络、不看时钟）。
  ///
  /// 之所以从 [_sign] 里抽出来并设为可见：这套算法是逆向得到的，
  /// 一旦被改坏，服务端只会回 `122001 应用签名失败`，与「站点改版」
  /// 「密钥轮换」表现完全一致，线上极难定位。抽出纯函数后
  /// `test/jplink_source_test.dart` 可以拿固定的 (参数, 时间戳) 钉死输出，
  /// 改错立刻红，不用等真机联调。
  static String computeSign(Map<String, dynamic> params, int tsMs) {
    final keys = params.keys.toList()..sort();
    final paramStr = keys.map((k) => '$k=${params[k]}').join('&');

    var h = 'key=$_kSignKey&t=$tsMs';
    if (paramStr.isNotEmpty) h = '$paramStr&$h';

    // md5 → 小写 hex 字符串 → sha1 → 小写 hex。
    // 注意第二步是拿 md5 的**字符串**再哈希，不是原始摘要字节。
    final m = _hex(MD5Digest().process(Uint8List.fromList(utf8.encode(h))));
    return _hex(SHA1Digest().process(Uint8List.fromList(utf8.encode(m))));
  }

  /// 带签名发一个 GET，返回 `data` 字段。
  Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic> params = const {}]) async {
    final signed = _sign(params);
    final sign = signed.remove('sign')!;
    final t = signed.remove('t')!;

    late final Response<String> resp;
    try {
      resp = await _dio.get<String>(
        path,
        queryParameters: signed,
        options: Options(headers: <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
          'Referer': '$_kBase/',
          'accept': 'application/json',
          'sign': sign,
          't': t,
          'deviceId': _kDeviceId,
        }),
      );
    } on DioException catch (e) {
      throw ApiException(-1, '金牌影院接口不可用：${e.type.name}');
    }

    final raw = resp.data ?? '';
    if (resp.statusCode != 200) {
      throw ApiException(-1, '金牌影院返回 HTTP ${resp.statusCode}');
    }

    Map<String, dynamic> env;
    try {
      env = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(-1, '金牌影院响应格式异常');
    }

    final code = env['code'];
    if (code != 200) {
      final msg = env['msg']?.toString() ?? '未知错误';
      // 122001 = 签名失败。这一条单独拎出来，因为它的成因几乎总是
      // 「时间戳不同步」或「参数串拼接规则改了」，跟网络无关，
      // 界面上提示成「网络错误」会让人白查半天。
      if (code == 122001 || code == 122012) {
        throw ApiException(-1, '金牌影院签名校验未通过（$msg），请检查设备时间');
      }
      throw ApiException(code is int ? code : -1, '金牌影院：$msg');
    }

    final d = env['data'];
    if (d is Map) return Map<String, dynamic>.from(d);
    return <String, dynamic>{};
  }

  // ───────────────────────────── 解析 ─────────────────────────────

  Drama _toDrama(Map<String, dynamic> v) {
    final id = '${v['vodId'] ?? ''}';
    final pic = '${v['vodPic'] ?? ''}';
    final score = v['vodScore'] ?? v['vodDoubanScore'];
    return Drama(
      id: id,
      name: '${v['vodName'] ?? ''}',
      area: '${v['vodArea'] ?? ''}',
      // 列表接口没有 vodContent，简介在 vodBlurb 里。
      // 早期写成 vodContent 会让所有卡片的简介都是空串。
      brief: _stripHtml('${v['vodBlurb'] ?? v['vodContent'] ?? ''}'),
      actor: '${v['vodActor'] ?? ''}',
      director: '${v['vodDirector'] ?? ''}',
      remark: '${v['vodRemarks'] ?? ''}',
      clazz: '${v['vodClass'] ?? ''}',
      // 列表接口**不下发** vodYear，只有 vodPubdate（`2026-11-12`）。
      // 直接取 vodYear 会让每部片的年份都显示 0，所以从日期里抠前四位。
      year: _yearOf(v),
      vodPubdate: '${v['vodPubdate'] ?? ''}',
      type: int.tryParse('${v['typeId'] ?? ''}') ?? 0,
      stars: score is num
          ? score.toDouble()
          : (double.tryParse('$score') ?? 0),
      cover: CoverImage(path: pic, thumbnail: pic),
      sourceId: id,
    );
  }

  /// 年份：优先 `vodYear`（详情接口有），否则从 `vodPubdate` 的 `YYYY-MM-DD` 取前四位。
  static int _yearOf(Map<String, dynamic> v) {
    final direct = int.tryParse('${v['vodYear'] ?? ''}');
    if (direct != null && direct > 1900) return direct;
    final pub = '${v['vodPubdate'] ?? ''}';
    if (pub.length >= 4) {
      final y = int.tryParse(pub.substring(0, 4));
      if (y != null && y > 1900) return y;
    }
    return 0;
  }

  /// 站点的简介里带 `<p>` 等标签，直接塞进卡片会显示成乱码。
  static String _stripHtml(String s) {
    if (s.isEmpty) return '';
    return s
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// `data.list` → List<Map>
  static List<Map<String, dynamic>> _list(Map<String, dynamic> data) {
    final l = data['list'];
    if (l is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final x in l) {
      if (x is Map) out.add(Map<String, dynamic>.from(x));
    }
    return out;
  }

  // ───────────────────────────── 对外能力 ─────────────────────────────

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return category('', page: page);

    final data = await _get('/api/mw-movie/anonymous/video/searchByWord', {
      'keyword': kw,
      'pageNum': page,
      'pageSize': 20,
    });

    // 搜索响应有两段：`typeResult`（按分类聚合，通常是空的）和 `result`
    // （真正的影片列表）。只读 result，否则搜索页会一直空白。
    final out = <Drama>[];
    final r = data['result'];
    if (r is Map) {
      for (final v in _list(Map<String, dynamic>.from(r))) {
        out.add(_toDrama(v));
      }
    }
    return out;
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    final data = await _get('/api/mw-movie/anonymous/video/list', {
      'pageNum': page,
      'pageSize': 20,
      if (categoryId.isNotEmpty) 'type1': categoryId,
    });
    return _list(data).map(_toDrama).toList();
  }

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final id = int.tryParse(dramaId);
    if (id == null) throw ApiException(-1, '无效的影片编号');

    final d = await _get('/api/mw-movie/anonymous/video/detail', {'id': id});
    if (d.isEmpty) throw ApiException(-1, '影片不存在或已下架');

    final eps = d['episodeList'];
    final videos = <DramaVideo>[];
    if (eps is List) {
      for (var i = 0; i < eps.length; i++) {
        final e = eps[i];
        if (e is! Map) continue;
        final nid = '${e['nid'] ?? ''}';
        if (nid.isEmpty) continue;
        final sort = e['sort'];
        final ep = sort is num ? sort.toInt() : i + 1;
        final nm = '${e['name'] ?? ''}'.trim();
        videos.add(DramaVideo(
          id: nid,
          title: nm.isEmpty ? '第$ep集' : nm,
          // path 存 `<vodId>:<nid>`：取流要两个 id 同时在场，而
          // DramaVideo 没有为「双 id」留额外字段。用 playToken 语义不对
          // （那是 kanju 的 resolve 令牌），会让后来读代码的人误判。
          path: '$id:$nid',
          source: 'jplink',
          sourceCn: '金牌影院',
          season: 1,
          episode: ep,
          dramaId: '$id',
        ));
      }
    }
    if (videos.isEmpty) throw ApiException(-1, '该片暂无可播放剧集');

    // 电影也在 episodeList 里，通常是 1 条叫「正片」，这里不特判：
    // 统一按剧集处理，界面自然显示成一集，选集栏只有一项。

    return DramaDetail(
      id: '$id',
      name: '${d['vodName'] ?? ''}',
      area: '${d['vodArea'] ?? ''}',
      brief: _stripHtml('${d['vodContent'] ?? ''}'),
      intro: _stripHtml('${d['vodContent'] ?? ''}'),
      director: '${d['vodDirector'] ?? ''}',
      actor: '${d['vodActor'] ?? ''}',
      remark: '${d['vodRemarks'] ?? ''}',
      tag: '${d['vodClass'] ?? ''}',
      year: int.tryParse('${d['vodYear'] ?? ''}') ?? 0,
      type: int.tryParse('${d['typeId'] ?? ''}') ?? 0,
      hits: int.tryParse('${d['vodHits'] ?? ''}') ?? 0,
      isEnd: '${d['vodIsend'] ?? ''}' == '1',
      stars: double.tryParse('${d['vodScore'] ?? ''}') ?? 0,
      cover: CoverImage(
        path: '${d['vodPic'] ?? ''}',
        thumbnail: '${d['vodPicSlide'] ?? d['vodPic'] ?? ''}',
      ),
      videos: videos,
      // 注意是 this.id（源标识 'jplink'），不是上面那个 int 型影片 id
      sourceId: this.id,
    );
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final parts = video.path.split(':');
    if (parts.length != 2) throw ApiException(-1, '剧集标识异常，请刷新重试');
    final id = int.tryParse(parts[0]);
    final nid = int.tryParse(parts[1]);
    if (id == null || nid == null) {
      throw ApiException(-1, '剧集标识异常，请刷新重试');
    }

    final d = await _get('/api/mw-movie/anonymous/v2/video/episode/url', {
      'id': id,
      'nid': nid,
    });

    final list = d['list'];
    if (list is! List || list.isEmpty) throw ApiException(-1, '该集暂无可播放地址');

    // 按清晰度从高到低挑。
    //
    // `needLogin: true` **不是**「不能播」：实测 1080P 那条带 needLogin
    // 但地址直连 HTTP 200，只是提示「登录可享更高权益」。早期实现按
    // needLogin 过滤会把最高画质全丢掉，用户只剩 480P。
    final cands = <Map<String, dynamic>>[];
    for (final x in list) {
      if (x is Map) cands.add(Map<String, dynamic>.from(x));
    }
    cands.sort((a, b) {
      final ra = (a['resolution'] is num) ? (a['resolution'] as num).toInt() : 0;
      final rb = (b['resolution'] is num) ? (b['resolution'] as num).toInt() : 0;
      return rb.compareTo(ra);
    });

    for (final c in cands) {
      final u = '${c['url'] ?? ''}';
      if (u.startsWith('http')) return u;
    }
    throw ApiException(-1, '该集暂无可播放地址');
  }

  // ───────────────────────────── 首页分区流 ─────────────────────────────

  @override
  Future<HomeFeed> homeFeed({String? cursor}) async {
    // 只有一页，没有游标。返回 null 让界面停止继续加载。
    final d = await _get('/api/mw-movie/anonymous/v1/home/all/list');

    const titles = <String, String>{
      'homeNewMoviePageData': '最新电影',
      'newestTvPageData': '最新剧集',
      'newestVarietyPageData': '最新综艺',
      'newestCartoonPageData': '最新动漫',
      'homeBroadcastPageData': '热播榜',
      'homeManagerPageData': '精选推荐',
      'homeTrailerPageData': '预告片',
      'newestShortTvPageData': '短剧',
    };

    final sections = <FeedSection>[];
    // 按固定顺序输出：接口返回的是对象，键序不保证稳定，
    // 直接遍历会让首页每次刷新换一次排布。
    for (final e in titles.entries) {
      final v = d[e.key];
      if (v is! Map) continue;
      final items = _list(Map<String, dynamic>.from(v));
      if (items.isEmpty) continue;
      sections.add(FeedSection(
        id: e.key,
        title: e.value,
        cards: items.map(_toDrama).toList(),
      ));
    }

    return HomeFeed(sections: sections);
  }
}