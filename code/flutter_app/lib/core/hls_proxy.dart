/// 桌面端 HLS 播放的中转代理。
///
/// ## 它为什么还存在（2026-11-12 换内核后重新定位）
///
/// 这层代理最早是为了绕开 Windows **Media Foundation** 的 HLS 缺陷才加的。
/// 当天把播放内核换成了 media_kit（libmpv + FFmpeg）之后，当初那些
/// 缺陷全部由 FFmpeg 兜住了，但代理**不能删**，因为它现在承担的是
/// 一件 FFmpeg 做不到的事：
///
///   libmpv 走自己的网络栈（FFmpeg 的 network.c），**不读 Windows
///   系统代理**。而本项目有四个源（云影 / 低调影视 / 极速追剧 / 4K影视）
///   直连不通、必须挂代理。播放地址若裸交给 libmpv，它会去直连，
///   现象就是「网页能播、App 里一直转圈」。经本代理转发时，取流请求由
///   Dart 的 HttpClient 发出，而 NetProxy 已经给 HttpClient 装了系统
///   代理——这是目前唯一能把视频流也拐上代理的通道。
///
/// 除此之外，代理顺手还做了几件仍然有用的事（下面逐条都有实测依据）：
///   - 相对分片地址展开成绝对地址（换内核后非必需，但能减少
///     FFmpeg 拼基址的分支，行为更可预测）
///   - 丢掉源站私货注释（`# ppvod-ad-injected v1`）
///   - 多级 master/variant 清单递归展开
///   - AES-128 分片在本地解密（见下面那一节）
///
/// 历史记录保留如下，改动前先读：
///
/// Windows 的 Media Foundation 自带 HLS 解析器，但它对清单的容错很差。
/// 实测同一个 App 里两条线路：
///
///   BL     清单 41 个分片、分片是**绝对地址**、带
///          `#EXT-X-INDEPENDENT-SEGMENTS`          → 正常播放
///   B蓝光  清单 2423 个分片、分片是 `0000000.ts` **相对地址**，
///          基址 `.../video/xxx/全集/index.m3u8`（含百分号编码），
///          还夹着 `# ppvod-ad-injected v1` 私货注释
///                                                  → MF 报
///          `MF_MEDIA_ENGINE_EVENT_ERROR: file not found /
///           corrupted / not supported`
///
/// 服务端侧完全健康（清单 200 / `application/vnd.apple.mpegurl`；
/// 分片 206 / `video/mp2t`、magic `47401110`；PMT 里是
/// stream_type 0x1B(H.264) + 0x0F(AAC)，MF 都支持），
/// 也不是 URL 编码问题（Dart 会把中文自动编成 `%E5%85%A8%E9%9B%86`）。
/// 问题在 MF 拼「相对地址 + 含百分号编码的基址」时拼错了，
/// 于是去取一个不存在的分片，报「file not found」。
///
/// 当时的解决办法不是改 MF，而是在本地起一个小代理：
/// 把清单拉下来、相对分片**全部改写成代理自己的绝对地址**、
/// 丢掉非 `#EXT` 的杂注释，再以标准 Content-Type 回给播放器。
/// 分片请求同样经代理转发（支持 Range），于是整条链路的地址
/// 都是纯 ASCII、不含相对路径，MF 不再需要做任何基址拼接。
///
/// 设计约束：
///   - 只监听 `127.0.0.1`，不对外暴露。
///   - 端口随机，地址带一次性 token，挡住本机其它进程瞎猜。
///   - 每次请求都回源拉最新清单：BL 那类源的分片地址带
///     `Expires`/`Signature`，签名会过期，缓存清单必然 403。
///
/// ## AES-128 加密的 HLS（2026-11-12 新增，血泪）
///
/// 看剧源的《名侦探柯南：高速公路的堕天使》清单第 5 行是：
///
///     #EXT-X-KEY:METHOD=AES-128,URI="enc.key",IV=0x000…000
///
/// 分片本身是 **加密的 TS**。改造前的代理只改写「分片」的地址，
/// `#EXT-X-KEY` 因为是以 `#EXT` 开头被原样透传，`URI="enc.key"` 还是
/// 相对路径。播放器于是拿代理的基址去拼：
///
///     http://127.0.0.1:<port>/hls/<token>/enc.key
///
/// 这个路径落到代理的「清单」分支，**把 178KB 的 m3u8 当成 16 字节的
/// AES 密钥回了回去**，解密必然失败 → 表现就是「地址解析出来了，
/// 但一直转圈/黑屏，播不了」。网页版能播是因为 hls.js 自己实现了
/// AES-128 解密，浏览器不依赖任何系统组件。
///
/// 修复没有走「只把 key 地址也改写成代理地址」这条更省事的路，因为
/// 那要求播放器自己支持 AES-128 解密——旧内核（MF）在 Windows 上
/// 没有任何保证，把命运交给一个不确定的组件比多写 30 行解密代码更糟。
/// 现在的做法是**代理侧解密**：拉下密文分片，本地解成明文 TS 再回给
/// 播放器，同时把 `#EXT-X-KEY` 从清单里摘掉。播放器看到的永远是最
/// 朴素的明文 TS，与「能不能解 AES」彻底无关。
///
/// 换内核后 FFmpeg 其实自己也能解 AES-128，但这段解密**保留**：
/// 它让播放器永远拿到明文，不依赖内核的实现差异；而且解密发生在
/// 取流侧（Dart 网络栈），不受 libmpv 网络栈的限制。
///
/// 密钥按 URL 缓存（一条清单所有分片共用一个 key，实测只出现 1 条
/// `#EXT-X-KEY`），命中后不再回源。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV;

