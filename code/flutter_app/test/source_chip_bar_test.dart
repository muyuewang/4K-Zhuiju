/// 线路胶囊栏的布局回归（2026-11-17 实机问题）
///
/// 用户截图：Windows 上看剧，26 条线路只露出前 14 条，右边被直接切掉，
/// 滚轮推不动、也没有滚动条——后面 12 条**永远选不到**。
///
/// 旧实现是固定高度的横向 `ListView`：桌面端滚轮 delta 是纵向的，横向
/// `ScrollView` 忽略它；也没有画 `Scrollbar`，用户连"还有更多"都不知道。
///
/// 这里锁住三件事，任何一条被改回去都会红：
///   1. 最后一条线路**渲染出来且落在可视宽度内**（不能被裁掉）；
///   2. 线路顺序 = 传入顺序（按阅读顺序还原，防"我们自己排序"）；
///   3. 点最后一条能回调出正确的线路名（别只是画出来点不到）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/theme.dart';
import 'package:zhuiju/widgets/source_chip_bar.dart';

/// 看剧实测的 26 条线路名（顺序取自站点 line_options 原版顺序）
const List<String> _kanju26 = [
  '红牛资源', '1080zyk', '极速资源', '魔都资源', '新浪资源', '西瓜资源',
  '无水印资源', '暴风资源', '豪华资源', 'ikun资源', '豆瓣资源', '索尼资源',
  'iqiyi资源', 'U酷资源', '茅台资源', '金鹰资源', '电影天堂资源', '猫眼资源',
  '无尽资源', '速播资源', '量子资源', '非凡资源', '牛牛资源', '360资源',
  '最大资源', '如意资源',
];

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: SizedBox(width: 900, child: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  testWidgets('26 条线路全部渲染，最后一条仍在可视宽度内', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(SourceChipBar(
      names: _kanju26,
      current: _kanju26.first,
      onSelect: (_) {},
    )));

    for (final n in _kanju26) {
      expect(find.text(n), findsOneWidget, reason: '「$n」没有渲染出来');
      final r = tester.getRect(find.text(n));
      expect(r.right, lessThanOrEqualTo(900),
          reason: '「$n」被右边缘裁掉了（right=${r.right}）');
    }
  });

  testWidgets('线路顺序 = 传入顺序（按阅读顺序还原）', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(SourceChipBar(
      names: _kanju26,
      current: _kanju26.first,
      onSelect: (_) {},
    )));

    // 收集所有胶囊的位置，按「先上后下、同一行先左后右」还原阅读顺序。
    // 同一行的胶囊共享同一个 top 值（Wrap 对齐），所以先取所有不同的 y
    // 排序得到行号，再按 (行号, x) 排——不依赖名字的传入顺序，否则这条
    // 断言会变成「自己跟自己比」。
    final items = <(double, double, String)>[];
    for (final n in _kanju26) {
      final o = tester.getTopLeft(find.text(n));
      items.add((o.dy, o.dx, n));
    }
    final rows = items.map((e) => e.$1).toSet().toList()..sort();
    int rowOf(double y) {
      for (var i = 0; i < rows.length; i++) {
        if ((rows[i] - y).abs() < 0.5) return i;
      }
      return rows.length;
    }

    items.sort((a, b) {
      final r = rowOf(a.$1).compareTo(rowOf(b.$1));
      if (r != 0) return r;
      return a.$2.compareTo(b.$2);
    });
    expect(items.map((e) => e.$3).toList(), _kanju26);
  });

  testWidgets('点最后一条线路能回调出正确名字', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    String? picked;
    await tester.pumpWidget(_host(SourceChipBar(
      names: _kanju26,
      current: _kanju26.first,
      onSelect: (n) => picked = n,
    )));

    await tester.tap(find.text(_kanju26.last));
    await tester.pump();
    expect(picked, _kanju26.last);
  });
}
