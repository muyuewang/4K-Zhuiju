/// MacCMS 采集接口（JSON API）解析回归（不联网）。
///
/// 这两个函数是「大师兄 · 暴风 / 大师兄 · 量子」两个源的全部解析逻辑，
/// 一旦被改坏，现象是「详情页能打开但一集都没有」或「点播放转圈后报错」，
/// 在联网测试里极难定位。所以用**真实报文片段**把它钉死。
///
/// 报文样本全部来自 2026-11-11 实测：
///   暴风 `?ac=detail&wd=嫁金钗` → vod_id=168316，from=`bfzym3u8`
///   量子 `?ac=detail&ids=91870` → from=`liangzi$$$lzm3u8`，各 455 集
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/maccms_api_source.dart';

void main() {
  group('parseApiLines', () {
    test(r'单线路单集：$ 分隔集名与地址', () {
      final lines = parseApiLines(
        'bfzym3u8',
        r'第1集$https://v.fengbao14.com/video/jiajincha/6fb630374787/index.m3u8',
      );
      expect(lines.length, 1);
      expect(lines.first.flag, 'bfzym3u8');
      expect(lines.first.eps.length, 1);
      expect(lines.first.eps.first.title, '第1集');
      expect(lines.first.eps.first.url,
          'https://v.fengbao14.com/video/jiajincha/6fb630374787/index.m3u8');
    });

    test(r'# 才是分集分隔符，$$$ 是线路分隔符（不能反）', () {
      // 真实形态：两条线路，第一条 2 集，第二条 1 集
      const from = r'liangzi$$$lzm3u8';
      const urls = r'第01集$https://v.cdnlz18.com/share/aaa#第02集$https://v.cdnlz18.com/share/bbb'
          r'$$$第01集$https://v.cdnlz18.com/20240727/14879_e529730a/index.m3u8';

      final lines = parseApiLines(from, urls);
      expect(lines.length, 2, reason: '两条线路，不是 5 条');
      expect(lines[0].flag, 'liangzi');
      expect(lines[0].eps.length, 2);
      expect(lines[1].flag, 'lzm3u8');
      expect(lines[1].eps.length, 1);
      expect(lines[1].eps.first.url,
          'https://v.cdnlz18.com/20240727/14879_e529730a/index.m3u8');
    });

    test('线路名走 nameCn 映射，未命中就保留原始 flag', () {
      final lines = parseApiLines(
        r'bfzym3u8$$$unknownm3u8',
        r'第1集$https://a.com/1.m3u8$$$第1集$https://b.com/1.m3u8',
        nameCn: const {'bfzym3u8': '暴风线路'},
      );
      expect(lines[0].name, '暴风线路');
      expect(lines[1].name, 'unknownm3u8', reason: '不认识的 flag 也要能显示，不能变成空白');
    });

    test(r'裸地址（没有 $ 集名）要补出「第N集」', () {
      final lines = parseApiLines(
        'bfzym3u8',
        'https://a.com/1.m3u8#https://a.com/2.m3u8',
      );
      expect(lines.first.eps.length, 2);
      expect(lines.first.eps[0].title, '第1集');
      expect(lines.first.eps[1].title, '第2集');
      expect(lines.first.eps[0].url, 'https://a.com/1.m3u8');
    });

    test(r'地址本身含 $ 时，只在第一个 $ 处切分', () {
      // 少数站会把带 token 的地址直接拼进去，token 里可能有 $
      final lines = parseApiLines(
        'bfzym3u8',
        r'第1集$https://a.com/x.m3u8?sign=ab$cd',
      );
      expect(lines.first.eps.first.title, '第1集');
      expect(lines.first.eps.first.url, r'https://a.com/x.m3u8?sign=ab$cd');
    });

    test('空线路 / 空集要跳过，不能生成空条目', () {
      // 真实报文里常见 `$$$` 连着写，代表中间那条线路是空的
      final lines = parseApiLines(
        r'aa$$$bb$$$cc',
        r'第1集$https://a.com/1.m3u8$$$$$$第1集$https://c.com/1.m3u8',
      );
      expect(lines.length, 2, reason: '空线路要整条丢掉');
      expect(lines[0].flag, 'aa');
      expect(lines[1].flag, 'cc');
    });

    test('play_from 比 play_url 短时不能越界', () {
      final lines = parseApiLines(
        'onlyone',
        r'第1集$https://a.com/1.m3u8$$$第1集$https://b.com/1.m3u8',
      );
      expect(lines.length, 2);
      expect(lines[1].flag, 'line1', reason: '缺 from 时给兜底标识，不能崩');
    });

    test('全空输入返回空列表而不是抛异常', () {
      expect(parseApiLines('', ''), isEmpty);
      expect(parseApiLines('', r'$$$'), isEmpty);
    });
  });

  group('extractShareMainUrl', () {
    // 量子 liangzi 线路分享页的真实片段（已截取关键部分）
    const sharePage = '''
<!doctype html>
<html><head><title>美食新闻报道001</title></head>
<body onload="init()">
<script type="text/javascript">
    var video_player= 'artplayer'
    var videoid = "e98549a4cb29369fb6dbb48ab0b6e018";
    var main = "/20240727/14879_e529730a/index.m3u8?sign=680726d69e82d1ee13d9eb539f89b485";
    var xml = "/20240727/14879_e529730a/index.xml?sign=680726d69e82d1ee13d9eb539f89b485";
</script>
</body></html>
''';

    test('从分享页抠出 var main 并补全为绝对地址', () {
      final url = extractShareMainUrl(
        sharePage,
        'https://v.cdnlz18.com/share/e98549a4cb29369fb6dbb48ab0b6e018/',
      );
      expect(url,
          'https://v.cdnlz18.com/20240727/14879_e529730a/index.m3u8?sign=680726d69e82d1ee13d9eb539f89b485');
    });

    test('已经是绝对地址就原样返回', () {
      final url = extractShareMainUrl(
        'var main = "https://cdn.x.com/a/index.m3u8";',
        'https://v.cdnlz18.com/share/abc',
      );
      expect(url, 'https://cdn.x.com/a/index.m3u8');
    });

    test('单引号写法也要认', () {
      final url = extractShareMainUrl(
        "var main = '/a/index.m3u8';",
        'https://h.com/share/x',
      );
      expect(url, 'https://h.com/a/index.m3u8');
    });

    test('没有 main 或不是视频地址时返回 null，交给上层给友好报错', () {
      expect(extractShareMainUrl('<html>nothing here</html>', 'https://h.com/x'),
          isNull);
      // 有 main 但指向网页 → 不能当播放地址返回
      expect(
        extractShareMainUrl('var main = "/player.html";', 'https://h.com/x'),
        isNull,
      );
      expect(extractShareMainUrl('var main = "";', 'https://h.com/x'), isNull);
    });
  });
}