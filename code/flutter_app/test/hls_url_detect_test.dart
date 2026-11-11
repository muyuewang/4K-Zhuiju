/// HLS 地址判定回归（不联网）。
///
/// 锁死一件容易被"优化"回去的事：**`.m3u8` 不一定在 path 里。**
///
/// 橘汁直播的取址接口实测返回：
///   `http://110.42.52.180:6688/zb/cctv.php?token=..&id=cctv1&zy.m3u8`
/// path 是 `/zb/cctv.php`，`.m3u8` 在 query 中，且是个无值的键 `zy.m3u8`。
///
/// 旧实现 `Uri.path.endsWith('.m3u8')` 会把它判成"不是 HLS"，
/// 于是本地代理不接管；而这类清单里的分片是**相对地址**
/// （`live-play.cctvnews.cctv.com_channel_cctv1_mbd-<ts>.ts`），
/// 桌面端 Media Foundation 自己拼基址会失败 → 直播全部无法播放。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/hls_proxy.dart';

void main() {
  group('looksLikeM3u8', () {
    test('普通 m3u8 直链要认出', () {
      expect(looksLikeM3u8('https://a.com/x/index.m3u8'), isTrue);
      expect(looksLikeM3u8('http://a.com/v/index.m3u8?token=abc'), isTrue);
      // 大写也要认，url 里大小写混用很常见
      expect(looksLikeM3u8('https://a.com/x/INDEX.M3U8'), isTrue);
    });

    test('.m3u8 只在 query 里也必须认出（直播取址的真实形态）', () {
      const live =
          'http://110.42.52.180:6688/zb/cctv.php?token=ZY-abc&id=cctv1&zy.m3u8';
      expect(Uri.parse(live).path.endsWith('.m3u8'), isFalse,
          reason: '确认这个地址的 path 确实不以 .m3u8 结尾');
      expect(looksLikeM3u8(live), isTrue,
          reason: '漏掉它，直播清单就不会走代理，相对分片必然拼错');
    });

    test('mp4 直链不能被误判成 HLS', () {
      expect(looksLikeM3u8('https://a.com/v/movie.mp4'), isFalse);
      expect(looksLikeM3u8('http://a.com/v/movie.mp4?sign=x'), isFalse);
    });

    test('无扩展名的 CDN 直链不误判', () {
      // 片库封面那种形态，不属于播放地址
      expect(looksLikeM3u8('http://m.ykimg.com/050E00006A85293BC7AFFF141AD91378'),
          isFalse);
    });

    test('非法输入不抛异常', () {
      expect(looksLikeM3u8(''), isFalse);
      expect(looksLikeM3u8('not a url'), isFalse);
    });
  });
}