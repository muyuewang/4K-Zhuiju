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

class RemoteJsSource implements DataSource {
  RemoteJsSource(this.plugin);

  final LoadedPlugin plugin;

  PluginManifest get manifest => plugin.manifest;

  @override
  String get id => 'js_${manifest.id}';

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

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    final req = manifest.listRequest;
    if (req == null) {
      throw PluginFetchException('${manifest.name} 不支持按分类浏览');
    }
    return _loadList(req, <String, String>{
      'page': '$page',
      'category': categoryId,
      'id': categoryId,
    });
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
    final lines = map['lines'];
    if (lines is List) {
      for (var li = 0; li < lines.length; li++) {
        final line = lines[li];
        if (line is! Map) continue;
        final lineName = _str(line['line'], '线路${li + 1}');
        final eps = line['episodes'];
        if (eps is! List) continue;
        for (var ei = 0; ei < eps.length; ei++) {
          final ep = eps[ei];
          if (ep is! Map) continue;
          final url = _str(ep['url'], '');
          if (url.isEmpty) continue;
          videos.add(DramaVideo(
            id: '${dramaId}_${li}_$ei',
            title: _str(ep['name'], '第${ei + 1}集'),
            path: url,
            source: lineName,
            sourceCn: lineName,
            episode: ei + 1,
            dramaId: dramaId,
            // 清单配了 resolve 接口 → 这个 path 还要再换一次
            needsResolve: manifest.resolveRequest != null,
          ));
        }
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

    final list = <Drama>[];
    for (final raw in rawItems) {
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
}