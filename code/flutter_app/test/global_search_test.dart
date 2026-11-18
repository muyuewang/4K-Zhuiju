/// 全局搜索：并发/去重/失败隔离/渐进回调。
///
/// 全局搜索是搜索页的核心，出错方式都很隐蔽：
///   1. 去重把不同剧并了 → 用户少看到结果
///   2. 去重把 sourceId 弄丢 → 点进去打错源
///   3. 一个源抛异常 → Future.wait 整体崩，整页红屏
///   4. 慢源拖住整轮 →  progressive 回调不触发，一直转圈
/// 所以用假源把这些场景全部钉死，不依赖真实网络。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/search/global_search.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/registry.dart';

class _FakeSource implements DataSource {
  _FakeSource(this.id, this._items, {this.delay = Duration.zero, this.throwErr = false});

  @override
  final String id;
  final List<Drama> _items;
  final Duration delay;
  final bool throwErr;

  @override
  String get displayName => '源 $id';

  @override
  String get description => 'test';

  @override
  List<SourceCategory> get categories => const [];

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (throwErr) throw StateError('boom $id');
    return _items;
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async => [];

  @override
  Future<DramaDetail> detail(String dramaId) async => DramaDetail(id: dramaId, name: '');

  @override
  Future<String> resolveUrl(DramaVideo video) async => video.path;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  bool get supportsDanmaku => false;
}

Drama _d(String id, String name, String sourceId, {int year = 2024, double stars = 0}) =>
    Drama(id: id, name: name, sourceId: sourceId, year: year, stars: stars);

void _install(List<DataSource> sources) => SourceRegistry.replacePlugins(sources);

void main() {
  setUp(() {
    // 每个用例之间清掉源，避免互相污染
    SourceRegistry.replacePlugins(<DataSource>[]);
  });

  test('跨源同剧去重，保留评分更高的那条及其 sourceId', () async {
    _install([
      _FakeSource('a', [_d('1', '庆余年', 'a', stars: 7.0)]),
      _FakeSource('b', [_d('2', '庆余年 ', 'b', stars: 9.0)]), // 空格应被归一化
      _FakeSource('c', [_d('3', '庆余年', 'c', year: 2019, stars: 8.0)]), // 不同年份=不同剧
    ]);

    final partials = <int>[];
    final r = await GlobalSearchService.instance.search(
      '庆余年',
      onPartial: (results, _) => partials.add(results.length),
    );

    expect(r.results.length, 2, reason: '2024 与 2019 两部，2024 的三条合并成一条');
    final y2024 = r.results.firstWhere((d) => d.year == 2024);
    expect(y2024.sourceId, 'b', reason: '保留评分更高的 9.0 那条，sourceId 也要跟着换');
    expect(partials.isNotEmpty, true);
  });

  test('单源超时/抛错被隔离，不影响其他源结果', () async {
    _install([
      _FakeSource('slow', [_d('1', '庆余年', 'slow')], delay: const Duration(seconds: 10)),
      _FakeSource('bad', [], throwErr: true),
      _FakeSource('good', [_d('2', '庆余年', 'good')]),
    ]);

    final r = await GlobalSearchService.instance.search(
      '庆余年',
      onPartial: (_, __) {},
      perSourceTimeout: const Duration(milliseconds: 200),
    );

    expect(r.results.length, 1);
    expect(r.results.first.sourceId, 'good');
    expect(r.failed.containsKey('bad'), true);
    expect(r.failed.containsKey('slow'), true);
  });

  test('渐进回调：快源先返回就先回调，不用等慢源', () async {
    _install([
      _FakeSource('fast', [_d('1', 'A', 'fast')], delay: const Duration(milliseconds: 20)),
      _FakeSource('slow', [_d('2', 'B', 'slow')], delay: const Duration(milliseconds: 400)),
    ]);

    final seenCounts = <int>[];
    await GlobalSearchService.instance.search(
      'x',
      onPartial: (results, progress) => seenCounts.add(results.length),
    );

    // 至少有一次回调时只拿到快源的 1 条（慢源还没回来）
    expect(seenCounts.contains(1), true, reason: '快源应先于慢源触发一次回调');
    expect(seenCounts.last, 2);
  });

  test('相关性排序：标题精确匹配排在包含匹配之前', () async {
    _install([
      _FakeSource('a', [_d('1', '庆余年第二季', 'a', year: 2025)]),
      _FakeSource('b', [_d('2', '庆余年', 'b', year: 2024)]),
    ]);

    final r = await GlobalSearchService.instance.search(
      '庆余年',
      onPartial: (_, __) {},
    );

    expect(r.results.first.name, '庆余年', reason: '完全相等相关度最高');
  });

  test('每源结果数受 perSourceLimit 限制', () async {
    final many = List.generate(50, (i) => _d('$i', '剧$i', 'a'));
    _install([_FakeSource('a', many)]);

    final r = await GlobalSearchService.instance.search(
      '剧',
      onPartial: (_, __) {},
      perSourceLimit: 10,
    );

    expect(r.results.length, 10);
  });
}
