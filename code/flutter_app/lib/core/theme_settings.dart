/// 主题模式：跟随系统 / 深色 / 浅色
///
/// 单独一个 ValueNotifier 而不是塞进其它设置类，是因为它要在
/// `MaterialApp` 最外层被监听——`App` 一变，整棵树用新主题重建。
///
/// 持久化选 string 而不是 index/int：将来枚举顺序调整、或再加一档
/// （比如「纯黑 AMOLED」），老用户的设置不会错位成另一个值。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode {
  system,
  dark,
  light;

  ThemeMode get material => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.light => ThemeMode.light,
      };

  String get label => switch (this) {
        AppThemeMode.system => '跟随系统',
        AppThemeMode.dark => '深色',
        AppThemeMode.light => '浅色',
      };

  /// 设置页副标题：让用户在点之前就知道会发生什么
  String get hint => switch (this) {
        AppThemeMode.system => '随系统的深色模式自动切换',
        AppThemeMode.dark => '夜间观看不刺眼',
        AppThemeMode.light => '白天户外更清晰',
      };

  static AppThemeMode fromName(String? n) => AppThemeMode.values.firstWhere(
        (e) => e.name == n,
        // 缺失或旧版本写入的未知值 → 跟随系统。
        // 默认不是 dark：新装用户大多希望跟系统一致，
        // 老用户升级也不会被强行改掉观感（系统是深色就还是深色）。
        orElse: () => AppThemeMode.system,
      );
}

class ThemeSettings {
  ThemeSettings._();
  static final ThemeSettings instance = ThemeSettings._();

  static const String _prefsKey = 'theme_mode';

  /// 初始值给 system：SharedPreferences 是异步的，
  /// runApp 之前来不及读。先按系统渲染首帧，读到用户选择再切，
  /// 避免为了一个设置项把启动卡住（这个项目刻意不在启动路径上 await）。
  final ValueNotifier<AppThemeMode> mode =
      ValueNotifier<AppThemeMode>(AppThemeMode.system);

  bool _restored = false;

  /// 启动时调用；不 await 也能用，读回来会自动刷新
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final sp = await SharedPreferences.getInstance();
      mode.value = AppThemeMode.fromName(sp.getString(_prefsKey));
    } catch (e) {
      debugPrint('[THEME] restore prefs failed: $e');
    }
  }

  void set(AppThemeMode m) {
    if (mode.value == m) return;
    mode.value = m;
    _persist(m);
  }

  void _persist(AppThemeMode m) {
    // 不 await：UI 立刻响应，磁盘写失败不该让点击卡住
    SharedPreferences.getInstance()
        .then((sp) => sp.setString(_prefsKey, m.name))
        .catchError((Object e) {
      debugPrint('[THEME] persist prefs failed: $e');
      return false;
    });
  }
}