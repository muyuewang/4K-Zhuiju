/// 把系统代理写进**进程环境变量**，让 libmpv 自己走代理。
///
/// ## 为什么需要这个文件（2026-11-13，桌面端播放链路的根本性简化）
///
/// 桌面端原来有一段 m3u8 本地中转（`HlsProxy`）。它存在的唯一理由是：
/// libmpv 走 FFmpeg 自己的网络栈，**不读 Windows 系统代理**，而本项目有
/// 四个源（云影 / 低调影视 / 极速追剧 / 4K影视）必须挂代理才通。
/// 为了让视频流也走代理，只能让 Dart 先发请求再转发给播放器。
///
/// 但这层中转代价极高：它把取流变成**单线程串行**。实测电影天堂
/// 《凡人修仙传》一集（322 个分片、3000k ≈ 375 KB/s）经中转只有
/// 208 KB/s，低于码率就必然缓冲不满、一直转圈。而同一批分片让 FFmpeg
/// 自己并行预读能到 429 KB/s。用户报的「浏览器秒开、雷电模拟器也快、
/// 唯独 PC 版慢还超时」，根子就在这里。
///
/// ## 实测结论（不是推断）
///
/// 用 dart:ffi 直接加载 libmpv-2.dll 问它自己：
///
/// | 做法 | 结果 |
/// | --- | --- |
/// | `mpv_set_option_string("http-proxy", …)` | 返回 0，接受，值能读回 |
/// | `mpv_set_option_string("http_proxy", …)` | 返回 -5，不认（是环境变量名，不是选项名）|
/// | `mpv_set_option_string("no_proxy", …)` | 返回 -5，同样不认 |
/// | `_putenv_s("http_proxy", 假代理)` 后 loadfile | 假代理收到 `CONNECT …:443`，**确实走了代理** |
/// | 再加 `no_proxy=该域名` | 假代理收到 **0 个请求**，排除精确生效 |
///
/// 所以正解是**环境变量**这条路：FFmpeg 的 http 协议在每次打开连接时
/// 读 `getenv("http_proxy")`，运行中改也生效。
///
/// ## `no_proxy` 的匹配语义（三轮实测，含一个必须绕开的坑）
///
/// 这条不能凭常识写，写错的后果是「内网地址被塞进代理」，而且完全静默。
/// 逐条测出来的真实行为：
///
/// | 写法 | 效果 |
/// | --- | --- |
/// | `127.0.0.1` / `localhost` / `::1` | 有效（精确项）|
/// | `probe.invalid` | 有效，且**顺带匹配** `sub.probe.invalid` |
/// | `*.1.2.3` | 有效 —— 星号只做**前缀**通配 |
/// | `10.*` / `192.168.*` / `172.16.*` | **全部无效**（尾星不认）|
/// | `127.*` / `127.0.0.` | **无效** |
/// | `10.0.0.0/8`（CIDR）| **无效** |
/// | `<local>` | **无效** |
///
/// 关键一条：**它按 hostname 字符串比对，不按解析后的 IP**。访问
/// `localhost` 时写 `127.0.0.1` 无效，反之亦然。
///
/// 结论是**IP 段根本没法用 `no_proxy` 表达** —— 一个 `/8` 或 `/16`
/// 不存在任何等价写法。所以 [bypass] 里只放逐字有效的项，而「播放地址
/// 本身就在内网」这种情况改由 Dart 侧提前判掉（[sync] 的 `targetHost`
/// 参数），判定复用 `NetProxy.isBypassed`，全 App 只有一份内网定义。
///
/// ## 为什么必须用 `_putenv_s` 而不是 SetEnvironmentVariableW
///
/// Windows 有两份环境：Win32 进程环境块、以及 UCRT 自己维护的一份。
/// `SetEnvironmentVariableW` 只改前者，而 MSVC 编译出的 `getenv` 读的是
/// 后者（首次调用时拷贝的缓存），两者不会自动同步 —— 改了等于没改。
/// `_putenv_s` 直接动 CRT 那份，正是 FFmpeg 读的地方。
///
/// Dart 侧没有现成 API，所以走 `ucrtbase.dll` 的 FFI。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'net_proxy.dart';

typedef _PutenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PutenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// 环境变量与 libmpv 的桥。
///
/// 只做一件事：把 [NetProxy] 当前判定出的代理，同步到 `http_proxy` /
/// `no_proxy` 两个环境变量上。不涉及任何播放逻辑。
class MpvProxyEnv {
  MpvProxyEnv._();

  static _PutenvDart? _putenv;

  /// 上一次真正写进去的值，用来跳过重复写入。
  ///
  /// 每次播放都会调 [sync]，但代理设置通常整场不变；无脑重写虽然也不慢，
  /// 但会在日志里刷一堆无意义输出，排查时反而看不清真正变化的那一刻。
  static String _applied = '<未初始化>';

  /// 本机与局域网**域名**的旁路名单。
  ///
  /// 只放实测逐条有效的项（见文件头表格）。历史版本这里写过
  /// `10.*,192.168.*,172.16.*`，实测 FFmpeg **一条都不认** —— 尾星
  /// 不是通配符，等于整条名单废掉，内网请求照样被塞进代理。
  ///
  /// 段通配在这里是**表达不出来**的（不是没写对）。真正的内网 IP
  /// 兜底在 [sync] 的 `targetHost` 分支：播放地址本身落在内网时，
  /// 干脆不写代理，比给 FFmpeg 一条它读不懂的规则可靠得多。
  ///
  /// `*.local` 是唯一保留的通配项：mDNS 名字（`nas.local` 这类）无法
  /// 逐个枚举，而星号前缀正是 FFmpeg 支持的形态。它不会吃掉公网流量
  /// —— 实测 `vip.dytt-tvs.com` 仍走代理。
  @visibleForTesting
  static const String bypass = 'localhost,127.0.0.1,::1,*.local';

