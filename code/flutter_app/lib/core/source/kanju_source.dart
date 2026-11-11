/// kanju.ai 数据源（第二个源）。
///
/// 协议细节全部来自实机抓包 + 反复实测，关键结论记在这里，改代码前先读：
///
/// 1. **签名**：HMAC-SHA256，密钥硬编码在前端包里（防爬，不是真安全）。
///    签名串是四行拼接：
///        {METHOD}\n{PATH?QUERY}\n{TIMESTAMP}\n{NONCE}
///    三个头：x-ai-movie-timestamp / -nonce / -signature。
///
/// 2. **中文参数必须先百分号编码再签名**（踩过，血泪）：
///    直接对 `q=沙` 的原文签名会得到 401 invalid_request_signature，
///    因为 HTTP 实际发出去的是 `q=%E6%B2%99`，两边字符串不一致。
///    所以这里统一走 [encodeQuery]，保证「签名用的串 == 发出去的串」。
///
/// 3. **两阶段取址**：
///    第一步 GET  /v1/playback/resolve/{episodeToken}
///         → 返回 30 多条线路，每条有 url 与 resolve_required
///    第二步 POST /v1/playback/resolve-line?view=compact  body {"ticket": ...}
///         只有 resolve_required=true 的「官方线」才需要；
///         ticket 就是 url 去掉 `resolve://` 前缀后的那串。
///    第三方采集源（26 条）直接给 m3u8，不消耗配额，最省事。
///
/// 4. **线路按集下发，不能预加载**：36 集的剧若每集都 resolve 就是 36 次
///    请求。所以详情页只 resolve 第 1 集拿到「线路名清单」，为每集×每线路
///    生成占位条目；真正播放时才 resolve 那一集。实测直出线路跨集稳定
///    为 26 条，只有官方线数量会浮动（4~7）。
///
/// 5. **401 有两种含义**，看 code 区分，别一看到 401 就怀疑密钥：
///    - invalid_request_signature      → 签名算错了
///    - playback_user_session_required → 这条线路要登录（部分新片）
///
/// 6. **游客会话能解锁官方线**（2026-11-11 实测，这条是官方线可用的前提）：
///    POST /v1/users/anonymous  body {"anonymous_id": <32位hex>}
///      → HTTP 201，Set-Cookie: ai_movie_session=...，并返回昵称/用户 id。
///    不带会话时，沙海第 10 集起官方线全部 401；带上会话后：
///      沙海     8 集抽样  官方线 16/16 可播
///      庆余年S2 6 集抽样  官方线 27/27 可播
///    所以「官方线优先」不是画质妥协，是真的 100% 能播。
///    Cookie 存 SharedPreferences，过期（服务端给一年）后自动重建。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:pointycastle/export.dart' show HMac, SHA256Digest, KeyParameter;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart' show ApiException;
import '../models.dart';
import 'data_source.dart';

/// 前端包里硬编码的签名密钥。换站/换版本时这里要跟着改。
const String _kSignKey =
    '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0';

const String _kHost = 'https://kanju.ai';

/// 客户端标识，服务端不校验但与前端保持一致，降低被风控的概率
const String _kClientName = 'dianyingtiantang-frontend';
const String _kClientVersion = '1.0.0';
const String _kProtocolVersion = '2026-07-05.library-v2.playback-v1';

/// kanju 的分类。推荐用 trending，其余用 content_kind。
const List<SourceCategory> kKanjuCategories = [
  SourceCategory('', '推荐'),
  SourceCategory('movie', '电影'),
  SourceCategory('series', '电视剧'),
  SourceCategory('variety', '综艺'),
  SourceCategory('anime', '动漫'),
  SourceCategory('short_drama', '短剧'),
  SourceCategory('documentary', '纪录片'),
];

/// content_kind → 中文，仅用于卡片角标兜底
const Map<String, String> kKanjuKindNames = {
  'movie': '电影',
  'series': '电视剧',
  'short_drama': '短剧',
  'anime': '动漫',
  'variety': '综艺',
  'documentary': '纪录片',
  'sports': '体育',
  'adult': '成人',
};

/// 一条播放线路（resolve 返回的 line_option 精简版）
class KanjuLine {
  final String label;
  final String playFrom;
  final String url;
  final bool resolveRequired;
  final bool selected;

  const KanjuLine({
    required this.label,
    required this.playFrom,
    required this.url,
    required this.resolveRequired,
    required this.selected,
  });

