/// 直播多线路：数据模型与线路切换的基础约定。
///
/// 这一层测的是「构建期聚合出来的 lines 能不能被运行时正确理解」。
/// 真实的失败切换要靠播放器 widget 去跑（需要真的播不出来），
/// 这里先把三条最容易出错、又完全能在纯逻辑层验证的约定钉死：
///
///   1. allLines 必须「主地址在前、备线路在后」且**不重复**；
///   2. 单线路频道的 lineCount 必须是 1（界面据此决定是否显示"线路 1/1"）；
///   3. JSON 往返不能丢 lines（丢了就等于多线路功能在打包后静默失效）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/live_tv_source.dart';

void main() {
  // LiveTvLibrary.all() 走 rootBundle，没有 binding 会直接抛
  // "Binding has not yet been initialized"，而那表现为"资产是空的"，
  // 很容易被误读成"聚合结果没写进去"。
  TestWidgetsFlutterBinding.ensureInitialized();

  LiveChannel withLines() => const LiveChannel(
        id: 'live_test',
        name: '浙江卫视',
        url: 'http://main.example/a.m3u8',
        section: '央卫视',
        kind: 'M3U8',
        lines: [
          LiveLine(url: 'http://backup1.example/b.m3u8', kind: 'M3U8'),
          LiveLine(
            url: 'http://backup2.example/c.m3u8',
            kind: 'FLV',
            ua: 'SpecialUA/1.0',
          ),
        ],
      );

  group('allLines', () {
    test('主地址排第一，备线路按声明顺序跟在后面', () {
      final urls = withLines().allLines.map((l) => l.url).toList();
      expect(urls, [
        'http://main.example/a.m3u8',
        'http://backup1.example/b.m3u8',
        'http://backup2.example/c.m3u8',
      ]);
    });

    test('主地址不会重复出现（构建脚本必须排除它）', () {
      final urls = withLines().allLines.map((l) => l.url).toList();
      expect(urls.toSet().length, urls.length);
    });

    test('每条线路带自己的 kind 与 ua，不套用频道级字段', () {
      final lines = withLines().allLines;
      // 主线路继承频道级 kind
      expect(lines[0].kind, 'M3U8');
      expect(lines[0].ua, '');
      // 备线路用自己的：这条是 FLV，且带专属 UA。
      // 若这里被频道级的 M3U8 覆盖，播放器会按 m3u8 去播一条 FLV 流。
      expect(lines[2].kind, 'FLV');
      expect(lines[2].ua, 'SpecialUA/1.0');
    });

    test('单线路频道的 lineCount 为 1', () {
      const single = LiveChannel(
        id: 'live_one',
        name: 'CCTV1',
        url: 'http://a.example/a.m3u8',
      );
      expect(single.lineCount, 1);
      expect(single.allLines.length, 1);
    });

    test('多线路频道的 lineCount 含主地址', () {
      expect(withLines().lineCount, 3);
    });
  });

  group('JSON 往返', () {
    test('lines 能完整还原', () {
      final back = LiveChannel.fromJson(withLines().toJson());
      expect(back.lineCount, 3);
      // allLines = [主, 备1, 备2]，所以下标 2 就是 lines[1]（带专属 UA 那条）
      expect(back.allLines[2].ua, 'SpecialUA/1.0');
      // lines 自己不含主地址，下标 0 是备1（M3U8），1 是备2（FLV）
      expect(back.lines[0].kind, 'M3U8');
      expect(back.lines[1].kind, 'FLV');
    });

    test('单线路不写 lines 字段，读回来也不能变成 null 崩溃', () {
      const single = LiveChannel(
        id: 'live_one',
        name: 'CCTV1',
        url: 'http://a.example/a.m3u8',
      );
      final j = single.toJson();
      // 空列表时不落盘：2676 个频道里绝大多数是单线路，
      // 每个都写一个 "lines":[] 会让资产白白变大
      expect(j.containsKey('lines'), isFalse);
      expect(LiveChannel.fromJson(j).lines, isEmpty);
    });

    test('lines 里有脏元素时跳过，不整条丢弃', () {
      final ch = LiveChannel.fromJson({
        'id': 'x',
        'name': 'n',
        'url': 'http://a/1.m3u8',
        'lines': [
          {'url': 'http://a/2.m3u8'},
          'not-a-map',
          123,
        ],
      });
      expect(ch.lines.length, 1);
      expect(ch.lines.first.url, 'http://a/2.m3u8');
    });
  });

  group('打包资产', () {
    test('多线路频道的 lines 不含主地址，且 URL 全局唯一', () async {
      final all = await LiveTvLibrary.all();
      expect(all, isNotEmpty);

      var multi = 0;
      for (final c in all) {
        if (c.lines.isEmpty) continue;
        multi++;
        final urls = c.allLines.map((l) => l.url).toList();
        expect(urls.toSet().length, urls.length,
            reason: '「${c.name}」的线路里有重复地址，切换时会重试同一条');
        expect(c.lines.any((l) => l.url == c.url), isFalse,
            reason: '「${c.name}」的 lines 里包含了主地址，会让失败重试多等一轮');
      }
      // 聚合脚本当前产出 12 组。这里只断言"确实存在多线路"，
      // 不锁死具体数字 —— 源更新后组数会变，锁死会让测试变成噪音。
      expect(multi, greaterThan(0),
          reason: '资产里一个多线路频道都没有，聚合脚本没跑或结果没写进去');
    });

    test('主播类不做多线路聚合（同名不等于同一路）', () async {
      final all = await LiveTvLibrary.all();
      // 「主播原创」「一起看」里大量同名条目其实是**不同主播**：
      // 实测 `YY用户` 69 条、`我是一颗小虎牙` 18 条。把它们聚成
      // 一个频道，用户点开就会在几十个陌生人之间乱跳。
      final bad = all.where((c) =>
          (c.section == '主播原创' || c.section == '一起看') &&
          c.lines.isNotEmpty);
      expect(bad, isEmpty,
          reason: '主播类出现了多线路聚合：${bad.map((c) => c.name).take(5).toList()}');
    });
  });
}