/// 判断一个 URL 是不是 HLS 清单。
///
/// **不能只看 `Uri.path.endsWith('.m3u8')`**：橘汁直播的取址接口返回的是
///
///   `http://110.42.52.180:6688/zb/cctv.php?token=..&id=cctv1&zy.m3u8`
///
/// 这里的 path 是 `/zb/cctv.php`，`.m3u8` 落在 **query** 里（而且是个
/// 无值的键 `zy.m3u8`）。旧判断只认 path，于是这类地址被当成「不是 m3u8」
/// 原样放行，代理完全不接管；而它们的清单里分片又是相对地址，桌面端的
/// Media Foundation 自己拼会失败——表现就是直播全部「无法播放」。
///
/// 这里放宽到「path 或整个 URL 里出现 .m3u8」，mp4 直链不会误判
/// （mp4 路径里不含 m3u8）。
bool looksLikeM3u8(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return false;
  if (u.path.toLowerCase().endsWith('.m3u8')) return true;
  return url.toLowerCase().contains('.m3u8');
}

/// 一个播放会话：清单地址 + 已展开的分片表。
class _Session {
  _Session(this.playlistUrl);
  final String playlistUrl;

  /// 分片信息，下标即代理地址里的序号。
  final List<_Seg> segments = <_Seg>[];

  /// 地址 → 下标。**必须去重**：多级清单下子清单每次请求都要重新解析
  /// 一遍，不去重的话 segments 会随播放无限增长（片库那份 2679 条清单
  /// 点一次涨一次，几分钟就能吃掉几十兆）。
  ///
  /// 去重键带上密钥信息：同一条分片地址若在不同密钥段下出现
  /// （理论罕见，但 AES 清单改 key 时可能发生），不能共用同一条记录，
  /// 否则会用错密钥解出花屏。
  final Map<String, int> _index = <String, int>{};

  /// 访问计数，仅用于排障日志（判断 MF 有没有真的来拉分片）。
  int segHits = 0;

  /// 已解析的清单层数。正常点播 2 层（master → variant），
  /// 留到 32 只为拦住异常源构造无限嵌套，正常播放碰不到。
  int playlistDepth = 0;

  int addSegment(String url, {String? keyUrl, Uint8List? iv}) {
    final k = '${keyUrl ?? ''}|$url';
    final hit = _index[k];
    if (hit != null) return hit;
    final i = segments.length;
    segments.add(_Seg(url, keyUrl, iv));
    _index[k] = i;
    return i;
  }
}

/// 一条分片：地址 + 它自己的 AES 密钥（没有密钥就是明文 TS）。
class _Seg {
  _Seg(this.url, this.keyUrl, this.iv);
  final String url;
  final String? keyUrl;
  final Uint8List? iv;

  bool get encrypted => keyUrl != null;
}

class HlsProxy {
  HlsProxy._();

  static final HlsProxy instance = HlsProxy._();

  /// 和 Android 侧一致的 UA。部分源站对空 UA 直接 403。
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  HttpServer? _server;
  Future<int>? _starting;

  /// 回源用的共享 HttpClient（懒建，整个代理生命周期只建一个）。
  ///
  /// ## 为什么必须共享（2026-11-13 实测，这个缺陷让 PC 版几乎不可用）
  ///
  /// 改动前每个分片都 `HttpClient()` + `close(force: true)`：等于**每个
  /// 分片都重做一次 TCP + TLS 握手**，而 `force: true` 还会明确把连接
  /// 踢掉、绝不复用。电影天堂《凡人修仙传》一集 322 个分片，就是 322
  /// 次完整握手。
  ///
  /// 同一批 6 个分片（4.24MB）在本机实测：
  ///   串行 + 每片新建连接   20.3s（214 KB/s）
  ///   并发 + 复用连接       10.6s（411 KB/s）
  /// 而这是 3000k 的流（约 375 KB/s 码率）。取流速度贴着甚至低于码率，
  /// 播放器缓冲永远填不满，表现就是「一直转圈」直到超时。
  ///
  /// 只看单次数字会误判：源站抖动极大（同一分片有时 2.5s、有时 22s），
  /// 偶尔会出现「新建比复用还快」的假象。真正的硬证据是复用时抓到的
  /// `Connection closed before full header was received` —— 源站对
  /// **高频新建连接**会直接掐，复用连接正是为了绕开它。
  ///
  /// 这也解释了为什么「浏览器 / 雷电模拟器都快，只有 PC 慢」：Android
  /// 走 ExoPlayer 直连、浏览器走自己的连接池，都不经过这一层；只有
  /// 桌面端被这层中转的每请求新建连接拖死。
  HttpClient? _client;

  HttpClient get _upstream {
    final c = _client;
    if (c != null) return c;
    final n = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      // 空闲连接留一会儿：分片是连续请求的，间隔通常只有几百毫秒，
      // 15s 足够覆盖，又不会把死连接留太久。
      ..idleTimeout = const Duration(seconds: 15)
      // 播放器会预读后续分片，允许多条并行，减少排队。
      ..maxConnectionsPerHost = 8;
    _client = n;
    return n;
  }

  /// token -> 播放会话。只在播放期间有效，离开页面整体清掉。
  final Map<String, _Session> _sessions = <String, _Session>{};

  /// host -> 是否可直连。**只在本次播放会话内有效**，[shutdown] 清空。
  ///
  /// 不做跨会话持久化：源站可达性是会变的（用户开关代理、CDN 切换、
  /// 源站临时抽风），把一次判定永久缓存会让「本来能播的源」长期走中转。
  final Map<String, bool> _directCache = <String, bool>{};

