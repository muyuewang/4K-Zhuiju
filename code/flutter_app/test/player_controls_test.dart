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
}