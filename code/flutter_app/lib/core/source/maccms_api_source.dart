/// MacCMS / 苹果CMS **采集接口**（JSON API）适配器。
///
/// 与 [MacCmsSource] 的区别是根本性的，不要混用：
///
///   | 维度     | MacCmsSource（HTML）              | MacCmsApiSource（本文件）        |
///   | -------- | --------------------------------- | -------------------------------- |
///   | 入口     | 网页 `/vodsearch/…`               | 接口 `/api.php/provide/vod/`     |
///   | 数据     | 正则啃 HTML，模板一改就崩          | 稳定 JSON，字段名固定             |
///   | 取址     | 每集再抓一次播放页解析 player_aaaa | 详情一次给全，`vod_play_url` 直出 |
///   | 脆弱点   | 模板 / class 名 / 反爬             | 只有域名和 UA                    |
///
/// 所以采集接口站只要填一份 [MacCmsApiConfig]，**零解析代码**。
///
/// ## 接口契约（2026-11-11 逐条实测）
///
/// ```
/// 分类   ?ac=list&t=<type_id>&pg=<page>      → 轻量列表（19 字段，约 10 KB）
/// 推荐   ?ac=list&pg=<page>                  → 最新更新混合流
/// 搜索   ?ac=list&wd=<关键词>&pg=<page>       → 命中 1216 条（“嫁金钗”）
/// 详情   ?ac=detail&ids=<vod_id>             → 全字段（85 字段，含播放地址）
/// ```
///
/// **列表一律走 `ac=list`，不要用 `ac=detail`**：同样 20 条，
/// `ac=list` 约 10 KB，`ac=detail` 约 540 KB。列表页根本不需要播放地址，
/// 用 detail 拉列表会让首屏慢一个数量级，弱网下直接超时。
///
/// ## 播放线路（这就是「大师兄影视」的源）
///
/// `vod_play_from` 与 `vod_play_url` 都用 `$$$` 分隔线路，顺序一一对应；
/// 每条线路内部再用 `#` 分集，每集形如 `第1集$https://…/index.m3u8`。
///
/// 实测线路质量（不是猜的，逐个 curl 过）：
///   - `bfzym3u8`（暴风）→ HTTP 200，24,005 B 合法 VOD 清单 ✅
///   - `lzm3u8`（量子）  → HTTP 200，96 B 多码率 master ✅
///   - `liangzi`（量子分享）→ 301 → 分享页 HTML，`var main = "…/index.m3u8?sign=…"`，
///     需要二次解析。这类线路**不能直接交给播放器**，否则用户看到的是
///     一个网页源码。见 [MacCmsApiSource.resolveUrl]。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../api.dart';
import '../models.dart';
import 'data_source.dart';
import 'site_http.dart' show kSiteUserAgent;

/// 一条采集接口站的配置。加新站 = 加一份这个，不改任何解析代码。
class MacCmsApiConfig {
  const MacCmsApiConfig({
    required this.id,
    required this.displayName,
    required this.apiUrl,
    required this.categories,
    this.description = '直连采集接口、无弹幕、线路直出 m3u8',
    this.lineNameCn = const <String, String>{},
    this.searchViaPost = false,
    this.preferDirectLine = true,
    this.listNeedsDetail = false,
  });

  final String id;
  final String displayName;

  /// 形如 `https://bfzyapi.com/api.php/provide/vod/`，**必须带结尾斜杠**，
  /// 否则 `Dio` 拼 query 时会把最后一个路径段当文件名吃掉。
  final String apiUrl;

  final List<SourceCategory> categories;

  /// 设置页的一句话说明（[DataSource.description] 必填）
  final String description;

  /// `vod_play_from` 的英文标识 → 面板上给人看的名字。
  ///
  /// 不配也能跑（直接显示 `bfzym3u8`），但线路面板是全 App 最需要
  /// 一眼看懂的地方，`bfzym3u8` 对用户没有任何信息量。
  final Map<String, String> lineNameCn;