  /// 直出地址（第三方采集源）
  bool get isDirect => !resolveRequired && url.startsWith('http');

  /// resolve:// 后面的 ticket
  String get ticket =>
      url.startsWith('resolve://') ? url.substring('resolve://'.length).trim() : '';
}

class KanjuSource implements DataSource, SectionedFeed {
  KanjuSource._();
  static final KanjuSource instance = KanjuSource._();

  @override
  String get id => 'kanju';

  @override
  String get displayName => '看剧（多线路）';

  @override
  String get description => '多线路、首页分区榜单（大家都在看/高分电影…），无弹幕';

  @override
  List<SourceCategory> get categories => kKanjuCategories;

  /// kanju 没有弹幕池，播放页会因此跳过请求
  @override
  bool get supportsDanmaku => false;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.byPreference;

  late final Dio _dio = Dio(BaseOptions(
    baseUrl: _kHost,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    responseType: ResponseType.json,
    // 非 2xx 也交给我们自己解，才能读到 code/message 给出准确提示
    validateStatus: (_) => true,
  ));

  final Random _rnd = Random.secure();

  // ---------------- 签名 ----------------

  String _nonce() {
    final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  String _hmacHex(String msg) => signHex(msg);

  /// 签名计算，抽成静态方法便于单测。
  ///
  /// 这不是为了「好测」而抽象：签名串一旦拼错（少一个换行、用了
  /// 未编码的中文），服务端只回一个 401 invalid_request_signature，
  /// 与「密钥过期」「接口改版」的表现完全一样，线上极难定位。
  /// 有一条对着真实样本的断言，改代码时立刻能发现。
  @visibleForTesting
  static String signHex(String msg) {
    final mac = HMac.withDigest(SHA256Digest())
      ..init(KeyParameter(Uint8List.fromList(utf8.encode(_kSignKey))));
    final out = mac.process(Uint8List.fromList(utf8.encode(msg)));
    return out.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 把 query 里的每个值规范化成百分号编码。
  ///
  /// 这是整个适配器最容易踩的坑：签名与发送必须用同一个字符串。
  /// 中文、空格、& 都要编码，否则服务端算出来的签名对不上。
  @visibleForTesting
  static String encodeQuery(Map<String, String> params) {
    if (params.isEmpty) return '';
    final parts = <String>[];
    for (final e in params.entries) {
      final k = Uri.encodeQueryComponent(e.key);
      final v = Uri.encodeQueryComponent(e.value);
      parts.add('$k=$v');
    }
    return parts.join('&');
  }

  Map<String, String> _headers(String method, String pathWithQuery) {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final n = _nonce();
    final sig = _hmacHex('${method.toUpperCase()}\n$pathWithQuery\n$ts\n$n');
    final h = <String, String>{
      'x-ai-movie-timestamp': ts,
      'x-ai-movie-nonce': n,
      'x-ai-movie-signature': sig,
      'x-ai-movie-client-name': _kClientName,
      'x-ai-movie-client-version': _kClientVersion,
      'x-ai-movie-protocol-version': _kProtocolVersion,
      'Accept': 'application/json',
      'Origin': _kHost,
      'Referer': '$_kHost/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    };
    // 游客会话：只有 resolve-line（官方线）需要，但带上无副作用。
    // 注意 Cookie 不参与签名（签名串只有 method/path/ts/nonce）。
    final c = _cookie;
    if (c != null && c.isNotEmpty) h['Cookie'] = c;
    return h;
  }

  // ---------------- 游客会话 ----------------
  //
  // 官方线走 resolve-line 时服务端要求有效会话，否则一律
  // 401 playback_user_session_required。前端包里对应的入口是
  // POST /v1/users/anonymous，body 只要一个 anonymous_id。
  //
  // 这里做了三层兜底，因为「会话失效」在用户侧表现为「官方线全不能用」，
  // 和「源站改版」长得一模一样，不做兜底很难定位：
  //   1. 内存缓存：同一次运行内只建一次
  //   2. 本地持久化：重启后复用，不必每次开 App 都注册新游客
  //   3. 401 重试：会话过期时清掉重建一次，再失败才报错

  static const String _kSessionKey = 'kanju.sessionCookie';
  static const String _kAnonIdKey = 'kanju.anonymousId';

  /// 会话 Cookie 名。抽成常量是因为它在「提取」和「校验」两处都要用，
  /// 写死两遍一旦改一半就会静默失效。
  static const String _kCookieName = 'ai_movie_session=';

  String? _cookie;
  Future<bool>? _sessionInflight;

  /// 确保有可用会话。并发调用会复用同一个 Future，避免同时注册多个游客。
  Future<bool> _ensureSession() {
    final c = _cookie;
    if (c != null && c.isNotEmpty) return Future<bool>.value(true);
    final inflight = _sessionInflight;
    if (inflight != null) return inflight;
    final f = _loadOrCreateSession();
    _sessionInflight = f;
    return f.whenComplete(() => _sessionInflight = null);
  }

  Future<bool> _loadOrCreateSession() async {
    SharedPreferences? sp;
    try {
      sp = await SharedPreferences.getInstance();
      final saved = sp.getString(_kSessionKey);
      if (saved != null && saved.isNotEmpty) {
        _cookie = saved;
        return true;
      }
    } catch (e) {
      debugPrint('[KJ] read session failed: $e');
    }
    return _createGuestSession(sp);
  }

  /// 注册游客会话并落盘。
  ///
  /// anonymous_id 要**稳定**：换一个 id 就是一个新游客，服务端的
  /// 频控会把陌生设备当异常。所以它和 Cookie 一起持久化。
  Future<bool> _createGuestSession([SharedPreferences? sp]) async {
    try {
      sp ??= await SharedPreferences.getInstance();
      var anonId = sp.getString(_kAnonIdKey) ?? '';
      if (anonId.isEmpty) {
        anonId = _nonce(); // 32 位 hex，与前端 anonymous_id 形态一致
        await sp.setString(_kAnonIdKey, anonId);
      }

      final resp = await _dio.postUri<dynamic>(
        Uri.parse('$_kHost/v1/users/anonymous'),
        data: {'anonymous_id': anonId},
        options: Options(headers: {
          ..._headers('POST', '/v1/users/anonymous'),
          'Content-Type': 'application/json',
        }),
      );

      // 成功是 201 不是 200（实测），别用 == 200 判断
      final code = resp.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        debugPrint('[KJ] anonymous session failed: HTTP $code');
        return false;
      }

      final cookie = _extractSessionCookie(resp.headers);
      if (cookie.isEmpty) {
        debugPrint('[KJ] anonymous session gave no cookie');
        return false;
      }
      _cookie = cookie;
      await sp.setString(_kSessionKey, cookie);
      return true;
    } catch (e) {
      debugPrint('[KJ] anonymous session error: $e');
      return false;
    }
  }

  /// 从 Set-Cookie 里挑出会话那一条。
  ///
  /// 只取 `ai_movie_session`：服务端可能同时下发统计类 Cookie，
  /// 全部带上会让请求头变脏，也没必要。
  ///
  /// **必须取最后一条「值非空」的，不能取第一条命中的**（2026-11-11 实测踩坑）：
  /// 该接口一次下发 5 条同名 Cookie，前面几条是清理旧域的删除指令：
  ///     ai_movie_session=; Path=/v1; Max-Age=0; ...        ← 空值，删 /v1
  ///     ai_movie_session=; Path=/v1; Domain=kanju.ai; ...  ← 空值
  ///     ai_movie_session=; Path=/; Max-Age=0; ...          ← 空值，删 /
  ///     ai_movie_session=; Path=/; Domain=kanju.ai; ...    ← 空值
  ///     ai_movie_session=ums_xxx; Path=/; Max-Age=31535999 ← 真正有效的那条
  /// 取第一条会得到一个空值（长度只有前缀 17），相当于把会话主动删掉，
  /// 之后所有官方线请求都回 401，而且报错信息和「源站改版」一模一样。
  String _extractSessionCookie(Headers headers) =>
      pickSessionCookie(headers.map['set-cookie'] ?? const []);

  /// 从 Set-Cookie 原始行里挑出有效会话（抽成静态方法便于单测）。
  ///
  /// [raw] 是 Dio 给的字符串列表，每条内部还可能用逗号串联多个 Cookie。
  ///
  /// 这条逻辑必须单测覆盖，理由是它「错了也不报错」：
  /// 取错值不会抛异常，只会拿到空会话，然后所有官方线静默回 401，
  /// 表现和「源站改版」完全一致，线上极难定位。实测踩过一次。
  @visibleForTesting
  static String pickSessionCookie(List<String> raw) {
    if (raw.isEmpty) return '';
    String found = '';
    for (final line in raw) {
      for (final part in line.split(',')) {
        final segs = part.split(';');
        final kv = segs.first.trim();
        if (!kv.startsWith(_kCookieName)) continue;
        final value = kv.substring(_kCookieName.length).trim();
        // 空值 = 删除指令（配合 Max-Age=0），跳过
        if (value.isEmpty) continue;
        // 顺手排除「已过期」的写法，避免取到一条实质上已作废的
        var expired = false;
        for (final s in segs.skip(1)) {
          final low = s.trim().toLowerCase();
          if (low.startsWith('max-age=')) {
            final sec = int.tryParse(low.substring('max-age='.length)) ?? 0;
            if (sec <= 0) expired = true;
          } else if (low.startsWith('expires=') &&
              low.contains('1970')) {
            expired = true;
          }
        }
        if (expired) continue;
        found = kv; // 继续往后找，最后一条有效的胜出
      }
    }
    return found;
  }

  Future<void> _dropSession() async {
    _cookie = null;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kSessionKey);
    } catch (e) {
      debugPrint('[KJ] drop session failed: $e');
    }
  }

