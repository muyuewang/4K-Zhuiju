/// 播放时保持屏幕常亮
///
/// 为什么需要它：Android 的默认息屏时间是 30 秒~1 分钟，视频画面本身
/// **不会**阻止系统息屏。没有这个开关，用户看剧时手机会在几十秒后黑屏，
/// 必须隔一会儿点一下屏幕——这是很明显的体验缺陷。
///
/// 实现选原生 `FLAG_KEEP_SCREEN_ON` 而不是引第三方包（wakelock_plus）：
///   1. 只是一行 Window flag，不需要额外依赖，包体积零增长；
///   2. 不依赖网络拉包，离线也能稳定构建；
///   3. 这个 flag 由系统在窗口不可见时自动失效，不会出现「App 退到后台
///      还一直亮着屏」的耗电问题——比手动维护 wake lock 更安全。
///
/// 只对 Android 生效。Windows 桌面没有「息屏」这回事（睡眠由系统策略控制，
/// 播放视频时通常已被系统识别为活跃），这里直接跳过。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenAwake {
  ScreenAwake._();

  static const MethodChannel _ch = MethodChannel('com.zhuiju.app/screen');

  /// 记录当前状态，避免每次播放进度回调都发一次平台调用。
  /// video_player 每秒会回调几十次，无脑透传会白白压平台通道。
  static bool _on = false;

  /// 设置是否常亮。重复设置同一值会被忽略。
  static Future<void> set(bool on) async {
    if (!Platform.isAndroid) return;
    if (_on == on) return;
    _on = on;
    try {
      await _ch.invokeMethod<void>('setAwake', {'on': on});
    } catch (e) {
      // 平台侧不可用时不该影响播放，静默降级成「按系统默认息屏」
      debugPrint('[SCREEN] setAwake($on) failed: $e');
      _on = !on; // 回滚，下次还能重试
    }
  }

  /// 页面退出时务必调用，否则回到列表页还一直亮着
  static Future<void> release() => set(false);
}