  /// 搜索是否改用 POST 表单提交。
  ///
  /// 樱花资源（apiyhzy）实测：`?ac=list&wd=关键词` 一律 **403 Forbidden**，
  /// 由 nginx 直接拦掉（响应 546 字节的 403 页，连 PHP 都没进）。
  /// 换 UA / Referer / Accept / Origin / 手机 UA 全部无效，
  /// 但同一个 `ac` + `wd` 用 **POST 表单**发出去就能正常返回 JSON。
  ///
  /// 所以这不是反爬策略差异，而是该站把 GET 的 `wd` 参数屏蔽了。
  /// 默认走 GET（大多数站都是 GET，且 GET 可被缓存），个别站按需打开。
  final bool searchViaPost;

  /// 是否把「直出 m3u8」的线路排到面板最前面。
  ///
  /// 实测（2026-11-13，走马上任）几乎所有采集站在第一部剧上都会给
  /// **两条线路**：
  ///   1. 第一条是**网页分享页**（`feifan` / `dytt` / `gsyun`），
  ///      地址形如 `…/share/<md5>`，返回的是 HTML；
  ///   2. 第二条才是直出 m3u8（`ffm3u8` / `dyttm3u8` / `gsm3u8`）。
  ///
  /// 其中非凡、电影天堂的分享页里连 m3u8 都抠不出来（要靠 JS 渲染），
  /// 播放器默认选第一条 → 必然失败。用户看到的现象就是
  /// 「点进去播放没出来」。
  ///
  /// 打开这个开关后，[ApiLine] 会按「地址里是否含 .m3u8/.mp4」重排，
  /// 直出的沉到前面。网页线路仍保留在后面（少数能靠
  /// [extractShareMainUrl] 二次解析出来，不能直接丢掉）。
  final bool preferDirectLine;

  /// 列表接口是否改用 `ac=detail` 来取（为了拿到封面）。
  ///
  /// ## 为什么需要这个开关（2026-11-13 逐站实测）
  ///
  /// MacCMS 采集站的 `ac=list` 有两种实现，差别很大：
  ///
  /// | 站 | `ac=list` 字段数 | 带 `vod_pic` |
  /// | --- | --- | --- |
  /// | 暴风 / 量子 | 19 | **20/20** ✅ |
  /// | 电影天堂 / 光速 / 非凡 / 猫眼 | 8~9 | **0/20** ❌ |
  ///
  /// 后四站把 `ac=list` 精简成了「只要够画列表就行」的字段集，
  /// 连封面都砍了。这不是我们解析漏了 —— [_drama] 一直在读 `it['vod_pic']`，
  /// 是服务端根本没下发。用户看到的就是一片灰底占位图。
  ///
  /// ## 为什么不是「按条拉详情补封面」
  ///
  /// 直觉做法是「列表出 20 条 → 并发拉 20 次 detail 拿封面」。实测否掉：
  /// 单条 detail 就有几十到上百 KB（电影天堂 3 个 id 就 144 KB），
  /// 20 条并发等于 **~500 KB + 20 个连接**，比一条整页请求还贵。
  ///
  /// ## 打开这个开关的真实代价（实测，不是估计）
  ///
  /// | 站 | `ac=list` | `ac=detail` | 涨幅 |
  /// | --- | --- | --- | --- |
  /// | 光速资源 | 7.1 KB | 104.4 KB | 15× |
  /// | 非凡资源 | 6.0 KB | 261.9 KB | 44× |
  /// | 猫眼资源 | 9.3 KB | 292.5 KB | 31× |
  /// | 电影天堂 | 6.0 KB | 459.1 KB | 77× |
  ///
  /// 涨得凶是因为 `vod_play_url`（全剧分集地址）占了 detail 体积的
  /// **86%~97%**（电影天堂实测 428 K / 441 K），而列表页一条都用不上。
  /// 也试过用 `fields=vod_id,vod_pic` 裁字段 —— **服务端不认**，
  /// 仍返回 83 字段、504.9 KB。
  ///
  /// 所以这是个明确的权衡：**用流量换封面**。默认关闭，
  /// 只在「列表确实没封面」的站上单独打开。翻页语义已实测一致
  /// （`ac=detail&pg=2` 的首条与 `ac=list&pg=2` 相同），不会错位。
  final bool listNeedsDetail;
}

