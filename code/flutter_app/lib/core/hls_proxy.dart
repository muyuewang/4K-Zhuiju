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

  /// token -> 播放会话。只在播放期间有效，离开页面整体清掉。
  final Map<String, _Session> _sessions = <String, _Session>{};
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

  /// 转发分片/其它资源，保留 Range 语义（MF 会发 Range 做 seek 探测）
  Future<void> _relay(
      String target, HttpRequest req, HttpResponse res) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final rq = await client.getUrl(Uri.parse(target));
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) rq.headers.set(HttpHeaders.rangeHeader, range);

      final rp = await rq.close();
      res.statusCode = rp.statusCode;
      final ct = rp.headers.contentType;
      if (ct != null) res.headers.contentType = ct;
      final cr = rp.headers.value('content-range');
      if (cr != null) res.headers.set('content-range', cr);
      final cl = rp.headers.contentLength;
      if (cl > 0) res.contentLength = cl;

      await rp.forEach(res.add);
      await res.close();
    } catch (e) {
      debugPrint('[HLS] relay error: $e  ($target)');
      try {
        await res.close();
      } catch (_) {}
    } finally {
      client.close(force: true);
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final rq = await client.getUrl(Uri.parse(url));
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      final rp = await rq.close();
      final bytes = await rp.fold<List<int>>(<int>[], (a, d) {
        a.addAll(d);
        return a;
      });
      if (rp.statusCode != HttpStatus.ok) {
        debugPrint('[HLS] upstream ${rp.statusCode} for $url');
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('[HLS] fetchBytes error: $e  ($url)');
      return null;
    } finally {
      client.close(force: true);
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final rq = await client.getUrl(Uri.parse(url));
      rq.headers.set(HttpHeaders.userAgentHeader, _ua);
      final rp = await rq.close();
      final bytes = await rp.fold<List<int>>(<int>[], (a, d) {
        a.addAll(d);
        return a;
      });

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
      return (bytes: null, finalUrl: url);
    } finally {
      client.close(force: true);
    }
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