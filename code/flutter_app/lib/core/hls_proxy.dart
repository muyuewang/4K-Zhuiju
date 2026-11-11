/// 桌面端 HLS 播放的中转代理。
///
/// 为什么需要它：
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
/// 解决办法不是改 MF，而是在本地起一个小代理：
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
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

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

  /// 分片绝对地址，下标即代理地址里的序号。
  List<String> segments = <String>[];

  /// 访问计数，仅用于排障日志（判断 MF 有没有真的来拉分片）。
  int segHits = 0;
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
        session.segHits++;
        // 只打前几条和每 50 条，避免 2400 条分片把日志刷爆
        if (session.segHits <= 5 || session.segHits % 50 == 0) {
          debugPrint('[HLS] seg #$n requested '
              '(hit=${session.segHits}, total=${session.segments.length})');
        }
        await _relay(session.segments[n], req, res);
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
  Future<void> _playlist(
      _Session session, String token, HttpResponse res) async {
    final bytes = await _fetch(session.playlistUrl);
    if (bytes == null) {
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }
    final text = _decode(bytes);
    if (text == null || !text.contains('#EXTM3U')) {
      debugPrint('[HLS] not a playlist: ${session.playlistUrl}');
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }

    final limit = _intEnv('ZJ_MAX_SEG');
    final base = Uri.parse(session.playlistUrl);
    final out = <String>[];
    final segs = <String>[];
    var truncated = false;

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        // 只保留标准 tag；`# ppvod-ad-injected v1` 这类源站私货一律丢弃
        if (line.startsWith('#EXT')) out.add(line);
        continue;
      }
      if (limit > 0 && segs.length >= limit) {
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
      out.add('http://127.0.0.1:${_server!.port}/hls/$token/seg/'
          '${segs.length}/$name');
      segs.add(abs.toString());
    }
    if (truncated) {
      // 截断后必须补 ENDLIST，否则 MF 认为这是直播流，一直等新分片
      out.add('#EXT-X-ENDLIST');
    }
    session.segments = segs;

    final body = utf8.encode('${out.join('\n')}\n');
    debugPrint('[HLS] playlist ${bytes.length}B -> ${body.length}B '
        'segments=${segs.length}');
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

  Future<List<int>?> _fetch(String url) async {
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
      debugPrint('[HLS] fetch error: $e  ($url)');
      return null;
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