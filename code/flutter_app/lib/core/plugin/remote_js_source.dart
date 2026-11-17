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

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../source/data_source.dart';
import 'plugin_fetch.dart';
import 'plugin_loader.dart';
import 'plugin_manifest.dart';
import 'plugin_runtime.dart';

class RemoteJsSource implements DataSource, SourceGrouped {
  RemoteJsSource(this.plugin);

  final LoadedPlugin plugin;

  PluginManifest get manifest => plugin.manifest;

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
    final req = manifest.searchRequest;
    if (req == null) {
      throw PluginFetchException('${manifest.name} 不支持搜索');
    }
    return _loadList(req, <String, String>{
      'page': '$page',
      'keyword': keyword,
    });
  }

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
    final req = manifest.listRequest;
    if (req == null) {
      throw PluginFetchException('${manifest.name} 不支持按分类浏览');
    }

    final ids = categoryId
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

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
          ));
        }
        if (episodes.isEmpty) continue;
        parsed.add(_ParsedLine(flag: flag, nameCn: nameCn, episodes: episodes));
      }
    }

    // 直出线路顶前，网页分享页沉底（相对顺序各自保持不变）。
    // 这里手写两段拼接而不是 sort：Dart 的 List.sort 不保证稳定，
    // 同组内相对次序一旦被打乱，用户熟悉的「线路1/线路2」就变了。
    final ordered = manifest.preferDirectLine
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

    final f = await _fetch(req, <String, String>{
      'id': video.dramaId.isNotEmpty ? video.dramaId : video.id,
      // 单集地址也传进去：多数站的取址接口要的是「这一集的标识」，
      // 而不是剧 id。两个都给，插件按自己的接口语义取用。
      'url': video.path,
      'episode': '${video.episode}',
      'line': video.source,
    });

    final out = await _call('parseResolve', <Object?>[f.body, _ctx(f)]);
    final map = _asMap(out, 'parseResolve');
    final url = _str(map['url'], '');
    if (url.isEmpty) {
      throw PluginFetchException('${manifest.name} 没能解析出播放地址');
    }
    return url;
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
    final prepared = prepareRequest(
      manifest: manifest,
      req: req,
      params: <String, String>{
        ...params,
        // vars 以 `vars.x` 的形式进占位符表，配置里写 `{vars.key}`
        for (final e in manifest.vars.entries) 'vars.${e.key}': e.value,
      },
    );

    // 配了 signEntry 就先让插件签一遍（改 header / query / body），
    // 再发出去。「先签后发」这个顺序不能反——签名算的就是要发出去
    // 的那个报文，反了就是在给已经发完的请求签名。
    final signed = manifest.signEntry == null
        ? prepared
        : await _sign(prepared);

    return PluginFetch.instance.fetch(signed);
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
  Future<PreparedRequest> _sign(PreparedRequest base) async {
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
          'baseUrl': manifest.baseUrl,
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
  Map<String, Object?> _ctx(FetchResult f) => <String, Object?>{
        'vars': manifest.vars,
        'baseUrl': manifest.baseUrl,
        'finalUrl': f.finalUrl,
        'sourceId': manifest.id,
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
  const _ParsedEp({required this.title, required this.url});

  final String title;
  final String url;
}