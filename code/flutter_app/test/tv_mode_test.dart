// TV / 遥控器适配回归测试
//
// 锁住四件事，都是"改一行代码就会静默失效、而人眼在电视上很难发现"的点：
//
//   1. 遥控器确定键能被翻译成点击。
//      电视上没有触摸，D-pad 的确定键在 Flutter 里是 `select` 而不是
//      `enter`，只认 enter 的话卡片全部按不动。
//   2. TvFocusRing 不能把按键吃掉。
//      Material 按钮自己就能响应确定键，外面再套一层会消费按键的
//      Focus 会导致一次按键触发两回（或干脆不响应）。
//   3. TV 的网格目标尺寸必须比手机大，否则 3 米外看不清。
//   4. TV 模式开关的三档语义：自动跟随探测、强制开、强制关。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhuiju/core/layout.dart';
import 'package:zhuiju/core/tv.dart';
import 'package:zhuiju/theme.dart';
import 'package:zhuiju/widgets/tv_focus.dart';

/// 找出当前树里带焦点描边（foregroundDecoration 有 border）的容器
int countFocusRings(WidgetTester tester) {
  var n = 0;
  for (final c in tester.widgetList<Container>(find.byType(Container))) {
    final d = c.foregroundDecoration;
    if (d is BoxDecoration && d.border != null) n++;
  }
  return n;
}

void main() {
  group('遥控器确定键映射', () {
    test('常见的确定键都被收录', () {
      // select 是 Android KEYCODE_DPAD_CENTER，电视盒子最常见；
      // 只认 enter 的话，绝大多数遥控器都按不动。
      expect(kActivateKeys.contains(LogicalKeyboardKey.select), isTrue);
      expect(kActivateKeys.contains(LogicalKeyboardKey.enter), isTrue);
      expect(kActivateKeys.contains(LogicalKeyboardKey.numpadEnter), isTrue);
      expect(kActivateKeys.contains(LogicalKeyboardKey.gameButtonA), isTrue);
      expect(kActivateKeys.contains(LogicalKeyboardKey.space), isTrue);
    });

    test('方向键不在确定键里（否则没法移动焦点）', () {
      expect(kActivateKeys.contains(LogicalKeyboardKey.arrowUp), isFalse);
      expect(kActivateKeys.contains(LogicalKeyboardKey.arrowDown), isFalse);
      expect(kActivateKeys.contains(LogicalKeyboardKey.arrowLeft), isFalse);
      expect(kActivateKeys.contains(LogicalKeyboardKey.arrowRight), isFalse);
    });
  });

  group('TvFocus', () {
    testWidgets('按下确定键（select）触发一次激活', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocus(
            autofocus: true,
            onActivate: () => taps++,
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1, reason: '遥控器确定键必须能触发，否则电视上什么都点不动');
    });

    testWidgets('按下 enter 同样触发（外接键盘/部分盒子）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocus(
            autofocus: true,
            onActivate: () => taps++,
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('方向键不触发激活（要留给焦点移动）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocus(
            autofocus: true,
            onActivate: () => taps++,
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('拿到焦点后画出描边（电视上没有指针，看不出选中谁）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocus(
            autofocus: true,
            onActivate: () {},
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ));
      await tester.pump();
      expect(countFocusRings(tester), greaterThan(0));

      final withRing = tester
          .widgetList<Container>(find.byType(Container))
          .firstWhere((c) {
        final d = c.foregroundDecoration;
        return d is BoxDecoration && d.border != null;
      });
      final bd = withRing.foregroundDecoration as BoxDecoration;
      // 描边必须是主题橙，否则在深色画面里几乎看不见
      expect((bd.border as Border).top.color, kAccent);
    });

    testWidgets('enabled=false 时不插入焦点节点，按键原样放过', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocus(
            autofocus: true,
            enabled: false,
            onActivate: () => taps++,
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 0);
      expect(countFocusRings(tester), 0);
    });
  });

  group('TvFocusRing', () {
    testWidgets('不吞按键：Material 按钮按一次只触发一次', (tester) async {
      var taps = 0;
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocusRing(
            child: TextButton(
              focusNode: node,
              onPressed: () => taps++,
              child: const Text('按钮'),
            ),
          ),
        ),
      ));
      node.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // 0 说明外层吃掉了按键（按钮收不到）；2 说明内外各响应一次
      expect(taps, 1);
    });

    testWidgets('子孙聚焦时画出描边', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFocusRing(
            child: TextButton(
              focusNode: node,
              onPressed: () {},
              child: const Text('按钮'),
            ),
          ),
        ),
      ));
      node.requestFocus();
      await tester.pump();
      expect(countFocusRings(tester), greaterThan(0));
    });
  });

  group('TV 布局尺寸', () {
    test('TV 网格的单卡目标宽度明显大于手机', () {
      final phone = posterGridDelegate() as SliverGridDelegateWithMaxCrossAxisExtent;
      final tv = posterGridDelegate(tv: true) as SliverGridDelegateWithMaxCrossAxisExtent;

      expect(phone.maxCrossAxisExtent, kPosterTargetExtent);
      expect(tv.maxCrossAxisExtent, kTvPosterTargetExtent);
      // 电视观看距离是沙发距离，按手持尺寸排版在 3 米外看不清
      expect(tv.maxCrossAxisExtent, greaterThan(phone.maxCrossAxisExtent * 1.5));
      // 间距也要一起放大，否则焦点框会挤在一起
      expect(tv.crossAxisSpacing, greaterThan(phone.crossAxisSpacing));
    });
  });

  group('TV 模式开关', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // 每个用例从干净状态开始，避免互相污染
      TvMode.instance.override.value = TvOverride.auto;
      TvMode.instance.detected = false;
      TvMode.instance.enabled.value = false;
    });

    test('三档的显示文案互不相同', () {
      final labels = TvOverride.values.map((e) => e.label).toSet();
      expect(labels.length, TvOverride.values.length);
      final hints = TvOverride.values.map((e) => e.hint).toSet();
      expect(hints.length, TvOverride.values.length);
    });

    test('从磁盘读回：未知值退回自动', () {
      expect(TvOverride.fromName('on'), TvOverride.on);
      expect(TvOverride.fromName('off'), TvOverride.off);
      expect(TvOverride.fromName('auto'), TvOverride.auto);
      expect(TvOverride.fromName(null), TvOverride.auto);
      // 枚举顺序变了或存了脏值，不该崩，也不该乱猜成"强制开"
      expect(TvOverride.fromName('Television'), TvOverride.auto);
    });

    test('自动档跟随探测结果', () async {
      TvMode.instance.detected = true;
      await TvMode.instance.setOverride(TvOverride.auto);
      expect(TvMode.instance.enabled.value, isTrue);

      TvMode.instance.detected = false;
      await TvMode.instance.setOverride(TvOverride.auto);
      expect(TvMode.instance.enabled.value, isFalse);
    });

    test('手动开启：探测没识别出电视也强制生效', () async {
      // 盒子固件经常不声明 leanback feature，探测必然漏判，
      // 手动强开是唯一的兜底手段。
      TvMode.instance.detected = false;
      await TvMode.instance.setOverride(TvOverride.on);
      expect(TvMode.instance.enabled.value, isTrue);
    });

    test('手动关闭：即使识别成电视也不启用', () async {
      TvMode.instance.detected = true;
      await TvMode.instance.setOverride(TvOverride.off);
      expect(TvMode.instance.enabled.value, isFalse);
    });
  });
}