  /// 直连探测的时限。
  ///
  /// 只等 2.5s，因为这一步是**起播前的串行等待**：探通了省掉整集的中转，
  /// 探不通也只是多花 2.5s 然后走原来的路径。取太大会让代理源的起播
  /// 明显变慢，取太小会把「慢但能通」的源误判成不能直连（回退到中转，
  /// 只是没优化，不影响正确性）。
  static const Duration _probeTimeout = Duration(milliseconds: 2500);

  /// 测试开关：为 true 时**跳过直连判定**，强制走中转。
  ///
  /// 回归测试（hls_aes128 / hls_redirect_playlist / hls_nested_playlist）
  /// 都在 `127.0.0.1` 上起本地服务模拟源站，而这些服务本身必然可直连。
  /// 不关掉直连优先的话，`wrap()` 会把地址原样返回，代理根本不介入，
  /// 那三组测试就全在测空气——它们锁的「相对地址补全 / 302 基准 /
  /// AES 解密」恰好都是**代理内部**的行为。
  ///
  /// 生产代码永远不设它。
  @visibleForTesting
  static bool debugForceProxy = false;

  final Random _rnd = Random();

  /// 把外部 m3u8 地址包成本地代理地址。
  ///
  /// 非 m3u8（mp4 直链等）原样返回：mp4 走 MF 一直正常，没必要多一跳。
  ///
  /// 代理本身出任何问题（端口被占、bind 失败）都退回原始地址：
  /// 代理只是「修 MF 相对地址缺陷」的增强手段，不该成为新的故障点。
  /// 退回后行为等同改造前——BL 这类绝对地址的源照样能播。
  Future<String> wrap(String url) async {
    if (!url.startsWith('http')) return url;
    if (!looksLikeM3u8(url)) return url;

    // ★ 直连优先：能直连就彻底不碰这一层（见 [_canDirect] 的注释）。
    // 这一步放在最前面，因为它决定了后面所有代码要不要执行。
    if (!debugForceProxy && await _canDirect(url)) {
      debugPrint('[HLS] direct reachable, bypass proxy: $url');
      return url;
    }

    try {
      final port = await _ensureStarted();
      final token = _newToken();
      _sessions[token] = _Session(url);
      // 以 .m3u8 结尾：MF 有时靠扩展名判断该用哪个源解析器
      return 'http://127.0.0.1:$port/hls/$token/index.m3u8';
    } catch (e) {
      debugPrint('[HLS] proxy unavailable, fallback to direct: $e');
      _starting = null;
      return url;
    }
  }

  Future<int> _ensureStarted() {
    // 并发调用只允许 bind 一次，否则第二个 bind 会抛端口占用
    return _starting ??= _start();
  }

  /// 这条地址所在的源站，**不经本代理**能否直接取到。
  ///
  /// ## 为什么必须做这一步（2026-11-13，用户实测后定的架构）
  ///
  /// 中转层解决的是「libmpv 不读系统代理」，但它同时也**接管了那些本来
  /// 不需要代理的源**，并因此引入了自己的短板：串行转发。实测本机
  /// 电影天堂《凡人修仙传》同一批分片：
  ///
  ///   经代理串行（共享连接池）  7.12MB / 35.1s / 208 KB/s
  ///   libmpv 直连（并行预读）   远高于此，起播只要 1~2s
  ///
  /// 而该流是 3000k ≈ 375 KB/s。中转一旦低于码率，缓冲永远填不满，
  /// 表现就是「一直转圈，最后报源站响应超时」——正是用户报的故障。
  ///
  /// 用户那三个对照很有说服力：浏览器快、雷电模拟器快、只有 PC 版慢。
  /// 浏览器有自己的连接池 + 并行拉片，ExoPlayer 读系统代理直连，
  /// **两者都不经过这一层**。所以正确的做法不是把中转层优化到极致，
  /// 而是让它只处理真正需要它的源。
  ///
  /// ## 判定方式与代价
  ///
  /// 用一个显式 `findProxy = DIRECT` 的独立 client 去取一次清单；
  /// 拿到 2xx 且响应体像 m3u8 就认定可直连。
  ///
  /// 不用 HEAD：不少源站对 HEAD 回 405，会把这批源误判成「不能直连」。
  /// 不查 DNS/端口：DNS 能解析、TCP 能连，都不代表 TLS 和实际取流能通，
  /// 而这里要的正是「真的能取到」。
  ///
  /// 代价是起播前多一次串行探测（上限 [_probeTimeout]）。命中缓存后
  /// 整集不再重复探测；探不通也只损失一次 2.5s，随后仍走原来的路径。
  /// 命中后不再探测的缓存键：`scheme://host:port`。
  ///
  /// 不能只用 host：同一台机器上不同端口是完全不同的服务
  /// （探通 8080 不代表 8081 也通），只用 host 会把结论串味。
  String _originKey(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return '';
    final port = u.hasPort
        ? u.port
        : (u.scheme == 'https' ? 443 : 80);
    return '${u.scheme}://${u.host}:$port';
  }

