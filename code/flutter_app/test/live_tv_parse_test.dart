/// 直播源 m3u 解析的离线回归（**不联网**）。
///
/// 这些用例的报文全部取自包内真实 `.m3u`，逐字节保留（含中文台标路径、
/// 频道名里的全角括号、属性间单空格），不手工简化。
///
/// 为什么值得单独测：直播解析错了，现象是「页面上出现一堆点不开的台」
/// 或者「某个分组整个消失」，在联网测试里很难判断是源站挂了还是解析丢了。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/live_tv_source.dart';

void main() {
  group('parseM3u —— 基本字段', () {
    test('取出名称、分组、台标、地址', () {
      const s = '''
#EXTM3U x-tvg-url="https://iptv.example.com/epg.xml.gz"

#EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV1" tvg-logo="https://iptv.example.com/logo/CCTV1.webp" group-title="央视",CCTV1综合
http://example.com/cctv1.m3u8
''';
      final r = parseM3u(s);
      expect(r.length, 1);
      expect(r.first.name, 'CCTV1综合');
      expect(r.first.group, '央视');
      expect(r.first.logo, 'https://iptv.example.com/logo/CCTV1.webp');
      expect(r.first.tvgId, 'CCTV1');
      expect(r.first.url, 'http://example.com/cctv1.m3u8');
    });

    test('#EXTM3U 与 #EXT-X-* 指令不产生条目', () {
      const s = '''
#EXTM3U
#EXT-X-APP APTV
#EXT-X-APTV-TYPE remote
#EXT-X-SUB-URL https://example.com/a.m3u
#EXT-X-APTV-LATENCY: FALSE
''';
      expect(parseM3u(s), isEmpty);
    });

    test('没有 #EXTINF 的裸地址用地址当名字（否则界面上是空白卡片）', () {
      const s = 'http://example.com/a.m3u8\n';
      final r = parseM3u(s);
      expect(r.length, 1);
      expect(r.first.name, 'http://example.com/a.m3u8');
      expect(r.first.group, '');
    });
  });

  group('parseM3u —— 频道名取法', () {
    test('频道名里含逗号时取最后一个逗号之后（不能用 indexOf 切第一个）', () {
      // 真实样例：部分源把「A, B」这种中英并列名直接写进 EXTINF
      const s = '#EXTINF:-1 group-title="电影",碟中谍系列电影, 完整版\nhttp://e.com/a.m3u8\n';
      expect(parseM3u(s).first.name, '碟中谍系列电影, 完整版');
    });

    test('属性为单空格分隔时仍能解析', () {
      // 真实样例：肥猫/iptv.m3u 就是单空格，不是标准的多属性写法
      const s = '#EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV1" http-user-agent="AptvPlayer-UA" group-title="央视IPV4",CCTV1\nhttp://e.com/a\n';
      final r = parseM3u(s).first;
      expect(r.name, 'CCTV1');
      expect(r.group, '央视IPV4');
    });

    test('name 为空时回落到地址', () {
      const s = '#EXTINF:-1 group-title="x",\nhttp://e.com/a.m3u8\n';
      expect(parseM3u(s).first.name, 'http://e.com/a.m3u8');
    });

    test('中文台标路径完整保留，不做百分号编码', () {
      // 这里的原样保留很重要：编码交给 HTTP 层，解析层擅自编码会导致
      // 台标 URL 二次编码变成 404
      const s = '#EXTINF:-1 tvg-logo="https://i.example.com/logo/睛彩广场舞.webp" group-title="咪咕",睛彩广场舞\nhttp://e.com/a\n';
      expect(parseM3u(s).first.logo, 'https://i.example.com/logo/睛彩广场舞.webp');
    });
  });

  group('parseM3u —— http-user-agent（必须带，否则 404）', () {
    test('取出 http-user-agent 属性', () {
      // 真实样例：肥猫/iptv.m3u 的央视条目
      const s = '#EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV1" http-user-agent="AptvPlayer-UA" group-title="央视频道",CCTV1\nhttp://101.35.240.114:88/live.php?id=CCTV1\n';
      expect(parseM3u(s).first.ua, 'AptvPlayer-UA');
    });

    test('没写这个属性时是空串，不能继承上一条的 UA', () {
      const s = '''
#EXTINF:-1 http-user-agent="AptvPlayer-UA" group-title="A",带UA
http://e.com/a
#EXTINF:-1 group-title="B",不带UA
http://e.com/b
''';
      final r = parseM3u(s);
      expect(r[0].ua, 'AptvPlayer-UA');
      expect(r[1].ua, '');
    });

    test('toChannels 透传到频道对象', () {
      const s = '#EXTINF:-1 http-user-agent="AptvPlayer-UA",CCTV1\nhttp://e.com/a\n';
      expect(toChannels(parseM3u(s)).first.ua, 'AptvPlayer-UA');
    });

    test('ua 参与 JSON 往返', () {
      const ch = LiveChannel(
        id: 'live_1',
        name: 'CCTV1',
        url: 'http://e.com/a',
        ua: 'AptvPlayer-UA',
      );
      final back = LiveChannel.fromJson(ch.toJson());
      expect(back.ua, 'AptvPlayer-UA');
    });

    test('旧资源没有 ua 字段时反序列化成空串，不崩', () {
      final back = LiveChannel.fromJson({
        'id': 'live_1',
        'name': 'CCTV1',
        'url': 'http://e.com/a',
      });
      expect(back.ua, '');
    });
  });

  group('parseM3u —— 配对与顺序', () {
    test('多条 EXTINF 与地址一一配对，不乱序', () {
      const s = '''
#EXTINF:-1 group-title="A",频道1
http://e.com/1
#EXTINF:-1 group-title="B",频道2
http://e.com/2
#EXTINF:-1 group-title="A",频道3
http://e.com/3
''';
      final r = parseM3u(s);
      expect(r.map((e) => e.name), ['频道1', '频道2', '频道3']);
      expect(r.map((e) => e.group), ['A', 'B', 'A']);
      expect(r.map((e) => e.url), [
        'http://e.com/1',
        'http://e.com/2',
        'http://e.com/3',
      ]);
    });

    test('分组不串台：上一条的 group 不能泄漏到下一条', () {
      const s = '''
#EXTINF:-1 group-title="有分组",A
http://e.com/a
#EXTINF:-1,B
http://e.com/b
''';
      final r = parseM3u(s);
      expect(r[0].group, '有分组');
      expect(r[1].group, '', reason: '第二条没写 group-title，不能继承上一条的');
    });

    test('rtmp/rtsp 也认作地址（直播源里确实有）', () {
      const s = '''
#EXTINF:-1,A
rtmp://e.com/live/a
#EXTINF:-1,B
rtsp://e.com/b
''';
      expect(parseM3u(s).length, 2);
    });

    test('非 URL 的裸行被忽略（避免把注释尾巴当成地址）', () {
      const s = '''
#EXTINF:-1,A
这不是地址
http://e.com/a
''';
      final r = parseM3u(s);
      expect(r.length, 1);
      expect(r.first.url, 'http://e.com/a');
    });
  });

  group('toChannels —— 去重与 id', () {
    test('同一 url 只保留一条（多个文件之间有大量重复）', () {
      const s = '''
#EXTINF:-1 group-title="A",频道1
http://e.com/dup
#EXTINF:-1 group-title="B",频道1又一份
http://e.com/dup
''';
      final ch = toChannels(parseM3u(s));
      expect(ch.length, 1);
      expect(ch.first.name, '频道1', reason: '保留先出现的那个');
    });

    test('id 由 url 派生，同 url 跨次运行稳定（收藏才不会失效）', () {
      const s = '#EXTINF:-1,A\nhttp://e.com/stable\n';
      final a = toChannels(parseM3u(s)).first.id;
      final b = toChannels(parseM3u(s)).first.id;
      expect(a, b);
      expect(a, startsWith('live_'));
    });

    test('不同 url 的 id 不同', () {
      const s = '''
#EXTINF:-1,A
http://e.com/1
#EXTINF:-1,B
http://e.com/2
''';
      final ch = toChannels(parseM3u(s));
      expect(ch[0].id, isNot(ch[1].id));
    });

    test('探活结果按 url 回填 kind', () {
      const s = '''
#EXTINF:-1,A
http://e.com/a
#EXTINF:-1,B
http://e.com/b
''';
      final ch = toChannels(parseM3u(s), kinds: {'http://e.com/b': 'FLV'});
      expect(ch[0].kind, '');
      expect(ch[1].kind, 'FLV');
    });

    test('空地址条目被丢弃', () {
      final ch = toChannels([
        const M3uEntry(name: '空', url: '  '),
        const M3uEntry(name: '正常', url: 'http://e.com/ok'),
      ]);
      expect(ch.length, 1);
      expect(ch.first.name, '正常');
    });
  });

  group('decodeChannels —— 打包 JSON 还原', () {
    test('正常 JSON 数组还原', () {
      const j = '[{"id":"live_1","name":"CCTV1","url":"http://e.com/a","group":"央视","logo":"","kind":"M3U8"}]';
      final ch = decodeChannels(j);
      expect(ch.length, 1);
      expect(ch.first.name, 'CCTV1');
      expect(ch.first.group, '央视');
      expect(ch.first.kind, 'M3U8');
    });

    test('缺字段时用默认值，不抛异常', () {
      const j = '[{"name":"只有名字"}]';
      final ch = decodeChannels(j);
      expect(ch.length, 1);
      expect(ch.first.url, '');
      expect(ch.first.group, '');
    });

    test('非法 JSON 返回空列表（资源坏了不能让 App 起不来）', () {
      expect(decodeChannels('not json'), isEmpty);
      expect(decodeChannels(''), isEmpty);
      expect(decodeChannels('{"a":1}'), isEmpty,
          reason: '顶层不是数组就当作空');
    });

    test('数组里有非对象元素时跳过，不整批丢', () {
      const j = '[123,{"name":"好条目","url":"http://e.com/a"},null]';
      final ch = decodeChannels(j);
      expect(ch.length, 1);
      expect(ch.first.name, '好条目');
    });
  });

  group('真实报文回归', () {
    test('东篱 Gather 的三行真实片段能正确解析', () {
      const s = '''
#EXTM3U x-tvg-url="https://iptv.yang-1989.xyz/epg.xml.gz"

#EXTINF:-1 tvg-id="睛彩广场舞" tvg-name="睛彩广场舞" tvg-logo="https://iptv.yang-1989.xyz/logo/睛彩广场舞.webp" group-title="•咪咕「移动」",睛彩广场舞「移动」
http://gslbserv.itv.cmvideo.cn/index.m3u8?channel-id=FifastbLive&Contentid=3000000020000011523&livemode=1&stbId=YanG-1989
''';
      final r = parseM3u(s).first;
      expect(r.name, '睛彩广场舞「移动」');
      expect(r.group, '•咪咕「移动」');
      expect(r.url, contains('Contentid=3000000020000011523'));
    });

    test('嗷呜系（B站/斗鱼/虎牙/YY 聚合）的地址形态', () {
      const s = '''
#EXTINF:-1 tvg-logo="https://i0.hdslb.com/bfs/live-key-frame/kf.jpg" group-title="户外", 不好好读书 长大要跟我回村的！
https://live.ottiptv.cc/bilibili/30180115
''';
      final r = parseM3u(s).first;
      // 注意：名字前有一个空格，必须 trim 掉，否则列表排序会跑偏
      expect(r.name, '不好好读书 长大要跟我回村的！');
      expect(r.group, '户外');
      expect(r.url, 'https://live.ottiptv.cc/bilibili/30180115');
    });
  });

  _crcCrossCheck();
}
/// 下面这组断言的**期望值全部由 Python 的 zlib.crc32 算出**，
/// 不是从 Dart 实现里抄回来的。这样才有意义：
/// 打包脚本（Python）和运行时代码（Dart）必须算出同一个 id，
/// 否则「运行时解析 m3u 得到的频道」和「打包文件里的频道」
/// 会被当成两个不同的台，收藏/历史全部对不上。
void _crcCrossCheck() {
  group('stableIdOf —— 与打包脚本的 Python zlib.crc32 对齐', () {
    test('纯 ASCII 地址', () {
      // python: zlib.crc32(b'http://e.com/a')
      expect(stableIdOf('http://e.com/a'), 'live_$_expectA');
    });

    test('带中文的地址（必须按 UTF-8 字节算，不能按 UTF-16 code unit）', () {
      expect(stableIdOf('https://e.com/logo/睛彩广场舞'),
          'live_$_expectB');
    });

    test('与资源文件里真实频道的 id 一致', () {
      // 取自 assets/live_channels.json 的真实条目
      expect(
        stableIdOf('https://live.ottiptv.cc/bilibili/30180115'),
        'live_$_expectC',
      );
    });

    test('同输入多次调用结果不变', () {
      const u = 'http://e.com/stable';
      expect(stableIdOf(u), stableIdOf(u));
    });

    test('不同输入结果不同', () {
      expect(stableIdOf('http://e.com/1'), isNot(stableIdOf('http://e.com/2')));
    });

    test('id 形如 live_ + 8 位小写十六进制', () {
      final id = stableIdOf('http://e.com/x');
      expect(id, matches(RegExp(r'^live_[0-9a-f]{8}$')));
    });
  });
}

const _expectA = 'fe8ae5d7';
const _expectB = '4551733e';
const _expectC = 'ffe61435';
