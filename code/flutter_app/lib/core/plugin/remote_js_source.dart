/// 由远程 JS 插件驱动的数据源。
///
/// ## 职责分界
///
/// ```
///   UI ──Future──▶ RemoteJsSource ──HTTP──▶ 站点
///                        │                    │
///                        │◀─────响应体────────┘
///                        │
///                        └─同步解析─▶ PluginRuntime（isolate + QuickJS）
/// ```
///
/// 三件事全在宿主：**决定请求什么、发请求、把结果转成模型**。
/// 插件只做中间那一步「字符串 → JSON 字符串」。这条分界让插件
/// 拿不到任何 IO 能力，也让「换域名」只需要改清单、不用动脚本。
///
/// ## 插件要提供什么
///
/// 三个**同步**函数（可以有条件省略，缺哪个就少一项能力）：
///
/// ```js
/// // 列表 / 搜索结果 → {"items":[{"id","name","pic","remark","area","year"}]}
/// function parseList(body, ctx) { ... }
///
/// // 详情 → {"name","content","lines":[{"line","episodes":[{"name","url"}]}]}
/// function parseDetail(body, ctx) { ... }
///
/// // 取播放地址（清单配了 resolve 才需要）→ {"url":"http://..."}
/// function parseResolve(body, ctx) { ... }
/// ```
///
/// `ctx` 是 JSON 对象（不是字符串），含 `vars`（清单变量）、`baseUrl`、
/// `id`、`page`。设计成对象而不是散参数，是为了将来加字段不破坏老脚本。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import '../source/data_source.dart';
import 'plugin_fetch.dart';
import 'plugin_loader.dart';
import 'plugin_manifest.dart';
import 'plugin_runtime.dart';

class RemoteJsSource implements DataSource, SourceGrouped, SearchUnsupported {
  RemoteJsSource(this.plugin);

  final LoadedPlugin plugin;

  PluginManifest get manifest => plugin.manifest;

  /// 本次会话里已经验证可用的根地址（源 id → 地址）。
  ///
  /// 放静态表而不是实例字段：插件清单热更新会重建 `RemoteJsSource`，
  /// 实例字段会随之丢失，用户就会在下一次热更新后重新吃一轮超时。
  /// 静态表按 id 索引，重建后仍能直接命中上次可用的域名。
  static final Map<String, String> _stickyBase = <String, String>{};

  /// 当前真正使用的根地址。
  ///
  /// 优先用粘住的备用地址；没有就用清单里的主地址。所有拼 URL 的地方
  /// （请求、签名 ctx、解析 ctx）**都必须读这个**，不能直接读
  /// `manifest.baseUrl`——否则换到备用域名后，解析出来的封面等相对
  /// 链接还会拼回那个连不上的主域名，图片全裂。
  String get _base => _stickyBase[manifest.id] ?? manifest.baseUrl;

  /// 判断异常是不是「换域名可能有用」的网络层故障。
  ///
  /// 只认超时/连接失败/连接重置这类**没拿到响应**的情况。
  /// HTTP 4xx/5xx 不走这条：那时站是通的，换域名重试不但没用，
  /// 还会让一个已经在报错的接口被多打 N 倍请求。
  static bool _isNetworkFailure(Object e) {
    if (e is DioException) {
      // connectionError 覆盖"连接被重置/拒绝"，connectionTimeout 覆盖
      // TCP 握手超时，receiveTimeout 覆盖连上了但迟迟不回包——
      // 被墙的三种表现正好对上。
      return e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
    }
    // Dio 偶尔会把底层 SocketException 原样抛出（keep-alive 复用失败时）
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    return false;
  }

  /// 源 id 直接取清单里的 id，**不加任何前缀**。
  ///
  /// 早期版本这里返回 `js_${manifest.id}`，目的是让插件源和内建源
  /// 在列表里一眼可分。但那个设计有个硬伤：同一个站在列表里会出现
  /// 两次（`pianku` 和 `js_pianku`），用户会以为是两个不同的源。
  ///
  /// 现在的规范是「插件层就是源层」——一个站的配置换掉脚本即可整站
  /// 换代，列表里始终只有一条。id 是收藏/历史持久化的键，因此它在
  /// 配置里的值必须保持稳定，否则换版本就等于换了一个源。
  @override
  String get id => manifest.id;

  /// 分组由清单声明，宿主不再维护 id 表。
  ///
  /// 源全在远端后，宿主不可能预知未来会有什么 id；硬编码的 id 表一旦
  /// 对不上，新源就会被静默归到默认分组，而它实际可能需要系统代理——
  /// 用户点进去只会看到「无法连接」，且完全看不出原因。
  @override
  String get group => manifest.group;

  @override
  String get displayName => manifest.name;

  @override
  String get description => manifest.description.isNotEmpty
      ? manifest.description
      // 没写说明时给一句能解释「为什么它在列表里」的话，
      // 而不是留空——设置页里空说明看起来像坏了
      : '远程插件源（配置可在线更新）';

  @override
  List<SourceCategory> get categories => manifest.categories;

  /// 采集站都是「服务端已排好序」，与 MacCMS 系一致。
  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  /// 插件无法提供弹幕（弹幕池是橘汁独有的私有接口）。
  @override
  bool get supportsDanmaku => false;

