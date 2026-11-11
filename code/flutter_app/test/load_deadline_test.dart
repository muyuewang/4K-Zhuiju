/// 请求永不返回时，列表必须自己退出加载态（回归测试，不联网）
///
/// 真实故障场景（用户实测）：
///   某个源的请求卡住不返回，界面就一直转圈；此时**切换到另一个正常源，
///   照样转圈出不来东西**，只能杀进程重开。
///
/// 根因不是「切换源没生效」，而是**加载态没有任何兜底**：
///   `PagedGrid._load()` 里 `await widget.loader(_page)` 一旦不返回，
///   `_loading` 永远停在 true，`build` 就一直渲染 [Loading] 转圈。
///   底层 Dio 虽然有 connectTimeout/receiveTimeout，但重试叠加后
///   （3 次 × 12s + 退避）能拖到 40 秒以上；更糟的是只要有任何一层
///   忘了把 `_loading` 复位，界面就永久卡死。
///
/// 这里锁死契约：**无论 loader 卡多久，加载态都必须在
/// [PagedGrid.requestDeadline] 内结束，并给出可重试的错误。**
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/widgets/common.dart';

/// 永不完成的 Future：模拟「请求挂住」
Future<List<Drama>> _hang(int page) => Completer<List<Drama>>().future;

/// 正常返回
Future<List<Drama>> _ok(int page) async => <Drama>[];

void main() {
  testWidgets('loader 永不返回时，超时后必须显示错误而不是一直转圈', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PagedGrid(
          loader: _hang,
          onTap: (_) {},
          // 测试用极短期限，避免真的等 20 秒
          requestDeadline: const Duration(milliseconds: 150),
        ),
      ),
    ));

    // 初始：转圈
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 超过期限后必须收敛为错误态，不能再转
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '超时后仍在转圈 = 用户看到的「永远加载中」');
    expect(find.byType(ErrorView), findsOneWidget,
        reason: '必须给出可见错误与重试入口，而不是静默卡死');
  });

  testWidgets('超时后切到正常 loader 必须能出内容（切源可恢复）', (tester) async {
    // 先挂住
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PagedGrid(
          key: const ValueKey('a'),
          loader: _hang,
          onTap: (_) {},
          requestDeadline: const Duration(milliseconds: 150),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(ErrorView), findsOneWidget);

    // 模拟「切换数据源」：HomePage 换 key，旧 State 丢弃，新 loader 正常
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PagedGrid(
          key: const ValueKey('b'),
          loader: _ok,
          onTap: (_) {},
          requestDeadline: const Duration(milliseconds: 150),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsNothing,
        reason: '换源后不该残留上一个源的错误态');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '正常源应当立刻结束加载态');
  });
}