/// 一条采集线路的原始三元组（纯数据，方便离线测试）。
class ApiLine {
  const ApiLine({required this.flag, required this.name, required this.eps});
  final String flag;
  final String name;
  final List<ApiEpisode> eps;
}

class ApiEpisode {
  const ApiEpisode({required this.title, required this.url});
  final String title;
  final String url;
}

/// 把采集接口的 `vod_play_from` + `vod_play_url` 拆成结构化线路。
///
/// 抽成顶层纯函数是为了能用真实报文写离线回归测试——这段解析如果
/// 出错，现象是「详情页能打开但一集都没有」，很难在联网测试里定位。
///
/// 报文形态（实测）：
///   from: `bfzym3u8$$$lzm3u8`
///   url : `第1集$https://…/a.m3u8#第2集$https://…/b.m3u8$$$第01集$https://…/c.m3u8`
///
/// 三个坑：
///   1. `$$$` 是线路分隔符，`#` 才是分集分隔符，**不能反**；
///   2. 集名与地址之间是单个 `$`，但地址本身可能含 `$`（罕见），
///      所以只取**第一个** `$` 切分；
///   3. 少数站只给裸地址不带集名，此时按序号补 `第N集`。
List<ApiLine> parseApiLines(
  String playFrom,
  String playUrl, {
  Map<String, String> nameCn = const <String, String>{},
}) {
  final froms = playFrom.split(r'$$$');
  final groups = playUrl.split(r'$$$');
  final out = <ApiLine>[];

  for (var i = 0; i < groups.length; i++) {
    final group = groups[i].trim();
    if (group.isEmpty) continue;
    final flag = i < froms.length ? froms[i].trim() : '';
    final cn = nameCn[flag] ?? (flag.isEmpty ? '线路${i + 1}' : flag);

    final eps = <ApiEpisode>[];
    for (final raw in group.split('#')) {
      final seg = raw.trim();
      if (seg.isEmpty) continue;
      final idx = seg.indexOf(r'$');
      var title = idx > 0 ? seg.substring(0, idx).trim() : '';
      final url = idx > 0 ? seg.substring(idx + 1).trim() : seg;
      if (url.isEmpty) continue;
      if (title.isEmpty) title = '第${eps.length + 1}集';
      eps.add(ApiEpisode(title: title, url: url));
    }
    if (eps.isEmpty) continue;
    out.add(ApiLine(flag: flag.isEmpty ? 'line$i' : flag, name: cn, eps: eps));
  }
  return out;
}

/// 从「分享页」HTML 里抠出真实播放地址。
///
/// 量子源 `liangzi` 线路给的是 `https://v.cdnlz18.com/share/<md5>`，
/// 直接请求会 301 到一个 HTML 播放页，地址写在页面脚本里：
///   `var main = "/20240727/14879_e529730a/index.m3u8?sign=680726d…";`
///
/// 这个地址带 `sign` 签名，**有时效**，不能缓存，每次播放都要现解析。
/// 页面自己的 `private` 变量名也可能变，所以只认 `var main`，其余不管。
String? extractShareMainUrl(String html, String pageUrl) {
  final m = RegExp(r'''var\s+main\s*=\s*["']([^"']+)["']''').firstMatch(html);
  final raw = m?.group(1)?.trim() ?? '';
  if (raw.isEmpty) return null;
  final abs = Uri.tryParse(pageUrl)?.resolve(raw).toString() ?? raw;
  final lower = abs.toLowerCase();
  if (!lower.contains('.m3u8') && !lower.contains('.mp4')) return null;
  return abs;
}