  // —— 公共入口 ——

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    // 站方把搜索接口拦死时，发出去也只会拿回一句「暂不支持搜索」。
    // 与其让搜索页渲染成「没找到」，不如直接抛一句能解释原因的话。
    if (manifest.searchUnsupported) {
      throw PluginFetchException(searchUnsupportedHint);
    }
    final req = manifest.searchRequest;
    if (req == null) {
      throw PluginFetchException('${manifest.name} 不支持搜索');
    }
    return _loadList(req, <String, String>{
      'page': '$page',
      'keyword': keyword,
    });
  }

  /// 空串 = 本源的搜索是好的（见 [SearchUnsupported] 的说明）。
  @override
  String get searchUnsupportedHint => manifest.searchUnsupported
      ? '${manifest.name} 的站方没有开放搜索，换个源搜，或从它的分类里找'
      : '';

  /// 分类列表。`categoryId` 支持「逗号串 = 多分类并发合并」。
  ///
  /// ## 为什么需要逗号串（2026-11-13 实测结论）
  ///
  /// 采集站的父分类（`1` 电影 / `2` 电视剧）在 `ac=list` 下**恒返回 0 条**，
  /// 内容全挂在子分类（`6` 动作片、`13` 国产剧…）上。而接口的 `t` 参数
  /// **不支持逗号聚合**：实测 `t=6,7` 与 `t=6` 的 total 完全相同，
  /// 返回条目的 type_id 里只有 `6` —— 逗号后面全被忽略，只取第一个。
  ///
  /// 所以聚合只能在客户端做：拆开、并发拉同一页码、再交错合并。
  /// 翻页语义天然正确——每个子分类都取第 [page] 页，不会重复也不会漏。
  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    final ids = categoryId
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    // 「推荐」位优先用 home 端点。
    //
    // 有一类站（云影）把推荐和分类做成两个接口，连分页字段名都不同
    // （`pageNo` vs `current`），一个 list 模板只能对上一边。
    // 没配 home 的源退回 list 并传空分类——采集站的 `t` 为空
    // 本来就是「全站最新」，语义正确。
    if (ids.isEmpty) {
      final home = manifest.homeRequest;
      if (home != null) {
        return _loadList(home, <String, String>{'page': '$page'});
      }
    }

    final req = manifest.listRequest;
    if (req == null) {
      throw PluginFetchException('${manifest.name} 不支持按分类浏览');
    }

    if (ids.length <= 1) {
      return _loadList(req, <String, String>{
        'page': '$page',
        'category': ids.isEmpty ? '' : ids.first,
        'id': ids.isEmpty ? '' : ids.first,
      });
    }

    // 单个子分类失败不能拖垮整个栏目：某条分类临时挂了，
    // 其余分类照常出内容，总比整页报错强。
    final groups = await Future.wait(ids.map((id) async {
      try {
        return await _loadList(req, <String, String>{
          'page': '$page',
          'category': id,
          'id': id,
        });
      } catch (e) {
        debugPrint('[PLUGIN] ${manifest.id} 分类 $id 拉取失败：$e');
        return const <Drama>[];
      }
    }));

    // 全部子分类都失败才报错，让界面给出可重试的提示；
    // 只判 page==1 是因为翻到后面本来就可能是空页
    if (groups.every((g) => g.isEmpty) && page == 1) {
      throw PluginFetchException('${manifest.name} 暂时取不到内容，请稍后重试');
    }
    return _interleave(groups);
  }

  /// 交错合并多组条目并去重。
  ///
  /// 不直接 `addAll`：第一个子分类往往有上千条，直接拼会让前几屏全是
  /// 同一类（点「电影」连翻三屏都是动作片）。交错后每屏都是混合的，
  /// 更接近「电影院线」的观感。
  ///
  /// 去重按 id：少数站跨分类重复收录同一部片，不去重会看到两张一样的卡。
  static List<Drama> _interleave(List<List<Drama>> groups) {
    var maxLen = 0;
    for (final g in groups) {
      if (g.length > maxLen) maxLen = g.length;
    }
    final out = <Drama>[];
    final seen = <String>{};
    for (var i = 0; i < maxLen; i++) {
      for (final g in groups) {
        if (i >= g.length) continue;
        final d = g[i];
        if (d.id.isEmpty || !seen.add(d.id)) continue;
        out.add(d);
      }
    }
    return out;
  }

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final req = manifest.detailRequest;
    if (req == null) {
      // 没有详情接口时，列表里能拿到的信息就是全部。
      // 返回一个只有名字的空详情，比抛异常好：
      // 用户至少能看到「这部剧存在，但这个源给不了更多」。
      return DramaDetail(
        id: dramaId,
        name: '',
        sourceId: id,
      );
    }

    final f = await _fetch(req, <String, String>{'id': dramaId});
    final out = await _call('parseDetail', <Object?>[f.body, _ctx(f)]);
    final map = _asMap(out, 'parseDetail');

    final videos = <DramaVideo>[];
    // 先把线路收成中间结构再展平：因为要按「直出优先」重排，
    // 而重排必须发生在展平成扁平的 videos 之前。
    // 如果边解析边 push，重排就得回头改已经算好的 li 索引，很容易错位。
    final parsed = <_ParsedLine>[];
    final lines = map['lines'];
    if (lines is List) {
      for (var li = 0; li < lines.length; li++) {
        final line = lines[li];
        if (line is! Map) continue;
        // 脚本给的是 `from` 里的原始代号（bfzym3u8 / jsyun…），
        // 由清单的 lineNameCn 翻成中文。未命中就原样显示——
        // 比显示「线路3」有用，至少能看出两条线是不是同一个来源。
        final flag = _str(line['line'], '线路${li + 1}');
        final nameCn = manifest.lineNameCn[flag] ?? flag;

        final eps = line['episodes'];
        if (eps is! List) continue;
        final episodes = <_ParsedEp>[];
        for (var ei = 0; ei < eps.length; ei++) {
          final ep = eps[ei];
          if (ep is! Map) continue;
          var url = _str(ep['url'], '');
          if (url.isEmpty) continue;
          if (manifest.derivePlayIndex) {
            url = _derivePlayIndex(url) ?? url;
          }
          episodes.add(_ParsedEp(
            title: _str(ep['name'], '第${ei + 1}集'),
            url: url,
            // 单集附加标识。kvm4k 要 `dataid` 去算 HMAC 签名，
            // kanju 要 episode token 去换线路，两者都不在 URL 里。
            //
            // 之前宿主**完全丢弃**这个键（脚本算了也传不出来），
            // 只能把标识拼进 url 再用正则抠回来——那种做法一旦站点
            // 的 id 形态变化（含 `-`、含 `/`）就会抠错，而且错得无声无息。
            token: _str(ep['token'], ''),
            isLive: ep['isLive'] == true,
          ));
        }
        if (episodes.isEmpty) continue;
        parsed.add(_ParsedLine(flag: flag, nameCn: nameCn, episodes: episodes));
      }
    }

    // 详情可能只给「一条占位线路 + 每集 token」（看剧这类站：线路清单
    // 藏在 resolve 接口里）。清单声明 expandLines 时，先 resolve 第一集
    // 拿线路模板，再把占位线路展开成多条——否则用户在选集面板只能看到
    // 一条「默认线路」，而站点实际有几十条。
    if (manifest.expandLines && parsed.isNotEmpty && manifest.resolveRequest != null) {
      final expanded = await _expandLineTemplate(parsed, dramaId);
      if (expanded != null) parsed..clear()..addAll(expanded);
    }

    // 无 resolve 能力的源，网页分享页线路永远播不了（要 JS 渲染）。
    // 与其让用户在选线路面板里一条条试错，不如直接隐藏。
    // 至少保留一条：全过滤掉会让详情页变成白板。
    if (manifest.dropIndirectLines && manifest.resolveRequest == null && parsed.length > 1) {
      final direct = parsed.where((l) => l.isDirect).toList();
      if (direct.isNotEmpty) parsed..clear()..addAll(direct);
    }

    // 直出线路顶前，网页分享页沉底（相对顺序各自保持不变）。
    // 这里手写两段拼接而不是 sort：Dart 的 List.sort 不保证稳定，
    // 同组内相对次序一旦被打乱，用户熟悉的「线路1/线路2」就变了。
    //
    // 两种情况**不能**再分区，否则就是「我们自己排的序」：
    //   - `expandLines`：线路清单来自站点 resolve 的 line_options[]，
    //     站点怎么排就怎么显示（看剧 20 多条线路，用户明确要求按原版顺序）；
    //   - `dropIndirectLines`：播不了的网页线已经整条删掉，剩下的全是直出，
    //     分区是恒等变换，不如不做。
    final keepStationOrder = manifest.expandLines || manifest.dropIndirectLines;
    final ordered = (manifest.preferDirectLine && !keepStationOrder)
        ? <_ParsedLine>[
            ...parsed.where((l) => l.isDirect),
            ...parsed.where((l) => !l.isDirect),
          ]
        : parsed;

    for (var li = 0; li < ordered.length; li++) {
      final line = ordered[li];
      for (var ei = 0; ei < line.episodes.length; ei++) {
        final ep = line.episodes[ei];
        videos.add(DramaVideo(
          id: '${dramaId}_${li}_$ei',
          title: ep.title,
          path: ep.url,
          // source 保留原始代号：它是「同一线路」的身份标识，
          // 切线路、续播恢复都靠它做等值比较。
          source: line.flag,
          // sourceCn 才是给人看的中文名。
          sourceCn: line.nameCn,
          episode: ei + 1,
          dramaId: dramaId,
          // 单集标识原样带下去。取址时脚本用 `ctx.token` 拿它，
          // 不必再从 url 里正则抠——站点 id 含 `-`/`/` 时抠错是静默的。
          playToken: ep.token,
          isLive: ep.isLive,
          // 清单配了 resolve 接口 → 这个 path 还要再换一次
          needsResolve: manifest.resolveRequest != null,
        ));
      }
    }

    return DramaDetail(
      id: dramaId,
      name: _str(map['name'], ''),
      brief: _str(map['brief'] ?? map['content'], ''),
      intro: _str(map['content'], ''),
      area: _str(map['area'], ''),
      year: _int(map['year']),
      remark: _str(map['remark'], ''),
      director: _str(map['director'], ''),
      actor: _str(map['actor'], ''),
      // 标签（`现代 / 都市`这类）宿主一直没接，脚本给了也被静默丢弃。
      // 云影这类站的 tagList 是筛选的主入口，缺了它详情页标签区是空的。
      tag: _str(map['tag'], ''),
      // 评分同理：宿主之前完全没读这个键，脚本算好的星星到不了界面。
      // 云影的 score 大量为 null，此时 _double 给 0，界面按「无评分」显示。
      stars: _double(map['stars']),
      cover: CoverImage(
        path: _str(map['pic'], ''),
        thumbnail: _str(map['pic'], ''),
      ),
      videos: videos,
      sourceId: id,
    );
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final req = manifest.resolveRequest;
    if (req == null) {
      // 没配 resolve 就是直出地址
      return video.path;
    }

    final params = <String, String>{
      'id': video.dramaId.isNotEmpty ? video.dramaId : video.id,
      // 单集地址也传进去：多数站的取址接口要的是「这一集的标识」，
      // 而不是剧 id。两个都给，插件按自己的接口语义取用。
      'url': video.path,
      'episode': '${video.episode}',
      'line': video.source,
      // 单集标识（kvm4k 的 dataid / kanju 的 token）可以进 query 模板，
      // 也能从 `ctx.token` 读到。
      'token': video.playToken,
      // 复合 token 用 `|` 分段时提供分段占位符（jisu 的 prefix|ep）。
      // 不含 `|` 时 token0 就是原值、token1 为空，对其它源无副作用。
      'token0': video.playToken.split('|').first,
      'token1': video.playToken.contains('|')
          ? video.playToken.split('|').skip(1).join('|')
          : '',
    };

    final f = await _fetch(req, params);
    final out = await _call('parseResolve', <Object?>[f.body, _ctx(f, video)]);
    final map = _asMap(out, 'parseResolve');

    // ---- 两阶段线路：第一次 resolve 只拿到票据，还要再换一次 ----
    //
    // 看剧这类站把「官方线」藏成一张票据（`resolve://<ticket>`），
    // 必须 POST 换票才拿得到真地址。清单配了 `resolveLine` 才走这条
    // 分支，普通线一步到位、不多发请求。
    final ticket = _ticketOf(map);
    if (ticket.isNotEmpty && manifest.resolveLineRequest != null) {
      return _resolveLine(ticket, video);
    }

    final url = _str(map['url'], '');
    if (url.isEmpty) {
      // 脚本给了具体原因（比如「这条线路需要登录」）就用它——
      // 比宿主统一编一句「没能解析出播放地址」有用得多。
      final why = _str(map['error'] ?? map['message'], '');
      throw PluginFetchException(
          why.isNotEmpty ? why : '${manifest.name} 没能解析出播放地址');
    }
    // 票据没换成功却把 `resolve://` 当地址返回，播放器会直接崩。
    // 这里挡住，给一句能指导用户动作的话。
    if (url.startsWith('resolve://')) {
      throw PluginFetchException('${manifest.name} 这条线路需要二次解析，但清单没配 resolveLine');
    }
    return url;
  }

  /// 从 parseResolve 的返回值里取「待换票的票据」。
  ///
  /// 认三种写法，都是同一个意思，让脚本作者按手头数据挑方便的：
  ///   - `{"ticket": "..."}`   显式给票据
  ///   - `{"url": "resolve://..."}`  原样透传站点给的票据地址
  ///   - `{"resolveRequired": true, "url": "<票据>"}`
  ///
  /// 空串表示这条线路不需要二次换票，直接可播。
  ///
  /// 为什么允许 `resolve://` 前缀：脚本从 `line_options[].url` 拿到的
  /// 原文就是这个形态，让它自己剥前缀属于无谓的重复劳动，剥错了
  /// （比如只 replace 了第一个 `/`）还会把票据弄坏，现象是换票 401。
  static String _ticketOf(Map<dynamic, dynamic> map) {
    final t = _str(map['ticket'], '');
    if (t.isNotEmpty) return t;
    final u = _str(map['url'], '');
    if (u.startsWith('resolve://')) {
      return u.substring('resolve://'.length);
    }
    if (map['resolveRequired'] == true && u.isNotEmpty) return u;
    return '';
  }

  /// 官方线的第二次换票。
  ///
  /// ## 为什么不需要游客会话
  ///
  /// `kanju_source.dart` 里记的是「必须 POST /v1/users/anonymous 建会话，
  /// 否则官方线 401」。2026-11-18 实测推翻了这条：带 ticket 直接 POST
  /// `/v1/playback/resolve-line?view=compact`，10/10 条官方线全部返回
  /// `{"line":{"url":"https://..."}}`，**全程没带任何 Cookie**。
  ///
  /// 所以这里不注入会话，也不碰 SharedPreferences——插件体系本来就没有
  /// 持久化 Cookie 的通道，硬加会把「无状态解析」这条架构分界破掉。
  Future<String> _resolveLine(String ticket, DramaVideo video) async {
    final f = await _fetch(
      manifest.resolveLineRequest!,
      <String, String>{
        'ticket': ticket,
        // 票据本身常常很长（实测 347 字符，含 `-` 和 `_`）。
        // 一并给出剧集维度参数，方便别的站把它拼进 query。
        'token': video.playToken,
        'id': video.dramaId.isNotEmpty ? video.dramaId : video.id,
        'episode': '${video.episode}',
        'line': video.source,
      },
    );

    final out = await _call(
      'parseLineResolve',
      <Object?>[f.body, _ctx(f, video)],
    );
    final map = _asMap(out, 'parseLineResolve');
    var url = _str(map['url'], '');
    // 换票应答偶尔也把地址埋在 `line.url` 里（站点原始结构就是
    // `{"line":{"url":...}}`）。脚本没剥就由宿主兜一层，免得
    // 每个插件作者都要重复写这段。
    if (url.isEmpty && map['line'] is Map) {
      final ln = map['line'] as Map;
      url = _str(ln['url'], '');
    }
    if (url.isEmpty || url.startsWith('resolve://')) {
      final why = _str(map['error'] ?? map['message'], '');
      throw PluginFetchException(
          why.isNotEmpty ? why : '${manifest.name} 的官方线路换票失败，请换一条线路');
    }
    return url;
  }

  /// 把「单条占位线路」按 resolve 接口返回的线路模板展开成多条。
  ///
  /// 返回 null 表示没能展开（接口失败 / 脚本没给模板），调用方保留原样。
  /// 只 resolve **第一集**：线路清单跨集稳定，逐集 resolve 会把详情页
  /// 拖成几十次请求。
  Future<List<_ParsedLine>?> _expandLineTemplate(
      List<_ParsedLine> parsed, String dramaId) async {
    // 找到第一集里可用的 token
    String token = '';
    for (final line in parsed) {
      for (final ep in line.episodes) {
        if (ep.token.isNotEmpty) {
          token = ep.token;
          break;
        }
      }
      if (token.isNotEmpty) break;
    }
    if (token.isEmpty) return null;

    final req = manifest.resolveRequest!;
    try {
      final f = await _fetch(req, <String, String>{
        'id': dramaId,
        'url': parsed.first.episodes.first.url,
        'token': token,
        'token0': token.split('|').first,
        'token1': token.contains('|') ? token.split('|').skip(1).join('|') : '',
      });
      final out = await _call('parseLines', <Object?>[f.body, _ctx(f)]);
      final map = _asMap(out, 'parseLines');
      final rawLines = map['lines'];
      if (rawLines is! List || rawLines.isEmpty) return null;

      final labels = <String>[];
      for (final l in rawLines) {
        if (l is Map) {
          final name = _str(l['line'], '');
          if (name.isNotEmpty) labels.add(name);
        } else {
          final name = _str(l, '');
          if (name.isNotEmpty) labels.add(name);
        }
      }
      if (labels.isEmpty) return null;

      // 以原线路为模板，每条标签复制一份完整剧集。
      // source 用标签本身：resolveUrl 时脚本按 ctx.line 选对应线路。
      final result = <_ParsedLine>[];
      for (final template in parsed) {
        for (final label in labels) {
          result.add(_ParsedLine(
            flag: label,
            nameCn: manifest.lineNameCn[label] ?? label,
            episodes: template.episodes,
          ));
        }
      }
      return result;
    } catch (e) {
      debugPrint('[PLUGIN] ${manifest.id} expandLines 失败，保留原线路：$e');
      return null;
    }
  }

  // —— 内部 ——

  Future<List<Drama>> _loadList(
    PluginRequest req,
    Map<String, String> params,
  ) async {
    final f = await _fetch(req, params);
    final out = await _call('parseList', <Object?>[f.body, _ctx(f)]);
    final map = _asMap(out, 'parseList');

    final rawItems = map['items'];
    if (rawItems is! List) {
      throw PluginFetchException('${manifest.name} 返回的 items 不是数组');
    }

    // 空列表 + 有 error ⇒ 这是**失败**，不是「这个分类没内容」。
    //
    // ## 为什么这条判断必须有（2026-11-19 的实际事故）
    //
    // 橘汁的服务端在签名不对时返回 `code=100001 请求时间戳过期`，
    // 脚本的 `parseList` 把错误吞成 `{items: []}`，宿主这边又只检查
    // 「items 是不是数组」——于是整条链路上没有任何一环报错，
    // 用户看到的是「这个分类暂时没有内容」，看起来像站方片库空了。
    //
    // 真正的原因是宿主把签名脚本写的 Content-Type 覆盖成了表单类型，
    // 服务端读不出时间戳。这个错误**本该在第一眼就暴露**，
    // 结果绕了一大圈才查出来。
    //
    // 约定：脚本想表达「失败」就返回 `error` 字段（parseResolve 一直是
    // 这么做的，列表这边漏了）。空 items + 无 error 仍然是合法的
    // 「真的没有内容」，不能报错——否则翻到最后一页会弹红色错误页。
    if (rawItems.isEmpty) {
      final why = _str(map['error'] ?? map['message'], '');
      if (why.isNotEmpty) {
        debugPrint('[PLUGIN] ${manifest.id} 列表返回空且带错误：$why');
        throw PluginFetchException('${manifest.name}：$why');
      }
    }

    // 两阶段回查：列表接口只给 id 和名字（无封面），要再按 ids 批量补全。
    // 必须在转成 Drama **之前**做，否则已经丢掉的封面字段没法补回来。
    final enriched = manifest.batchDetail
        ? await _enrichByBatchDetail(rawItems)
        : rawItems;

    final list = <Drama>[];
    for (final raw in enriched) {
      if (raw is! Map) continue;
      final dramaId = _str(raw['id'], '');
      final name = _str(raw['name'], '');
      // 没有 id 或没有名字的条目直接丢：前者点进去必崩，
      // 后者在列表里是一块空白占位，都不如不显示
      if (dramaId.isEmpty || name.isEmpty) continue;

      final pic = _str(raw['pic'], '');
      list.add(Drama(
        id: dramaId,
        name: name,
        area: _str(raw['area'], ''),
        brief: _str(raw['brief'] ?? raw['remark'], ''),
        remark: _str(raw['remark'], ''),
        year: _int(raw['year']),
        clazz: _str(raw['type'], ''),
        stars: _double(raw['stars']),
        cover: CoverImage(path: pic, thumbnail: pic),
        sourceId: id,
      ));
    }
    return list;
  }

  /// 用 `ids=a,b,c` 批量回查，把封面等信息补进刚拿到的列表。
  ///
  /// 失败时**原样返回入参**：封面没有只是不好看，列表直接空掉才是事故。
  /// 所以这里刻意不抛异常，只记一条日志。
  ///
  /// 回填必须**按原顺序**：服务端批量接口可能乱序或漏条，直接采用返回
  /// 顺序会让列表突然变成另一套排序，用户翻页时会看到重复条目。
  Future<List<Object?>> _enrichByBatchDetail(List<Object?> rawItems) async {
    final detailReq = manifest.detailRequest;
    if (detailReq == null) return rawItems;

    final ids = <String>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final one = _str(raw['id'], '');
      if (one.isNotEmpty) ids.add(one);
    }
    if (ids.isEmpty) return rawItems;

    try {
      final f = await _fetch(detailReq, <String, String>{
        'id': ids.join(','),
        'ids': ids.join(','),
      });

      // 批量回查的响应是一屏**多条**，所以必须走 parseList——
      // parseDetail 只返回第一条（单条详情语义），用它会把整页压成 1 条。
      final filled = await _batchListOf(f);
      if (filled.isEmpty) return rawItems;

      final byId = <String, Map<Object?, Object?>>{};
      for (final one in filled) {
        if (one is Map) {
          final k = _str(one['id'], '');
          if (k.isNotEmpty) byId[k] = one;
        }
      }
      if (byId.isEmpty) return rawItems;

      final outItems = <Object?>[];
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final k = _str(raw['id'], '');
        outItems.add(byId[k] ?? raw);
      }
      // 一条都没匹配上说明 ids 参数没生效，保留原列表比返回空更安全
      return outItems.isEmpty ? rawItems : outItems;
    } catch (e) {
      debugPrint('[PLUGIN] ${manifest.id} 批量回查失败，保留无封面列表：$e');
      return rawItems;
    }
  }

  /// 调 parseList 解析批量回查的响应，返回 items 数组。
  Future<List<Object?>> _batchListOf(FetchResult f) async {
    try {
      final out = await _call('parseList', <Object?>[f.body, _ctx(f)]);
      final map = _asMap(out, 'parseList');
      final items = map['items'];
      if (items is List) return items;
    } catch (e) {
      debugPrint('[PLUGIN] ${manifest.id} 批量回查 parseList 失败：$e');
    }
    return const <Object?>[];
  }

  Future<FetchResult> _fetch(
    PluginRequest req,
    Map<String, String> params,
  ) async {
    final all = <String, String>{
      ...params,
      // vars 以 `vars.x` 的形式进占位符表，配置里写 `{vars.key}`
      for (final e in manifest.vars.entries) 'vars.${e.key}': e.value,
    };

    // 候选根地址：**粘住的可用地址排第一**，然后是清单主地址与备用地址。
    //
    // 顺序很关键。粘住地址已经验证过能连，正常情况下第一个就命中，
    // 全程只有一次请求；只有它后来也挂了，才会退回去重试后面的候选。
    // 如果反过来（每次从主地址开始试），一个被墙的主域名会让**每一条**
    // 请求都先白等一次超时，分类页会被拖到十几秒。
    final bases = <String>[];
    void addBase(String b) {
      if (bases.contains(b)) return;
      // 备用地址来自远程配置，可能是内网地址，提前剔掉。
      //
      // 但**主地址不剔**：配置本身就是坏的，应该让它走到 prepareRequest
      // 抛出原本那句「源站地址不可用：…」——错误页和测试都依赖这句
      // 文案，换成一句笼统的「没有可用的源站地址」反而更难排查。
      if (b != manifest.baseUrl && urlRejectionReason(b) != null) {
        debugPrint('[PLUGIN] ${manifest.id} 忽略不可用的备用地址：$b');
        return;
      }
      bases.add(b);
    }

    final sticky = _stickyBase[manifest.id];
    if (sticky != null) addBase(sticky);
    for (final b in manifest.baseCandidates) {
      addBase(b);
    }

    for (var i = 0; i < bases.length; i++) {
      final base = bases[i];
      try {
        final prepared = prepareRequest(
          manifest: manifest,
          req: req,
          params: all,
          baseOverride: base,
        );

        // 配了 signEntry 就先让插件签一遍（改 header / query / body），
        // 再发出去。「先签后发」这个顺序不能反——签名算的就是要发出去
        // 的那个报文，反了就是在给已经发完的请求签名。
        final signed =
            manifest.signEntry == null ? prepared : await _sign(prepared, base);

        final res = await PluginFetch.instance.fetch(signed);

        // 成功即粘住，后续请求直接走这个域名。
        if (sticky != base) {
          _stickyBase[manifest.id] = base;
          if (base != manifest.baseUrl) {
            debugPrint('[PLUGIN] ${manifest.id} 主域名不可用，改用 $base');
          }
        }
        return res;
      } catch (e) {
        // 站是通的（拿到 4xx/5xx 或解析出错）时换域名没有意义，
        // 直接抛：否则一个报错的接口会被乘以候选域名个数地重打。
        if (!_isNetworkFailure(e)) rethrow;
        if (i == bases.length - 1) rethrow;
        debugPrint('[PLUGIN] ${manifest.id} 访问 $base 失败（$e），试下一个地址');
      }
    }
    // 理论上到不了这里：baseCandidates 至少包含主地址，循环必然返回或抛出。
    throw PluginFetchException(
        '源站地址不可用：${manifest.id} 没有可用的根地址（${manifest.baseUrl}）');
  }

  /// 调插件的签名钩子，把返回的改动合并进请求。
  ///
  /// ## 只做覆盖，不做推断
  ///
  /// 插件返回什么就改什么，没返回的字段一律不动。宿主完全不理解
  /// 具体站点的协议——那是插件的事。这样加一个新签名方案不需要
  /// 动宿主代码。
  ///
  /// ## 安全边界
  ///
  /// 签名钩子是远程脚本，和清单一样不可信。它能改 header，那就必须
  /// 拦住 `Host`（会把请求劫持到别的站，绕开 SNI 与证书校验）、
  /// `Cookie` / `Authorization`（凭证不该由远程脚本注入）。
  /// 命中即整个请求作废，而不是「过滤掉继续发」——后者会让作者
  /// 以为签名生效了，实际发出去的是没签的报文，比直接报错难查得多。
  Future<PreparedRequest> _sign(PreparedRequest base, String rootUrl) async {
    final u = Uri.parse(base.url);
    final out = await _call(manifest.signEntry!, <Object?>[
      <String, Object?>{
        'url': base.url,
        'method': base.method,
        'query': u.queryParameters,
        'headers': base.headers,
        'body': base.body,
        'vars': manifest.vars,
        'ctx': <String, Object?>{
          // 用本次请求真正走的根地址，不是清单主地址：换到备用域名后
          // 签名脚本若按 baseUrl 拼参，拼出来的必须是那个能连上的域名。
          'baseUrl': rootUrl,
          'sourceId': manifest.id,
        },
      },
    ]);

    if (out is! Map) {
      throw PluginFetchException(
          '${manifest.name} 的 ${manifest.signEntry} 没返回对象');
    }

    // ---- headers ----
    final extraHeaders = <String, String>{};
    final rawHeaders = out['headers'];
    if (rawHeaders is Map && rawHeaders.isNotEmpty) {
      for (final e in rawHeaders.entries) {
        final k = '${e.key}';
        final lower = k.toLowerCase();
        if (lower == 'host' || lower == 'cookie' || lower == 'authorization') {
          throw PluginFetchException(
              '${manifest.name} 的签名脚本试图设置 $k，已拒绝');
        }
        final v = e.value;
        if (v == null) continue;
        extraHeaders[k] = '$v';
      }
    }

    // ---- query ----
    final mergedQuery = <String, String>{...u.queryParameters};
    final rawQuery = out['query'];
    if (rawQuery is Map && rawQuery.isNotEmpty) {
      for (final e in rawQuery.entries) {
        final v = e.value;
        if (v == null) continue;
        mergedQuery['${e.key}'] = '$v';
      }
    }

    final query = mergedQuery.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final newUrl = u.replace(query: query.isEmpty ? null : query).toString();

    // 改完 URL 必须重新过一遍安全校验。
    // 虽然签名只改 query（改不了主机），但这条校验很便宜，
    // 而且挡住了「将来允许改 host 时忘了加校验」这种演进风险。
    final reject = urlRejectionReason(newUrl);
    if (reject != null) {
      throw PluginFetchException('签名后的地址被拒绝：$reject');
    }

    return PreparedRequest(
      url: newUrl,
      method: base.method,
      headers: <String, String>{...base.headers, ...extraHeaders},
      body: out['body'] is String ? out['body'] as String : base.body,
      // 脚本改了 body 就以它的新值为准，且必须按声明的格式重新解码。
      // 橘汁的 protobuf 体是签名钩子现算的，不重解码就会当文本发出去。
      bodyBytes: out['body'] is String
          ? (base.bodyFormat == 'hex'
              ? Uint8List.fromList(hexDecode(out['body'] as String))
              : base.bodyFormat == 'base64'
                  ? Uint8List.fromList(base64.decode(out['body'] as String))
                  : null)
          : base.bodyBytes,
      bodyFormat: base.bodyFormat,
      // 重建请求时必须带走这三项。漏掉的话「签名 + JSON body」会
      // 退化成表单（服务端报参数缺失），「签名 + 二进制」会拿到
      // 乱码或空体——故障离签名代码很远，极难定位。
      contentType: base.contentType,
      binaryResponse: base.binaryResponse,
    );
  }

  /// 调插件函数，把「JSON 字符串」解成对象。
  Future<Object?> _call(String entry, List<Object?> args) async {
    // 明显死循环的脚本直接拒掉，不扔进引擎（扔进去就杀不掉了，
    // 见 plugin_runtime.dart 顶部的实测说明）
    if (looksLikeInfiniteLoop(plugin.script)) {
      throw PluginFetchException('${manifest.name} 的脚本含疑似死循环，已拒绝执行');
    }

    final res = await PluginRuntime.instance.call(
      script: plugin.script,
      entry: entry,
      argsJson: jsonEncode(args),
    );

    if (!res.ok) {
      debugPrint('[PLUGIN] ${manifest.id}.$entry 失败：${res.error}');
      throw PluginFetchException('${manifest.name} 解析失败');
    }

    try {
      return jsonDecode(res.value);
    } catch (e) {
      // 插件返回了非 JSON（比如直接 return 一个字符串）。
      // 这种情况通常是作者漏了 JSON.stringify —— 明确提示比
      // 「解析失败」有用得多。
      throw PluginFetchException(
          '${manifest.name} 的 $entry 没返回合法 JSON');
    }
  }

  /// 传给插件的上下文对象。
  ///
  /// 用「对象」而不是散参数：将来加字段（比如 referer）不用改所有脚本。
  ///
  /// [video] 只在取址（parseResolve）时给：那时脚本需要知道「这是哪一集、
  /// 哪条线路、单集标识是什么」，才能拼出该集的取址参数。
  /// 列表/详情的 ctx 里不含这些字段——它们对解析整页没有意义。
  Map<String, Object?> _ctx(FetchResult f, [DramaVideo? video]) => <String, Object?>{
        'vars': manifest.vars,
        // 解析阶段补全相对链接（封面、相对播放地址）用的根地址。
        // 必须用 _base 而不是 manifest.baseUrl：走备用域名时，
        // 站方返回的 `//upload/x.jpg` 要拼到**实际可用的**那个域名上。
        'baseUrl': _base,
        'finalUrl': f.finalUrl,
        'sourceId': manifest.id,
        if (video != null) ...<String, Object?>{
          'dramaId': video.dramaId,
          'path': video.path,
          'episode': video.episode,
          'line': video.source,
          'token': video.playToken,
        },
      };

  static Map _asMap(Object? o, String entry) {
    if (o is Map) return o;
    throw PluginFetchException('$entry 的返回值不是对象');
  }

  /// 取字符串，带兜底。
  ///
  /// 插件可能返回数字（`id: 123` 而不是 `"123"`），直接 `as String`
  /// 会崩。采集接口里 id 是数字还是字符串完全看站方心情，
  /// 所以这里统一转字符串。
  static String _str(Object? v, String fallback) {
    if (v == null) return fallback;
    if (v is String) return v.trim().isEmpty ? fallback : v.trim();
    if (v is num) return '$v';
    return fallback;
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  /// 取浮点，带兜底。
  ///
  /// 评分在 JSON 里是 9 / 9.2 / "8.7" / null 四种形态都见过
  /// （云影实测大量为 null），统一收敛到 double。
  static double _double(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim()) ?? 0;
    return 0;
  }

  /// 把 `/play/<token>` 推成 `/play/<token>/index.m3u8`。
  ///
  /// 只对「纯壳播放页」有意义：金山这类站的网页线路给的是
  /// `vv.jisuzyv.com/play/epY8gOra`，抓下来是 1294 B 的 Vue 空壳
  /// （正文只有 `<div id="app">`），但同目录下的 `index.m3u8` 实测可播。
  ///
  /// 三条守卫缺一不可：
  ///   - 已经是 `.m3u8`/`.mp4` 就返回 null，否则会拼成
  ///     `…/index.m3u8/index.m3u8`；
  ///   - 路径必须恰好是 `play/<一段>`，不加这个限制的话 `/play/a/b`
  ///     也可能被误拼成一个看起来合法的路径；
  ///   - 拼不出合法主机就返回 null，交给调用方退回原地址。
  ///
  /// 返回 null 表示「这条规则不适用」，由调用方保留原 URL。
  static String? _derivePlayIndex(String pageUrl) {
    final u = Uri.tryParse(pageUrl.trim());
    if (u == null || u.host.isEmpty) return null;
    final p = u.path.toLowerCase();
    if (p.contains('.m3u8') || p.contains('.mp4')) return null;
    final segs = u.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segs.length != 2 || segs.first != 'play') return null;
    return '${u.scheme}://${u.authority}/play/${segs[1]}/index.m3u8';
  }
}

