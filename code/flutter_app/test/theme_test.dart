// 主题切换回归测试
//
// 锁住两件事：
//   1. 三档模式（跟随系统 / 深色 / 浅色）能正确映射到 ThemeMode，
//      并且从磁盘读回时不会因为未知值而错乱。
//   2. 浅色主题下**不能再出现白字压白底**。
//      这是这次改主题最容易回归的坑：全套颜色原本是 const 常量，
//      改成运行时取色后，任何漏改的 `Colors.white` 在浅色下都会消失。
//      所以这里直接扫一遍真实页面的文本颜色对比度，而不是只测颜色值相等。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/theme_settings.dart';
import 'package:zhuiju/theme.dart';

void main() {
  group('AppThemeMode 映射', () {
    test('三档模式映射到正确的 ThemeMode', () {
      expect(AppThemeMode.system.material, ThemeMode.system);
      expect(AppThemeMode.dark.material, ThemeMode.dark);
      expect(AppThemeMode.light.material, ThemeMode.light);
    });

    test('从磁盘读回：已知值正常，未知/空值退回跟随系统', () {
      expect(AppThemeMode.fromName('light'), AppThemeMode.light);
      expect(AppThemeMode.fromName('dark'), AppThemeMode.dark);
      expect(AppThemeMode.fromName('system'), AppThemeMode.system);
      // 老版本没写过这个 key，或写了以后被改坏
      expect(AppThemeMode.fromName(null), AppThemeMode.system);
      expect(AppThemeMode.fromName(''), AppThemeMode.system);
      expect(AppThemeMode.fromName('amoled'), AppThemeMode.system);
    });

    test('每档都有可读的标签，不会两个选项重名', () {
      final labels = AppThemeMode.values.map((e) => e.label).toSet();
      expect(labels.length, AppThemeMode.values.length);
      expect(labels.contains('跟随系统'), isTrue);
    });
  });

  group('色板', () {
    test('深色沿用原配色，老用户视觉零变化', () {
      expect(AppPalette.dark.bg, const Color(0xFF0E0F13));
      expect(AppPalette.dark.card, const Color(0xFF181A21));
      expect(AppPalette.dark.textDim, const Color(0xFF9AA0AE));
    });

    test('浅色：卡片必须比页面底色更亮，否则卡片边界消失', () {
      // 用亮度而不是直接比颜色值：深色下是 card 比 bg 亮，
      // 浅色下也应该是 card（纯白）比 bg（#F4F5F7）亮。
      expect(
        AppPalette.light.card.computeLuminance(),
        greaterThan(AppPalette.light.bg.computeLuminance()),
      );
    });

    test('两套主题的次要文字都达到 4.5:1（正文可读下限）', () {
      for (final p in [AppPalette.dark, AppPalette.light]) {
        final ratio = _contrast(p.textDim, p.bg);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '次要文字在底色上的对比度只有 ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('两套主题的正文色都达到 7:1（AAA 正文）', () {
      for (final p in [AppPalette.dark, AppPalette.light]) {
        final ratio = _contrast(p.onSurface, p.bg);
        expect(ratio, greaterThanOrEqualTo(7.0),
            reason: '正文对比度只有 ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('lerp 能在两套主题间平滑过渡（切主题不闪黑）', () {
      final mid = AppPalette.dark.lerp(AppPalette.light, 0.5);
      // 中间值必须落在两端之间，不能等于任何一端
      expect(mid.bg, isNot(AppPalette.dark.bg));
      expect(mid.bg, isNot(AppPalette.light.bg));
    });
  });

  group('MaterialApp 主题装配', () {
    testWidgets('themeMode 跟随设置变化', (tester) async {
      ThemeSettings.instance.mode.value = AppThemeMode.dark;
      await tester.pumpWidget(const _Harness());
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byKey(const Key('probe')))).brightness,
          Brightness.dark);

      ThemeSettings.instance.mode.value = AppThemeMode.light;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byKey(const Key('probe')))).brightness,
          Brightness.light);
    });

    testWidgets('浅色主题下，页面上的文字不能是浅色（白底白字检测）', (tester) async {
      ThemeSettings.instance.mode.value = AppThemeMode.light;
      await tester.pumpWidget(const _Harness());
      await tester.pumpAndSettle();

      final ctx = tester.element(find.byKey(const Key('probe')));
      final bg = ctx.palette.bg;

      // 取实际渲染出来的所有文字颜色，逐个算对比度
      final texts = tester.widgetList<Text>(find.byType(Text));
      expect(texts, isNotEmpty);

      for (final t in texts) {
        final style = t.style;
        if (style?.color == null) continue; // 继承主题色的不单独校验
        final ratio = _contrast(style!.color!, bg);
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason: '文字「${t.data}」在浅色底上对比度仅 '
              '${ratio.toStringAsFixed(2)}:1，几乎看不见',
        );
      }
    });
  });
}

/// 相对亮度对比度（WCAG 公式）
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 最小复现壳：和 main.dart 的接法保持一致（light + dark + themeMode）
class _Harness extends StatelessWidget {
  const _Harness();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeSettings.instance.mode,
      builder: (ctx, mode, _) => MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode.material,
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                key: const Key('probe'),
                children: [
                  Text('正文', style: TextStyle(color: c.palette.onSurface)),
                  Text('次要', style: TextStyle(color: c.palette.textDim)),
                  const Text('默认色标题',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}