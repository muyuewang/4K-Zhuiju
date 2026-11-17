/// 插件清单（manifest）数据模型。
///
/// ## 这是什么
///
/// 一份 JSON 描述「一个用 JS 写的数据源」：叫什么、走哪个域名、要抓哪些接口、
/// 脚本在哪个文件。宿主读到它就能把这个源注册进 [SourceRegistry]，
/// 用户切过去就能用——**整个过程不需要发版**。
///
/// ## 为什么配置和脚本要分开
///
/// 两者的变更频率差一个数量级：
///
///   | 内容 | 典型变更 | 变更时要不要动脚本 |
///   | --- | --- | --- |
///   | 域名 / 分类 id / 分页参数 | 一周几次 | 不要 |
///   | 解析逻辑（字段名变了、加了加密） | 几个月一次 | —— |
///
/// 合在一起的话，改一个分类 id 就得重发整段脚本，review 成本高、出错面大。
/// 分开之后，日常的「站点换域名」只改 JSON 里一行，脚本原样复用。
///
/// 所以清单里刻意**只用声明式字段描述请求**，把「怎么发请求」交给宿主，
/// 脚本只负责「响应体怎么解析成条目」。这条分界线让 90% 的失效
/// 都能靠改 JSON 解决。
///
/// ## 校验为什么这么严
///
/// 清单来自远程文件，会被直接拼进 URL、当作脚本路径去下载。任何一个字段
/// 写错（哪怕只是多个空格）都会让源静默不可用，而现象是「转圈半天然后失败」，
/// 极难定位。所以这里宁可拒绝整份清单，也不要半对半错地跑起来。
library;

import '../source/data_source.dart';

/// 一次接口请求的声明。
///
/// 只描述「请求长什么样」，不描述「怎么解析」。解析在 JS 里。
class PluginRequest {
  const PluginRequest({
    required this.path,
    this.method = 'GET',
    this.query = const <String, String>{},
    this.body = '',
    this.headers = const <String, String>{},
  });

  /// 相对路径或绝对地址。
  ///
  /// 相对路径（如 `/api.php/provide/vod/`）会拼到 [PluginManifest.baseUrl] 后面，
  /// 站点换域名时只改 baseUrl 即可。绝对地址用于「接口不在同一个域名」的情况
  /// （比如封面走独立 CDN）。
  final String path;

  final String method;

  /// query 参数。值里支持以下占位符，由宿主在发请求前替换：
  ///
  ///   `{page}`     页码
  ///   `{keyword}`  搜索词（URL 编码后的）
  ///   `{id}`       详情/取址用的条目 id
  ///   `{category}` 分类 id
  ///   `{vars.x}`   清单 [PluginManifest.vars] 里的变量
  ///
  /// 用占位符而不是让脚本拼 URL，是因为拼 URL 需要 `encodeURIComponent`，
  /// 而一旦脚本拼错（少编码一个 `&`）就会变成「关键词被截断」这种
  /// 莫名其妙的现象。宿主拼 URL 更可靠，且能统一做编码。
  final Map<String, String> query;

  /// POST 表单体的模板，占位符同上。仅 [method] 为 POST 时使用。
  final String body;

  /// 附加请求头。**不允许**写 Host / Cookie —— 见 [PluginManifest.validate]。
  final Map<String, String> headers;

  bool get isPost => method.toUpperCase() == 'POST';

  static PluginRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.trim().isEmpty) return null;

    final method = (raw['method'] is String)
        ? (raw['method'] as String).toUpperCase()
        : 'GET';
    // 只接受 GET / POST：PUT/DELETE 在这类采集接口上没有正当用途，
    // 而一个「能对任意 URL 发 DELETE」的远程配置本身就是个隐患。
    if (method != 'GET' && method != 'POST') return null;

    return PluginRequest(
      path: path.trim(),
      method: method,
      query: _strMap(raw['query']),
      body: raw['body'] is String ? raw['body'] as String : '',
      headers: _strMap(raw['headers']),
    );
  }

  static Map<String, String> _strMap(Object? raw) {
    final out = <String, String>{};
    if (raw is! Map) return out;
    for (final e in raw.entries) {
      final k = e.key;
      final v = e.value;
      if (k is String && v is String) out[k] = v;
    }
    return out;
  }

  /// 落缓存用。只写非默认值，让缓存文件保持可读。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        if (method != 'GET') 'method': method,
        if (query.isNotEmpty) 'query': query,
        if (body.isNotEmpty) 'body': body,
        if (headers.isNotEmpty) 'headers': headers,
      };
}