/// 把「直出 m3u8 / mp4」的线路排到最前，网页分享页线路保持原相对顺序沉到后面。
///
/// ## 为什么必须重排（2026-11-13 实测，走马上任）
///
/// 主流采集站给同一部剧常同时下发两条线路，**第一条往往是网页分享页**：
///
/// | 站       | 第 1 条（网页）                              | 第 2 条（直出）            |
/// | -------- | -------------------------------------------- | -------------------------- |
/// | 光速     | `v.gsuus.com/play/elYvnEra`                  | `…/play/elYvnEra/index.m3u8` |
/// | 非凡     | `super.ffzy-online6.com/share/3df77411…`     | `…/20261102/44636_3df77411/index.m3u8` |
/// | 电影天堂 | `vip.dytt-tvs.com/share/0be68b6b40bb…`       | `…/20261102/43673_0be68b6b/index.m3u8` |
///
/// 播放器默认取第一条。光速那条分享页还能靠 [extractShareMainUrl] 抠出
/// 地址，**非凡和电影天堂的分享页里一个 m3u8 都找不到**（靠 JS 渲染），
/// 于是必然失败——用户看到的就是「点进去播放没出来」。
///
/// 这里不能简单 `sort`（Dart 的 sort 不保证稳定，会打乱同组线路的原有
/// 次序，而原有次序是站方按质量排的）。改用「两趟收集」保序分区。
List<ApiLine> sortDirectLinesFirst(List<ApiLine> lines) {
  if (lines.length < 2) return lines;

  bool isDirect(ApiLine l) {
    if (l.eps.isEmpty) return false;
    final u = l.eps.first.url.toLowerCase();
    return u.contains('.m3u8') || u.contains('.mp4');
  }

  final direct = <ApiLine>[];
  final web = <ApiLine>[];
  for (final l in lines) {
    // 直不直出按「首集地址」判断：同一线路内各集形态一致，
    // 抽查首集足够，也避免为了判断去遍历几千集。
    (isDirect(l) ? direct : web).add(l);
  }
  // 全是网页线路时保持原样，不要把顺序洗一遍却没带来任何好处
  if (direct.isEmpty) return lines;
  return <ApiLine>[...direct, ...web];
}

class MacCmsApiSource implements DataSource {
  MacCmsApiSource(this.cfg);

