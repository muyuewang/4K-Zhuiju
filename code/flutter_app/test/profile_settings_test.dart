/// 「我的」页设置区的可见性
///
/// 用户反馈「深色/浅色/跟随系统 的入口没有了」。代码里 `_settings()`
/// 明明有「主题外观」这一行，所以要么是渲染层被别的行挤掉，
/// 要么是构建产物与源码不一致。这里直接把页面 pump 出来验证，
/// 比逐行读代码可靠。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/pages/profile_page.dart';
import 'package:zhuiju/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: child,
      );

  testWidgets('设置区包含主题外观一行', (tester) async {
    await tester.pumpWidget(wrap(const ProfilePage()));
    await tester.pump();

    // 设置项在页面下方，先滚到底再断言
    final list = find.byType(Scrollable);
    if (list.evaluate().isNotEmpty) {
      await tester.drag(list.first, const Offset(0, -1200));
      await tester.pump();
    }

    expect(find.text('主题外观'), findsOneWidget,
        reason: '设置页必须有「主题外观」入口');
    expect(find.text('遥控器模式'), findsOneWidget);
    expect(find.text('清空观看记录'), findsOneWidget);
    expect(find.text('清理缓存'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('主题行的右侧显示当前档位文案', (tester) async {
    await tester.pumpWidget(wrap(const ProfilePage()));
    await tester.pump();

    final list = find.byType(Scrollable);
    if (list.evaluate().isNotEmpty) {
      await tester.drag(list.first, const Offset(0, -1200));
      await tester.pump();
    }

    // 默认跟随系统，右侧应显示「跟随系统」
    expect(find.text('跟随系统'), findsWidgets);
  });
}