  /// 加载 UCRT 的 `_putenv_s`。失败只记一次，之后静默跳过。
  static bool _ensureReady() {
    if (_putenv != null) return true;
    if (!Platform.isWindows) return false;
    try {
      final ucrt = DynamicLibrary.open('ucrtbase.dll');
      _putenv =
          ucrt.lookupFunction<_PutenvNative, _PutenvDart>('_putenv_s');
      return true;
    } catch (e) {
      // 理论上不会发生（UCRT 是 Windows 10+ 的系统组件），
      // 真失败就退回「播放器直连」，不影响其它功能。
      debugPrint('[MPV] 无法加载 ucrtbase._putenv_s: $e');
      return false;
    }
  }

  /// 计算「这次该写入什么」的状态标签。纯函数，便于离线回归。
  ///
  /// 抽出来是因为**判定规则本身**才是要盯住的东西，而它依赖
  /// `NetProxy.active` —— 那取决于本机有没有开代理软件，测试环境
  /// 无法控制（实测开发机上 Clash 常驻 7897，直接断言「一定是直连」
  /// 会假失败）。把规则变成纯函数后，两种情况都能精确断言。
  ///
  /// [server] 传空串表示当前不走代理（必须**清空**环境变量）。
  /// [targetHost] 是即将播放的地址；落在内网时即便有代理也不写——
  /// 见 [sync] 里的说明。
  @visibleForTesting
  static String stateLabelFor(String server, {String targetHost = ''}) {
    if (server.isEmpty) return '<direct>';
    // 内网目标单独记一个标签：它和「用户没开代理」是两回事，
    // 日志里混在一起会让排查时分不清到底是没代理还是被主动跳过。
    if (targetHost.isNotEmpty && NetProxy.isBypassed(targetHost)) {
      return '<lan:$targetHost>';
    }
    return '$server|$bypass';
  }

  /// 把当前系统代理同步给 libmpv。可反复调用。
  ///
  /// **每次开始播放之前都要调**。三个原因：
  ///   1. 用户可能刚打开或关掉 Clash，代理可达性已经变了；
  ///   2. [NetProxy] 的探测结果有 30 秒 TTL，而全 App 只在启动时
  ///      刷新过一次 —— 启动后才开代理的话，`_active` 会一直是 false。
  ///      这里主动 refresh 一次，让它有机会重新判断（有 TTL 挡着，
  ///      连续播放不会每次都真去探端口）；
  ///   3. [targetHost] 决定这次要不要挂代理（见下）。
  ///
  /// ## 为什么需要 [targetHost]
  ///
  /// 内网地址必须直连，否则变成「代理去连代理」。而这件事**没法写在
  /// `no_proxy` 里**：实测 FFmpeg 的 `no_proxy` 只认精确 hostname 和
  /// 前缀星号，`10.*` / `192.168.*` / CIDR 全部无效，一个 `/16` 不存在
  /// 任何等价写法（详见文件头表格）。
  ///
  /// 所以改成在写入前判一次：目标本身在内网，就整条代理都不写。
  /// 判定复用 [NetProxy.isBypassed]，全 App 只有一份内网定义，
  /// 不会再出现「Dart 侧判对了、FFmpeg 侧写错了」这种分裂。
  static Future<void> sync({String targetHost = ''}) async {
    if (!_ensureReady()) return;
    try {
      await NetProxy.refresh();
    } catch (_) {
      // 探测失败就按当前已知状态继续，不让它挡住播放
    }
    final put = _putenv!;

    // 未启用代理时必须显式清空：否则上一次写进去的值会一直留着，
    // 用户关掉代理后所有请求仍被塞进一个已经没人监听的端口，
    // 表现为「关代理后整个 App 都连不上」——比不设代理糟糕得多。
    //
    // 内网目标同理：写空串，让 FFmpeg 直连。
    final lanTarget =
        targetHost.isNotEmpty && NetProxy.isBypassed(targetHost);
    final server = (NetProxy.active && !lanTarget) ? NetProxy.server : '';
    final want = stateLabelFor(server, targetHost: targetHost);
    if (want == _applied) return;
    _applied = want;

    final kProxy = 'http_proxy'.toNativeUtf8();
    final vProxy = server.toNativeUtf8();
    final rc1 = put(kProxy, vProxy);

    final kNo = 'no_proxy'.toNativeUtf8();
    final vNo = bypass.toNativeUtf8();
    final rc2 = put(kNo, vNo);

    // https_proxy 也设上：虽然本项目源站混用 http/https，但 FFmpeg 对
    // https 走的是 CONNECT 隧道，仍然只认 http_proxy。多设一个不伤人，
    // 且能覆盖将来换协议的情况。
    final kHttps = 'https_proxy'.toNativeUtf8();
    final rc3 = put(kHttps, vProxy);

    calloc.free(kProxy);
    calloc.free(vProxy);
    calloc.free(kNo);
    calloc.free(vNo);
    calloc.free(kHttps);

    final shown = server.isEmpty
        ? (lanTarget ? '直连（内网目标 $targetHost）' : '清空（直连）')
        : server;
    debugPrint('[MPV] 代理环境变量 -> $shown (rc=$rc1/$rc2/$rc3)');
  }

  /// 仅用于测试与排障：当前已写入的值。
  @visibleForTesting
  static String get applied => _applied;

  /// 仅用于测试：重置内部状态，让下一次 [sync] 必然重写。
  @visibleForTesting
  static void debugReset() {
    _applied = '<未初始化>';
  }
}