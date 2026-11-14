/// 直播页 UI 验收（**不联网**）
///
/// 这一组测的是「用户真正能看见、能点动的东西」，与 `live_tv_parse_test`
/// （纯解析函数）、`live_tv_asset_test`（数据完整性）互补：
///
///   - parse 测试全绿，不代表列表渲染得出来；
///   - asset 测试全绿，不代表 Tab 和卡片能点到；
///   - 而「数据对、界面白」正是这类离线资源页最容易出的问题。
///
/// ## 【关键】缓存必须在 testWidgets 之外预热
///
/// `testWidgets` 的测试体跑在 `FakeAsync` 时区里，只推进「被 pump 出来的」
/// 时间与微任务。`LiveTvLibrary.all()` 首次调用会 `await
/// rootBundle.loadString(...)`，那是一次真实的文件读取 —— 它的完成回调
/// 要等真实时钟，而 FakeAsync 已经不再推进，于是 `await` 永远不返回。
///
/// 表现极具误导性：测试不是失败，而是 **did not complete**，一路挂到
/// 180 秒超时，日志里连一行断言失败都看不到。
///
/// 解法是在 `setUpAll`（普通异步环境，不受 FakeAsync 管辖）里先把缓存
/// 填好。之后页面内 `_load()` 拿到的就是一个已完成的 Future，
/// 走微任务即可完成，pump 一帧就能结束 loading。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/source/live_tv_source.dart';
import 'package:zhuiju/pages/live_page.dart';
import 'package:zhuiju/pages/player_page.dart';
import 'package:zhuiju/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, List<LiveChannel>> bySection;
  late List<LiveChannel> all;

  setUpAll(() async {
    // 见文件头注释：必须在 FakeAsync 之外预热，否则页面内的
    // rootBundle 读取会把测试挂死。
    all = await LiveTvLibrary.all();
    bySection = await LiveTvLibrary.bySection();
  });

  /// 挂起页面并把 `_load` 的微任务推完。
  ///
  /// 不能用 `pumpAndSettle`：页面首帧有 `CircularProgressIndicator`
  /// （无限动画），settle 会一直转圈到超时。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const LivePage(),
    ));
    // 首帧 loading → _load 的 await（缓存命中，走微任务）→ setState
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  group('直播页渲染', () {
    testWidgets('每个栏目都出现在 Tab 里', (tester) async {
      await pumpPage(tester);

      for (final key in bySection.keys) {
        // Tab 文案是「栏目名 数量」
        expect(
          find.textContaining(key),
          findsWidgets,
          reason: '「$key」栏目没有出现在 Tab 里',
        );
      }
    });

    testWidgets('标题展示频道总数（用户要能感知资源规模）', (tester) async {
      await pumpPage(tester);
      expect(find.text('${all.length} 个频道'), findsOneWidget);
    });

    testWidgets('首屏渲染出频道卡片（不是一片空白）', (tester) async {
      await pumpPage(tester);

      // 第一个栏目（央卫视）的头部若干条应至少有一条渲染出来。
      // 只要前 8 条里命中一条就说明网格建起来了；要求全部命中会因
      // 网格懒加载与屏幕高度而误报。
      final first = bySection.entries.first.value;
      final hit = first
          .take(8)
          .where((ch) => find.text(ch.name).evaluate().isNotEmpty)
          .length;
      expect(hit, greaterThan(0), reason: '首屏一个频道名都没渲染出来');
    });
  });

  group('直播页搜索', () {
    /// 进入搜索态并输入关键词，推完 `_search` 的微任务。
    Future<void> search(WidgetTester tester, String q) async {
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pump();
      await tester.enterText(find.byType(TextField), q);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('点搜索图标进入搜索态，提示文案出现', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pump();
      expect(find.text('输入频道名开始搜索'), findsOneWidget);
    });

    testWidgets('输入关键词后只剩命中的频道，且 Tab 消失', (tester) async {
      await pumpPage(tester);
      await search(tester, 'CCTV');

      final hits = await LiveTvLibrary.search('CCTV');
      expect(hits, isNotEmpty, reason: '数据层搜不到 CCTV，先查资源');
      expect(find.text(hits.first.name), findsWidgets);
      // 结果跨栏目，留着 Tab 会让人误以为只搜了当前栏目
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('搜不到时给出空状态与「清空搜索」出路', (tester) async {
      await pumpPage(tester);
      await search(tester, 'zzz不存在zzz');

      expect(find.textContaining('没有找到'), findsOneWidget);
      expect(find.text('清空搜索'), findsOneWidget);
    });
  });

  group('点频道跳播放器', () {
    testWidgets('点击频道打开 PlayerPage，且走直连模式', (tester) async {
      await pumpPage(tester);

      final first = bySection.entries.first.value.first;
      final target = find.text(first.name).first;
      await tester.ensureVisible(target);
      await tester.pump();

      await tester.tap(target);
      // PlayerPage 进来就开始解析地址，会起 InfiniteProgress 动画，
      // 所以只推固定帧数，不 settle。
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      // 本次接入的核心：地址直接来自打包资源，不经任何源解析
      expect(page.directUrl, first.url);
      expect(page.isLive, isTrue);
      // UA 必须一路带过去，否则「能探活却点开 404」
      expect(page.userAgent, first.ua);
      expect(page.liveChannel?.id, first.id, reason: '频道对象要传到播放页');
      expect(page.sourceId, 'live');
    });
  });
}