/// 云影（yuny.app）适配器。
///
/// 站点是 **Nuxt 3 SSR + 一套纯 JSON 的 app 接口**，所以这个源和
/// [JisuSource] 那种「HTML 里抠正则」完全不是一类活：这里全程走 JSON。
///
/// ## 2026-11-12 逐条实测（每条都是跑出来的）
///
///   ✅ 接口**免鉴权**。不带任何 Cookie / Token，直接 GET 就返回数据。
///      带 `User-Agent` + `Referer: https://www.yuny.app/` 更稳（与浏览器一致）。
///   ✅ 首页 `POST /app/video-home/today-updates` body `{pageNo,pageSize}`
///      → `data.list[]` + `total` + `hasMore`。实测 total=638、hasMore=true。
///   ✅ 分类 `POST /app/video-search/label-v2` body `{current,size,type}`
///      其中 `type` 是**中文分类名**，不是数字 id。五个分类实测：
///      电影 47000 / 剧集 30159 / 动漫 32617 / 综艺 8708 / 短剧 16789。
///      **真分页**：current=1/2/3 三页相邻零重叠。
///   ✅ 搜索 `POST /app/video-search/type-v2`
///      body `{current,key,size,searchCode:1,order:"desc"}`
///      实测「权力」= 43 条 / 2 页，current=2 返回的是另一批。
///   ✅ 详情 `GET /app/video-interact/get-video-detail?videoInfoId=<id>`
///      → `data.videoChannelList[]` 每项 `{collectChannelName, collectNum, videoSelectResList[]}`，
///      选集项 `{id, series, resource, resourceType, danmuUrl}`。
///   ✅ 取址 `GET /app/video-interact/get-video-play-urlv2?videoSelectId=<id>&errorCode=0`
///      → `{"success":true,"code":200,"data":"<m3u8>"}`。
///
/// ## 一个能省一次请求的细节
///
/// 详情接口的 `videoSelectResList[].resource` **本身就是 m3u8 直链**
/// （实测 `https://player.yzzyvip-35.com/20260806/12819_7b951cd0/index.m3u8`）。
/// 所以正常情况下播放**完全不需要**再调取址接口。
/// 只有当 `resource` 为空（个别采集线路没填）时，才用 `selects[].id`
/// 去调 `get-video-play-urlv2` 换地址。这样绝大多数情况下点开即播。
///
/// ## 各线路集数不一致
///
/// 实测《换座位后发现身后的男生好像喜欢我》(259266)：5 条线路的集数分别是
/// **5 / 7 / 8 / 8 / 8**。所以选集必须**逐线路**解析，不能拿某条线路的
/// 集数去铺满所有线路——那样会造出一堆点开就 404 的死条目。
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
const String kYunyBase = 'https://www.yuny.app';

/// 一页多少条。接口接受任意 size，18 与界面的两列/三列排布比较贴合。
const int kYunyPageSize = 18;

/// 「推荐」频道固定取的类型。
///
/// 不传 `type` 时接口混排全站更新，实测一半以上是没有可播线路的低幼动画
/// （只挂爱奇艺网页外链）。带上「剧集」后抽样 6/6 全部有 m3u8 线路。
/// 详见 [YunySource._home] 的注释与实测数据。
const String kYunyHomeType = '剧集';

// ==================== 纯函数区（便于离线回归，不依赖网络） ====================

/// 从统一响应壳 `{success, code, msg, data}` 里取出 `data`。
///
/// 站点在业务失败时也返回 HTTP 200，只把 `success` 置 false，
/// 所以**不能只看状态码**，必须看这个字段。
Map<String, dynamic> yunyUnwrap(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    throw ApiException(-1, '接口返回的不是 JSON：${yunyClip(body)}');
  }
  if (decoded is! Map) {
    throw ApiException(-1, '接口返回结构异常：${yunyClip(body)}');
  }
  final map = decoded.cast<String, dynamic>();
  if (map['success'] != true) {
    final msg = (map['msg'] ?? '').toString().trim();
    throw ApiException(
      (map['code'] as num?)?.toInt() ?? -1,
      msg.isEmpty ? '接口返回失败' : msg,
    );
  }
  final data = map['data'];
  return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
}

