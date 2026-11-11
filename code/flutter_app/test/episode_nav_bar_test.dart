/// 选集导航：两个按钮常显、首尾置灰（2026-11-11 用户反馈）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/theme.dart';
import 'package:zhuiju/widgets/episode_nav_bar.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

InkWell inkOf(WidgetTester tester, String key) => tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(InkWell),
      ),
    );

void main() {
  testWidgets('第一集：上一集置灰，下一集可点', (tester) async {
    int next = 0;
    await tester.pumpWidget(wrap(EpisodeNavBar(onNext: () => next++)));
    await tester.pump();

    expect(find.text('上一集'), findsOneWidget);
    expect(find.text('下一集'), findsOneWidget,
        reason: '两个按钮必须都显示，不能把不可用的那个藏起来');

    expect(inkOf(tester, 'episodePrev').onTap, isNull,
        reason: '第一集的上一集应置灰不可点');
    expect(inkOf(tester, 'episodeNext').onTap, isNotNull);

    await tester.tap(find.text('下一集'));
    await tester.pump();
    expect(next, 1);
  });

  testWidgets('最后一集：下一集置灰，上一集可点', (tester) async {
    int prev = 0;
    await tester.pumpWidget(wrap(EpisodeNavBar(onPrev: () => prev++)));
    await tester.pump();

    expect(find.text('上一集'), findsOneWidget);
    expect(find.text('下一集'), findsOneWidget);
    expect(inkOf(tester, 'episodeNext').onTap, isNull);
    expect(inkOf(tester, 'episodePrev').onTap, isNotNull);

    await tester.tap(find.text('上一集'));
    await tester.pump();
    expect(prev, 1);
  });

  testWidgets('单集剧：两个按钮都显示且都置灰', (tester) async {
    await tester.pumpWidget(wrap(const EpisodeNavBar()));
    await tester.pump();

    expect(find.text('上一集'), findsOneWidget);
    expect(find.text('下一集'), findsOneWidget);
    expect(inkOf(tester, 'episodePrev').onTap, isNull);
    expect(inkOf(tester, 'episodeNext').onTap, isNull);
  });

  testWidgets('中间集：两个方向都可点', (tester) async {
    await tester.pumpWidget(wrap(EpisodeNavBar(
      onPrev: () {},
      onNext: () {},
    )));
    await tester.pump();

    expect(inkOf(tester, 'episodePrev').onTap, isNotNull);
    expect(inkOf(tester, 'episodeNext').onTap, isNotNull);
  });
}
