/// 桌面窗口能力（Windows）
///
/// 通过原生方法通道 `zhuiju/window` 控制窗口全屏与最小尺寸。
/// 非 Windows 平台全部退化为空操作，调用方不需要判断平台。
///
/// 为什么不用 window_manager 这类插件：
///   本项目只需要「全屏开关」和「最小尺寸」两件事，引一个插件要多一份
///   原生依赖、多一层版本兼容风险，而这俩用 30 行 Win32 就能做完。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

const MethodChannel _ch = MethodChannel('zhuiju/window');

/// 桌面窗口全屏状态变化（原生侧按 Esc 退出时触发）
///
/// 值：是否处于全屏
final ValueNotifier<bool> desktopFullscreen = ValueNotifier<bool>(false);

/// 是否支持窗口级全屏控制
bool get _supported => Platform.isWindows;

/// 原生 → Dart 的单向通知：Esc 退出全屏后同步界面状态
void _installHandler() {
  _ch.setMethodCallHandler((call) async {
    if (call.method == 'exitedFullscreen') {
      desktopFullscreen.value = false;
    }
  });
}

bool _handlerInstalled = false;

/// 初始化窗口能力：注册通知 + 设置最小尺寸
///
/// 在 runApp 之后调用（需要引擎已就绪），失败不影响主流程。
Future<void> initDesktopWindow() async {
  if (!_supported) return;
  if (!_handlerInstalled) {
    _installHandler();
    _handlerInstalled = true;
  }
  try {
    // 最小 880x560：再小的话首页侧边导航 + 三列海报就挤不下了，
    // 用户能拖到一条缝那么窄，界面直接 overflow 出一片黄黑条纹。
    await _ch.invokeMethod('setMinimumSize', {'width': 880.0, 'height': 560.0});
  } catch (e) {
    debugPrint('[WIN] setMinimumSize failed: $e');
  }
}

/// 进入/退出窗口全屏
///
/// 返回原生侧实际状态（可能因为已处于该状态而没变化）。
Future<bool> setDesktopFullscreen(bool on) async {
  if (!_supported) return false;
  try {
    final r = await _ch.invokeMethod<bool>('setFullscreen', {'on': on});
    final v = r ?? on;
    desktopFullscreen.value = v;
    return v;
  } catch (e) {
    debugPrint('[WIN] setFullscreen($on) failed: $e');
    return false;
  }
}

/// 是否是「桌面窗口全屏」（区别于移动端的横屏沉浸式）
bool get supportsWindowFullscreen => isDesktop && _supported;