/// 把一条列表记录转成 [Drama]。
///
/// 列表接口（首页/分类/搜索）的 records 是同一套字段：
/// `id / name / cover / tags / description / remark / hot / score`。
Drama yunyRecordToDrama(
  Map<String, dynamic> r, {
  required String sourceId,
}) {
  return Drama(
    id: (r['id'] ?? '').toString(),
    name: stripHtml((r['name'] ?? '').toString()).trim(),
    brief: stripHtml(yunyUnescape((r['description'] ?? '').toString())),
    remark: stripHtml((r['remark'] ?? '').toString()).trim(),
    clazz: stripHtml((r['tags'] ?? '').toString()).trim(),
    stars: _yunyScore(r['score']),
    cover: CoverImage(path: yunyAbsUrl((r['cover'] ?? '').toString())),
    sourceId: sourceId,
  );
}

/// 解析列表：取 `data.records`（分类/搜索）或 `data.list`（首页更新）。
List<Drama> parseYunyList(String body, {required String sourceId}) {
  final data = yunyUnwrap(body);
  final raw = data['records'] ?? data['list'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => yunyRecordToDrama(e.cast<String, dynamic>(), sourceId: sourceId))
      .where((d) => d.id.isNotEmpty && d.name.isNotEmpty)
      .toList();
}

/// 解析详情：元信息 + 逐线路的选集。
///
/// 关键点：**每条线路单独铺自己的集数**。实测同一部剧 5 条线路的集数
/// 可以是 5/7/8/8/8，按最长线路铺会把短线路铺出一堆死链。
DramaDetail parseYunyDetail(
  String dramaId,
  String body, {
  required String sourceId,
}) {
  final data = yunyUnwrap(body);
  // 两个键都要认：详情接口原始返回用 `videoChannelList`；
  // 而站点前端 bundle 里有个 `It()` 转换器会把它改写成 `lines`
  // （`lines[].selects[]`），缓存或换版本时可能拿到后者。
  final records =
      (data['videoChannelList'] ?? data['lines']) as List? ?? const [];
  final videos = <DramaVideo>[];

  for (var li = 0; li < records.length; li++) {
    final line = records[li];
    if (line is! Map) continue;
    final lm = line.cast<String, dynamic>();
    // 字段名有两个版本：详情接口用 collectChannelName / videoSelectResList，
    // 前端 bundle 里还兼容 lineSourceName / selects，这里都兜住。
    final lineName =
        (lm['collectChannelName'] ?? lm['lineSourceName'] ?? '').toString().trim();
    final selects = (lm['videoSelectResList'] ?? lm['selects']) as List? ?? const [];

    for (var ei = 0; ei < selects.length; ei++) {
      final sel = selects[ei];
      if (sel is! Map) continue;
      final sm = sel.cast<String, dynamic>();
      final selId = (sm['id'] ?? '').toString().trim();
      if (selId.isEmpty) continue;
      final series = stripHtml((sm['series'] ?? '').toString()).trim();
      final resource = yunyAbsUrl((sm['resource'] ?? '').toString());

      // 跳过点开就是死链的条目。判据与原因见 _yunyIsPlayable 的注释：
      // `resourceType == 2` 一律不可播（covip 编码 / 爱奇艺·腾讯·优酷网页），
      // 且站方自己的取址接口与网页播放器也救不回来（固定 422）。
      // 留着这类条目只会让用户点了报错，所以解析阶段就不展示。
      if (!_yunyIsPlayable(resource, resourceType: sm['resourceType'])) continue;

      videos.add(DramaVideo(
        id: 'yuny_${dramaId}_$selId',
        title: series.isEmpty ? '第${ei + 1}集' : series,
        // resource 就是 m3u8 直链，直接放 path，播放时零额外请求。
        path: resource,
        source: '${li + 1}',
        sourceCn: lineName.isEmpty ? '线路${li + 1}' : lineName,
        episode: _yunyEpNo(series, ei + 1),
        dramaId: dramaId,
        // 万一 resource 缺失，还能用这个 id 去取址接口换地址。
        playToken: selId,
      ));
    }
  }

  return DramaDetail(
    id: dramaId,
    name: stripHtml((data['name'] ?? '').toString()).trim(),
    area: (data['area'] ?? '').toString().trim(),
    brief: stripHtml(yunyUnescape((data['description'] ?? '').toString())),
    intro: stripHtml(yunyUnescape((data['description'] ?? '').toString())),
    director: (data['director'] ?? '').toString().trim(),
    actor: _yunyActor(data),
    remark: (data['remark'] ?? '').toString().trim(),
    tag: _yunyTags(data),
    year: int.tryParse((data['years'] ?? '').toString()) ?? 0,
    stars: _yunyScore(data['score']),
    cover: CoverImage(
      path: yunyAbsUrl(
        (data['cover'] ?? data['resourceCover'] ?? '').toString(),
      ),
    ),
    videos: videos,
    sourceId: sourceId,
  );
}

