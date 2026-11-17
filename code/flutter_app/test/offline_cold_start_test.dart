/// 零源冷启动：配置还没拉到时，首页必须能正常渲染。
///
/// ## 为什么这个文件必须存在
///
/// 2026-11-17 的架构反转把「源」从安装包里搬到了远端，于是
/// **「一个源都没有」从不可能状态变成了每次首次安装的必经状态**。
///
/// 这条路径藏着几处会直接崩的写法，而且都只在空列表时触发：
///
///   1. `SourceRegistry.all.first` → `Bad state: No element`
///      （首次启动必然空，等于一装就闪退）
///   2. `TabController(length: 0)` → TabBarView 断言失败
///   3. TV 布局 `_cats[i].name` 在没有分类时越界
///
/// 这些都不是「布局好看不好看」的问题，是「能不能启动」的问题。
/// 用户看到的会是白屏或闪退，而我们这边一条日志都没有——
/// 所以必须在 CI 里钉死。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/offline_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/tv.dart';
import 'package:zhuiju/pages/home_page.dart';
import 'package:zhuiju/theme.dart';

/// 立即返回空列表，不产生任何异步延迟（见 tv_home_layout_test 的说明）
Future<List<Drama>> _emptyLoader(int tabIndex, int page) async => const [];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 刻意什么都不装：这就是「配置还没拉到」的真实状态
    SourceRegistry.replacePlugins(const <DataSource>[]);
  });

  tearDown(() {
    SourceRegistry.replacePlugins(const <DataSource>[]);
    TvMode.instance.override.value = TvOverride.auto;
    TvMode.instance.enabled.value = false;
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: child,
      );

  void useTvViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('零源状态', () {
    test('注册表本身不抛异常', () {
      // 这一条看似琐碎，但它盯的是最容易犯的写法：
      // `_all.first` 在空列表上直接 `Bad state: No element`。
      expect(SourceRegistry.isEmpty, isTrue);
      expect(SourceRegistry.pluginCount, 0);
      expect(() => SourceRegistry.all, returnsNormally);
      expect(() => SourceRegistry.instance.now, returnsNormally);
      expect(SourceRegistry.all.first, isA<OfflineSource>());
    });

    test('byId 任何输入都返回占位，不抛异常', () {
      for (final id in <String?>[null, '', 'bofeng', 'nonexistent']) {
        expect(() => SourceRegistry.instance.byId(id), returnsNormally,
            reason: 'byId($id) 抛异常会让所有详情页/收藏页在冷启动时崩');
        expect(SourceRegistry.instance.byId(id), isA<OfflineSource>());
      }
    });

    testWidgets('手机布局：首页能渲染，不崩', (tester) async {
      await tester.pumpWidget(wrap(const HomePage(debugLoader: _emptyLoader)));
      await tester.pump();

      // 不要求具体文案（提示语以后可能改），只要求「画出来了」：
      // 有 Scaffold 说明树建完了，没抛异常。
      expect(find.byType(Scaffold), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: '空分类导致 TabController(length: 0) 或 TabBarView 断言失败');
    });

    testWidgets('TV 布局：首页能渲染，不崩', (tester) async {
      // TV 分支单独测：它走 IndexedStack + 自绘频道条，
      // 和手机分支是两条几乎不相交的代码路径，
      // `_cats[i].name` 那种越界只在 TV 侧出现。
      useTvViewport(tester);
      TvMode.instance.enabled.value = true;

      await tester.pumpWidget(wrap(const HomePage(debugLoader: _emptyLoader)));
      await tester.pump();

      expect(find.byType(Scaffold), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'TV 频道条在零分类时越界（_cats[i].name）');
      // 频道条标题仍在，只是没有胶囊
      expect(find.text('频道'), findsOneWidget);
    });

    testWidgets('零源 → 装入源：首页自动重建出分类条', (tester) async {
      // 这是真实的时间线：App 先起来（零源），配置几百毫秒后才到。
      // 注册表的变化必须能推着首页重建，否则用户要手动切一次源
      // 才看得到内容——而那时候他根本还不知道有「切源」这件事。
      await tester.pumpWidget(wrap(const HomePage(debugLoader: _emptyLoader)));
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);

      SourceRegistry.replacePlugins(<DataSource>[_StubSource()]);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      for (final c in const ['电影', '剧集']) {
        expect(find.text(c), findsWidgets,
            reason: '配置到达后应自动出现分类「$c」，不需要用户操作');
      }
    });
  });
}

/// 带两个分类的最小源，用于验证「配置到达后界面自动跟上」。
class _StubSource implements DataSource {
  @override
  String get id => 'stub';
  @override
  String get displayName => '假源';
  @override
  String get description => '测试用';
  @override
  List<SourceCategory> get categories => const <SourceCategory>[
        SourceCategory('', '推荐'),
        SourceCategory('1', '电影'),
        SourceCategory('2', '剧集'),
      ];
  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;
  @override
  bool get supportsDanmaku => false;
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
}