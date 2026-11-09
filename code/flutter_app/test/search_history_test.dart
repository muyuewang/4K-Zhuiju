/// 搜索历史
///
/// 这个功能最容易出错的地方不是「存不进去」，而是**顺序和去重**：
/// 重复搜同一个词时如果只是追加，列表里会出现两三个一样的词；
/// 而如果去重时不是「删掉旧的再插到最前」，用户最近搜的词会沉底，
/// 历史就失去了意义。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuiju/core/search_history.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 单例在测试之间会保留状态，每个用例开头清掉
    SearchHistory.instance.clear();
  });

  group('SearchHistory', () {
    test('空关键词不产生记录', () {
      SearchHistory.instance.add('');
      SearchHistory.instance.add('   ');
      SearchHistory.instance.add('\n\t ');
      expect(SearchHistory.instance.items.value, isEmpty);
    });

    test('最近搜的排最前', () {
      final h = SearchHistory.instance;
      h.add('仙逆');
      h.add('凡人修仙传');
      h.add('吞噬星空');
      expect(h.items.value, ['吞噬星空', '凡人修仙传', '仙逆']);
    });

    test('重复搜索只顶到最前，不出现两次', () {
      final h = SearchHistory.instance;
      h.add('仙逆');
      h.add('凡人修仙传');
      h.add('仙逆');
      expect(h.items.value, ['仙逆', '凡人修仙传']);
      expect(h.items.value.where((e) => e == '仙逆').length, 1);
    });

    test('首尾空白被裁掉，内部连续空白压成一个空格', () {
      final h = SearchHistory.instance;
      h.add('  凡人   修仙传  ');
      expect(h.items.value, ['凡人 修仙传']);
    });

    test('超长关键词被截断，不会把列表撑爆', () {
      final h = SearchHistory.instance;
      h.add('剧' * 200);
      expect(h.items.value.single.length, SearchHistory.maxKeywordLen);
    });

    test('超过上限时丢掉最旧的', () {
      final h = SearchHistory.instance;
      for (var i = 0; i < SearchHistory.maxItems + 5; i++) {
        h.add('词$i');
      }
      expect(h.items.value.length, SearchHistory.maxItems);
      // 最新的在最前，最旧的（词0~词4）已被挤出
      expect(h.items.value.first, '词${SearchHistory.maxItems + 4}');
      expect(h.items.value.contains('词0'), isFalse);
    });

    test('删除单条只影响这一条', () {
      final h = SearchHistory.instance;
      h.add('A');
      h.add('B');
      h.add('C');
      h.remove('B');
      expect(h.items.value, ['C', 'A']);
    });

    test('删除不存在的词不改变列表', () {
      final h = SearchHistory.instance;
      h.add('A');
      final before = List<String>.from(h.items.value);
      h.remove('不存在的');
      expect(h.items.value, before);
    });

    test('清空后列表为空', () {
      final h = SearchHistory.instance;
      h.add('A');
      h.add('B');
      h.clear();
      expect(h.items.value, isEmpty);
    });

    test('写盘后能读回，且顺序不变', () async {
      final h = SearchHistory.instance;
      h.add('仙逆');
      h.add('吞噬星空');
      // 写入是 fire-and-forget，等一轮事件循环让 setStringList 落地
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final sp = await SharedPreferences.getInstance();
      final saved = sp.getStringList('search_history');
      expect(saved, isNotNull);
      expect(saved!.first, '吞噬星空');
      expect(saved.length, 2);
    });
  });
}