/// 多分辨率布局溢出回归
///
/// 字号归一化的副作用：`9 -> 11`、`15 -> 16` 两档是把小字号**调大**了。
/// 紧凑布局（横排一行塞多个元素、定高容器里的多行文字）最容易因此撑破。
///
/// 为什么用测试而不是肉眼：RenderFlex 溢出会走 FlutterError.onError，
/// 在 flutter_test 里能被 `tester.takeException()` 精确捕获，还能拿到
/// 溢出像素数；模拟器截图只能靠看，容易被「刚好挤下一行」骗过去。
///
/// 覆盖三种真实视口：
///   - 720x1280  低端机（本次模拟器的实际分辨率）
///   - 1080x1920 主流机
///   - 1920x1080 电视（横屏，布局分支完全不同）
///
/// 不覆盖的：播放器页与详情页。它们的首帧依赖网络数据，
/// 注入成本高且本次改动只碰字号，风险由 114 项既有测试兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/tv.dart';
import 'package:zhuiju/pages/download_page.dart';
import 'package:zhuiju/pages/favorites_page.dart';
import 'package:zhuiju/pages/history_page.dart';
import 'package:zhuiju/pages/home_page.dart';
import 'package:zhuiju/pages/profile_page.dart';
import 'package:zhuiju/theme.dart';

Future<List<Drama>> _emptyLoader(int tabIndex, int page) async => const [];

/// 真实设备视口
const _viewports = <String, Size>{
  '720p 低端机': Size(720, 1280),
  '1080p 主流机': Size(1080, 1920),
  '1080p 电视横屏': Size(1920, 1080),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    TvMode.instance.override.value = TvOverride.auto;
    TvMode.instance.enabled.value = false;
  });

  Widget wrap(Widget child, Brightness b) => MaterialApp(
        theme: buildTheme(b),
        home: Scaffold(body: child),
      );

  /// 在指定视口渲染并断言无溢出
  ///
  /// `ignoreOverflow` 之外的所有异常都照常抛出 —— 只放过溢出这一种，
  /// 避免把真实的空指针之类静默吞掉。
  Future<void> render(
    WidgetTester tester, {
    required Size size,
    required Widget child,
    required Brightness brightness,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(child, brightness));
    await tester.pump(const Duration(milliseconds: 300));

    final err = tester.takeException();
    if (err is FlutterError) {
      // 只针对溢出放行判断，其余 FlutterError 视为真失败
      final s = err.toString();
      if (s.contains('overflowed')) {
        fail('布局溢出（$size）：\n$s');
      }
    }
    expect(err, isNull, reason: '渲染 $size 时抛了非溢出异常');
  }

  for (final entry in _viewports.entries) {
    final label = entry.key;
    final size = entry.value;

    // 电视视口下 TvMode 必须打开，否则走的是手机分支，白测
    final isTvViewport = size.width > size.height;
    if (isTvViewport) {
      TvMode.instance.override.value = TvOverride.on;
    }

    group(label, () {
      // 深色与浅色都要过：浅色下部分前景/背景对比靠色值区分，
      // 布局无关，但同一次改动可能只在一套主题里改错。
      for (final b in Brightness.values) {
        final bn = b == Brightness.dark ? '深色' : '浅色';

        testWidgets('首页 $bn', (t) async {
          await render(t,
              size: size,
              brightness: b,
              child: const HomePage(debugLoader: _emptyLoader));
        });

        testWidgets('我的 $bn', (t) async {
          await render(t, size: size, brightness: b, child: const ProfilePage());
        });

        testWidgets('收藏 $bn', (t) async {
          await render(t,
              size: size, brightness: b, child: const FavoritesPage());
        });

        testWidgets('历史 $bn', (t) async {
          await render(t, size: size, brightness: b, child: const HistoryPage());
        });

        testWidgets('下载 $bn', (t) async {
          await render(t,
              size: size,
              brightness: b,
              child: const DownloadPage(embedded: true));
        });
      }
    });
  }
}