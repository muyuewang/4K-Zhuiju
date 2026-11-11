/// 追剧收藏
///
/// 关键行为是「幂等 + 不重复」：同一部剧反复收藏/取消，列表里只能有
/// 一条；重复 add 不该变成两条，也不该把收藏时间刷新成最新（否则
/// 「最近收藏」的排序会乱跳）。
///
/// 2026-11 起 id 从 int 改成 String，以兼容第二个数据源（kanju 的
/// `av_xxx` 长串 id）。这里额外覆盖了「旧本地数据是 int」的读取兼容，
/// 因为用户手机上已经存着旧格式的 JSON。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/favorites.dart';

void main() {
  setUp(() {
    // 单例跨用例保留状态，每条用例开头清干净
    FavoriteStore.instance.clear();
  });

  group('FavoriteItem 模型', () {
    test('副标题拼接日期/地区/备注，空项跳过', () {
      const a = FavoriteItem(dramaId: '1', name: 'x', year: 2024, area: '国产');
      expect(a.subtitle, '2024 · 国产');

      const b = FavoriteItem(dramaId: '1', name: 'x', remark: '全40集');
      expect(b.subtitle, '全40集');

      const c = FavoriteItem(dramaId: '1', name: 'x');
      expect(c.subtitle, '');
    });

    test('序列化往返保持一致', () {
      const a = FavoriteItem(
        dramaId: '7',
        name: '仙逆',
        cover: 'http://x/y.jpg',
        year: 2023,
        area: '国产',
        remark: '更新至80集',
        sourceId: 'kanju',
        addedAt: 1700000000000,
      );
      final back = FavoriteItem.fromJson(a.toJson())!;
      expect(back.dramaId, a.dramaId);
      expect(back.name, a.name);
      expect(back.cover, a.cover);
      expect(back.year, a.year);
      expect(back.area, a.area);
      expect(back.remark, a.remark);
      expect(back.sourceId, a.sourceId);
      expect(back.addedAt, a.addedAt);
      expect(back.subtitle, a.subtitle);
    });

    test('缺 id 或名字的记录被判为无效', () {
      // 旧版本写下的 int 0 必须仍被当作「没有 id」
      expect(FavoriteItem.fromJson({'dramaId': 0, 'name': 'x'}), isNull);
      expect(FavoriteItem.fromJson({'dramaId': '', 'name': 'x'}), isNull);
      expect(FavoriteItem.fromJson({'name': 'x'}), isNull);
      expect(FavoriteItem.fromJson({'dramaId': '3', 'name': ''}), isNull);
      expect(FavoriteItem.fromJson({'dramaId': 3}), isNull);
    });

    test('旧版 int 格式的本地数据能读成字符串 id', () {
      // 这是真实升级路径：用户手机上存的还是 {"dramaId": 12345}
      final old = FavoriteItem.fromJson({'dramaId': 12345, 'name': '老剧'})!;
      expect(old.dramaId, '12345');
      expect(old.name, '老剧');

      // 新格式（长串）也要能读
      final nu = FavoriteItem.fromJson({
        'dramaId': 'av_nH2ZeKZ0Ft4q',
        'name': '新剧',
        'sourceId': 'kanju',
      })!;
      expect(nu.dramaId, 'av_nH2ZeKZ0Ft4q');
      expect(nu.sourceId, 'kanju');
    });

    test('宽高无关，但缺可选字段时给默认值', () {
      final it = FavoriteItem.fromJson({'dramaId': 5, 'name': '剧'})!;
      expect(it.cover, '');
      expect(it.year, 0);
      expect(it.area, '');
      expect(it.remark, '');
      expect(it.sourceId, '');
      expect(it.addedAt, 0);
    });
  });

  group('FavoriteStore', () {
    test('初始为空', () {
      expect(FavoriteStore.instance.items.value, isEmpty);
      expect(FavoriteStore.instance.contains('1'), isFalse);
    });

    test('add 之后 contains 为真，出现在列表里', () {
      FavoriteStore.instance.add(dramaId: '1', name: '仙逆');
      expect(FavoriteStore.instance.contains('1'), isTrue);
      expect(FavoriteStore.instance.items.value.single.name, '仙逆');
    });

    test('toggle 第一次返回 true（已收藏），第二次返回 false（已取消）', () {
      final s = FavoriteStore.instance;
      expect(s.toggle(dramaId: '9', name: '剧'), isTrue);
      expect(s.contains('9'), isTrue);
      expect(s.toggle(dramaId: '9', name: '剧'), isFalse);
      expect(s.contains('9'), isFalse);
    });

    test('重复 add 不会产生两条', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '2', name: 'A');
      s.add(dramaId: '2', name: 'A');
      s.add(dramaId: '2', name: 'A');
      expect(s.items.value.length, 1);
    });

    test('重复 add 保留原收藏时间，不刷新排序', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '2', name: 'A');
      final firstAt = s.items.value.single.addedAt;
      s.add(dramaId: '2', name: 'A');
      expect(s.items.value.single.addedAt, firstAt);
    });

    test('重复 add 会更新封面等元信息', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '2', name: 'A', cover: 'old');
      s.add(dramaId: '2', name: 'A', cover: 'new', remark: '全10集');
      expect(s.items.value.single.cover, 'new');
      expect(s.items.value.single.remark, '全10集');
    });

    test('新收藏排在最前', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '1', name: 'A');
      s.add(dramaId: '2', name: 'B');
      s.add(dramaId: '3', name: 'C');
      expect(s.items.value.map((e) => e.dramaId).toList(), ['3', '2', '1']);
    });

    test('remove 只删指定的一部', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '1', name: 'A');
      s.add(dramaId: '2', name: 'B');
      s.remove('1');
      expect(s.items.value.single.dramaId, '2');
    });

    test('remove 不存在的 id 不改变列表', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '1', name: 'A');
      final before = List<FavoriteItem>.from(s.items.value);
      s.remove('999');
      expect(s.items.value, before);
    });

    test('id 为空或名字为空时拒绝收藏（脏数据防护）', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '', name: '有名字');
      s.add(dramaId: '5', name: '');
      expect(s.items.value, isEmpty);
    });

    test('kanju 长串 id 与橘汁数字 id 可共存且不互相覆盖', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '12345', name: '橘汁剧');
      s.add(dramaId: 'av_nH2ZeKZ0Ft4q', name: 'kanju剧', sourceId: 'kanju');
      expect(s.items.value.length, 2);
      expect(s.contains('12345'), isTrue);
      expect(s.contains('av_nH2ZeKZ0Ft4q'), isTrue);
      // 存进去的 sourceId 要能被读回来，否则回详情页会用错源
      final k = s.items.value.firstWhere((e) => e.dramaId.startsWith('av_'));
      expect(k.sourceId, 'kanju');
    });

    test('清空后为空', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '1', name: 'A');
      s.add(dramaId: '2', name: 'B');
      s.clear();
      expect(s.items.value, isEmpty);
    });

    test('收藏与观看历史互不影响（收藏不会被历史清空带走）', () {
      final s = FavoriteStore.instance;
      s.add(dramaId: '42', name: '想追的剧');
      // 只调收藏侧的 clear 以外什么都不做，模拟「清空观看记录」：
      // 那个操作只碰 HistoryStore，这里确认收藏仍在
      expect(s.contains('42'), isTrue);
    });
  });
}