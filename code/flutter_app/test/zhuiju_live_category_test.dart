/// 橘汁直播分类 + 频道名展示的回归测试（不联网）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/zhuiju_source.dart';

void main() {
  group('橘汁频道顺序', () {
    test('包含官方的 7 个内容分类，直播 id 必须是 25', () {
      final ids = kZhuijuCategories.map((e) => e.id).toList();
      expect(ids, contains('25'));
      expect(ids, contains('26'));
      expect(kZhuijuCategories.firstWhere((e) => e.id == '25').name, '直播');
      expect(kZhuijuCategories.firstWhere((e) => e.id == '26').name, '漫剧');
      expect(ids, isNot(contains('27'))); // 实测 27-200 全空
    });

    test('Netflix 伪分类必须已删除（它不是真 typeId1）', () {
      final ids = kZhuijuCategories.map((e) => e.id).toList();
      final names = kZhuijuCategories.map((e) => e.name).toList();
      expect(ids, isNot(contains('netflix')));
      expect(names, isNot(contains('Netflix')));
      // 它的内容本质是搜索 `clazz` 标签，和电视剧/电影重复
      expect(names.any((n) => n.contains('Netflix')), isFalse);
    });

    test('「其他」这个误标不能再出现', () {
      expect(kZhuijuCategories.map((e) => e.name), isNot(contains('其他')));
    });

    test('默认分类仍是推荐', () {
      expect(kZhuijuCategories.first.id, '');
      expect(kZhuijuCategories.first.name, '推荐');
    });
  });

  group('直播频道的 epLabel', () {
    DramaVideo live(String title, String titleOld, int ep) => DramaVideo(
          id: 'v$ep',
          title: title,
          titleOld: titleOld,
          path: 'zb-cctv$ep',
          source: 'cctv',
          sourceCn: '直播',
          episode: ep,
          dramaId: '223354',
        );

    test('频道名优先取 titleOld，不显示成「第N集」', () {
      expect(live('1', 'CCTV1综合', 1).epLabel, 'CCTV1综合');
      expect(live('2', '浙江卫视', 2).epLabel, '浙江卫视');
    });

    test('普通剧集不受影响，仍显示「第N集」', () {
      expect(
        live('第1集', '', 1).epLabel,
        '第1集',
      );
      final normal = DramaVideo(
        id: 'v1',
        title: '',
        path: 'xx',
        source: 'bfzym3u8',
        episode: 3,
        dramaId: '1',
      );
      expect(normal.epLabel, '第3集');
    });

    test('title 不是纯数字时不套用 titleOld', () {
      expect(live('CCTV1', '旧的别名', 1).epLabel, '第1集');
    });

    test('episode=0 时仍回落到 title', () {
      final v = DramaVideo(
        id: 'v0',
        title: '预告片',
        titleOld: '',
        path: 'x',
        source: 'bfzym3u8',
        dramaId: '1',
      );
      expect(v.epLabel, '预告片');
    });
  });
}