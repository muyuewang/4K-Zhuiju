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
    this.bodyType = 'form',
    this.bodyFormat = 'text',
    this.responseType = 'text',
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

  /// POST 的请求体类型。`form`（默认）或 `json`。
  ///
  /// ## 为什么需要区分
  ///
  /// 采集接口的 POST 有两种截然不同的形态，混用一定失败：
  ///   - **表单**（`application/x-www-form-urlencoded`）：MacCMS 系
  ///     `wd=关键词&pg=2` 那种，绝大多数站是这一类；
  ///   - **JSON**（`application/json`）：云影这类自研 App 接口，
  ///     要发的是 `{"current":1,"size":18,"type":"剧集"}`。
  ///
  /// 用表单发 JSON 的 body，服务端会收到一个键叫
  /// `{"current":1,...}` 的畸形字段，返回 400 或「参数缺失」——
  /// 而现象是「这个源永远搜不到东西」，看不出是编码问题。
  final String bodyType;

  /// 请求体的承载格式：`text`（默认）/ `hex` / `base64`。
  ///
  /// protobuf 这类二进制请求体不能走普通字符串：Dio 会按 UTF-8 编码，
  /// 把 >=0x80 的字节展开成两三个字节，服务端收到的是被污染的帧。
  /// 声明 `hex` / `base64` 后，宿主先把模板里的占位符替换好，再解码成
  /// 原始字节发出——脚本只负责生成编码后的字符串，不碰 socket。
  final String bodyFormat;

  /// 响应体的形态：`text`（默认）或 `bin`。
  ///
  /// ## 为什么需要二进制通道（2026-11-18）
  ///
  /// 橘汁的接口全部返回 **protobuf**（`Content-Type: application/x-protobuf`），
  /// 里面是二进制帧。而插件的取数层原先固定 `ResponseType.plain`，
  /// Dio 会把字节按 UTF-8 解码，protobuf 里的长度前缀/varint（如 `0x08`、
  /// `0x00`）会被替换成 U+FFFD 或直接丢失，**解析出来必然是全错**。
  ///
  /// 更隐蔽的一层：即使拿到了原始字节，`JsEvalResult.stringResult` 跨 FFI
  /// 是 **C 字符串**，任何 `\u0000` 都会把内容截断（实测 `nulLen=3` 但
  /// 字符串在第一个 NUL 处就断了）。所以二进制不能以原文穿过去。
  ///
  /// 结论：`bin` 模式下宿主取回原始字节 → **base64 编码** → 交给插件，
  /// 插件用 `host.b64d(s, 'hex')` 之类的调用拿回字节表示。
  /// base64 的字母表不含 NUL，跨 FFI 安全。
  ///
  /// 默认 `text` 是有意的：99% 的源是 HTML/JSON/XML，多一次 base64
  /// 编解码纯属浪费；这也保证老配置的行为一字不变。
  final String responseType;

  /// 附加请求头。**不允许**写 Host / Cookie —— 见 [PluginManifest.validate]。
  final Map<String, String> headers;

  bool get isPost => method.toUpperCase() == 'POST';

  /// 请求体是否为 JSON。
  bool get isJsonBody => bodyType == 'json';

  /// 响应是否是二进制（需 base64 承载）。
  bool get isBinaryResponse => responseType == 'bin';

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
      // 只认 form / json 两个值。写错成别的（比如 jsonp）
      // 就退回表单——那是采集接口的绝大多数情况，
      // 静默变成「能发出去但服务端不认」比直接失败更难查。
      bodyType: raw['bodyType'] == 'json' ? 'json' : 'form',
      // 未知格式退回 text：宁可发出可被服务端拒绝的文本，
      // 也不要让配置里的拼写错误变成静默的二进制污染。
      bodyFormat: raw['bodyFormat'] == 'hex' || raw['bodyFormat'] == 'base64'
          ? raw['bodyFormat'] as String
          : 'text',
      // 同理只认 bin 这个显式值。写错成 base64 / binary 都退回 text：
      // 退回 text 的表现是「解析出来全是乱码」，比「整份清单被拒」
      // 更容易在日志里看出是配置写错了。
      responseType: raw['responseType'] == 'bin' ? 'bin' : 'text',
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
        // 只写非默认值：绝大多数请求是表单，全写进缓存会让文件很吵
        if (bodyType != 'form') 'bodyType': bodyType,
        if (bodyFormat != 'text') 'bodyFormat': bodyFormat,
        if (responseType != 'text') 'responseType': responseType,
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
    this.group = '',
    this.lineNameCn = const <String, String>{},
    this.preferDirectLine = true,
    this.derivePlayIndex = false,
    this.batchDetail = false,
    this.expandLines = false,
    this.dropIndirectLines = false,
    this.searchUnsupported = false,
    this.vars = const <String, String>{},
    this.defaultHeaders = const <String, String>{},
    this.homeRequest,
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

  /// 切换面板里的分组名，如「常用」「需系统代理」。
  ///
  /// ## 为什么由配置声明而不是宿主硬编码
  ///
  /// 源全在远端之后，宿主不可能预知会下发哪些 id。硬编码的 id 表
  /// 一旦对不上，新源就会被静默归到「采集站」——而它实际可能需要
  /// 系统代理，用户点进去只看到「无法连接」，且看不出原因。
  ///
  /// 空串表示不声明，宿主按「采集站（直连）」处理。
  final String group;

  /// 线路英文标识 → 中文名，如 `{'bfzym3u8': '暴风线路'}`。
  ///
  /// ## 为什么这个必须由配置声明而不是脚本硬编码
  ///
  /// MacCMS 的 `vod_play_from` 给的是 `bfzym3u8` / `lzm3u8` / `jsyun`
  /// 这类站点内部代号。直接显示给用户就是「bfzym3u8」这种天书，
  /// 而选线路面板里恰恰最需要「哪条能播」这个信息。
  ///
  /// 映射表放在清单里而不是脚本里，是因为**同一个代号在不同站上
  /// 含义不同**：`dyttm3u8` 在电影天堂是本家线路，在起点资源却只是
  /// 借用这个行业通用名（地址完全不同的 CDN）。脚本是多个源共用的，
  /// 硬编码就会把 A 站的叫法套到 B 站上。
  ///
  /// 未命中的标识原样显示——比显示「线路3」有用，至少用户能看出
  /// 两条线路是不是同一个来源。
  final Map<String, String> lineNameCn;

  /// 是否把「直出 m3u8/mp4」的线路排到最前。默认开。
  ///
  /// ## 为什么默认开而不是默认关
  ///
  /// 2026-11-13 实测：这批采集站给同一部剧常下发两条线路，第一条是
  /// `…/share/<md5>` 的网页页，第二条才是直出 m3u8。播放器默认取第一条，
  /// 而网页分享页靠 JS 渲染，抓下来连 m3u8 都抠不出来 —— 用户看到的是
  /// 「点进去一直转圈」。
  ///
  /// 默认开 = 新接入的站不用摸清线路顺序也是好的；确实需要保留站点
  /// 原始顺序的，显式写 `"preferDirectLine": false`。
  final bool preferDirectLine;

  /// 是否把 `/play/<token>` 派生为 `/play/<token>/index.m3u8`。默认关。
  ///
  /// 金山这类站的网页线路给的是 `vv.jisuzyv.com/play/epY8gOra`，
  /// 抓下来是 1294 B 的 Vue 空壳（正文只有 `<div id="app">`），
  /// 但同目录下的 `index.m3u8` 实测可播。默认关是因为绝大多数站
  /// 没这个目录约定，盲目拼接会造出一堆 404 地址。
  final bool derivePlayIndex;

  /// 列表拿到 id 后，是否再用 [detailRequest] 的 `ids=` 批量回查一遍。默认关。
  ///
  /// ## 什么时候需要（优子资源，2026-11-14 实测）
  ///
  /// 这类站的两个出口能力互补且**互斥**，没有任何参数能同时满足：
  ///   - `ac=list&pg=n` → 按更新时间倒序（最新片），但只有线路名、
  ///     没有封面没有分集，5.7 KB；
  ///   - `ac=videolist&pg=n` → 有封面有分集，但**按 id 升序**，
  ///     第一页全是 2022 年的老片，用户打开就是「这源怎么这么旧」。
  ///
  /// `order=time` / `order=last` / `at=json` 三种参数实测**被服务端忽略**
  /// （返回字节数与不加参数完全一致）。所以只能先拿 id 再批量回查。
  /// 代价：1.2s + 2.1s ≈ 3.3s / 页，但它换来「最新且有封面」。
  ///
  /// 回查失败时**保留原列表**：封面没有只是不好看，列表直接空掉才是事故。
  final bool batchDetail;

  /// 详情阶段是否先 resolve 第一集、把线路清单展开成多条线路。默认关。
  ///
  /// ## 什么时候需要（看剧 kanju，2026-11-17 实测）
  ///
  /// 这类站详情页只给剧集列表（每集一个 token），真正的线路清单在
  /// `/v1/playback/resolve/{token}` 的 `line_options[]` 里——实测一部剧
  /// 有 33 条线路。不展开的话用户只能在选集面板看到一条「默认线路」，
  /// 而之前的内置实现是先 resolve 第一集拿模板、再按模板给每集铺线路。
  ///
  /// 展开需要额外一次请求；失败时**退回单条占位线路**，不让详情页空掉。
  ///
  /// 脚本需实现 `parseLines(body, ctx)` → `{lines:[{line:"线路名"}]}`。
  /// 宿主只取 `line` 当线路名，剧集复用的是 `parseDetail` 已经给出的那份
  /// （线路清单跨集稳定，逐集由脚本重铺反而容易错位）。名字的粗细程度
  /// 由脚本决定——它在解析现场，最清楚哪条线当前真的能播。
  final bool expandLines;

  /// 没有 resolve 接口的源，是否丢掉「网页分享页」线路，只留直出 m3u8。默认关。
  ///
  /// 采集站常给同一部剧两条线：`share/<md5>` 网页页 + 直出 m3u8。
  /// 网页页靠 JS 渲染，播放器抓不到地址，用户点开就是「当前源无法播放」。
  /// 有 resolve 接口的源留着它们还有救（能二次解析），没有的就该在
  /// 选线路面板里直接隐藏——留着只会让用户一条条试错。
  final bool dropIndirectLines;

  /// 站方是否**根本不提供**站内搜索。默认关。
  ///
  /// 开了之后搜索页直接给提示，不再发那次注定被拦的请求；同时本源的
  /// `search` 端点配置会被忽略（留着只为配置可读）。见 [SearchUnsupported]。
  final bool searchUnsupported;

  /// 所有请求默认带的头（如 UA / Referer）。单个请求可覆盖。
  final Map<String, String> defaultHeaders;

  /// 首页/「推荐」请求。null 表示复用 [listRequest]（采集站的常见情况：
  /// 推荐位就是不带分类参数的列表）。
  ///
  /// ## 为什么需要一个独立端点（2026-11-17 实测，云影）
  ///
  /// 有一类站把「推荐」和「分类」做成了**两个完全不同的接口**：
  ///   - 推荐：`POST /app/video-home/today-updates`，
  ///     body 是 `{pageNo, pageSize, type}`；
  ///   - 分类：`POST /app/video-search/label-v2`，
  ///     body 是 `{current, size, type}`。
  ///
  /// 两者的**分页字段名都不一样**（`pageNo` vs `current`），
  /// 用一个 `list` 模板无论怎么写都只能对上其中一边。
  /// 早先只能退而求其次让「推荐」也走分类接口，代价是推荐页
  /// 变成「最新入库」——内容对，但失去了站方人工编排的推荐位。
  ///
  /// 采集站没有这个需要（`t` 为空就是全站最新），所以该项可选。
  final PluginRequest? homeRequest;

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
  ///
  /// [homeRequest] 也算：只有推荐位、没有分类列表的源（纯 App 接口站）
  /// 同样能浏览，只是分类 tab 少。漏掉它会让这类源被判成「空白页」直接拒掉。
  bool get canBrowse =>
      categories.isNotEmpty && (listRequest != null || homeRequest != null);

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

  List<PluginRequest?> get _allRequests => [
        homeRequest,
        listRequest,
        searchRequest,
        detailRequest,
        resolveRequest,
      ];

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
          // **允许空 id**：它表示「不传分类参数」，也就是首页首屏的
          // 「推荐」。采集站的推荐位不带 `t` 才是全站最新，带一个
          // 具体 id 反而会变成某个子分类。
          //
          // 早先这里要求 `cid.isNotEmpty`，结果所有源的「推荐」tab
          // 被静默丢掉——现象是「第一个 tab 不见了」，且没有任何日志。
          if (cid is String && cname is String && cname.isNotEmpty) {
            cats.add(SourceCategory(cid.trim(), cname));
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
      group: raw['group'] is String ? (raw['group'] as String).trim() : '',
      lineNameCn: PluginRequest._strMap(raw['lineNameCn']),
      // 默认值与构造函数保持一致：配置没写就是「开」，
      // 写成 `raw[...] == true` 会让缺省变成关，与文档相反
      preferDirectLine: raw['preferDirectLine'] is bool
          ? raw['preferDirectLine'] as bool
          : true,
      derivePlayIndex: raw['derivePlayIndex'] is bool
          ? raw['derivePlayIndex'] as bool
          : false,
      batchDetail: raw['batchDetail'] is bool ? raw['batchDetail'] as bool : false,
      expandLines: raw['expandLines'] is bool ? raw['expandLines'] as bool : false,
      dropIndirectLines: raw['dropIndirectLines'] is bool ? raw['dropIndirectLines'] as bool : false,
      searchUnsupported: raw['searchUnsupported'] is bool ? raw['searchUnsupported'] as bool : false,
      vars: PluginRequest._strMap(raw['vars']),
      defaultHeaders: PluginRequest._strMap(raw['defaultHeaders']),
      listRequest: PluginRequest.fromJson(raw['list']),
      homeRequest: PluginRequest.fromJson(raw['home']),
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
        if (group.isNotEmpty) 'group': group,
        if (lineNameCn.isNotEmpty) 'lineNameCn': lineNameCn,
        // 只写非默认值：这两个开关绝大多数源用默认，
        // 全写进缓存会让文件里塞满 `"preferDirectLine": true`
        if (!preferDirectLine) 'preferDirectLine': preferDirectLine,
        if (derivePlayIndex) 'derivePlayIndex': derivePlayIndex,
        if (batchDetail) 'batchDetail': batchDetail,
        if (expandLines) 'expandLines': expandLines,
        if (dropIndirectLines) 'dropIndirectLines': dropIndirectLines,
        if (searchUnsupported) 'searchUnsupported': searchUnsupported,
        'categories': categories
            .map((c) => <String, dynamic>{'id': c.id, 'name': c.name})
            .toList(),
        if (vars.isNotEmpty) 'vars': vars,
        if (defaultHeaders.isNotEmpty) 'defaultHeaders': defaultHeaders,
        if (listRequest != null) 'list': listRequest!.toJson(),
        if (homeRequest != null) 'home': homeRequest!.toJson(),
        if (searchRequest != null) 'search': searchRequest!.toJson(),
        if (detailRequest != null) 'detail': detailRequest!.toJson(),
        if (resolveRequest != null) 'resolve': resolveRequest!.toJson(),
        if (signEntry != null) 'signEntry': signEntry,
        'enabled': enabled,
        'version': version,
      };
}