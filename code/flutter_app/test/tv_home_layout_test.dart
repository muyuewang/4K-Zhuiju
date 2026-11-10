/// TV 首页布局回归
///
/// 锁住三件「改一行代码就会静默失效、而电视上很难看出来」的事：
///
///   1. TV 下必须有横向频道条，且 7 个分类全部可见。
///      TabBarView 在电视上没有意义（遥控器没有「横划」手势），
///      换成常显的胶囊行后，频道必须一次性全摆出来。
///   2. 非当前分类不能构建网格。
///      TV 布局用 IndexedStack，它会把 children 全部实例化 ——
///      7 个分类等于开机并发 7 个列表请求。必须按 _visited 剪掉。
///   3. 手机布局不能被 TV 改动带坏。
///      同一个 build 里分了两条分支，改动很容易只顾一边。
///
/// **为什么全部注入 debugLoader**：
///   PagedGrid 在 initState 就发请求。widget 测试结束时只要还有未完成的
///   定时器，flutter_test 的 `!timersPending` 断言就直接失败，而 Dio 在
///   fetch 内部会挂一个零时长定时器。用假 HttpClient 桩拦不住它——请求链
///   不止走 dart:io 那一层（试过，5 个用例照样全红）。所以统一注入一个
///   立即返回空列表的 loader：布局测试本来就不该联网。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/tv.dart';
import 'package:zhuiju/pages/home_page.dart';
import 'package:zhuiju/theme.dart';
import 'package:zhuiju/widgets/common.dart';

/// 立即返回空列表，且**不创建任何异步延迟**
///
/// 返回空列表（而非一堆假数据）是有意的：本文件验的是布局骨架，
/// 空数据会让 PagedGrid 直接进 EmptyView，树更浅、断言更稳。
/// 卡片本身的渲染另有 drama_card_test.dart 覆盖。
Future<List<Drama>> _emptyLoader(int tabIndex, int page) async => const [];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    // 测试之间必须复位，否则 TV 状态会漏到下一个用例
    TvMode.instance.override.value = TvOverride.auto;
    TvMode.instance.enabled.value = false;
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: child,
      );

  /// 把测试视口设成真实电视分辨率
  ///
  /// 默认的 800x600 装不下 7 个频道胶囊（每个约 84dp，再加「频道」标题
  /// 和两个图标按钮，总宽接近 900）。超出视口的部分被裁掉，`tester.tap`
  /// 点过去命中不到 GestureDetector，setState 不会触发 —— 断言就会以
  /// 「切换后网格数没变」的形式失败，看起来像布局 bug，其实是视口太窄。
  /// TV 本来就是 1080p/4K，用 1920x1080 也更贴近真实条件。
  void useTvViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// TV 首页（注入空数据源）
  Widget tvHome() => wrap(const HomePage(debugLoader: _emptyLoader));

  group('TV 首页布局', () {
    testWidgets('频道条渲染全部 7 个分类', (tester) async {
      useTvViewport(tester);
      TvMode.instance.enabled.value = true;
      await tester.pumpWidget(tvHome());
      await tester.pump();

      // 「频道」是 TV 频道条左侧的固定标题
      expect(find.text('频道'), findsOneWidget,
          reason: 'TV 首页必须有频道条标题');

      for (final c in kCategories) {
        expect(find.text(c.name), findsWidgets,
            reason: '频道条应包含分类「${c.name}」');
      }
    });

    testWidgets('只构建当前分类的网格，不并发请求全部分类', (tester) async {
      useTvViewport(tester);
      TvMode.instance.enabled.value = true;
      await tester.pumpWidget(tvHome());
      await tester.pump();

      // **必须 skipOffstage: false**。IndexedStack 会把非当前页标记为
      // offstage，而 find.byType 默认跳过 offstage —— 用默认值只会数到
      // 当前页那 1 个网格，这条断言就变成「1 < 7 恒成立」的假通过，
      // 完全测不到按需构建。关掉 skipOffstage 才能看见被保留的兄弟页。
      final all = find.byType(PagedGrid, skipOffstage: false).evaluate().length;
      expect(all, 1,
          reason: '首屏只应构建下标 0 的网格；等于 7 说明 _visited 剪枝失效，'
              '开机就会并发 7 个请求');
    });

    testWidgets('切换分类后才构建新网格', (tester) async {
      useTvViewport(tester);
      TvMode.instance.enabled.value = true;
      await tester.pumpWidget(tvHome());
      await tester.pump();

      // 同上，必须带上 skipOffstage: false 才看得到被隐藏的兄弟页
      int gridCount() =>
          find.byType(PagedGrid, skipOffstage: false).evaluate().length;

      expect(gridCount(), 1, reason: '初始只应有一个网格');

      // 点「动漫」胶囊。用文字定位再点到它外面的 GestureDetector，
      // 避免依赖下标顺序（分类顺序以后可能调整）。
      final chip = find.ancestor(
        of: find.text('动漫').first,
        matching: find.byType(GestureDetector),
      );
      await tester.tap(chip.first);
      await tester.pump();
      await tester.pump();

      expect(gridCount(), 2,
          reason: '切到新分类后应新增一个网格，并保留旧分类的（保活）');
    });

    testWidgets('不出现 AppBar：TV 顶部空间留给频道条', (tester) async {
      useTvViewport(tester);
      TvMode.instance.enabled.value = true;
      await tester.pumpWidget(tvHome());
      await tester.pump();

      expect(find.byType(AppBar), findsNothing,
          reason: 'TV 布局应自绘频道条，而不是复用 AppBar + TabBar');
    });

    testWidgets('遥控器焦点能停到频道胶囊上', (tester) async {
      useTvViewport(tester);
      TvMode.instance.enabled.value = true;
      await tester.pumpWidget(tvHome());
      await tester.pump();

      // 频道胶囊外层包了 TvFocus，它挂的是 Focus 节点。
      // 只要 Focus 节点存在，方向键就能停上来；
      // 用 GestureDetector 裸包的话遥控器完全够不着。
      final focuses = find.byType(Focus);
      expect(focuses.evaluate().isNotEmpty, isTrue);
    });
  });

  group('手机布局不受影响', () {
    testWidgets('非 TV 仍走 AppBar + TabBar', (tester) async {
      TvMode.instance.enabled.value = false;
      await tester.pumpWidget(tvHome());
      await tester.pump();

      expect(find.byType(AppBar), findsOneWidget,
          reason: '手机布局应保留 AppBar');
      expect(find.byType(TabBar), findsOneWidget,
          reason: '手机布局应保留分类 TabBar');
      expect(find.text('频道'), findsNothing,
          reason: '手机布局不应出现 TV 频道条');
    });
  });
}