/// 这条选集能不能播。**以 `resourceType` 为准**，URL 形态只作兜底。
///
/// ## 2026-11-12 全量实测（1500+ 条选集，跨 30 部剧）
///
/// `resourceType` 和资源形态是一一对应的，没有例外：
///   - `1` → **1701/1701 全是 m3u8 直链**（`svip.yzzy*-play.vip/.../index.m3u8`）
///   - `2` → **1159/1159 全部不可播**，具体是三类：
///     - `covip_xxx` 编码（507 条）：不是地址，是个选集指纹。站方自己的
///       取址接口也换不出来，见下面的说明。
///     - 爱奇艺网页（486 条，`http://www.iqiyi.com/v_xxx.html`）
///     - 腾讯 / 优酷网页（118 + 48 条）
///
/// 所以判据就是 `resourceType == 1`，比字符串匹配干净得多。
///
/// ## 为什么 `covip_` 不能靠取址接口救回来
///
/// 这类条目的 `get-video-play-urlv2` 一律回
///   `{"success":false,"code":422,"msg":"暂时无法确认设备信息…"}`
/// 而且**站方网页版同样失败**：打开 `/videoPlayer/<selectId>` 时 Nuxt payload 里
/// `playSelectItem-<id>` 存的是 `["NuxtError", {...statusCode: 422...}]`。
/// 也就是说这不是我们缺了某个头，是站点自己这条链路就是坏的。
/// 试过 `X-Real-IP` / `X-Forwarded-For`（前者直接触发 WAF 456 挑战）、
/// 各种 devicePlatform、移动 UA、改 Referer，全部不行。
///
/// 结论：`resourceType == 2` 的条目**展示出来就是死链**，解析阶段直接丢。
bool _yunyIsPlayable(String url, {Object? resourceType}) {
  // 优先信 resourceType：实测无例外。
  final rt = resourceType is num
      ? resourceType.toInt()
      : int.tryParse((resourceType ?? '').toString());
  if (rt == 1) return true;
  if (rt == 2) return false;

  // 没有 resourceType 的旧响应才走 URL 兜底。
  if (!url.startsWith('http')) return false;
  final low = url.toLowerCase();
  // 明确的媒体流后缀：直接放行。
  if (low.contains('.m3u8') || low.contains('.mp4') || low.contains('.flv')) {
    return true;
  }
  // 知名视频站的**网页**地址：一定播不了。
  const webHosts = <String>[
    'v.qq.com',
    'm.v.qq.com',
    'www.iqiyi.com',
    'v.youku.com',
    'www.bilibili.com',
    'www.mgtv.com',
    'www.le.com',
    'www.youtube.com',
  ];
  for (final h in webHosts) {
    if (low.contains(h)) return false;
  }
  // 其它 http 地址交给播放器自己试（有些采集站给的是无后缀直链）。
  return true;
}

