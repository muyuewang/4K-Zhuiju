/// 插件网络层的轻量 Cookie 会话（按 host 隔离，纯内存）。
///
/// ## 为什么需要这一层
///
/// 有一类站点对**搜索页**做了挑战式软验证：首次请求回 `403` 并下发
/// `Set-Cookie`，带着这个 cookie 再请求一次才是 `200 + 结果`。
/// 剧踪（`www.juzong01.me`）实测就是这样：
///
/// ```
/// 无 cookie         → 403，Set-Cookie: <32位hex>=<32位hex>; server_session=...
/// 带这次下发的 cookie → 200，22 条结果（连测 3 次全成功）
/// 随便编一个 cookie  → 403（服务端认值，不是只认 cookie 名）
/// ```
///
/// 也就是说这既不是图形验证码，也不需要浏览器跑 JS，只是「你得先来一次」。
///
/// ## 为什么这不违反「插件不许碰 Cookie」的规矩
///
/// `plugin_manifest.dart` 对 `Host` / `Cookie` / `Authorization` 做了三重拦截，
/// 那条规矩的目的是**阻止远程下发的脚本注入凭证**。这里由宿主代管、
/// 只把**服务端自己下发的会话值**回送给**同一个 host**，插件全程接触不到，
/// 也无法指定要发哪个值。两者的区别：
///
/// | | 谁产生 | 能不能夹带用户凭证 | 结论 |
/// | --- | --- | --- | --- |
/// | 脚本写 `Cookie: token=…` | 远程脚本 | 能 | 必须拦 |
/// | 服务端 Set-Cookie → 宿主回送 | 目标站点 | 不能 | 可允许 |
///
/// 清单里用 `cookieJar: true` 显式开启，**默认关闭**，
/// 现有源的请求行为一个字节都不会变。
///
/// ## 为什么不落盘
///
/// 会话值只在这几十秒内有用（搜索一次就够），落盘反而多一份要过期、
/// 要清理、可能被备份工具带走的状态。进程退出即丢弃。
library;

/// 单个 host 最多保存多少条 cookie。
///
/// 40 的依据：正常站点一个域名下发 2~5 条。给到 40 是为了容纳
/// 「按 A/B 分组批量下发」的站，同时挡住一个恶意响应塞几千条把内存吃穿。
const int kCookieMaxPerHost = 40;

/// 最多跟踪多少个 host。
///
/// 32 的依据：一个源的请求基本只落在 1~3 个 host（主站 + CDN + 解析站）。
/// 超了按「最久未写入」淘汰，避免长时间运行后无限增长。
const int kCookieMaxHosts = 32;

/// 按 host 隔离的内存 cookie 存储。
class PluginCookieJar {
  PluginCookieJar._();

  /// 全局单例。**必须共享**：挑战 cookie 是在搜索请求之前那次请求下发的，
  /// 每次 new 一个就永远接不上。
  static final PluginCookieJar instance = PluginCookieJar._();

  /// host → (name → value)。
  ///
  /// 用 `LinkedHashMap` 的插入顺序当作 LRU 依据：写入时先 remove 再 put，
  /// 命中最新的就排到末尾，淘汰时删第一个。
  final Map<String, Map<String, String>> _store = <String, Map<String, String>>{};

  /// 给某个 URL 取应该回送的 `Cookie` 头值；没有则返回 null。
  ///
  /// 只按 host 匹配，**不校验 path**。理由：剧踪的挑战 cookie 落在 `Path=/`，
  /// 而我们要请求的 `/vodsearch/...` 与之兼容；真遇到「cookie 限定 path」的
  /// 站点，多带一个 cookie 通常无害，少带却会直接 403。
  String? headerFor(String url) {
    final host = _hostOf(url);
    if (host == null) return null;
    final bag = _store[host];
    if (bag == null || bag.isEmpty) return null;
    final parts = <String>[];
    for (final e in bag.entries) {
      parts.add('${e.key}=${e.value}');
    }
    return parts.join('; ');
  }

  /// 吸收一次响应里的 `Set-Cookie`。
  ///
  /// [setCookie] 是原始的多条 `Set-Cookie` 头（一条一个字符串）。
  /// 只取 `name=value` 部分，丢弃 `Expires` / `Path` / `HttpOnly` 等属性 ——
  /// 我们不做完整的 cookie 语义，只需要「原样带回去」。
  void absorb(String url, List<String>? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return;
    final host = _hostOf(url);
    if (host == null) return;

    for (final raw in setCookie) {
      final one = raw.split(';').first.trim();
      if (one.isEmpty) continue;
      final eq = one.indexOf('=');
      if (eq <= 0) continue;
      final name = one.substring(0, eq).trim();
      final value = one.substring(eq + 1).trim();
      if (name.isEmpty) continue;

      // Max-Age=0 / 空值 = 服务端要求删除这条
      final lower = raw.toLowerCase();
      final expired = lower.contains('max-age=0') || lower.contains('max-age=-');
      if (expired) {
        _bagFor(host, create: false)?.remove(name);
        continue;
      }

      _bagFor(host)![name] = value;
      if (_bagFor(host)!.length > kCookieMaxPerHost) {
        // 超出上限删最早的一条，保证不无限增长
        _bagFor(host)!.remove(_bagFor(host)!.keys.first);
      }
    }
  }

  /// 清掉某个 host 的会话。源站换域名或用户手动刷新源时用得上。
  void clearHost(String url) {
    final host = _hostOf(url);
    if (host != null) _store.remove(host);
  }

  /// 清空全部。测试与「刷新数据源配置」用。
  void clearAll() => _store.clear();

  /// 当前跟踪的 host 数，仅用于测试断言。
  int get hostCount => _store.length;

  /// 某个 host 当前的 cookie 条数，仅用于测试断言。
  int countFor(String url) {
    final host = _hostOf(url);
    if (host == null) return 0;
    return _store[host]?.length ?? 0;
  }

  Map<String, String>? _bagFor(String host, {bool create = true}) {
    var bag = _store[host];
    if (bag == null) {
      if (!create) return null;
      bag = <String, String>{};
      _store[host] = bag;
      // 超过上限淘汰最久未写入的 host
      while (_store.length > kCookieMaxHosts) {
        _store.remove(_store.keys.first);
      }
    } else {
      // 命中即刷新位置（LRU）
      _store.remove(host);
      _store[host] = bag;
    }
    return bag;
  }

  /// 取 host。解析失败返回 null（宁可不带 cookie，也不要抛异常把请求拦掉）。
  static String? _hostOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return null;
    return u.host.toLowerCase();
  }
}