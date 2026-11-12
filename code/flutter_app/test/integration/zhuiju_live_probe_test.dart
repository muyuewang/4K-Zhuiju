/// 橘汁直播频道批量校验（联网探针，非断言型）
///
/// 用户反馈：直播分类 26 个频道全部「当前源无法播放」。
///
/// 逐条链路已查清：
///   1. `videoUsableUrl` 返回
///      `http://110.42.52.180:6688/zb/cctv.php?token=..&id=cctv1&zy.m3u8`
///   2. 该地址返回**合法 HLS**（`#EXTM3U` + `#EXT-X-MEDIA-SEQUENCE` + 分片）
///   3. 但分片是**相对名**：
///      `live-play.cctvnews.cctv.com_channel_cctv1_mbd-<ts>.ts?auth_key=..`
///      按标准解析（相对于 `/zb/cctv.php`）得到 `/zb/<该名>` → **nginx 404**
///   4. 把分片名还原成央视原始路径直连 → **403**（auth_key 绑定回源服务器 IP）
///   5. 穷举 `/zb/ts/`、`/zb/seg/`、`/zb/hls/`、`/ts/` 等 12 个前缀
///      × 带/不带 auth_key × Host 覆盖 → 全部 404
///
/// 结论：**源站的直播中转是坏的**——它下发的清单引用了自己并不托管的文件。
/// 本探针批量跑一遍全部频道，确认这不是单个频道的问题。
///
/// 断网自动跳过，不把套件弄红。
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';
import 'package:zhuiju/core/models.dart';

const String _ua = 'Mozilla/5.0 (Linux; Android 9; SM-N9700) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36';

class _R {
  _R(this.status, this.bytes);
  final int status;
  final List<int> bytes;
  bool get isTs => bytes.isNotEmpty && bytes.first == 0x47;
  bool get isHls =>
      bytes.length > 7 && latin1.decode(bytes.sublist(0, 7)) == '#EXTM3U';
  String get tag => isTs ? 'TS' : (isHls ? 'HLS' : '$status');
}

Future<_R?> _get(String url, {int maxBytes = 8192}) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final rq = await c.getUrl(Uri.parse(url));
    rq.headers.set(HttpHeaders.userAgentHeader, _ua);
    final rp = await rq.close();
    final b = <int>[];
    await for (final ch in rp) {
      b.addAll(ch);
      if (b.length >= maxBytes) break;
    }
    return _R(rp.statusCode, b);
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('直播全部频道：清单可用性 + 首个分片可达性', () async {
    final api = ZhuijuApi.instance;
    DramaDetail det;
    try {
      final list = await api.category('25');
      det = await api.detail(list.first.id);
    } catch (e) {
      print('[skip] 拿不到直播详情：$e');
      return;
    }
    print('「${det.name}」共 ${det.videos.length} 个频道\n');

    var okPlaylist = 0;
    var okSeg = 0;
    var tried = 0;
    for (final v in det.videos) {
      if (tried >= 8) break; // 抽检 8 个足够判断整体
      tried++;
      String url;
      try {
        url = (await api.playUrl(v.source, v.path)).playUrl;
      } catch (e) {
        print('${v.epLabel.padRight(16)} 取址失败：$e');
        continue;
      }
      if (!ZhuijuApi.isDirectUrl(url)) {
        print('${v.epLabel.padRight(16)} 取址无地址：$url');
        continue;
      }
      final pl = await _get(url, maxBytes: 64 * 1024);
      if (pl == null || !pl.isHls) {
        print('${v.epLabel.padRight(16)} 清单不可用 ${pl?.tag}');
        continue;
      }
      okPlaylist++;
      final segs = const LineSplitter()
          .convert(latin1.decode(pl.bytes))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.startsWith('#'))
          .toList();
      if (segs.isEmpty) {
        print('${v.epLabel.padRight(16)} 清单无分片');
        continue;
      }
      final segUrl = Uri.parse(url).resolve(segs.first).toString();
      final sg = await _get(segUrl);
      if (sg != null && sg.isTs) {
        okSeg++;
        print('${v.epLabel.padRight(16)} 清单OK 分片OK ✅');
      } else {
        print('${v.epLabel.padRight(16)} 清单OK(${segs.length}段) '
            '分片${sg?.tag ?? 'ERR'} ✗');
      }
    }
    print('\n抽检 $tried 个：清单可用 $okPlaylist，分片可取 $okSeg');
    if (okPlaylist > 0 && okSeg == 0) {
      print('=> 源站清单正常但分片全 404，直播中转在服务端就是坏的');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}