/// 一个 JS 数据源的完整描述。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.script,
    required this.categories,
    this.description = '',
    this.vars = const <String, String>{},
    this.defaultHeaders = const <String, String>{},
    this.listRequest,
    this.searchRequest,
    this.detailRequest,
    this.resolveRequest,
    this.signEntry,
    this.enabled = true,
    this.version = 0,
  });

  /// 源标识。会写进收藏/历史的 `sourceId`，**改了就等于让老收藏失效**。
  /// 所以校验时不允许空、不允许含空格，且要求短。
  final String id;

  /// 展示名（设置页里给人看）
  final String name;

  /// 站点根地址，如 `https://api.example.com`。
  ///
  /// 单独拎出来是因为它是**最高频的变更项**：采集站换域名是常态，
  /// 而换域名时只需要改这一个字段。
  final String baseUrl;

  /// JS 脚本在仓库里的相对路径，如 `config/plugins/maccms-generic.js`。
  ///
  /// 相对路径而非内容：脚本可能几 KB，塞进 index.json 会让所有人
  /// 每次启动都下载全部脚本。分开文件还能让脚本被 CDN/浏览器缓存。
  final String script;

  final String description;

  final List<SourceCategory> categories;

  /// 站点级变量，脚本和请求模板都能引用（`{vars.x}`）。
  ///
  /// 典型用途：某个站的接口要带固定 `key=xxx`，或者分类 id 表是站方
  /// 自定义的一串数字。放这里就不用为每个站改脚本。
  final Map<String, String> vars;

  /// 所有请求默认带的头（如 UA / Referer）。单个请求可覆盖。
  final Map<String, String> defaultHeaders;

  /// 分类列表请求。null 表示该源不支持浏览分类。
  final PluginRequest? listRequest;

  /// 搜索请求。null 表示不支持搜索。
  ///
  /// 单独一项而不是复用 [listRequest]：实测不少采集站的搜索走另一个
  /// 端点（`?wd=` vs `?t=`），或者干脆只支持 POST。
  final PluginRequest? searchRequest;

  final PluginRequest? detailRequest;

  /// 取播放地址的请求。null 表示 detail 里给的地址可以直接播。
  final PluginRequest? resolveRequest;

  /// 请求签名钩子的函数名。null 表示该源不需要签名。
  ///
  /// ## 为什么签名要单独一个入口
  ///
  /// 签名和解析是**方向相反**的两件事：
  ///   - 解析：响应体 → 数据（请求已经发完了）
  ///   - 签名：请求参数 → 要加的请求头（请求还没发）
  ///
  /// 塞进 [listRequest].query 里是做不到的：`sig = RSA(ts + nonce + vApp)`
  /// 这种要一次算出、同时影响 header 和 query，纯模板展开写不出来。
  ///
  /// ## 它长什么样
  ///
  /// 插件里写一个同名的**同步**函数，签名约定是：
  ///
  /// ```js
  /// // 入参：{url, method, query, headers, body, vars, ctx}
  /// // 返回：{query?, headers?, body?}  —— 只返回要改/要加的部分
  /// function sign(req) {
  ///   var ts = String(Date.now());
  ///   var nonce = host.randomAlnum(16);
  ///   var sig = host.rsaEncrypt({ nHex: pubN, data: ts + nonce + '1.0.0' });
  ///   return { headers: { 'x-sig': sig, 'x-ts': ts } };
  /// }
  /// ```
  ///
  /// 宿主拿到返回值后**只做覆盖，不做推断**：返回什么就改什么，
  /// 没返回的字段一律不动。这样作者能完整控制报文，而宿主不用
  /// 理解任何具体站点的协议。
  ///
  /// ## 安全边界没有松动
  ///
  /// 签名函数能改 header，那能不能加 `Host` 把请求劫持走？
  /// 不能——返回值会过一遍和清单同样的黑名单（Host/Cookie/
  /// Authorization），命中就整个请求作废。这是必要的：签名钩子是
  /// 远程脚本，和清单一样不可信。
  final String? signEntry;

  final bool enabled;

  /// 清单版本号。仅用于日志/排障，不参与逻辑判断。
  final int version;

  /// 该源是否声明了「能在首页浏览」（有分类且有列表请求）。
  bool get canBrowse => categories.isNotEmpty && listRequest != null;

  bool get canSearch => searchRequest != null;

  /// 逐字段校验。返回 null 表示通过，否则返回人话错因。
  ///
  /// 之所以返回字符串而不是 bool：这份清单是远程下发的，出错时必须能
  /// 在日志里一眼看出「哪一条、哪个字段、错在哪」，否则排查只能是猜。
  String? validate() {
    if (id.trim().isEmpty) return 'id 为空';
    if (id.length > 40) return 'id 过长（$id）';
    // id 会进 SharedPreferences 的 key 和收藏记录，带空格/斜杠会让
    // 「按 id 找回源」这种字符串比较出错，且现象诡异
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(id)) {
      return 'id 只能是小写字母/数字/下划线/连字符（$id）';
    }
    if (name.trim().isEmpty) return 'name 为空（$id）';
    if (script.trim().isEmpty) return 'script 为空（$id）';

    final baseErr = validateBaseUrl(baseUrl);
    if (baseErr != null) return '$id: $baseErr';

    // signEntry 会被拼进 `$entry.apply(null, ...)` 执行，必须是一个
    // 合法的 JS 标识符。不校验的话，写错成 `sign(req)` 或带空格的
    // 字符串会让整段调用代码语法错误，报错是「装载脚本失败」——
    // 完全看不出问题在清单的这一行。
    if (signEntry case final entry?) {
      // 注意：这里必须用模式匹配绑定局部变量。
      // Dart 不会对**实例字段**做空类型提升（`field != null` 之后
      // 它仍认为是可空的），直接传 signEntry 会报类型错误。
      if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(entry)) {
        return '$id: signEntry 必须是合法的函数名（$entry）';
      }
    }

    if (!canBrowse && !canSearch) {
      // 既不能浏览也不能搜索的源，用户切过去只会看到空白页。
      // 这种源不该被下发，直接拒掉。
      return '$id: 既没有分类列表也没有搜索，切过去会是空白页';
    }

    // 请求头里出现 Host / Cookie / Authorization 一律拒绝：
    //   - Host 会打乱 SNI 与证书校验，等于把请求伪装到别的站；
    //   - Cookie / Authorization 是凭证，不该出现在公开仓库的配置里。
    //
    // 注意 _allRequests 里会有 null（源可以只配 search、不配 list），
    // 所以这里必须判空——用 req! 会在「没配 detail」的正常配置上直接崩。
    for (final req in _allRequests) {
      if (req == null) continue;
      for (final k in req.headers.keys) {
        final lower = k.toLowerCase();
        if (lower == 'host' || lower == 'cookie' || lower == 'authorization') {
          return '$id: 请求头不允许出现 $k';
        }
      }
    }
    for (final k in defaultHeaders.keys) {
      final lower = k.toLowerCase();
      if (lower == 'host' || lower == 'cookie' || lower == 'authorization') {
        return '$id: 默认请求头不允许出现 $k';
      }
    }
    return null;
  }

  List<PluginRequest?> get _allRequests =>
      [listRequest, searchRequest, detailRequest, resolveRequest];

  /// baseUrl 校验。规则与 [RemoteEndpoints.isValidBase] 一致，但这里
  /// **允许带路径前缀**：部分站点的接口挂在 `https://cdn.example.com/api/`
  /// 这种子路径下，把前缀写进 baseUrl 比每条 request 都重复一遍更省事。
  static String? validateBaseUrl(String s) {
    if (s.trim().isEmpty) return 'baseUrl 为空';
    if (s.length > 200) return 'baseUrl 过长';
    final u = Uri.tryParse(s.trim());
    if (u == null) return 'baseUrl 不是合法 URL（$s）';
    if (u.scheme != 'http' && u.scheme != 'https') {
      return 'baseUrl 只允许 http/https（$s）';
    }
    if (u.host.isEmpty) return 'baseUrl 没有主机名（$s）';
    if (u.userInfo.isNotEmpty) return 'baseUrl 不允许带用户名密码（$s）';
    return null;
  }

  /// 从 JSON 解析。返回 null 表示结构不成立（缺必填字段）。
  ///
  /// 注意：这里**不做** [validate] 的语义校验，由调用方决定
  /// 「跳过这一条」还是「整份清单作废」。混在一起的话，
  /// 一条配错就会让整个源列表消失，用户看到「所有源都没了」。
  static PluginManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final baseUrl = raw['baseUrl'];
    final script = raw['script'];
    if (id is! String || name is! String) return null;
    if (baseUrl is! String || script is! String) return null;

    final cats = <SourceCategory>[];
    final rawCats = raw['categories'];
    if (rawCats is List) {
      for (final c in rawCats) {
        if (c is Map) {
          final cid = c['id'];
          final cname = c['name'];
          if (cid is String && cname is String && cid.isNotEmpty) {
            cats.add(SourceCategory(cid, cname));
          }
        } else if (c is String && c.isNotEmpty) {
          // 简写形式：直接给 id，名字用 id 顶替。
          // 很多采集站的分类 id 就是 `1`/`2`，站方也常直接用数字当名字。
          cats.add(SourceCategory(c, c));
        }
      }
    }

    return PluginManifest(
      id: id,
      name: name,
      baseUrl: baseUrl,
      script: script,
      categories: cats,
      description: raw['description'] is String
          ? raw['description'] as String
          : '',
      vars: PluginRequest._strMap(raw['vars']),
      defaultHeaders: PluginRequest._strMap(raw['defaultHeaders']),
      listRequest: PluginRequest.fromJson(raw['list']),
      searchRequest: PluginRequest.fromJson(raw['search']),
      detailRequest: PluginRequest.fromJson(raw['detail']),
      resolveRequest: PluginRequest.fromJson(raw['resolve']),
      signEntry: raw['signEntry'] is String && (raw['signEntry'] as String).trim().isNotEmpty
          ? (raw['signEntry'] as String).trim()
          : null,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      version: raw['version'] is int ? raw['version'] as int : 0,
    );
  }

  /// 落缓存用。
  ///
  /// 必须能「存进去再读出来完全等价」，否则缓存会让源在下次启动时
  /// 悄悄变形（比如分类丢了、POST 变 GET）。[PluginLoader] 落盘后再
  /// 从缓存恢复，走的就是这条路径。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'script': script,
        if (description.isNotEmpty) 'description': description,
        'categories': categories
            .map((c) => <String, dynamic>{'id': c.id, 'name': c.name})
            .toList(),
        if (vars.isNotEmpty) 'vars': vars,
        if (defaultHeaders.isNotEmpty) 'defaultHeaders': defaultHeaders,
        if (listRequest != null) 'list': listRequest!.toJson(),
        if (searchRequest != null) 'search': searchRequest!.toJson(),
        if (detailRequest != null) 'detail': detailRequest!.toJson(),
        if (resolveRequest != null) 'resolve': resolveRequest!.toJson(),
        if (signEntry != null) 'signEntry': signEntry,
        'enabled': enabled,
        'version': version,
      };
}