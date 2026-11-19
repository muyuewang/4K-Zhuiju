/// 全局搜索：并发/去重/失败隔离/渐进回调。
///
/// 全局搜索是搜索页的核心，出错方式都很隐蔽：
///   1. 去重把不同剧并了 → 用户少看到结果
///   2. 去重把 sourceId 弄丢 → 点进去打错源
///   3. 一个源抛异常 → Future.wait 整体崩，整页红屏
///   4. 慢源拖住整轮 →  progressive 回调不触发，一直转圈
/// 所以用假源把这些场景全部钉死，不依赖真实网络。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/search/global_search.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/ddys_source.dart';
import 'package:zhuiju/core/source/jisu_source.dart';
import 'package:zhuiju/core/source/kanju_source.dart';
import 'package:zhuiju/core/source/kvm4k_source.dart';
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

  group('perSource：左栏按源的原始条数', () {
    test('perSource 保留每源未去重的原始列表，与去重后的总数不同', () async {
      // 三个源都命中「庆余年」，去重后只剩 1 条，
      // 但左栏必须显示 a=1、b=1、c=1 —— 否则用户点进去会看到
      // 「左栏说 1 条，列表里是 1 条」这种在单源上碰巧一致、
      // 多源重复时却对不上的数字。
      _install([
        _FakeSource('a', [_d('1', '庆余年', 'a')]),
        _FakeSource('b', [_d('2', '庆余年', 'b')]),
        _FakeSource('c', [_d('3', '庆余年', 'c')]),
      ]);

      final r = await GlobalSearchService.instance.search(
        '庆余年',
        onPartial: (_, __) {},
      );

      expect(r.results.length, 1, reason: '同名片跨源合并成一条');
      expect(r.progress.perSource.length, 3, reason: '三个源各自都有结果');
      for (final sid in ['a', 'b', 'c']) {
        expect(r.progress.perSource[sid]!.length, 1);
        expect(r.progress.perSource[sid]!.single.sourceId, sid,
            reason: '单源列表里必须保留自己源的 sourceId');
      }
      expect(r.progress.totalHits, 3, reason: '各源条数之和（未去重）');
    });

    test('perSource 不含无结果的源，且被 perSourceLimit 截断', () async {
      final many = List.generate(30, (i) => _d('$i', '剧$i', 'a'));
      _install([
        _FakeSource('a', many),
        _FakeSource('empty', const []),
      ]);

      final r = await GlobalSearchService.instance.search(
        '剧',
        onPartial: (_, __) {},
        perSourceLimit: 12,
      );

      expect(r.progress.perSource['empty'], isNull, reason: '无结果的源不该出现');
      expect(r.progress.perSource['a']!.length, 12);
      expect(r.progress.noResult, contains('empty'));
      expect(r.progress.totalHits, 12);
    });

    test('失败的源不进 perSource', () async {
      _install([
        _FakeSource('ok', [_d('1', '甲', 'ok')]),
        _FakeSource('bad', const [], throwErr: true),
      ]);

      final r = await GlobalSearchService.instance.search(
        '甲',
        onPartial: (_, __) {},
      );

      expect(r.progress.perSource.keys, ['ok']);
      expect(r.failed.containsKey('bad'), isTrue);
    });

    test('渐进回调里 perSource 随源返回逐步变大', () async {
      _install([
        _FakeSource('fast', [_d('1', '甲', 'fast')]),
        _FakeSource('slow', [_d('2', '乙', 'slow')],
            delay: const Duration(milliseconds: 120)),
      ]);

      final snapshots = <int>[];
      await GlobalSearchService.instance.search(
        'keyword',
        onPartial: (_, p) => snapshots.add(p.perSource.length),
      );

      expect(snapshots.first, 1, reason: '快源先回来，这时只有 1 个源');
      expect(snapshots.last, 2, reason: '慢源回来后才两个都有');
    });

    test('全部源都不支持搜索时 perSource 为空', () async {
      final r = await GlobalSearchService.instance.search(
        '任意',
        onPartial: (_, __) {},
      );

      expect(r.allUnsupported, isTrue);
      expect(r.progress.perSource, isEmpty);
      expect(r.progress.totalHits, 0);
    });
  });

  test('SearchSinglePage 标记只加在真的不支持翻页的源上', () {
    // 这三个源的 search 里有 `if (page > 1) return const []`（或等价
    // 的「page=2 与第 1 页逐字节相同」），页面据此隐藏分页条并给出
    // 「该源不支持翻页」的说明。用类型标记而不是 id 白名单，
    // 是为了加源时不用改页面的判断逻辑。
    expect(DdysSource.instance, isA<SearchSinglePage>());
    expect(JisuSource.instance, isA<SearchSinglePage>());
    expect(Kvm4kSource.instance, isA<SearchSinglePage>());

    // 反向断言：支持翻页的源不能被误标，否则分页条会永远不出现
    expect(KanjuSource.instance, isNot(isA<SearchSinglePage>()));
  });
}
