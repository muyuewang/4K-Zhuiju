/// 采集站 HTML 解析的离线回归：用真实抓下来的片段，不联网。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/mac_cms_source.dart';

const String kBase = 'https://4k01.pianku.online';

void main() {
  group('片库首页封面：CDN 直链大量无扩展名', () {
    // 2026-11-11 从 4k01.pianku.online 首页抓的真实片段
    const noExtCard = '''
<div class="swiper-slide"><div class="vod-item">
<a href="/voddetail/118681.html" title="师兄太稳健">
<div class="vod-pic">
<img src="http://m.ykimg.com/050E00006A85293BC7AFFF141AD91378"
 referrerpolicy="no-referrer" loading="lazy" onerror="this.src='/load.gif'">
<span class="remarks">全剧集</span></div>
<div class="vod-info"><h4 class="title">师兄太稳健</h4></div></a></div></div>
''';

    test('无扩展名的 http 封面必须被取到（旧版整片空白的根因）', () {
      expect(parseSiteCover(noExtCard, kBase),
          'http://m.ykimg.com/050E00006A85293BC7AFFF141AD91378');
    });

    test('带 .jpg 的封面仍正常', () {
      const h = '<img src="https://img1.wsyzy.org/upload/vod/x.jpg">';
      expect(parseSiteCover(h, kBase),
          'https://img1.wsyzy.org/upload/vod/x.jpg');
    });

    test('相对路径补站点域名', () {
      const h = '<img data-original="/upload/vod/2026/a.jpg">';
      expect(parseSiteCover(h, kBase),
          'https://4k01.pianku.online/upload/vod/2026/a.jpg');
    });

    test('协议相对路径补 https', () {
      const h = '<img src="//cdn.example.com/a.webp">';
      expect(parseSiteCover(h, kBase), 'https://cdn.example.com/a.webp');
    });

    test('script 的 src 不能被当成封面', () {
      const h = '<script src="/template/a/jquery.min.js"></script>'
          '<img src="https://cdn.example.com/poster">';
      expect(parseSiteCover(h, kBase), 'https://cdn.example.com/poster');
    });

    test('占位图 / load.gif 要跳过，取后面那张真封面', () {
      const h = '<img class="lazy" data-original="/load.gif">'
          '<img src="https://cdn.example.com/real">';
      expect(parseSiteCover(h, kBase), 'https://cdn.example.com/real');
    });

    test('整段没有图片时返回空串，不抛异常', () {
      expect(parseSiteCover('<div>文字</div>', kBase), '');
    });
  });
}