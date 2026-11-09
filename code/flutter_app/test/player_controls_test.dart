// PlayerControlBar 状态同步回归测试
//
// 锁死一个曾经真实存在的 bug：组件内部把倍速/音量各存了一份本地副本，
// 只在 initState 里读一次 controller。结果是
//   1. 换源换了 controller 后，按钮显示还是上一个源的倍速；
//   2. 键盘 ↑↓ 调音量、M 静音（直接改 controller，不经过这个组件），
//      控制条上的音量图标和百分比纹丝不动。
// 现在改成每次 build 直接从 VideoPlayerValue 现读，本测试保证它不会再退回去。
//
// 不需要伪造播放平台：video_player 的 setVolume / setPlaybackSpeed 是
// 先写 value 并 notify，再去调平台层（未初始化时平台调用直接 return），
// 所以未初始化的 controller 也足以验证「显示是否跟着 value 走」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'package:zhuiju/widgets/player_controls.dart';

void main() {
  late VideoPlayerController ctrl;

  setUp(() {
    ctrl = VideoPlayerController.networkUrl(
      Uri.parse('http://127.0.0.1:1/probe.mp4'),
    );
  });

  tearDown(() async {
    await ctrl.dispose();
  });

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 160,
              child: ColoredBox(
                color: Colors.black,
                child: PlayerControlBar(ctrl: ctrl),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('外部改倍速，控制条立即显示新倍速', (tester) async {
    await pumpBar(tester);

    // 1.0 倍速时按钮显示文案「倍速」而不是「1X」
    expect(find.text('倍速'), findsOneWidget);

    await ctrl.setPlaybackSpeed(1.5);
    await tester.pump();

    expect(find.text('1.5X'), findsOneWidget);
    expect(find.text('倍速'), findsNothing);
  });

  testWidgets('外部改音量（快捷键路径），图标和数值同步', (tester) async {
    await pumpBar(tester);

    // 初始 1.0：图标是 volume_up
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

    // 模拟按 ↓ 三次：1.0 → 0.7
    await ctrl.setVolume(0.7);
    await tester.pump();
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

    // 再降到 0.3，图标要切到 volume_down
    await ctrl.setVolume(0.3);
    await tester.pump();
    expect(find.byIcon(Icons.volume_down_rounded), findsOneWidget);

    // 打开音量面板，百分比读数必须是 30 而不是留在 100
    await tester.tap(find.byIcon(Icons.volume_down_rounded));
    await tester.pumpAndSettle();
    expect(find.text('30'), findsOneWidget);
    expect(find.text('100'), findsNothing);

    // 静音（M 键路径）→ 图标切到 volume_off
    await ctrl.setVolume(0);
    await tester.pump();
    expect(find.byIcon(Icons.volume_off_rounded), findsWidgets);
  });

  testWidgets('换源换 controller 后，倍速跟随新 controller', (tester) async {
    await pumpBar(tester);

    await ctrl.setPlaybackSpeed(2.0);
    await tester.pump();
    expect(find.text('2X'), findsOneWidget);

    // 新 controller 默认 1.0 倍速，模拟换源
    final next = VideoPlayerController.networkUrl(
      Uri.parse('http://127.0.0.1:1/probe2.mp4'),
    );
    addTearDown(() async => next.dispose());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 160,
              child: ColoredBox(
                color: Colors.black,
                child: PlayerControlBar(ctrl: next),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Widget 位置和类型没变，Flutter 会复用同一个 State；
    // 若还留着本地副本，这里会错误地继续显示 2X。
    expect(find.text('倍速'), findsOneWidget);
    expect(find.text('2X'), findsNothing);
  });

  // ---------------- 浮层可点击性 ----------------
  //
  // 用户反馈「竖屏和横屏的倍速、音量都显示不全、点了没反应」。
  // 根因：浮层原本画在控制条自己的 Stack 里，向上弹出 200+px，
  // 一定超出 Stack 的尺寸。Clip.none 只让它「画」出去，
  // 命中测试仍被父级尺寸卡死；竖屏还多一层 SingleChildScrollView 裁剪。
  // 这几个测试用「矮容器 + 滚动视图」把原场景复现出来，
  // 保证浮层必须挂在 Overlay 上，不能退回局部 Stack。

  Future<void> pumpInScroll(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 60),
                SizedBox(
                  width: 420,
                  height: 90, // 比速度面板（232px）矮得多
                  child: ColoredBox(
                    color: Colors.black,
                    child: PlayerControlBar(ctrl: ctrl),
                  ),
                ),
                const SizedBox(height: 500),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('矮容器里倍速面板完整显示，并且点得到', (tester) async {
    await pumpInScroll(tester);

    await tester.tap(find.text('倍速'));
    await tester.pumpAndSettle();

    // 7 档全部在树里：显示不全的话这里就会缺项
    for (final s in ['0.5X', '0.75X', '1X', '1.25X', '1.5X', '1.75X', '2X']) {
      expect(find.text(s), findsOneWidget, reason: '$s 应该可见');
    }

    // 真正点一下，验证命中测试能穿透到 Overlay 上的浮层
    await tester.tap(find.text('1.5X'));
    await tester.pumpAndSettle();

    expect(ctrl.value.playbackSpeed, 1.5);
    // 选完自动收起，按钮变成 1.5X
    expect(find.text('1.5X'), findsOneWidget);
    expect(find.text('0.5X'), findsNothing);
  });

  testWidgets('矮容器里音量面板能改音量', (tester) async {
    await pumpInScroll(tester);

    await tester.tap(find.byIcon(Icons.volume_up_rounded));
    await tester.pumpAndSettle();

    // 面板里的百分比读数（进度条的 Slider 也在树里，所以按类型找有 2 个）
    expect(find.text('100'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));

    // 直接驱动浮层里 Slider 的回调，验证它接的是当前 controller。
    // 用 RotatedBox 精确定位音量滑杆，别按「第几个 Slider」猜顺序。
    final volSlider = tester.widget<Slider>(find.descendant(
      of: find.byType(RotatedBox),
      matching: find.byType(Slider),
    ));
    volSlider.onChanged!(0.4);
    await tester.pumpAndSettle();

    expect(ctrl.value.volume, closeTo(0.4, 0.001));
    expect(find.text('40'), findsOneWidget);
    expect(find.text('100'), findsNothing);
  });

  testWidgets('点浮层以外的地方会收起面板', (tester) async {
    await pumpInScroll(tester);

    await tester.tap(find.text('倍速'));
    await tester.pumpAndSettle();
    expect(find.text('0.5X'), findsOneWidget);

    // 点顶部那块空白区域（不在浮层上）
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('0.5X'), findsNothing);
    expect(find.text('倍速'), findsOneWidget);
  });
}