  /// 统一请求入口：先把 query 编码好，再签名，再发——三处用同一个串。
  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? params]) async {
    final q = encodeQuery(params ?? const {});
    final full = q.isEmpty ? path : '$path?$q';
    final resp = await _dio.getUri<dynamic>(
      Uri.parse('$_kHost$full'),
      options: Options(headers: _headers('GET', full)),
    );
    return _unwrap(resp, full);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, [
    Map<String, String>? params,
  ]) async {
    final q = encodeQuery(params ?? const {});
    final full = q.isEmpty ? path : '$path?$q';
    final resp = await _dio.postUri<dynamic>(
      Uri.parse('$_kHost$full'),
      data: body,
      options: Options(
        headers: {
          ..._headers('POST', full),
          'Content-Type': 'application/json',
        },
      ),
    );
    return _unwrap(resp, full);
  }

  Map<String, dynamic> _unwrap(Response<dynamic> resp, String path) {
    final code = resp.statusCode ?? 0;
    final data = resp.data;
    if (data is! Map) {
      throw ApiException(code, '源返回格式异常（HTTP $code）');
    }
    final m = Map<String, dynamic>.from(data);
    if (code >= 200 && code < 300) return m;

    // 把服务端的 code 翻译成用户能行动的一句话
    final errCode = (m['code'] ?? '').toString();
    final msg = (m['message'] ?? m['error'] ?? '').toString();

    if (errCode == 'playback_user_session_required') {
      throw ApiException(code, '该线路需要登录才能播放，请换一条线路');
    }
    if (errCode == 'playback_line_unavailable') {
      throw ApiException(code, '这条线路暂时不可用，请换一条');
    }
    if (errCode == 'invalid_public_playback_id') {
      throw ApiException(code, '播放标识已失效，请重新打开详情页');
    }
    if (errCode == 'invalid_request_signature' || msg.contains('signature')) {
      throw ApiException(code, '签名校验失败（接口可能已变更）');
    }
    if (code == 401) {
      throw ApiException(code, msg.isEmpty ? '需要登录后播放' : msg);
    }
    throw ApiException(code, msg.isEmpty ? '请求失败（HTTP $code）' : msg);
  }

  // ---------------- 列表 ----------------

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    final params = <String, String>{
      'page': '$page',
      'limit': '20',
    };
    if (keyword.trim().isNotEmpty) params['q'] = keyword.trim();
    return _browse(params);
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    final params = <String, String>{
      'page': '$page',
      'limit': '20',
    };
    if (categoryId.isEmpty) {
      // 「推荐」= 本周热度榜。实测比不带参数的结果质量高得多
      params['sort'] = 'trending';
      params['window'] = 'week';
    } else {
      params['kind'] = categoryId;
    }
    return _browse(params);
  }

  Future<List<Drama>> _browse(Map<String, String> params) async {
    final m = await _get('/v1/browse/catalog', params);
    final cards = m['cards'];
    if (cards is! List) return const [];
    final out = <Drama>[];
    for (final c in cards) {
      if (c is! Map) continue;
      try {
        out.add(_cardToDrama(Map<String, dynamic>.from(c)));
      } catch (e) {
        debugPrint('[KJ] card parse failed: $e');
      }
    }
    return out;
  }

  Drama _cardToDrama(Map<String, dynamic> c) {
    final poster = (c['poster_url'] ?? '').toString();
    final genres = (c['genres'] as List?)?.whereType<String>().toList() ?? const [];
    final kind = (c['content_kind'] ?? '').toString();
    final score = c['score'];
    return Drama(
      id: (c['id'] ?? '').toString(),
      name: (c['title'] ?? '').toString(),
      area: (c['area'] ?? '').toString(),
      // 卡片没有简介，用类型拼一句，比空着强
      brief: genres.isEmpty ? (kKanjuKindNames[kind] ?? '') : genres.take(3).join(' / '),
      stars: score is num ? score.toDouble() : 0,
      director: _joinNames(c['directors']),
      actor: _joinNames(c['actors']),
      remark: (c['remarks'] ?? '').toString(),
      year: (c['year'] as num?)?.toInt() ?? 0,
      clazz: kind,
      cover: CoverImage(path: poster, thumbnail: poster),
      sourceId: id,
    );
  }

  String _joinNames(Object? v) {
    if (v is List) return v.whereType<String>().take(3).join(' / ');
    return '';
  }

  // ---------------- 榜单（分区流） ----------------

  /// 每页拉几个分区。
  ///
  /// 服务端上限 11，一页全拉会返回 ~200KB，首次进首页要等明显一下。
  /// 取 3 与官方前端一致：首屏 3 个分区（约 15 行内容）已经远超一屏，
  /// 剩下的靠滚动增量加载。
  static const int _kSectionsPerPage = 3;

  /// 每个分区几张卡。服务端上限 20，取 12 够铺满一行横向列表。
  static const int _kCardsPerSection = 12;

  @override
  Future<HomeFeed> homeFeed({String? cursor}) async {
    final params = <String, String>{
      'scope': 'public',
      'mode': 'page',
      'sections': '$_kSectionsPerPage',
      'cards': '$_kCardsPerSection',
    };
    // cursor 是服务端给的 base64 串，里面全是 url-safe 字符，
    // 但仍要经过 encodeQuery 统一编码，保证签名串与实际发送一致。
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;

    final m = await _get('/v1/feed/home', params);
    final raw = m['sections'];
    if (raw is! List) {
      return const HomeFeed(sections: []);
    }

    final out = <FeedSection>[];
    for (final s in raw) {
      if (s is! Map) continue;
      final sm = Map<String, dynamic>.from(s);
      final title = (sm['title'] ?? '').toString();
      final cardsRaw = sm['cards'];
      if (cardsRaw is! List) continue;

      final cards = <Drama>[];
      for (final c in cardsRaw) {
        if (c is! Map) continue;
        try {
          cards.add(_cardToDrama(Map<String, dynamic>.from(c)));
        } catch (e) {
          // 单张卡字段缺失不该拖垮整个分区：feed 的卡片有 26/28 两套
          // 字段组合，偶尔还会混进没有 poster_url 的条目。
          debugPrint('[KJ] feed card parse failed: $e');
        }
      }
      // 整个分区一张都没解析出来就整块丢掉：首页留一个只有标题的空行
      // 比不显示更难看，用户会以为加载卡住了。
      if (cards.isEmpty) continue;

      out.add(FeedSection(
        id: (sm['id'] ?? '').toString(),
        title: title,
        subtitle: (sm['subtitle'] ?? '').toString(),
        cards: cards,
      ));
    }

    final next = (m['next_cursor'] ?? '').toString();
    return HomeFeed(
      sections: out,
      nextCursor: next.isEmpty ? null : next,
    );
  }

  // ---------------- 详情 ----------------

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final m = await _get('/v1/catalog/$dramaId');
    final episodes = (m['episodes'] as List?) ?? const [];
    if (episodes.isEmpty) {
      // 没有剧集不代表错，但也没有可播内容，给出明确提示
      throw ApiException(200, '该作品暂无可用剧集');
    }

    final poster = (m['poster_url'] ?? '').toString();
    final kind = (m['content_kind'] ?? '').toString();

    // 只 resolve 第一集拿「线路名清单」。36 集全 resolve 要 36 次请求，
    // 而直出线路跨集稳定为 26 条，用第一集的清单做模板足够。
    List<KanjuLine> template = const [];
    final firstToken = _epToken(episodes.first);
    if (firstToken.isNotEmpty) {
      try {
        template = await _resolveLines(firstToken);
      } catch (e) {
        // 第一集线路拿不到不该让整个详情页失败：用户还能看到简介，
        // 换一集也许就好了。
        debugPrint('[KJ] resolve first episode failed: $e');
      }
    }

    final videos = <DramaVideo>[];
    for (final e in episodes) {
      if (e is! Map) continue;
      final em = Map<String, dynamic>.from(e);
      final token = _epToken(em);
      if (token.isEmpty) continue;
      // 别用 num 当变量名：它会遮蔽 Dart 的 num 类型，
      // 导致上面那行 `as num?` 报「no type named num」
      final epNum = (em['number'] as num?)?.toInt() ?? 0;
      final title =
          (em['title'] ?? (epNum > 0 ? '第$epNum集' : '')).toString();

      if (template.isEmpty) {
        // 线路清单都没拿到，至少给一条占位，播放时再试
        videos.add(DramaVideo(
          id: '${token}_play',
          title: title,
          path: 'resolve://$token',
          source: 'kanju',
          sourceCn: '默认线路',
          episode: epNum,
          dramaId: dramaId,
          playToken: token,
        ));
        continue;
      }

      for (final l in template) {
        videos.add(DramaVideo(
          id: '${token}_${l.playFrom}',
          title: title,
          // 用 resolve:// 承载 episode token：既让 pathLooksPlayable 通过
          // （否则 source_picker 会把整条线路判死），又能在播放时取回 token
          path: 'resolve://$token',
          source: l.playFrom,
          sourceCn: l.label,
          episode: epNum,
          dramaId: dramaId,
          playToken: token,
          needsResolve: l.resolveRequired,
        ));
      }
    }

    if (videos.isEmpty) throw ApiException(200, '该作品暂无可用线路');

    return DramaDetail(
      id: (m['id'] ?? dramaId).toString(),
      name: (m['title'] ?? '').toString(),
      area: (m['area'] ?? '').toString(),
      brief: _plainText((m['remarks'] ?? '').toString()),
      intro: _plainText((m['description'] ?? '').toString()),
      director: _joinNames(m['directors']),
      actor: _joinNames(m['actors']),
      remark: (m['remarks'] ?? '').toString(),
      tag: kind,
      year: (m['year'] as num?)?.toInt() ?? 0,
      isEnd: m['is_completed'] == true,
      hits: (m['playback_count'] as num?)?.toInt() ?? 0,
      cover: CoverImage(path: poster, thumbnail: poster),
      videos: videos,
      sourceId: id,
    );
  }

  String _epToken(Map<String, dynamic> e) => (e['token'] ?? '').toString();

  /// 简介里可能带 HTML 实体，粗洗一遍就够（完整的 stripHtml 在 models 里）
  String _plainText(String s) {
    if (s.isEmpty) return s;
    var t = s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ');
    t = t.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'<[^>]*>'), '');
    return t.trim();
  }

  // ---------------- 播放取址 ----------------

  /// resolve 结果短缓存。
  ///
  /// 同一集的线路列表在一次播放里会被问很多次（换源、自动连播回头、
  /// 失败重试）。每次都发请求既慢又容易被限流。
  /// 但**不能永久缓存**：线路里的 ticket 有时效，缓存太久会拿到失效票。
  ///
  /// 必须限制条目数：一部 54 集的剧连续追下去，按集 key 缓存会一直
  /// 只增不减——过期项只有「再次访问同一 token」时才被覆盖，
  /// 而追剧时恰恰是每集只访问一次。120 集的长剧就是 120 份线路对象
  /// 常驻内存（每份 14~28 条），换几部剧看下来更糟。
  final Map<String, _CachedLines> _lineCache = {};
  static const int _kLineCacheMax = 24;

  /// 清掉过期项；仍超限时按插入顺序丢最旧的。
  ///
  /// Dart 的 LinkedHashMap 保证迭代顺序即插入顺序，所以直接
  /// 从头删就是「最久未新增」优先，不需要额外维护时间戳。
  void _evictLineCache() {
    _lineCache.removeWhere((_, v) => v.expired);
    if (_lineCache.length <= _kLineCacheMax) return;
    final overflow = _lineCache.length - _kLineCacheMax;
    for (final k in _lineCache.keys.take(overflow).toList()) {
      _lineCache.remove(k);
    }
  }

  Future<List<KanjuLine>> _resolveLines(String episodeToken) async {
    final hit = _lineCache[episodeToken];
    if (hit != null && !hit.expired) return hit.lines;

    final m = await _get('/v1/playback/resolve/$episodeToken');
    final raw = (m['line_options'] as List?) ?? const [];
    final lines = <KanjuLine>[];
    for (final x in raw) {
      if (x is! Map) continue;
      final xm = Map<String, dynamic>.from(x);
      lines.add(KanjuLine(
        label: (xm['label'] ?? xm['display_label'] ?? '').toString(),
        playFrom: (xm['play_from'] ?? '').toString(),
        url: (xm['url'] ?? '').toString(),
        resolveRequired: xm['resolve_required'] == true,
        selected: xm['selected'] == true,
      ));
    }
    _lineCache[episodeToken] = _CachedLines(lines);
    _evictLineCache();
    return lines;
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final token = video.playToken.isNotEmpty
        ? video.playToken
        : (video.path.startsWith('resolve://')
            ? video.path.substring('resolve://'.length).trim()
            : '');
    if (token.isEmpty) throw ApiException(-1, '缺少播放标识，请重新打开详情页');

    final lines = await _resolveLines(token);
    if (lines.isEmpty) throw ApiException(200, '这一集没有可用线路');

    // 精确匹配当前条目所属的线路（换源时会带着原 source/sourceCn 过来）
    KanjuLine? line;
    for (final l in lines) {
      if (l.playFrom == video.source && l.label == video.sourceCn) {
        line = l;
        break;
      }
    }
    // 该集没有这条线路（官方线按集浮动会缺）：退到直出线路优先
    line ??= lines.where((l) => l.isDirect).firstOrNull ??
        lines.where((l) => l.url.isNotEmpty).firstOrNull;

    if (line == null) throw ApiException(200, '这一集没有可播放的线路');

    // 采集源：直接就是 m3u8，拿来就播
    if (line.isDirect) return line.url;

    // 官方线：拿 ticket 换真实地址（需游客会话）
    final ticket = line.ticket;
    if (ticket.isEmpty) {
      // 既不是 http 也不是 resolve://，当作异常输入
      if (line.url.startsWith('http')) return line.url;
      throw ApiException(200, '线路地址格式异常：${line.label}');
    }

    return _resolveOfficialLine(ticket, line.label);
  }

  /// 官方线取址：带游客会话，遇到 401 自动重建会话重试一次。
  ///
  /// 为什么要重试而不是直接报错：会话有效期一年，但服务端可能提前
  /// 吊销（换设备、风控）。用户看到的就是「官方线全都播不了」，
  /// 而它和「源站改版」的表现完全一致。重试一次能把「会话过期」这种
  /// 可自愈的情况挡在用户看不见的地方。
  Future<String> _resolveOfficialLine(String ticket, String label) async {
    final ready = await _ensureSession();
    if (!ready) {
      // 拿不到会话也别直接判死：先照常请求，服务端可能对某些片免费
      debugPrint('[KJ] no guest session, try direct resolve');
    }

    try {
      return await _postResolveLine(ticket, label);
    } on ApiException catch (e) {
      // 401 = 会话无效或过期，清掉重建后再试一次
      final needsSession = e.code == 401;
      if (!needsSession) rethrow;
      debugPrint('[KJ] resolve-line 401, rebuilding session: ${e.msg}');
      await _dropSession();
      final ok = await _createGuestSession();
      if (!ok) rethrow;
      return await _postResolveLine(ticket, label);
    }
  }

  Future<String> _postResolveLine(String ticket, String label) async {
    final m = await _post(
      '/v1/playback/resolve-line',
      {'ticket': ticket},
      {'view': 'compact'},
    );
    final ln = m['line'];
    if (ln is! Map) throw ApiException(200, '线路解析失败：$label');
    final url = (ln['url'] ?? '').toString();
    if (url.isEmpty) throw ApiException(200, '线路解析结果为空：$label');
    return url;
  }
}

class _CachedLines {
  final List<KanjuLine> lines;
  final DateTime at = DateTime.now();
  _CachedLines(this.lines);

  /// ticket 有时效，60 秒后重新 resolve，兼顾「不重复请求」与「不过期」
  bool get expired =>
      DateTime.now().difference(at) > const Duration(seconds: 60);
}