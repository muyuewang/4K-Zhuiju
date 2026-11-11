/// 「我的」页继续观看：紧凑横向条（2026-11-11 用户反馈）
///
/// 旧布局一条记录就是一整行（竖版海报 84px + 文字 + 进度条），
/// 3 条吃掉 300 多 px，把下面的设置项全挤出屏幕。参考橘汁原版改成
/// 一行横向缩略图后，**1 条和 8 条必须占完全相同的高度**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/history.dart';
import 'package:zhuiju/pages/profile_page.dart';
import 'package:zhuiju/theme.dart';

WatchRecord rec(int i) => WatchRecord(
      dramaId: 'd$i',
      dramaName: '剧集$i',
      epLabel: '第${i + 1}集',
      source: 'pylg',
      path: 'v0d5aag10002dbk6tdvog65q84mufc70',
      episode: i + 1,
      positionSec: 60 + i,
      durationSec: 3600,
      updatedAt: 1000 + i,
      // cover 留空：测试里不发起任何网络图片请求
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap() => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ProfilePage(),
      );

  setUp(() => HistoryStore.instance.records.value = const []);
  tearDown(() => HistoryStore.instance.records.value = const []);

  Future<double> stripHeight(WidgetTester tester, int count) async {
    HistoryStore.instance.records.value =
        List.generate(count, (i) => rec(i));
    await tester.pumpWidget(wrap());
    await tester.pump();
    return tester.getSize(find.byKey(const ValueKey('recentStrip'))).height;
  }

  testWidgets('无记录时整个区块不占位', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.byKey(const ValueKey('recentStrip')), findsNothing);
  });

  testWidgets('记录条数从 1 增到 8，区块高度不变', (tester) async {
    final h1 = await stripHeight(tester, 1);
    // 换一批数据前先卸载，避免同一 tester 复用旧 element 树
    await tester.pumpWidget(const SizedBox.shrink());
    final h8 = await stripHeight(tester, 8);
    expect(h8, h1, reason: '横向条必须是固定高度，否则又会把设置项挤下去');
    expect(h1, lessThan(180), reason: '整块不应超过 180px');
  });

  testWidgets('用横向 ListView 承载，且保留删除入口', (tester) async {
    HistoryStore.instance.records.value =
        List.generate(6, (i) => rec(i));
    await tester.pumpWidget(wrap());
    await tester.pump();

    final horizontal = find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.horizontal,
    );
    expect(horizontal, findsOneWidget);

    final strip = find.byKey(const ValueKey('recentStrip'));
    expect(
      find.descendant(
        of: strip,
        matching: find.byIcon(Icons.close_rounded),
      ),
      findsWidgets,
      reason: '紧凑化不能把「移除记录」功能弄丢',
    );
    expect(find.text('全部 6'), findsOneWidget);
    expect(find.text('继续观看'), findsOneWidget);
  });

  testWidgets('设置项在首屏可见范围内（不必大幅滚动）', (tester) async {
    HistoryStore.instance.records.value =
        List.generate(8, (i) => rec(i));
    // 用接近真机的视口，而不是 flutter_test 默认的 800x600
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap());
    await tester.pump();

    // 之前 8 条记录要占 800px+，设置项完全被推到屏外。
    // 现在只滚一屏就该能看到「主题外观」。
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -400));
    await tester.pump();

    expect(find.text('主题外观'), findsOneWidget);
    expect(find.text('下载保存位置'), findsOneWidget);
  });
}
