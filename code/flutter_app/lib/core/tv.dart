/// TV（大屏 + 遥控器）模式识别与开关
///
/// 为什么需要单独一个「模式」，而不是直接按屏幕宽度判断：
/// 电视盒子的逻辑分辨率经常是 960x540（1080p 面板 dpr=2），
/// 按宽度判断只会得到「平板」，走的是底部导航 + 手机字号 —— 投到
/// 3 米外的大屏上字小得看不清，导航也够不着。真正的判断依据是
/// 「这台设备是电视，用户手里是遥控器」，只能问系统。
///
/// 判定分两层：
///   1. 系统探测：UiModeManager 的当前模式是 UI_MODE_TYPE_TELEVISION，
///      或 PackageManager 报了 leanback / television feature。
///      这是「它是不是电视」的事实判断。
///   2. 用户覆盖：设置里可强制开 / 关。盒子固件五花八门，有的把
///      UI_MODE 报成 NORMAL、有的没有 leanback feature，纯靠探测会漏判；
///      也有人在 HTPC / 投影上接电视用，需要手动强开。
///
/// 覆盖值优先于探测结果。存字符串而不是 bool，是为了区分
/// 「没设过」（跟随探测）和「显式设为关」这两种情况。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户对 TV 模式的选择
enum TvOverride {
  /// 跟随系统探测
  auto,

  /// 强制开启
  on,

  /// 强制关闭
  off;

  String get label => switch (this) {
        TvOverride.auto => '自动识别',
        TvOverride.on => '开启',
        TvOverride.off => '关闭',
      };

  String get hint => switch (this) {
        TvOverride.auto => '检测到电视/盒子时自动启用遥控器操作',
        TvOverride.on => '强制启用：大字号、焦点高亮、遥控器操作',
        TvOverride.off => '关闭，按手机/平板方式显示',
      };

  static TvOverride fromName(String? n) => TvOverride.values
      .firstWhere((e) => e.name == n, orElse: () => TvOverride.auto);
}

class TvMode {
  TvMode._();

  static final TvMode instance = TvMode._();

  static const MethodChannel _ch = MethodChannel('com.zhuiju.app/tv');
  static const String _prefKey = 'tv_mode_override';

  /// 最终是否启用 TV 模式。界面用它决定字号、导航形态和焦点样式。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// 用户选择（设置页展示用）
  final ValueNotifier<TvOverride> override =
      ValueNotifier<TvOverride>(TvOverride.auto);

  /// 系统探测结果：这台 Android 设备是不是电视
  bool detected = false;

  bool _restored = false;

  /// 读设置 + 探测设备。
  ///
  /// 可以重复调用（内部幂等），启动路径里不 await 也不会重复探测。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    await detect();
    try {
      final sp = await SharedPreferences.getInstance();
      override.value = TvOverride.fromName(sp.getString(_prefKey));
    } catch (e) {
      debugPrint('[TV] prefs restore failed: $e');
    }
    _apply();
  }

  /// 问原生：这台设备是不是电视
  ///
  /// 非 Android 一律 false。桌面端不算 TV —— 那边有鼠标和键盘，
  /// 已经有一整套 hover 与快捷键，硬套遥控器样式只会变丑。
  /// 需要时用户可以在设置里手动开（HTPC 场景）。
  Future<void> detect() async {
    if (!Platform.isAndroid) {
      detected = false;
      _apply();
      return;
    }
    try {
      final r = await _ch.invokeMethod<bool>('isTv');
      detected = r ?? false;
    } catch (e) {
      // 通道没实现（比如跑在旧的原生壳里）不该让 App 起不来
      debugPrint('[TV] detect failed: $e');
      detected = false;
    }
    debugPrint('[TV] detected=$detected');
  }

  /// 用户在设置里改选择
  Future<void> setOverride(TvOverride v) async {
    override.value = v;
    _apply();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefKey, v.name);
    } catch (e) {
      debugPrint('[TV] persist failed: $e');
    }
  }

  void _apply() {
    final on = switch (override.value) {
      TvOverride.auto => detected,
      TvOverride.on => true,
      TvOverride.off => false,
    };
    if (enabled.value == on) return;
    enabled.value = on;
    debugPrint('[TV] enabled=$on (detected=$detected, '
        'override=${override.value.name})');
  }
}

/// 当前是否 TV 模式（同步读，供热路径用）
bool get tvModeOn => TvMode.instance.enabled.value;