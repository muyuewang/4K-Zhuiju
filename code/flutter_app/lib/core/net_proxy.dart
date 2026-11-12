/// 让 App 跟随 Windows 系统代理（Clash / v2rayN 之类）。
///
/// ## 为什么必须有这个文件
///
/// Dart 的 `HttpClient` **完全不读系统代理设置**，永远直连。浏览器读，
/// 所以同一个站点会出现「网页版正常、App 里打不开」这种极其迷惑的现象。
///
/// 实测（2026-11-12，同一台机器、同一时刻）：
///
/// | 目标 | 直连 | 经 127.0.0.1:7897 |
/// | --- | --- | --- |
/// | `p.bfvp26.com`（暴风封面 CDN） | TLS 握手中断 | 200 / 21,780B |
/// | `www.keke1.app`（可可影视） | TCP 连接超时 | 850 挑战（正常准入） |
/// | `bfzyapi.com`（暴风接口） | 200 | 200 |
/// | `4k01.pianku.online`（片库） | 200 | 200 |
///
/// 前两个正是用户报的「封面加载不出来」「列表也加载不出来，网页版却正常」。
///
/// ## 为什么用 HttpOverrides 而不是逐个改 Dio
///
/// 全 App 的 HTTP 出口很分散：8 个 Dio 实例、`SiteHttp` 里裸的 `HttpClient`
/// （准入 PoW 必须复用同一条 keep-alive 连接，不能换成 Dio）、`HlsProxy`
/// 的转发、`cached_network_image` 内部的 `package:http`，还有 `video_player`。
/// 逐个注入代理既容易漏，也会在以后新增请求点时再漏一次。
///
/// `HttpOverrides.global` 卡在 `HttpClient()` 工厂这一层，**所有**走 dart:io
/// 的请求都自动带上 `findProxy`，包括第三方包内部 new 出来的。一个注入点，
/// 全覆盖。
///
/// ## 为什么一定要做存活探测
///
/// 注册表里 `ProxyEnable=1` 是 Clash 开的，但 Clash 退出后这个值**不会被
/// 清掉**。如果无条件按注册表走代理，用户一关代理软件，整个 App 就全废了
/// ——这比不读代理更糟。所以真用之前先 TCP 探一下端口，探不通就当没配。
library;

import 'dart:io';

/// 系统代理探测结果，进程内缓存。
///
/// [findProxyFor] 是同步回调（`HttpClient.findProxy` 的签名不允许 await），
/// 所以真实探测放在 [refresh] 里异步做，回调只读缓存好的结果。
class NetProxy {
  NetProxy._();

  /// 代理是否真的可用（注册表开着 **且** 端口探通）。
  static bool _active = false;

  /// 探测到的代理主机:端口，仅用于日志和 UI 提示。
  static String _server = '';

  static DateTime _probedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 缓存有效期。代理开关是用户随时可能动的，不能永久缓存；
  /// 但也不能每个请求都 reg query + TCP 探测，30 秒是折中。
  static const Duration _ttl = Duration(seconds: 30);

  static Future<void>? _pending;

  /// 当前是否走代理
  static bool get active => _active;

  /// 当前代理地址（未启用时为空串），供「技术信息」面板显示
  static String get server => _server;

  /// 日志用的可读状态
  static String get statusLabel =>
      _active ? '经系统代理 $_server' : '直连（未使用代理）';

  /// 装到 dart:io 的工厂上。必须在任何 HTTP 请求发生前调用一次。
  static void install() {
    HttpOverrides.global = _ProxyOverrides();
  }

  /// 判定本次请求该不该走代理。
  ///
  /// **本机/内网必须直连**：`HlsProxy` 自己监听 `127.0.0.1:<随机端口>`，
  /// 播放器来拉清单时如果被塞进代理，就会变成「代理去连代理」——
  /// 直接死循环或者 502，整个 HLS 播放全挂。这条不是优化，是正确性。
  static String findProxyFor(Uri uri) {
    if (!_active) return 'DIRECT';
    if (_bypass(uri.host)) return 'DIRECT';
    return 'PROXY $_server';
  }

