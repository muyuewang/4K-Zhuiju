/// 平台差异封装
///
/// 桌面端（Windows/Linux/macOS）与移动端（Android/iOS）在几处行为上根本不同，
/// 散在业务代码里写 `if (Platform.isAndroid)` 会让页面逻辑越来越难看，
/// 统一收在这一处：
///
///   1. 屏幕方向 / 沉浸式系统栏：桌面没有「竖屏/横屏」概念，也没有系统状态栏可隐藏。
///      直接调用 SystemChrome 不会崩，但会静默无效，全屏后窗口仍是原来大小，
///      用户会觉得「全屏按钮没反应」。桌面需要走窗口全屏（见 desktop_window.dart）。
///   2. 下载目录：桌面没有外部存储沙箱，直接用「下载」文件夹更符合直觉。
///   3. 返回键：桌面没有物理返回键，全屏退出要靠 Esc（原生侧已接管）。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_window.dart';

/// 是否桌面平台
bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 是否移动端
bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// 进入/退出全屏（自动分流到平台正确实现）
///
/// 移动端：锁横屏 + 隐藏系统栏。
/// 桌面端：真正把窗口切全屏（去掉标题栏、铺满显示器）。
Future<void> setFullscreen(bool on) async {
  if (isDesktop) {
    if (supportsWindowFullscreen) {
      await setDesktopFullscreen(on);
    }
    return;
  }
  if (on) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } else {
    await restorePortrait();
  }
}

/// 恢复竖屏 + 常驻系统栏（移动端）；桌面端退出窗口全屏
Future<void> restorePortrait() async {
  if (isDesktop) {
    if (supportsWindowFullscreen) {
      await setDesktopFullscreen(false);
    }
    return;
  }
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

/// 只在移动端执行的回调包装，桌面端直接跳过
Future<void> mobileOnly(Future<void> Function() action) async {
  if (!isMobile) return;
  await action();
}