  Future<bool> _canDirect(String url) async {
    final key = _originKey(url);
    if (key.isEmpty) return false;
    final hit = _directCache[key];
    if (hit != null) return hit;

    var ok = false;
    HttpClient? probe;
    try {
      probe = HttpClient()
        // 显式 DIRECT：HttpOverrides 会给每个新建的 client 装系统代理，
        // 这里必须推翻它，否则探的其实是「经代理能不能通」，
        // 那就不用探了——代理能用时永远为真，直连优先也就永远不生效。
        ..findProxy = ((Uri _) => 'DIRECT')
        ..connectionTimeout = _probeTimeout;
      final rq = await probe.getUrl(Uri.parse(url)).timeout(_probeTimeout);
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      final rp = await rq.close().timeout(_probeTimeout);
      // 只读到够判断就走：真清单开头必然是 `#EXTM3U`。
      // 不整份读完，是因为超大清单（片库那份 451KB）会把探测时间拉长。
      // `await for` + break 会自动取消订阅；不读完的残留连接由
      // 下面的 force close 收掉。
      final head = <int>[];
      await for (final d in rp.timeout(_probeTimeout)) {
        head.addAll(d.take(64 - head.length));
        if (head.length >= 64) break;
      }
      ok = rp.statusCode == HttpStatus.ok &&
          String.fromCharCodes(head).contains('#EXTM3U');
      if (!ok) {
        debugPrint('[HLS] direct probe not usable '
            '(status=${rp.statusCode}) for $url');
      }
    } catch (e) {
      // 超时 / 连接被拒 / TLS 失败都算「不能直连」，这是预期分支，
      // 不是错误——四个代理源就是靠这个分支才继续走中转的。
      debugPrint('[HLS] direct probe failed: ${e.runtimeType}  ($url)');
      ok = false;
    } finally {
      try {
        probe?.close(force: true);
      } catch (_) {}
    }
    _directCache[key] = ok;
    return ok;
  }