  static bool _bypass(String host) {
    if (host.isEmpty) return true;
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h.endsWith('.local')) return true;
    if (h.startsWith('127.')) return true;
    if (h.startsWith('10.')) return true;
    if (h.startsWith('192.168.')) return true;
    // 172.16.0.0/12
    if (h.startsWith('172.')) {
      final second = int.tryParse(h.split('.').elementAt(1));
      if (second != null && second >= 16 && second <= 31) return true;
    }
    return false;
  }

  /// 重新探测。并发调用会合并成一次。
  ///
  /// [force] 为 true 时忽略 TTL（用户手动点「重新检测」时用）。
  static Future<void> refresh({bool force = false}) {
    if (!force &&
        _probedAt != DateTime.fromMillisecondsSinceEpoch(0) &&
        DateTime.now().difference(_probedAt) < _ttl) {
      return Future<void>.value();
    }
    return _pending ??= _probe().whenComplete(() => _pending = null);
  }

  static Future<void> _probe() async {
    _probedAt = DateTime.now();
    try {
      // 环境变量优先：调试时想临时改走哪个代理不用动注册表
      final env = Platform.environment['ZJ_PROXY']?.trim();
      if (env != null && env.isNotEmpty) {
        if (env.toLowerCase() == 'direct' || env.toLowerCase() == 'none') {
          _setOff();
          return;
        }
        await _tryServer(env);
        return;
      }
      if (!Platform.isWindows) {
        // Android / iOS 拿不到系统代理（Dart 没有对应 API），保持直连
        _setOff();
        return;
      }
      final server = await _readWindowsProxyServer();
      if (server != null && server.isNotEmpty) {
        await _tryServer(server);
        return;
      }
      // 读不到注册表（reg.exe 被安全软件/组策略拦掉，或键值缺失）时
      // 退一步：探一遍常见本地代理端口。这个兜底很值得：
      // 用户报「网页版正常、App 空白」的机器，多半正是那些装了
      // 安全加固、外部进程跑不起来的机器，只靠注册表会全军覆没。
      await _probeCommonPorts();
    } catch (_) {
      // 探测本身出任何问题都退回直连：宁可走直连，也不能让 App 卡住
      _setOff();
    }
  }

  /// 本机常见代理端口，按流行程度排。
  ///
  /// 只探 **127.0.0.1**，不扫局域网：这是「用户自己开的代理软件」的
  /// 典型形态，扫内网既慢又像是嗅探行为，本项目不做。
  ///
  /// 刻意**不含 8080 / 1080**：这两个端口被本地开发服务器、Tomcat、
  /// 各种调试工具占用的概率远高于代理软件。如果把它们放进候选，
  /// 兜底逻辑就可能把全 App 流量导到一个静态服务器上——那比不设代理
  /// 还糟（所有请求变 404，看起来像「全网都挂了」）。
  /// 宁可少认几个代理软件，也不能误伤。
  static const List<int> _commonProxyPorts = <int>[
    7897, // Clash Verge / Clash for Windows 默认混合端口
    7890, // Clash 经典 http 端口
    10809, // v2rayN 默认 http
    10808, // v2rayN 默认 socks（部分版本同时监听 http）
    7891, // Clash socks
    20171, // Shadowsocks-windows 常见
  ];

  /// 探一遍常见端口，第一个**确认是代理**的就采用。
  ///
  /// 并行探而不是串行：串行最坏要 6 × 300ms。并行总耗时约 300ms。
  ///
  /// 「端口开着」不等于「这是代理」——必须再验一次协议。
  static Future<void> _probeCommonPorts() async {
    final open = await Future.wait(
      _commonProxyPorts.map((p) async {
        Socket? s;
        try {
          s = await Socket.connect('127.0.0.1', p,
              timeout: const Duration(milliseconds: 300));
          return p;
        } catch (_) {
          return -1;
        } finally {
          s?.destroy();
        }
      }),
    );
    for (final p in open) {
      if (p <= 0) continue;
      if (await _looksLikeHttpProxy(p)) {
        _active = true;
        _server = '127.0.0.1:$p';
        return;
      }
    }
    _setOff();
  }

  /// 用 CONNECT 探测这个端口是不是 HTTP 代理。
  ///
  /// 为什么用 `CONNECT 127.0.0.1:1`：目标端口故意选一个必然没人监听的，
  /// 这样**不需要任何外网**就能完成判断：
  ///   - 是 HTTP 代理 → 会尝试建隧道、失败后回 `HTTP/1.1 502 …`
  ///     （个别代理对本地目标回 403，同样是 HTTP 响应行，一样认）
  ///   - 是普通 web 服务器 → 不认 CONNECT 方法，回 400/405 或直接断开
  ///   - 是别的协议（socks / 反向代理控制端口）→ 不回 HTTP 响应行
  ///
  /// 只要拿到以 `HTTP/` 开头的状态行就认定是 HTTP 代理。
  /// 判断宁可保守：认错会把全 App 流量导错，不认只是退回直连。
  static Future<bool> _looksLikeHttpProxy(int port) async {
    Socket? s;
    try {
      s = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 250));
      s.write('CONNECT 127.0.0.1:1 HTTP/1.1\r\n'
          'Host: 127.0.0.1:1\r\n'
          'User-Agent: zhuiju\r\n\r\n');
      final buf = <int>[];
      await for (final chunk
          in s.timeout(const Duration(milliseconds: 500))) {
        buf.addAll(chunk);
        // 只要状态行就够判断，不必读完整个响应
        if (buf.length >= 12) break;
      }
      return String.fromCharCodes(buf).startsWith('HTTP/');
    } catch (_) {
      return false;
    } finally {
      s?.destroy();
    }
  }

  static void _setOff() {
    _active = false;
    _server = '';
  }

  /// TCP 探一下代理端口。探得通才认为代理可用。
  ///
  /// 300ms 上限：本机回环端口要么秒连上，要么根本没在听。
  static Future<void> _tryServer(String server) async {
    final idx = server.lastIndexOf(':');
    final host = idx > 0 ? server.substring(0, idx) : server;
    final port = idx > 0 ? int.tryParse(server.substring(idx + 1)) : null;
    if (port == null) {
      _setOff();
      return;
    }
    Socket? s;
    try {
      s = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 300));
      _active = true;
      _server = '$host:$port';
    } catch (_) {
      // 注册表说开着、端口没人听 → 代理软件已退出，按直连处理
      _setOff();
    } finally {
      s?.destroy();
    }
  }

  /// 从注册表读代理地址。未启用时返回 null。
  ///
  /// [regRunner] 可注入，方便离线测试；默认走 `reg query`。
  static Future<String?> _readWindowsProxyServer({
    Future<ProcessResult?> Function(List<String> args)? regRunner,
  }) async {
    // 用 Process.run 而不是 runSync：`reg` 是外部进程，runSync 会把
    // UI 线程卡住几十毫秒，首屏缓存未命中时这个开销会连着吃好几次。
    final run = regRunner ?? _defaultRegRunner;

    final enable = await _queryValue('ProxyEnable', run);
    if (enable == null) return null;
    final on = enable.startsWith('0x')
        ? int.tryParse(enable.substring(2), radix: 16) == 1
        : enable.trim() == '1';
    if (!on) return null;

    final raw = await _queryValue('ProxyServer', run);
    return parseProxyServer(raw);
  }

  static Future<ProcessResult?> _defaultRegRunner(List<String> args) async {
    try {
      return await Process.run('reg', args, runInShell: false);
    } catch (_) {
      // 被安全软件/组策略禁用时 Process.run 可能直接抛，交给上层降级
      return null;
    }
  }

  static Future<String?> _queryValue(
    String name,
    Future<ProcessResult?> Function(List<String>) run,
  ) async {
    final r = await run([
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      '/v',
      name,
    ]);
    if (r == null || r.exitCode != 0) return null;
    final text = r.stdout.toString();
    // 形如：`    ProxyEnable    REG_DWORD    0x1`
    final m = RegExp('$name\\s+REG_\\w+\\s+(.+)').firstMatch(text);
    return m?.group(1)?.trim();
  }

  /// 把注册表里的 `ProxyServer` 原文解析成 `host:port`。拿不到就返回 null。
  ///
  /// 两种写法都要认（抽成纯函数是为了能离线回归，不用真去跑 reg）：
  ///   `127.0.0.1:7897`                              ← 最常见
  ///   `http=127.0.0.1:7897;https=127.0.0.1:7897`    ← 分组写法
  static String? parseProxyServer(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('=')) {
      return s.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    }
    // 分组写法：优先 https（本项目的源站几乎全是 https），其次 http
    final map = <String, String>{};
    for (final part in s.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      map[part.substring(0, i).trim().toLowerCase()] =
          part.substring(i + 1).trim();
    }
    final vals = map.values.where((v) => v.isNotEmpty);
    final pick =
        map['https'] ?? map['http'] ?? (vals.isEmpty ? null : vals.first);
    if (pick == null || pick.isEmpty) return null;
    return pick.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
  }
}

/// 全局覆盖：给每个新建的 HttpClient 挂上 findProxy。
class _ProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = NetProxy.findProxyFor;
    return client;
  }
}