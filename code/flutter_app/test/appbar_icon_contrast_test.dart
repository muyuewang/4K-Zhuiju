/// 播放页黑底栏的图标可读性回归。
///
/// ## 为什么这个测试必须存在（它对应一次真实的漏修）
///
/// 上一轮修「返回按钮隐形」时，只给 AppBar 加了
/// `backgroundColor: Colors.black` + `foregroundColor: Colors.white`，
/// 测试也跟着写了「黑底 AppBar 必须声明白色前景」——看起来齐活了。
///
/// 用户装上新包后反馈：**返回箭头和标题确实变白了，但右边那排
/// 「投屏 / 选集 / 下载 / 技术信息」图标还是黑的，看不见。**
///
/// 根因在 AppBar 内部的取值顺序（flutter/lib/src/material/app_bar.dart）：
///
/// ```dart
/// IconThemeData overallIconTheme =
///     widget.iconTheme ?? appBarTheme.iconTheme ?? defaults.iconTheme!.copyWith(color: foregroundColor);
/// ```
///
/// `appBarTheme.iconTheme` **排在 foregroundColor 之前**。本项目
/// theme.dart 恰好钉了 `appBarTheme.iconTheme = IconThemeData(color: p.onSurface)`，
/// 于是浅色主题下图标永远拿 #14161A，`foregroundColor: Colors.white`
/// 被完全跳过。标题能看见只是因为另外写了 `TextStyle(color: white)`。
///
/// 静态扫源码抓不住这类问题——「写了 foregroundColor」这件事本身是真的，
/// 只是它不生效。所以这里**真的构建一棵 AppBar，读解析后的颜色**，
/// 再按 WCAG 对比度判定。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/theme.dart';

/// 在给定主题下搭一个和播放页同配置的黑底 AppBar，
/// 返回 leading / actions / title 实际解析到的颜色。
///
/// 标题**不能**用 `DefaultTextStyle.of(ctx)` 读：AppBar 内部是先把
/// title 包进 AnimatedDefaultTextStyle 再渲染，放在 Builder 里取到的是
/// 页面级的默认 TextStyle，不是标题真正用的那个（实测差了 4 倍对比度）。
/// 所以标题改为从渲染出来的 RenderParagraph 上读实际生效的样式。
Future<({Color? leading, Color? actions, Color? title})> _resolveColors(
  WidgetTester tester, {
  required ThemeData theme,
  bool declareIconTheme = true,
}) async {
  Color? leadingColor;
  Color? actionColor;

  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          // 被验证的那两行：漏掉它们，图标就还是近黑色
          iconTheme: declareIconTheme
              ? const IconThemeData(color: Colors.white)
              : null,
          actionsIconTheme: declareIconTheme
              ? const IconThemeData(color: Colors.white)
              : null,
          leading: Builder(
            builder: (ctx) {
              leadingColor = IconTheme.of(ctx).color;
              return const Icon(Icons.arrow_back_rounded);
            },
          ),
          // 与 player_page 一致：标题显式写白，不依赖主题
          title: const Text(
            '测试标题',
            style: TextStyle(color: Colors.white),
          ),
          actions: [
            Builder(
              builder: (ctx) {
                actionColor = IconTheme.of(ctx).color;
                return const Icon(Icons.info_outline_rounded);
              },
            ),
          ],
        ),
        body: const SizedBox(),
      ),
    ),
  );

  // 从实际渲染的段落里取最终生效的文字颜色
  final para = tester.renderObject<RenderParagraph>(find.text('测试标题'));
  final titleColor = para.text.style?.color;

  return (leading: leadingColor, actions: actionColor, title: titleColor);
}

/// 相对亮度（WCAG 2.1）。Color.r/g/b 在 Flutter 里已是 0~1。
double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// 两色对比度
double _contrast(Color fg, Color bg) {
  final l1 = _luminance(fg);
  final l2 = _luminance(bg);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

void main() {
  group('播放页黑底栏图标', () {
    testWidgets('浅色主题下 leading / actions 的黑底对比度必须达标', (tester) async {
      final colors = await _resolveColors(
        tester,
        theme: buildTheme(Brightness.light),
      );

      final targets = <String, Color?>{
        'leading（返回箭头）': colors.leading,
        'actions（投屏/选集/下载/技术信息）': colors.actions,
      };

      for (final e in targets.entries) {
        final c = e.value;
        expect(c, isNotNull, reason: '${e.key} 没解析到颜色');
        final ratio = _contrast(c!, Colors.black);
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason: '${e.key} 在黑底上的对比度只有 ${ratio.toStringAsFixed(2)}:1 '
              '（实际颜色 ${_hex(c)}），低于 WCAG 非文本图形 3:1 的下限 —— '
              '用户看到的就是「图标不见了」。\n'
              '修法：AppBar 里除 foregroundColor 外，还要显式写 '
              'iconTheme: IconThemeData(color: Colors.white) 与 '
              'actionsIconTheme: IconThemeData(color: Colors.white)。',
        );
      }
    });

    testWidgets('标题在黑底上同样要可读', (tester) async {
      final colors = await _resolveColors(
        tester,
        theme: buildTheme(Brightness.light),
      );
      final c = colors.title;
      expect(c, isNotNull, reason: '标题没解析到颜色');
      expect(
        _contrast(c!, Colors.black),
        greaterThanOrEqualTo(4.5),
        reason: '标题是正文级文字，黑底上应达 4.5:1，实际 ${_hex(c)}',
      );
    });

    testWidgets('只写 foregroundColor 不足以让图标变白（锁住这个坑）', (tester) async {
      final colors = await _resolveColors(
        tester,
        theme: buildTheme(Brightness.light),
        declareIconTheme: false,
      );

      // 这条断言看着像在「断言 bug」，实际锁的是 Flutter 的既定取值顺序。
      // 一旦有人以为 foregroundColor 够用而删掉 iconTheme，第一条测试会红，
      // 这条会解释「为什么红」。若哪天这条自己红了，说明 Flutter 改了
      // 优先级，player_page 里那两行声明就可以简化。
      final ratio = _contrast(colors.actions!, Colors.black);
      expect(
        ratio,
        lessThan(3.0),
        reason: 'appBarTheme.iconTheme 优先级高于 foregroundColor，'
            '本项目主题钉了 onSurface。此断言失败说明 Flutter 的取值顺序变了。',
      );
      expect(
        _hex(colors.actions!),
        _hex(AppPalette.light.onSurface),
        reason: '只写 foregroundColor 时，图标应拿到主题的 onSurface',
      );
    });
  });
}