/// 从「第01集」「第1集」「第12话」里抠出集号；抠不到就退回序号。
///
/// 站内两种写法都出现过（js 线路用「第1集」，其它用「第01集」），
/// 所以不能直接按固定宽度切。
int _yunyEpNo(String series, int fallback) {
  final m = RegExp(r'第\s*(\d+)\s*[集话期]').firstMatch(series);
  final v = int.tryParse(m?.group(1) ?? '');
  return (v == null || v < 1) ? fallback : v;
}

String _yunyActor(Map<String, dynamic> d) {
  final direct = (d['performer'] ?? '').toString().trim();
  if (direct.isNotEmpty) return direct;
  final list = d['actorList'];
  if (list is List) {
    return list
        .whereType<Map>()
        .map((e) => (e['name'] ?? e['actorName'] ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .join(' / ');
  }
  return '';
}

String _yunyTags(Map<String, dynamic> d) {
  final list = d['tagList'];
  if (list is List) {
    return list
        .whereType<Map>()
        .map((e) => (e['tagName'] ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .join(' / ');
  }
  return (d['tags'] ?? '').toString().trim();
}

double _yunyScore(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse((v ?? '').toString()) ?? 0;
}

String yunyAbsUrl(String p) {
  final t = p.trim();
  if (t.isEmpty) return '';
  if (t.startsWith('//')) return 'https:$t';
  return t;
}

String yunyUnescape(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'");

String yunyClip(String s) =>
    s.length <= 120 ? s.replaceAll('\n', ' ') : '${s.substring(0, 120)}…';

// ============================== 适配器 ==============================

class YunySource implements DataSource {
  YunySource._();

  static final YunySource instance = YunySource._();

  late final Dio _dio = Dio(BaseOptions(
    baseUrl: kYunyBase,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
    headers: {
      'User-Agent': kSiteUserAgent,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': '$kYunyBase/',
    },
  ));

  /// 分类 id 直接用**中文分类名**：`label-v2` 的 `type` 参数认的就是它，
  /// 数字 id（videoClassify/1..5）只是路由，接口不认。用中文名还能省掉
  /// 一层映射，改站时不容易对错号。
  static const List<SourceCategory> _categories = [
    SourceCategory('', '推荐'),
    SourceCategory('电影', '电影'),
    SourceCategory('剧集', '剧集'),
    SourceCategory('动漫', '动漫'),
    SourceCategory('综艺', '综艺'),
    SourceCategory('短剧', '短剧'),
  ];

  @override
  String get id => 'yuny';

  @override
  String get displayName => '云影';

  @override
  String get description => '需系统代理；无弹幕；分类齐全，各线路集数可能不同';

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
      // 空关键词等同「推荐」，与分类页的「推荐」共享同一份内容，分页也照走。
      return _home(page: page);
    }
    final body = await _post('/app/video-search/type-v2', {
      'current': page,
      'key': k,
      'size': kYunyPageSize,
      'searchCode': 1,
      'order': 'desc',
    });
    return parseYunyList(body, sourceId: id);
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty) return _home(page: page);
    final body = await _post('/app/video-search/label-v2', {
      'current': page,
      'size': kYunyPageSize,
      'type': categoryId,
    });
    return parseYunyList(body, sourceId: id);
  }

  /// 首页推荐 = 「今日更新」。
  ///
  /// ## 2026-11-12 修正：必须带 `type`，否则推荐页一半点不开
  ///
  /// 不带 `type` 时接口混排全站更新，实测第 1 页 18 条里 **16 条点进去没有
  /// 任何线路**（用户报的「怎么好多点进去后没有播放线路、只能看到个详情」
  /// 就是这个）。抽样结果：
  ///   - 混排（无 type）18 条：只有 2 条有 m3u8 线路，其余全是
  ///     `covip_*` 编码或爱奇艺网页外链（`www.iqiyi.com` 235 条）。
  ///     那批是低幼动画，站方只挂了「官方线路」外链。
  ///   - `type=剧集` 6 条：**6/6 全部有 m3u8 线路**（24~275 条）。
  ///   - 剧集分类 `label-v2` 12 条：12/12 全部有线路。
  ///
  /// 所以推荐页固定取「剧集」：内容质量稳定、真分页（total=68）、
  /// 与主流影视 App 的「今日更新」一致。电影/动漫另有独立分类可选，
  /// 用户想看那两类点分类就行，不必让推荐页拿一堆点不开的片子凑数。
  Future<List<Drama>> _home({int page = 1}) async {
    final body = await _post('/app/video-home/today-updates', {
      'pageNo': page,
      'pageSize': kYunyPageSize,
      'type': kYunyHomeType,
    });
    return parseYunyList(body, sourceId: id);
  }

  // ---------------------------- 详情 ----------------------------

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final body = await _get(
      '/app/video-interact/get-video-detail',
      {'videoInfoId': dramaId},
    );
    return parseYunyDetail(dramaId, body, sourceId: id);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    // 首选：详情里下发的 resource 本身就是 m3u8 直链，直接用，不发请求。
    final direct = video.path.trim();
    if (direct.startsWith('http')) return direct;

    // 兜底：个别线路没填 resource，用选集的 id 去换一次地址。
    final selId = video.playToken.trim();
    if (selId.isEmpty) {
      throw ApiException(-1, '这条剧集缺少播放标识，请返回重新进入详情页');
    }
    final body = await _get(
      '/app/video-interact/get-video-play-urlv2',
      {'videoSelectId': selId, 'errorCode': 0},
    );
    // 这个接口的 data 是**裸字符串**而不是对象，不能套 yunyUnwrap。
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw ApiException(-1, '取址接口返回的不是 JSON：${yunyClip(body)}');
    }
    if (decoded is! Map) {
      throw ApiException(-1, '取址接口返回结构异常');
    }
    final map = decoded.cast<String, dynamic>();
    if (map['success'] != true) {
      final msg = (map['msg'] ?? '').toString().trim();
      throw ApiException(
        (map['code'] as num?)?.toInt() ?? -1,
        msg.isEmpty ? '取址失败' : msg,
      );
    }
    final url = (map['data'] ?? '').toString().trim();
    if (!url.startsWith('http')) {
      throw ApiException(-1, '该集没有可播放的地址，换个线路试试');
    }
    return url;
  }

  // ---------------------------- HTTP ----------------------------

  Future<String> _get(String path, Map<String, dynamic> query) async {
    try {
      final r = await _dio.get<String>(
        path,
        queryParameters: query,
      );
      return _check(r);
    } on DioException catch (e) {
      throw _netError(e);
    }
  }

  Future<String> _post(String path, Map<String, dynamic> body) async {
    try {
      final r = await _dio.post<String>(
        path,
        data: jsonEncode(body),
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      return _check(r);
    } on DioException catch (e) {
      throw _netError(e);
    }
  }

  String _check(Response<String> r) {
    final code = r.statusCode ?? -1;
    final body = r.data ?? '';
    if (code != 200) {
      throw ApiException(code, '站点返回 HTTP $code：${yunyClip(body)}');
    }
    return body;
  }

  ApiException _netError(DioException e) {
    // 连不上通常是代理没开，直接说清楚，别让界面显示一串英文异常。
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return ApiException(-2, '无法连接云影，请确认代理已开启');
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return ApiException(-1, '云影响应超时，请稍后重试');
    }
    return ApiException(-1, '请求云影失败：${e.message ?? e.type.name}');
  }
}