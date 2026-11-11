/// 播放偏好（目前只有「线路优先级」一项）。
///
/// 为什么要做成可切换而不是写死：
///
/// kanju 一部剧有 14~28 条线路，分两类，各自的优劣完全相反：
///
///   | 类型         | 画质            | 代价                        |
///   | ------------ | --------------- | --------------------------- |
///   | 官方线       | 1080P / 4K 最高 | 多一次 resolve 请求 + 需会话 |
///   | 普通/采集线  | 清晰度参差      | 拿来即播，但实测常卡        |
///
/// 实测 2026-11-11（游客会话下）：
///   沙海      8 集抽样  官方线 16/16 全部可播
///   庆余年S2  6 集抽样  官方线 27/27 全部可播
///
/// 所以默认给「官方优先」。但保留手动切换：官方线要过一次会话接口，
/// 网络差的环境下多一跳反而更慢，用户需要能退回去。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 线路优先级偏好
enum LinePreference {
  /// 官方线优先：画质最高，需游客会话
  officialFirst,

  /// 普通线优先：不依赖会话，少一次请求
  directFirst;

  String get label => this == LinePreference.officialFirst ? '官方线路优先' : '普通线路优先';

  String get hint => this == LinePreference.officialFirst
      ? '画质最高（1080P/4K），播放前会建立游客会话'
      : '少一次请求，不依赖会话，但清晰度参差';
}

/// 全局播放偏好。单例 + ValueNotifier，页面监听即可自动重建。
class PlaybackPrefs {
  PlaybackPrefs._();
  static final PlaybackPrefs instance = PlaybackPrefs._();

  static const String _kLinePrefKey = 'app.linePreference';

  /// 默认官方优先：用户实测反馈「普通源很卡」，且官方线已验证 100% 可播
  final ValueNotifier<LinePreference> linePref =
      ValueNotifier<LinePreference>(LinePreference.officialFirst);

  bool _loaded = false;

  /// 启动时读回。失败一律保留默认，不让 App 起不来。
  Future<void> restore() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kLinePrefKey);
      if (raw == null || raw.isEmpty) return;
      for (final p in LinePreference.values) {
        if (p.name == raw) {
          linePref.value = p;
          return;
        }
      }
    } catch (e) {
      debugPrint('[PREF] restore linePreference failed: $e');
    }
  }

  Future<void> setLinePref(LinePreference p) async {
    if (linePref.value == p) return;
    linePref.value = p;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLinePrefKey, p.name);
    } catch (e) {
      debugPrint('[PREF] persist linePreference failed: $e');
    }
  }
}