/// 解析过程中的一条线路（尚未展平成 [DramaVideo]）。
///
/// 引入这个中间结构只为了一件事：**先收齐再排**。直出线路要顶到前面，
/// 而重排必须发生在展平之前，否则展平时算好的 `li` 索引会全部错位，
/// 表现为「切到第 2 条线路播的却是第 1 条」。
class _ParsedLine {
  const _ParsedLine({
    required this.flag,
    required this.nameCn,
    required this.episodes,
  });

  /// `vod_play_from` 里的原始代号，如 `bfzym3u8`。
  final String flag;

  /// 给人看的中文名，如「暴风线路」。
  final String nameCn;

  final List<_ParsedEp> episodes;

  /// 是否直出可播地址。
  ///
  /// 按**首集**判断：同一线路内各集形态一致，抽查首集足够，
  /// 也避免为了判断去遍历几千集。
  bool get isDirect {
    if (episodes.isEmpty) return false;
    final u = episodes.first.url.toLowerCase();
    return u.contains('.m3u8') || u.contains('.mp4');
  }
}

class _ParsedEp {
  const _ParsedEp({
    required this.title,
    required this.url,
    this.token = '',
    this.isLive = false,
  });

  final String title;
  final String url;

  /// 单集附加标识（kvm4k 的 `dataid`、kanju 的 episode token）。
  /// 空串表示这个源不需要——绝大多数采集站都是这一类。
  final String token;

  /// 直播流标记（橘汁的直播分类）。普通采集站恒为 false。
  final bool isLive;
}