  Future<int> _start() async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.autoCompress = false;
    _server = srv;
    srv.listen(_handle, onError: (Object e) {
      debugPrint('[HLS] server error: $e');
    });
    debugPrint('[HLS] proxy listening on 127.0.0.1:${srv.port}');
    return srv.port;
  }

  String _newToken() {
    const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(24, (_) => cs[_rnd.nextInt(cs.length)]).join();
  }

  /// 释放端口。离开播放页时调用，避免长时间挂着监听。
  Future<void> shutdown() async {
    _sessions.clear();
    // 密钥跟着会话一起清：换片后旧 key 没用，留着只是徒增内存足迹。
    _keyCache.clear();
    // 直连判定的结论也必须清：用户开关代理、换源之后可达性会变。
    // 留着会让「上次探不通、这次其实能直连」的源一直走中转。
    _directCache.clear();
    // 共享连接池也要关：本代理是「进播放页建、离开就拆」的生命周期，
    // 留着连接会一直占用源站的 keep-alive 额度，下次进页面反而是旧的。
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
    final s = _server;
    _server = null;
    _starting = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    try {
      // 路径形态：
      //   /hls/<token>/index.m3u8     清单
      //   /hls/<token>/seg/<n>.<ext>  分片
      final segs = req.uri.pathSegments;
      if (segs.length < 2) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final token = segs[1];
      final session = _sessions[token];
      if (session == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }

      final isSeg = segs.length >= 4 && segs[2] == 'seg';
      if (isSeg) {
        final n = int.tryParse(segs[3].split('.').first);
        if (n == null || n < 0 || n >= session.segments.length) {
          debugPrint('[HLS] seg $n out of range '
              '(total=${session.segments.length})');
          res.statusCode = HttpStatus.notFound;
          await res.close();
          return;
        }
        final target = session.segments[n];
        // 条目自己也是清单（master → variant 这种多级结构）时必须
        // **继续展开**，不能当分片转发。否则子清单原样回给播放器，
        // 里面全是相对地址，播放器会以 `127.0.0.1:port/...` 为基址去
        // 拼分片，请求必然 404 —— 表现就是「点了播放一直转圈」。
        // 片库 4K 的 master 只有 101 字节、1 个条目，就是这个形态。
        if (looksLikeM3u8(target.url)) {
          session.playlistDepth++;
          if (session.playlistDepth > 32) {
            debugPrint('[HLS] playlist nesting too deep, give up');
            res.statusCode = HttpStatus.badGateway;
            await res.close();
            return;
          }
          debugPrint('[HLS] expand nested playlist #${session.playlistDepth}');
          await _playlist(session, token, res, playlistUrl: target.url);
        } else if (target.encrypted) {
          // 加密分片：拉密文 -> 本地 AES-128-CBC 解密 -> 回明文 TS。
          // 不走 _relay，因为 _relay 是流式转发，解密必须整段拿到内存。
          session.segHits++;
          if (session.segHits <= 3 || session.segHits % 50 == 0) {
            debugPrint('[HLS] seg #$n decrypt '
                '(hit=${session.segHits}, total=${session.segments.length})');
          }
          await _decryptSegment(target, res);
        } else {
          session.segHits++;
          // 只打前几条和每 50 条，避免 2400 条分片把日志刷爆
          if (session.segHits <= 5 || session.segHits % 50 == 0) {
            debugPrint('[HLS] seg #$n requested '
                '(hit=${session.segHits}, total=${session.segments.length})');
          }
          await _relay(target.url, req, res);
        }
      } else {
        await _playlist(session, token, res);
      }
    } catch (e) {
      debugPrint('[HLS] handle error: $e');
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
    }
  }

  /// 拉清单 -> 规范化（分片改写成代理地址）-> 返回
  ///
  /// [playlistUrl] 不传就用会话主地址。子清单（master → variant）展开时
  /// 传目标地址进来，这样才能按子清单自己的 URL 做相对地址补全。
  Future<void> _playlist(
    _Session session,
    String token,
    HttpResponse res, {
    String? playlistUrl,
  }) async {
    final src = playlistUrl ?? session.playlistUrl;
    // 关键：拿**重定向后的最终地址**做相对路径基准，不是原始地址。
    // 直播源普遍是「PHP 接口 302 到 CDN 真清单」，分片又是相对地址；
    // 用原始地址拼会得到源站自己的 404 路径。详见 _fetchWithUrl 的注释。
    final fetched = await _fetchWithUrl(src);
    final bytes = fetched.bytes;
    if (bytes == null) {
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }
    if (fetched.finalUrl != src) {
      debugPrint('[HLS] playlist redirected: $src -> ${fetched.finalUrl}');
    }
    final text = _decode(bytes);
    if (text == null || !text.contains('#EXTM3U')) {
      debugPrint('[HLS] not a playlist: $src');
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }

    final limit = _intEnv('ZJ_MAX_SEG');
    final base = Uri.parse(fetched.finalUrl);
    final out = <String>[];
    var truncated = false;
    var added = 0;

    // 当前生效的 AES 密钥（`#EXT-X-KEY` 是「作用域」语义：出现一次，
    // 其后所有分片都受它约束，直到下一条 `#EXT-X-KEY` 覆盖它）。
    String? curKeyUrl;
    Uint8List? curIv;
    // 清单起始序号：IV 缺省时要用 media sequence 参与计算，见下面注释。
    var mediaSeq = 0;
    var encryptedCount = 0;

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        // `#EXT-X-MEDIA-SEQUENCE` 影响 IV 缺省时的推导，先记下来
        if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
          mediaSeq = int.tryParse(line.split(':').last.trim()) ?? 0;
          if (line.startsWith('#EXT')) out.add(line);
          continue;
        }
        if (line.startsWith('#EXT-X-KEY:')) {
          // 关键：**这条 tag 绝不透传**。
          //
          // 透传的话播放器会自己去取 `URI` 的密钥，而该 URI 通常是相对
          // 路径（`enc.key`），拼出来的代理地址会落到「清单」分支，
          // 拿到一整份 m3u8 当密钥，解密必失败。解密已经在 _decryptSegment
          // 里做完了，所以这里把它从清单里摘掉，播放器就当普通明文 TS 播。
          final method = _keyAttr(line, 'METHOD')?.toUpperCase() ?? 'NONE';
          if (method == 'NONE') {
            // METHOD=NONE 表示后续分片恢复明文
            curKeyUrl = null;
            curIv = null;
          } else if (method == 'AES-128') {
            final uri = _keyAttr(line, 'URI');
            if (uri == null || uri.isEmpty) {
              debugPrint('[HLS] AES-128 key without URI, ignore: $line');
              curKeyUrl = null;
              curIv = null;
            } else {
              try {
                curKeyUrl = base.resolve(uri).toString();
              } catch (_) {
                curKeyUrl = null;
              }
              final ivStr = _keyAttr(line, 'IV');
              curIv = _parseIv(ivStr);
            }
          } else {
            // SAMPLE-AES / SAMPLE-AES-CTR：只加密部分样本（音频/视频轨），
            // 不是整段加密，本地解密要解 TS 内的 NAL，不做。
            // 保留 tag 让播放器自己试，失败也能从日志看出原因。
            debugPrint('[HLS] unsupported key method $method, pass through');
            curKeyUrl = null;
            curIv = null;
            out.add(line);
            continue;
          }
          continue;
        }
        // 只保留标准 tag；`# ppvod-ad-injected v1` 这类源站私货一律丢弃
        if (line.startsWith('#EXT')) out.add(line);
        continue;
      }
      if (limit > 0 && added >= limit) {
        truncated = true;
        break;
      }
      Uri abs;
      try {
        abs = base.resolve(line);
      } catch (_) {
        continue; // 拼不出来的分片直接丢，别让整份清单作废
      }
      if (!abs.hasScheme) continue;
      // 扩展名保留：MF 有时靠后缀判断容器类型
      final name = abs.pathSegments.isEmpty
          ? 'seg.ts'
          : abs.pathSegments.last;

      // IV 缺省时的推导（RFC 8216 §5.2）：
      //   若未显式给 IV，则用该分片的 media sequence number 作为
      //   128 位大端整数当 IV。序号从清单的 EXT-X-MEDIA-SEQUENCE 起算，
      //   点播清单该值恒为 0，于是第 n 个分片的 IV 就是 n。
      //   看剧源这条清单显式带了全 0 的 IV，但别的源不一定带，
      //   不实现这一条会在「有 key 无 IV」的源上解出满屏花屏。
      final iv = curKeyUrl == null
          ? null
          : (curIv ?? _ivFromSeq(mediaSeq + added));

      final idx = session.addSegment(
        abs.toString(),
        keyUrl: curKeyUrl,
        iv: iv,
      );
      if (curKeyUrl != null) encryptedCount++;
      added++;
      out.add('http://127.0.0.1:${_server!.port}/hls/$token/seg/'
          '$idx/$name');
    }
    if (truncated) {
      // 截断后必须补 ENDLIST，否则 MF 认为这是直播流，一直等新分片
      out.add('#EXT-X-ENDLIST');
    }

    final body = utf8.encode('${out.join('\n')}\n');
    debugPrint('[HLS] playlist ${bytes.length}B -> ${body.length}B '
        'entries=$added total=${session.segments.length}'
        '${encryptedCount > 0 ? ' aes=$encryptedCount' : ''}');
    res.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl');
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }

  /// 单个分片的取流时限。
  ///
  /// 为什么必须有（2026-11-13，用户报「PC 版慢得很还会超时失败」）：
  /// 改动前 `_relay` 里**一个超时都没有** —— `rq.close()` 等待响应头、
  /// `rp.forEach()` 读响应体，两处都能无限期挂着。源站一抖（实测同一
  /// 分片有时 2.5s、有时 22s），整个播放就干等这一片，最后是播放页
  /// 那个 `initialize().timeout(30s)` 到点报「源站响应超时」。
  ///
  /// 用户看到的是「失败」，但同一片重试一次往往就成功了 —— 因为慢的
  /// 那一次多半是撞上了源站的坏连接，而不是这一片真的没了。
  ///
  /// 15s 是折中：3 秒一段的分片正常 2~5s 拿完，15s 已能覆盖明显抖动；
  /// 再长就会把「应该重试」的等待变成「用户干等半分钟」。
  static const Duration _segTimeout = Duration(seconds: 15);

  /// 失败后额外重试的次数（只对「尚未开始写响应体」的失败生效）。
  static const int _segRetries = 1;

  /// 清单 / 密钥请求的时限。
  ///
  /// 比单分片更短：清单本身只有几十 KB，正常几百毫秒。
  /// 它拿不到就等于整集起不来，快速失败让播放器重试比干等更好——
  /// 用户看到的是「重连一次就好了」，而不是「卡住半分钟然后报错」。
  static const Duration _playlistTimeout = Duration(seconds: 10);

  /// 转发分片/其它资源，保留 Range 语义（MF 会发 Range 做 seek 探测）
  Future<void> _relay(
      String target, HttpRequest req, HttpResponse res) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    for (var attempt = 0; attempt <= _segRetries; attempt++) {
      final done = await _relayOnce(target, range, res);
      if (done) return;
      // _relayOnce 返回 false 只代表「还没往响应里写字节就失败了」，
      // 此时重试是安全的：播放器那边什么都还没收到。
      if (attempt < _segRetries) {
        debugPrint('[HLS] relay retry ${attempt + 1}: $target');
        _discardUpstream(reason: 'relay retry');
      }
    }
    try {
      await res.close();
    } catch (_) {}
  }

  /// 单次转发。
  ///
  /// 返回值语义很关键：
  ///   - `true`  → 本次转发已经「了结」：要么成功，要么响应体写到一半
  ///               断了（此时**不能**重试，否则播放器会收到两份拼接的
  ///               数据，表现为花屏或解码错误）
  ///   - `false` → 尚未写任何响应体就失败，调用方可以安全重试
  Future<bool> _relayOnce(
      String target, String? range, HttpResponse res) async {
    var bodyStarted = false;
    try {
      final rq = await _upstream.getUrl(Uri.parse(target)).timeout(_segTimeout);
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      if (range != null) rq.headers.set(HttpHeaders.rangeHeader, range);

      final rp = await rq.close().timeout(_segTimeout);
      res.statusCode = rp.statusCode;
      final ct = rp.headers.contentType;
      if (ct != null) res.headers.contentType = ct;
      final cr = rp.headers.value('content-range');
      if (cr != null) res.headers.set('content-range', cr);
      final cl = rp.headers.contentLength;
      if (cl > 0) res.contentLength = cl;

      bodyStarted = true;
      // 用 Stream.timeout 而不是 Future.timeout：后者只是「不再等」，
      // 底层连接仍在读，数据还会继续往 res 里灌，把响应写坏。
      await rp.timeout(_segTimeout).forEach(res.add);
      await res.close();
      return true;
    } catch (e) {
      debugPrint('[HLS] relay error: $e  ($target)');
      // 连接级 / 超时错误：池子里那条连接多半已经废了，丢掉重建，
      // 否则后续每个分片都会立刻踩到同一条坏连接。
      if (e is HttpException ||
          e is SocketException ||
          e is TimeoutException) {
        _discardUpstream(reason: 'relay: ${e.runtimeType}');
      }
      if (bodyStarted) {
        try {
          await res.close();
        } catch (_) {}
        return true;
      }
      return false;
    }
  }

  /// AES 密钥缓存：key URL -> 16 字节密钥。
  ///
  /// 一条清单里所有分片共用一个 key（实测看剧源只出现 1 条 `#EXT-X-KEY`，
  /// 2183 个分片共用）。不缓存的话每一片都要多回源一次，1080P 一集
  /// 就是两千多个多余请求，播放会明显起播慢。
  ///
  /// 不设上限但**随 shutdown 清空**：key 只有 16 字节，一条清单通常 1~3 个，
  /// 播放结束即释放，不存在长期泄漏。
  final Map<String, Uint8List> _keyCache = <String, Uint8List>{};

  /// 拉密文分片 -> 本地 AES-128-CBC 解密 -> 回明文 TS。
  ///
  /// 为什么整段读进内存而不是流式：CBC 需要按 16 字节块对齐，最后一块
  /// 还要剥 PKCS#7 padding，流式处理要自己维护跨块的残字节缓冲，
  /// 复杂度远高于收益。分片本身是 3 秒一段（实测约 850KB），
  /// 单段内存占用完全可接受。
  Future<void> _decryptSegment(_Seg seg, HttpResponse res) async {
    final key = await _loadKey(seg.keyUrl!);
    if (key == null) {
      // key 拿不到就别回错误码了：直接回密文，让播放器按它自己的方式
      // 尝试（大概率也失败），但至少日志能明确指向「密钥获取失败」。
      debugPrint('[HLS] key fetch failed, relay ciphertext: ${seg.keyUrl}');
      final raw = await _fetch(seg.url);
      if (raw == null) {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
        return;
      }
      res.headers.contentType = ContentType('video', 'mp2t');
      res.contentLength = raw.length;
      res.add(raw);
      await res.close();
      return;
    }

    final cipher = await _fetchBytes(seg.url);
    if (cipher == null) {
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }

    final iv = seg.iv ?? Uint8List(16);
    Uint8List plain;
    try {
      plain = _aesCbcDecrypt(cipher, key, iv);
    } catch (e) {
      debugPrint('[HLS] decrypt failed: $e  (${seg.url})');
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }

    res.headers.contentType = ContentType('video', 'mp2t');
    res.contentLength = plain.length;
    res.add(plain);
    await res.close();
  }

  /// 取密钥，带缓存。密钥必须是 16 字节，长度不对直接判失败——
  /// 这就是改造前「把整份 m3u8 当密钥」那个坑的判别式。
  Future<Uint8List?> _loadKey(String url) async {
    final hit = _keyCache[url];
    if (hit != null) return hit;
    final bytes = await _fetchBytes(url);
    if (bytes == null) return null;
    if (bytes.length != 16) {
      debugPrint('[HLS] bad key length ${bytes.length} for $url '
          '(expect 16)');
      return null;
    }
    final key = Uint8List.fromList(bytes);
    _keyCache[url] = key;
    debugPrint('[HLS] key loaded ${bytes.length}B for $url');
    return key;
  }

  /// 解密：AES-128-CBC + PKCS#7 去填充。
  ///
  /// 抽成顶层纯函数便于单测——这段逻辑「错了不报错」，只会解出花屏或
  /// 黑屏，跟「源站地址失效」长得一模一样，必须有对着真实样本的断言。
  @visibleForTesting
  static Uint8List aesCbcDecrypt(
      List<int> cipher, List<int> key, List<int> iv) {
    if (cipher.length % 16 != 0) {
      throw FormatException('密文长度不是 16 的倍数：${cipher.length}');
    }
    // processBlock 要求 Uint8List 入参，List<int> 不行，先转一次。
    // 不能用 as 强转：调用方常常直接传 Uint8List 之外的列表。
    final input = cipher is Uint8List ? cipher : Uint8List.fromList(cipher);
    final engine = AESEngine()
      ..init(false, KeyParameter(Uint8List.fromList(key)));
    final cbc = CBCBlockCipher(engine)
      ..init(
          false,
          ParametersWithIV(
              KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));
    final out = Uint8List(input.length);
    var off = 0;
    while (off < input.length) {
      cbc.processBlock(input, off, out, off);
      off += 16;
    }
    return _stripPkcs7(out);
  }

  static Uint8List _aesCbcDecrypt(
          List<int> cipher, Uint8List key, Uint8List iv) =>
      aesCbcDecrypt(cipher, key, iv);

  /// 剥 PKCS#7 填充。
  ///
  /// 容错优先：填充不合法时**原样返回**而不是抛异常。理由是有源站的分片
  /// 本身就是完整 16 字节倍数且不带填充（或被重复加密），严格校验会让
  /// 这类片全部播放失败；宁可让它带着尾部垃圾字节去解码，
  /// TS 解析器自己能跳过无效数据。
  static Uint8List _stripPkcs7(Uint8List data) {
    if (data.isEmpty) return data;
    final pad = data[data.length - 1];
    if (pad == 0 || pad > 16 || pad > data.length) return data;
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) return data;
    }
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  /// 从 `#EXT-X-KEY` 行里取属性值，形如 `METHOD=AES-128,URI="enc.key"`。
  ///
  /// 不能简单 split(',')：URI 里可能带合法的逗号（查询串里常见），
  /// 所以只按「逗号 + 合法的属性名 =」切分。
  @visibleForTesting
  static String? keyAttr(String line, String name) {
    // 分隔符必须是「行首 / 逗号 / 冒号」三者之一：
    //   第一个属性紧跟在 tag 名后面，是冒号分隔（`#EXT-X-KEY:METHOD=...`），
    //   后面的属性才是逗号分隔。只写 `(?:^|,)` 会导致 **METHOD 永远取不到**，
    //   于是所有清单都被判成「无密钥」，加密分片原样回给播放器 —— 这
    //   正是本次 bug 的同一个症状，只是换了个更隐蔽的地方犯。
    final re = RegExp('(?:^|[,:])\\s*$name\\s*=\\s*("([^"]*)"|([^,]*))',
        caseSensitive: false);
    final m = re.firstMatch(line);
    if (m == null) return null;
    final v = m.group(2) ?? m.group(3) ?? '';
    return v.trim();
  }

  static String? _keyAttr(String line, String name) => keyAttr(line, name);

  /// 解析 `IV=0x…`（32 位十六进制 = 16 字节）。
  @visibleForTesting
  static Uint8List? parseIv(String? s) {
    if (s == null) return null;
    var t = s.trim();
    if (t.isEmpty) return null;
    if (t.toLowerCase().startsWith('0x')) t = t.substring(2);
    if (t.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final b = int.tryParse(t.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  static Uint8List? _parseIv(String? s) => parseIv(s);

  /// media sequence -> 128 位大端 IV（RFC 8216 §5.2 的缺省推导）
  static Uint8List _ivFromSeq(int seq) {
    final out = Uint8List(16);
    var v = seq;
    for (var i = 15; i >= 0 && v > 0; i--) {
      out[i] = v & 0xff;
      v >>= 8;
    }
    return out;
  }

  /// 取原始字节（分片/密钥都用它，不解码文本）
  Future<List<int>?> _fetchBytes(String url) async {
    final client = _upstream;
    try {
      final rq = await client.getUrl(Uri.parse(url)).timeout(_playlistTimeout);
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      final rp = await rq.close().timeout(_playlistTimeout);
      final bytes = await rp
          .fold<List<int>>(<int>[], (a, d) {
            a.addAll(d);
            return a;
          })
          .timeout(_playlistTimeout);
      if (rp.statusCode != HttpStatus.ok) {
        debugPrint('[HLS] upstream ${rp.statusCode} for $url');
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('[HLS] fetchBytes error: $e  ($url)');
      if (e is HttpException ||
          e is SocketException ||
          e is TimeoutException) {
        _discardUpstream(reason: 'fetchBytes: ${e.runtimeType}');
      }
      return null;
    }
  }

  Future<List<int>?> _fetch(String url) async {
    final r = await _fetchWithUrl(url);
    return r.bytes;
  }

  /// 拉取资源，并同时回传**重定向之后的最终地址**。
  ///
  /// ## 为什么必须要最终地址（2026-11-12 橘汁直播修复）
  ///
  /// 直播源普遍是「一个 PHP 接口 302 到真实清单」的形态：
  /// ```
  /// /zb/cctv.php?token=...&id=cctv1&zy.m3u8
  ///    --302--> http://live-play-hls.cctvnews.cctv.com/CCTVChannel/channel_cctv1_mbd.m3u8?auth_key=...
  /// ```
  /// 而那份清单里的分片是**相对地址**（`live-play.cctvnews..._mbd-xxx.ts?auth_key=...`）。
  /// 若拿原始 `cctv.php` 当基准去 `resolve`，会拼成
  /// `http://110.42.52.180:6688/zb/live-play...ts` —— 恒 404，
  /// 播放器一直转圈。改用最终地址当基准，同一个分片立刻 200（实测 1.6MB）。
  ///
  /// 这不是直播独有的问题：凡是「接口跳转到 CDN 真清单」的源都会踩，
  /// 所以修复放在这一层，而不是给直播开特例。
  Future<({List<int>? bytes, String finalUrl})> _fetchWithUrl(
      String url) async {
    final client = _upstream;
    try {
      // 清单本身很小（实测 97B ~ 40KB），但源站抖动时也会挂很久。
      // 这里用比单分片更短的上限：清单拿不到就等于整集起不来，
      // 快速失败 + 让播放器重试，比干等 15s 体验好得多。
      final rq = await client.getUrl(Uri.parse(url)).timeout(_playlistTimeout);
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      final rp = await rq.close().timeout(_playlistTimeout);
      final bytes = await rp
          .fold<List<int>>(<int>[], (a, d) {
            a.addAll(d);
            return a;
          })
          .timeout(_playlistTimeout);

      // 逐跳解析重定向：`location` 可能是相对地址，不能直接取最后一跳的原文。
      var finalUrl = url;
      for (final r in rp.redirects) {
        try {
          finalUrl = Uri.parse(finalUrl).resolveUri(r.location).toString();
        } catch (_) {
          // 解析不出来就保留上一跳，至少不至于把基准弄坏
        }
      }

      if (rp.statusCode != HttpStatus.ok) {
        debugPrint('[HLS] upstream ${rp.statusCode} for $url');
        return (bytes: null, finalUrl: finalUrl);
      }
      return (bytes: bytes, finalUrl: finalUrl);
    } catch (e) {
      debugPrint('[HLS] fetch error: $e  ($url)');
      if (e is HttpException ||
          e is SocketException ||
          e is TimeoutException) {
        _discardUpstream(reason: 'fetchUrl: ${e.runtimeType}');
      }
      return (bytes: null, finalUrl: url);
    }
  }

  /// 丢弃共享连接池并重建。
  ///
  /// 只在遇到连接级错误（`HttpException` / `SocketException`）时调用：
  /// 源站掐断连接后，池子里那条连接已经是坏的，继续复用会让后续每个
  /// 分片都立刻失败。重建的代价远低于「整集播不出来」。
  ///
  /// 用 `force: false` 而不是 `true`：正在传输中的连接不打断，
  /// 只把空闲的关掉，避免误伤同时进行的其它分片请求。
  void _discardUpstream({required String reason}) {
    final c = _client;
    if (c == null) return;
    _client = null;
    debugPrint('[HLS] upstream pool reset ($reason)');
    try {
      c.close(force: false);
    } catch (_) {}
  }

  /// 清单基本都是 ASCII（分片名、tag），但个别源站会带 BOM 或 GBK 注释。
  /// 先按 UTF-8 严格解，失败就按 latin1 兜底——反正我们只处理 ASCII 结构。
  String? _decode(List<int> bytes) {
    try {
      var s = utf8.decode(bytes);
      if (s.startsWith('\uFEFF')) s = s.substring(1);
      return s;
    } catch (_) {
      try {
        return latin1.decode(bytes, allowInvalid: true);
      } catch (_) {
        return null;
      }
    }
  }

  /// 排障开关：`ZJ_MAX_SEG=50` 启动时清单只保留前 50 个分片。
  ///
  /// 用来判定「B蓝光 卡在加载」是不是清单条目太多（2423 条）导致。
  /// 不设就是 0（不截断），正常播放路径不受影响。
  int _intEnv(String key) {
    final v = Platform.environment[key];
    if (v == null) return 0;
    return int.tryParse(v) ?? 0;
  }
}