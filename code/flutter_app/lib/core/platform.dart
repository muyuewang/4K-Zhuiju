/// 平台差异封装
///
/// 桌面端（Windows/Linux/macOS）与移动端（Android/iOS）在几处行为上根本不同，
/// 散在业务代码里写 `if (Platform.isAndroid)` 会让页面逻辑越来越难看，
/// 统一收在这一处：
///
///   1. 屏幕方向 / 沉浸式系统栏：桌面没有「竖屏/横屏」概念，也没有系统状态栏可隐藏。
///      直接调用 SystemChrome 不会崩，但会静默无效，全屏后窗口仍是原来大小，
///      用户会觉得「全屏按钮没反应」。桌面需要走窗口全屏。
///   2. 下载目录：桌面没有外部存储沙箱，直接用「下载」文件夹更符合直觉。
///   3. 返回键：桌面没有物理返回键，全屏退出要靠 Esc。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 是否桌面平台
bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 是否移动端
bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// 进入/退出全屏（自动分流到平台正确实现）
///
/// 移动端：锁横屏 + 隐藏系统栏。
/// 桌面端：交给页面自己处理窗口尺寸（见 [DesktopWindow]），
/// 这里只做 no-op，避免调用无效 API 产生误导性的「已全屏」状态。
Future<void> setFullscreen(bool on) async {
  if (isDesktop) return;
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

/// 恢复竖屏 + 常驻系统栏（移动端）
Future<void> restorePortrait() async {
  if (isDesktop) return;
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