  final MacCmsApiConfig cfg;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.json,
      validateStatus: (_) => true,
      headers: {
        'User-Agent': kSiteUserAgent,
        'Accept': 'application/json, text/plain, */*',
      },
    ),
  );

  @override
  String get id => cfg.id;

  @override
  String get displayName => cfg.displayName;

  @override
  String get description => cfg.description;

  @override
  List<SourceCategory> get categories => cfg.categories;

  @override
  bool get supportsDanmaku => false;

  /// 采集接口的线路顺序是站方按清晰度/稳定性排好的，保持原样即可。
  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  /// 构造列表请求参数。`ac` 由 [MacCmsApiConfig.listNeedsDetail] 决定。
  ///
  /// 抽成一个方法而不是每处手写 `'ac': 'list'`：现在有 4 个调用点
  /// （搜索、推荐、单分类、多分类并发），漏掉任何一个的表现都是
  /// 「这个入口的封面又没了」，极难发现。只留一个出口就不会漏。
  Map<String, dynamic> _listQuery(int page, {String? typeId, String? keyword}) {
    final q = <String, dynamic>{
      // 用 detail 只是为了拿 vod_pic。翻页语义已实测与 list 一致
      // （`ac=detail&pg=2` 首条 == `ac=list&pg=2` 首条），不会错位。
      'ac': cfg.listNeedsDetail ? 'detail' : 'list',
      'pg': page,
    };
    if (typeId != null && typeId.isNotEmpty) q['t'] = typeId;
    if (keyword != null && keyword.isNotEmpty) q['wd'] = keyword;
    return q;
  }

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    final k = keyword.trim();
    final q = _listQuery(page, keyword: k);
    // 带关键词搜索且该站屏蔽了 GET 的 wd 参数时，改走 POST 表单。
    // 只有「真在搜索」才需要：空关键词（推荐位）走 GET 一直是好的。
    if (cfg.searchViaPost && k.isNotEmpty) {
      return _cards(await _post(q));
    }
    return _cards(await _get(q));
  }

  /// 分类列表。`categoryId` 支持「逗号串 = 多分类合并」。
  ///
  /// ## 为什么要支持逗号串（2026-11-13 实测结论，踩过坑）
  ///
  /// 采集接口的父分类（`1` 电影 / `2` 电视剧 / `3` 综艺 / `4` 动漫）
  /// 在 `ac=list` 下**恒返回 0 条**，数据全挂在子分类上
  /// （`6` 动作片、`13` 国产剧…）。暴风源早就踩过：父分类实测只有 14 / 7 条。
  ///
  /// 一开始我以为接口的 `t` 参数能像 MacCMS 后台那样用逗号聚合，
  /// 实测**不行**：`t=6,7` 与 `t=6` 的 `total` 完全一致（都是 5705），
  /// 返回条目的 `type_id` 分布里只有 `6`。也就是说逗号后面全被忽略，
  /// 只取第一个 id。所以聚合只能在客户端做。
  ///
  /// 这里的做法：按逗号拆开，**并发**拉每个子分类的第 [page] 页，
  /// 再交错合并（round-robin，保证第一屏不会全是同一个子分类）。
  /// 翻页语义天然正确——每个子分类都取同一页码，不会重复也不会漏。
  ///
  /// 去重按 `Drama.id`：少数站会跨分类重复收录同一部片
  /// （比如「动作片」和「剧情片」都收了同一部），不按 id 去重在
  /// 列表里会看到两张一模一样的卡。
  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    final ids = categoryId
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    if (ids.isEmpty) {
      return _cards(await _get(_listQuery(page)));
    }
    if (ids.length == 1) {
      return _cards(await _get(_listQuery(page, typeId: ids.first)));
    }

    // 单个子分类失败不能拖垮整个栏目：某条分类临时挂了，
    // 其余分类照常出内容，总比整页报错强。
    final groups = await Future.wait(ids.map((id) async {
      try {
        final d = await _get(_listQuery(page, typeId: id));
        return _cards(d);
      } catch (_) {
        return const <Drama>[];
      }
    }));

    // 全部子分类都失败才报错，让界面给出可重试的提示
    if (groups.every((g) => g.isEmpty) && page == 1) {
      throw ApiException(-1, '${cfg.displayName} 暂时取不到内容，请稍后重试');
    }
    return _interleave(groups);
  }

  /// 交错合并多组条目并去重。
  ///
  /// 不直接 `addAll`：第一个子分类往往有上千条，直接拼会让前几屏
  /// 全是同一类（比如点「电影」连翻三屏都是动作片）。交错后
  /// 每一屏都是混合的，更接近「电影院线」的观感。
  List<Drama> _interleave(List<List<Drama>> groups) {
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
    final d = await _get(<String, dynamic>{'ac': 'detail', 'ids': dramaId});
    final list = _list(d);
    if (list.isEmpty) {
      throw ApiException(404, '该影片在源站已下架，换源试试');
    }
    return _detail(dramaId, list.first);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    final p = video.path.trim();
    if (p.isEmpty || !p.startsWith('http')) {
      throw ApiException(200, '该线路没有下发播放地址，请切换其它线路');
    }
    final lower = p.toLowerCase();
    // 绝大多数线路（bfzym3u8 / lzm3u8 / 各类直链）到这一步就能直接播
    if (lower.contains('.m3u8') || lower.contains('.mp4')) return p;

    // 剩下的是「分享页」线路：URL 指向一个 HTML 播放页，
    // 真正的地址写在页面里的 `var main = "/xxx/index.m3u8?sign=…"`。
    // 直接把 HTML 地址丢给播放器只会 UnrecognizedInputFormat。
    final html = await _getText(p);
    final abs = extractShareMainUrl(html, p);
    if (abs == null) {
      throw ApiException(
        200,
        '「${video.sourceCn.isEmpty ? video.source : video.sourceCn}」解析不出播放地址，'
        '请在上方切到其它线路',
      );
    }
    return abs;
  }

  // ---------------- 请求 ----------------

  /// 带退避重试的 JSON 请求。采集站偶发 5xx / 限流，重试一次通常就好；
  /// 4xx（参数错、下架）重试无意义，直接抛给界面。
  ///
  /// 必须有**总期限**：Dio 的 12s 连接 + 20s 接收叠 3 次重试最坏 96s，
  /// 而界面的 `.timeout()` 只让页面不再等、并不会取消这次请求，它照样
  /// 占着连接池。反复换集/重刷时挂起的请求越积越多，连接池占满后新请求
  /// 只能排队，表现就是「一直转圈、杀掉重开就好」。
  Future<Map<String, dynamic>> _get(Map<String, dynamic> query) async {
    const total = Duration(seconds: 18);
    final deadline = DateTime.now().add(total);
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      }
      // 每次尝试独立一个 token：共用一个的话，第一次 cancel 之后
      // 后面几轮请求会被 dio 直接拒掉，重试等于失效。
      final token = CancelToken();
      try {
        final remain = deadline.difference(DateTime.now());
        if (remain <= Duration.zero) break;
        final r = await _dio
            .get(cfg.apiUrl,
                queryParameters: query, cancelToken: token)
            .timeout(remain);
        final code = r.statusCode ?? -1;
        if (code != 200) {
          throw ApiException(code, '采集接口返回 HTTP $code');
        }
        final data = r.data;
        if (data is Map<String, dynamic>) return data;
        if (data is String && data.isNotEmpty) {
          final dec = jsonDecode(data);
          if (dec is Map<String, dynamic>) return dec;
        }
        throw ApiException(-1, '采集接口返回格式异常');
      } on ApiException catch (e) {
        last = e;
        if (e.code >= 500 || e.code == -1) continue;
        rethrow;
      } catch (e) {
        // ★ 关键：`.timeout()` 只让这里不再等，底层请求和 socket 还活着。
        // 不 cancel 的话每次失败都留一条僵尸连接，反复换集/重刷会把它
        // 攒满，最后表现成「连不上、重启才好」。
        if (!token.isCancelled) token.cancel('attempt ${attempt + 1} aborted: $e');
        // 超时 / 连接被重置 / JSON 截断，都还有重试价值
        last = e;
      }
    }
    if (last is ApiException) throw last;
    if (last is TimeoutException) {
      throw ApiException(-1, '采集接口 ${total.inSeconds} 秒无响应，请稍后重试');
    }
    throw ApiException(-1, '采集接口暂时不可用，请稍后重试');
  }

  /// POST 表单方式请求（[MacCmsApiConfig.searchViaPost] 专用）。
  ///
  /// 樱花资源把 GET 的 `wd` 参数在 nginx 层就拦成 403，但同样的
  /// `ac` + `wd` 用 POST 表单发出去能正常返回 JSON。这里刻意**不**做成
  /// 「GET 失败再退 POST」：403 是确定性的，退一次只是多等一个来回，
  /// 弱网下用户感知明显。由配置显式声明更干净。
  ///
  /// 重试与总期限逻辑和 [_get] 保持一致，避免出现「POST 路径没有
  /// 僵尸连接保护」这种只有某个源才会踩的坑。
  Future<Map<String, dynamic>> _post(Map<String, dynamic> form) async {
    const total = Duration(seconds: 18);
    final deadline = DateTime.now().add(total);
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      }
      final token = CancelToken();
      try {
        final remain = deadline.difference(DateTime.now());
        if (remain <= Duration.zero) break;
        final r = await _dio
            .post(
              cfg.apiUrl,
              data: form,
              // MacCMS 的 POST 分支读的是表单字段，不是 JSON body。
              // 不显式指定会用 dio 默认的 JSON 序列化，服务端收不到 wd。
              options: Options(contentType: Headers.formUrlEncodedContentType),
              cancelToken: token,
            )
            .timeout(remain);
        final code = r.statusCode ?? -1;
        if (code != 200) {
          throw ApiException(code, '采集接口返回 HTTP $code');
        }
        final data = r.data;
        if (data is Map<String, dynamic>) return data;
        if (data is String && data.isNotEmpty) {
          final dec = jsonDecode(data);
          if (dec is Map<String, dynamic>) return dec;
        }
        throw ApiException(-1, '采集接口返回格式异常');
      } on ApiException catch (e) {
        last = e;
        if (e.code >= 500 || e.code == -1) continue;
        rethrow;
      } catch (e) {
        if (!token.isCancelled) token.cancel('attempt ${attempt + 1} aborted: $e');
        last = e;
      }
    }
    if (last is ApiException) throw last;
    if (last is TimeoutException) {
      throw ApiException(-1, '采集接口 ${total.inSeconds} 秒无响应，请稍后重试');
    }
    throw ApiException(-1, '采集接口暂时不可用，请稍后重试');
  }

  Future<String> _getText(String url) async {
    try {
      final r = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final code = r.statusCode ?? -1;
      if (code != 200) throw ApiException(code, '页面返回 HTTP $code');
      return r.data ?? '';
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(-1, '无法打开线路播放页（${e.runtimeType}）');
    }
  }

  List<Map<String, dynamic>> _list(Map<String, dynamic> d) {
    final raw = d['list'];
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  // ---------------- 解析 ----------------

  List<Drama> _cards(Map<String, dynamic> d) {
    final out = <Drama>[];
    for (final it in _list(d)) {
      final name = _str(it['vod_name']);
      if (name.isEmpty) continue;
      out.add(_drama(it, name));
    }
    return out;
  }

  Drama _drama(Map<String, dynamic> it, String name) => Drama(
        id: _str(it['vod_id']),
        name: name,
        area: _str(it['vod_area']),
        brief: stripHtml(_str(it['vod_blurb']).isEmpty
            ? _str(it['vod_content'])
            : _str(it['vod_blurb'])),
        stars: double.tryParse(_str(it['vod_score'])) ?? 0,
        director: _str(it['vod_director']),
        actor: _str(it['vod_actor']),
        remark: _str(it['vod_remarks']),
        year: int.tryParse(_str(it['vod_year'])) ?? 0,
        cover: CoverImage(path: _str(it['vod_pic'])),
        sourceId: cfg.id,
      );

  DramaDetail _detail(String dramaId, Map<String, dynamic> it) {
    final name = _str(it['vod_name']);
    var lines = parseApiLines(
      _str(it['vod_play_from']),
      _str(it['vod_play_url']),
      nameCn: cfg.lineNameCn,
    );
    // 直出 m3u8 的线路沉不到前面时，用户默认点第一条会撞上「分享页」
    // （HTML），非凡 / 电影天堂的分享页连 m3u8 都抠不出来 → 播放必失败。
    if (cfg.preferDirectLine) lines = sortDirectLinesFirst(lines);

    final videos = <DramaVideo>[];
    for (final line in lines) {
      for (var e = 0; e < line.eps.length; e++) {
        final ep = line.eps[e];
        videos.add(DramaVideo(
          id: '${cfg.id}_${dramaId}_${line.flag}_${e + 1}',
          title: ep.title,
          path: ep.url,
          source: line.flag,
          sourceCn: line.name,
          episode: e + 1,
          dramaId: dramaId,
        ));
      }
    }

    return DramaDetail(
      id: dramaId,
      name: name.isEmpty ? dramaId : name,
      area: _str(it['vod_area']),
      brief: stripHtml(_str(it['vod_blurb'])),
      intro: stripHtml(_str(it['vod_content'])),
      director: _str(it['vod_director']),
      actor: _str(it['vod_actor']),
      remark: _str(it['vod_remarks']),
      tag: _str(it['vod_class']),
      year: int.tryParse(_str(it['vod_year'])) ?? 0,
      hits: int.tryParse(_str(it['vod_hits'])) ?? 0,
      isEnd: _str(it['vod_isend']) == '1',
      stars: double.tryParse(_str(it['vod_score'])) ?? 0,
      cover: CoverImage(path: _str(it['vod_pic'])),
      videos: videos,
      sourceId: cfg.id,
    );
  }

  /// 采集接口的字段类型不统一：`vod_id` 是 int，`vod_year` 有时是
  /// 空串、有时是 int，`vod_score` 是字符串小数。统一走这里，
  /// 免得每个字段各写一遍 `?? ''` 还在空值上崩。
  String _str(Object? v) {
    if (v == null) return '';
    if (v is String) return v.trim();
    return v.toString();
  }
}