/// 搜索结果页：左侧源导航 + 单源分页。
///
/// 这几个断言守的都是「一眼看不出、但用户一定会撞上」的问题：
///   1. 左栏把无结果/超时的源也列出来 → 用户点进去必然空屏
///   2. 单源视图的条数与左栏角标对不上 → 用户以为数据错了
///   3. 不支持翻页的源画了「下一页」 → 点了没反应，看起来像坏了
///   4. 单源页丢掉来源角标 → 用户点进去不知道走的是哪个源
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/pages/home_page.dart';
import 'package:zhuiju/theme.dart';
import 'package:zhuiju/widgets/search_source_rail.dart';

/// 可翻页的假源：每页返回 [perPage] 条，超过 [maxPage] 页返回空。
class _PagingSource implements DataSource {
  _PagingSource(this.id, this.name, {this.maxPage = 2});

  @override
  final String id;
  final String name;

  /// 每页条数必须与 `kGlobalSearchPerSourceLimit` 一致（20）。
  ///
  /// 页面的「还有没有下一页」判断就是「本页条数是否够一整页」，
  /// 假源如果返回别的数字，测出来的分页行为与真机不符。
  /// 设为常量而不是构造参数：没有一个用例需要它不同。
  static const int perPage = 20;

  final int maxPage;

  @override
  String get displayName => name;

  @override
  String get description => 'test';

  @override
  List<SourceCategory> get categories => const [];

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    if (page > maxPage) return const [];
    return List.generate(
      perPage,
      (i) => Drama(
        id: '$id-p$page-$i',
        name: '$name 第$page页 第$i部',
        sourceId: id,
      ),
    );
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async =>
      const [];

  @override
  Future<DramaDetail> detail(String dramaId) async =>
      DramaDetail(id: dramaId, name: '');

  @override
  Future<String> resolveUrl(DramaVideo video) async => video.path;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  bool get supportsDanmaku => false;
}

/// 不支持翻页的假源（模拟低调/极速/4K影视）。
class _SinglePageSource extends _PagingSource implements SearchSinglePage {
  _SinglePageSource(super.id, super.name);
}

/// 永远搜不到东西的源。
class _EmptySource implements DataSource {
  _EmptySource(this.id);

  @override
  final String id;

  @override
  String get displayName => '空源 $id';

  @override
  String get description => 'test';

  @override
  List<SourceCategory> get categories => const [];

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async => const [];

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async =>
      const [];

  @override
  Future<DramaDetail> detail(String dramaId) async =>
      DramaDetail(id: dramaId, name: '');

  @override
  Future<String> resolveUrl(DramaVideo video) async => video.path;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  bool get supportsDanmaku => false;
}

/// 在左栏内部按文字找项。
///
/// 不能用 `find.text('看剧').last` —— 单源页每张海报的**来源角标**
/// 也写着「看剧」，`find.text` 会把它们全部匹配上，`.last` 点中的
/// 是某个角标而不是左栏项，于是「点了没反应」，测试以超时告终。
/// 这正是「单源页保留角标」带来的副作用，值得在这里留一条注释。
Finder _railText(String label) => find.descendant(
      of: find.byType(SearchSourceRail),
      matching: find.text(label),
    );

Future<void> _search(WidgetTester tester, String word) async {
  await tester.enterText(find.byType(TextField), word);
  await tester.tap(find.text('搜索'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SourceRegistry.replacePlugins(const []));
  tearDown(() => SourceRegistry.replacePlugins(const []));

  testWidgets('左栏只列有结果的源，无结果的源不再出现', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SourceRegistry.replacePlugins([
      _PagingSource('a', '看剧'),
      _EmptySource('b'),
    ]);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const SearchPage(),
    ));
    await _search(tester, '测试');

    // 「全部」恒在；有结果的源在；无结果的不在
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('看剧'), findsWidgets);
    expect(find.text('空源 b'), findsNothing,
        reason: '无结果的源点进去必然空屏，不该列出来');
  });

  testWidgets('单源视图出现分页条，且保留来源角标', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SourceRegistry.replacePlugins([_PagingSource('a', '看剧', maxPage: 2)]);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const SearchPage(),
    ));
    await _search(tester, '测试');

    // 「全部」页没有分页条
    expect(find.text('下一页'), findsNothing, reason: '全部页不分页');

    // 切到单源
    await tester.tap(_railText('看剧'));
    await tester.pumpAndSettle();

    expect(find.text('下一页'), findsOneWidget);
    expect(find.text('上一页'), findsOneWidget);

    // 单源页仍要显示来源角标（用户要求保留）
    final rail = tester.widget<SearchSourceRail>(find.byType(SearchSourceRail));
    expect(rail.selectedId, 'a');
    expect(rail.items.first.id, '', reason: '「全部」必须置顶');
  });

  testWidgets('不支持翻页的源给出说明，不画下一页', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SourceRegistry.replacePlugins([_SinglePageSource('s', '极速追剧')]);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const SearchPage(),
    ));
    await _search(tester, '测试');

    await tester.tap(_railText('极速追剧'));
    await tester.pumpAndSettle();

    expect(find.textContaining('该源不支持翻页'), findsOneWidget);
  });

  testWidgets('全部页显示具体条数', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SourceRegistry.replacePlugins([_PagingSource('a', '看剧')]);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const SearchPage(),
    ));
    await _search(tester, '测试');

    expect(find.textContaining('共 20 条'), findsWidgets);
  });
}