/// DramaDetail.sourcesByCn 分组缓存的回归测试。
///
/// 背景：这个 getter 被详情页调用了 6 处（构建体、续播、下载索引、
/// 线路面板、标签、播放页传参），而 kanju 一部 54 集的剧有 14 条线路
/// = 756 条记录，每次调用都要建 Map + 对 14 个列表各排序一次。
/// 任一 setState（切源、展开简介、点收藏）都会让这 6 处全部重算。
///
/// 所以加了惰性缓存。但缓存有两个必须守住的前提，这里逐条钉住：
///   1. 同一实例多次访问必须返回**同一个对象**（否则缓存没生效）
///   2. 分组内容必须依然正确（按 sourceCn 归并、按集数升序）
///
/// 第 2 条尤其重要：缓存写错不会报错，只会让线路面板少几条或者
/// 集数乱序，测不出来就只能等用户反馈。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';

DramaVideo mk({
  required int ep,
  required String source,
  String sourceCn = '',
  String path = '',
}) =>
    DramaVideo(
      id: '$source-$ep',
      title: '第$ep集',
      path: path.isEmpty ? 'https://cdn.example.com/$source/$ep.m3u8' : path,
      source: source,
      sourceCn: sourceCn,
      episode: ep,
    );

DramaDetail detail(List<DramaVideo> videos) =>
    DramaDetail(id: 'av_test', name: '测试剧', videos: videos);

void main() {
  group('sourcesByCn 缓存', () {
    test('同一实例多次访问返回同一个对象（缓存真的生效）', () {
      final d = detail([
        mk(ep: 1, source: 'a', sourceCn: '线路A'),
        mk(ep: 2, source: 'a', sourceCn: '线路A'),
      ]);
      expect(identical(d.sourcesByCn, d.sourcesByCn), isTrue,
          reason: '不缓存的话每次都是新 Map，'
              '详情页 6 处调用就要重算 6 遍');
    });

    test('按 sourceCn 归并，且每个列表内按集数升序', () {
      // 故意打乱顺序传入，模拟接口返回乱序的情况
      final d = detail([
        mk(ep: 3, source: 'a', sourceCn: '线路A'),
        mk(ep: 1, source: 'a', sourceCn: '线路A'),
        mk(ep: 2, source: 'a', sourceCn: '线路A'),
        mk(ep: 2, source: 'b', sourceCn: '线路B'),
        mk(ep: 1, source: 'b', sourceCn: '线路B'),
      ]);
      final m = d.sourcesByCn;

      expect(m.keys.toSet(), {'线路A', '线路B'});
      expect(m['线路A']!.map((e) => e.episode), [1, 2, 3],
          reason: '选集面板靠这个顺序，乱序会让「下一集」跳错');
      expect(m['线路B']!.map((e) => e.episode), [1, 2]);
    });

    test('sourceCn 为空时退化用 source 做键', () {
      final d = detail([
        mk(ep: 1, source: 'hnm3u8'),
        mk(ep: 2, source: 'hnm3u8'),
      ]);
      expect(d.sourcesByCn.keys, ['hnm3u8']);
    });

    test('缓存不影响不同实例之间的隔离', () {
      final a = detail([mk(ep: 1, source: 'a', sourceCn: '线路A')]);
      final b = detail([mk(ep: 1, source: 'b', sourceCn: '线路B')]);
      expect(a.sourcesByCn.keys, ['线路A']);
      expect(b.sourcesByCn.keys, ['线路B']);
      expect(identical(a.sourcesByCn, b.sourcesByCn), isFalse);
    });

    test('空 videos 返回空 Map，且仍可重复访问', () {
      final d = detail(const []);
      expect(d.sourcesByCn, isEmpty);
      expect(identical(d.sourcesByCn, d.sourcesByCn), isTrue);
    });

    test('kanju 量级（54 集 × 14 线路）分组正确且只算一次', () {
      final videos = <DramaVideo>[];
      for (var line = 0; line < 14; line++) {
        for (var ep = 1; ep <= 54; ep++) {
          videos.add(mk(
            ep: ep,
            source: 'src$line',
            sourceCn: '线路$line',
            path: 'https://cdn.example.com/l$line/$ep.m3u8',
          ));
        }
      }
      final d = detail(videos);

      final first = d.sourcesByCn;
      expect(first.length, 14);
      expect(first['线路0']!.length, 54);
      expect(identical(first, d.sourcesByCn), isTrue);

      // 756 条记录、14 次排序，只应发生一次
      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        d.sourcesByCn;
      }
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(50),
          reason: '缓存命中应该是纯查表；'
              '若这里超时说明缓存没生效，每次都在重建 756 条记录');
    });
  });
}