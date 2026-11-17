/// 插件源的「刷新并应用」流程，两个调用点共用。
///
/// ## 为什么单独抽一个文件
///
/// 这件事有两个触发时机：
///   1. App 启动后后台跑一次（`main.dart`）
///   2. 用户在设置页手动点「刷新插件配置」
///
/// 两边要做的动作**完全相同**：拉远端 → 装进注册表 → 预热引擎。
/// 复制一份的话，迟早会有一边漏改（最常见的漏改是「忘了预热」，
/// 表现为首次进插件源卡一下，很难归因）。
///
/// ## 和 UI 的关系
///
/// 这个文件**不 import Flutter 的 widget 层**，只依赖 debugPrint。
/// 这样设置页可以按需 `await` 拿结果做反馈，启动路径可以 `unawaited`
/// 直接扔后台——同一份逻辑，两种用法。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../source/data_source.dart';
import '../source/registry.dart';
import 'plugin_loader.dart';
import 'plugin_runtime.dart';
import 'remote_js_source.dart';

/// 一次刷新的结果。给 UI 用，所以带的是能直接显示给人看的文案。
class PluginSyncResult {
  const PluginSyncResult._({
    required this.ok,
    required this.count,
    this.message = '',
    this.usedCache = false,
  });

  /// 远端拉到并成功替换。
  factory PluginSyncResult.success(int count, {required bool usedCache}) =>
      PluginSyncResult._(ok: true, count: count, usedCache: usedCache);

  /// 失败。此时**注册表保持原状**（继续用缓存里的源）。
  factory PluginSyncResult.failure(String message) =>
      PluginSyncResult._(ok: false, count: 0, message: message);

  final bool ok;

  /// 刷新后实际生效的插件源数量。
  final int count;

  /// 失败原因（人话）。
  final String message;

  /// 是否用的是旧缓存（远端失败但缓存可用）。
  final bool usedCache;

  /// 设置页上显示的一行结果。
  String get display => ok
      ? (count == 0
          ? '远端配置里没有启用的源'
          : '已更新 $count 个源${usedCache ? '（部分来自缓存）' : ''}')
      : message;
}

/// 插件源同步。全部是静态方法，没有状态——状态都在 [PluginLoader]。
class PluginSync {
  PluginSync._();

  /// 把 [PluginLoader] 当前持有的插件装进注册表。
  ///
  /// 幂等：重复调用不会产生重复源（[SourceRegistry.replacePlugins]
  /// 内部按 id 去重，并处理「当前源被摘掉」的回退）。
  static void apply() {
    final sources = PluginLoader.instance.plugins
        .map<DataSource>((p) => RemoteJsSource(p))
        .toList();
    SourceRegistry.replacePlugins(sources);
    debugPrint('[PLUGIN] applied ${sources.length} source(s)');
  }

  /// 拉远端 → 应用 → 预热。
  ///
  /// **会等网络**（最长约 10 秒 × 镜像数）。启动路径请用 `unawaited`，
  /// 设置页可以 `await` 以便给用户反馈。
  ///
  /// 任何异常都被吃掉并转成失败结果：插件是增强能力，
  /// 它挂掉绝不能让 App 起不来，也不该让设置页弹红屏。
  static Future<PluginSyncResult> refresh() async {
    try {
      final ok = await PluginLoader.instance.refresh();
      if (!ok) {
        final why = PluginLoader.instance.lastError ?? '无可用镜像';
        debugPrint('[PLUGIN] refresh failed: $why');
        // 远端失败但本地缓存还在 → 源照常可用，只是不是最新。
        // 这种情况必须说清楚，否则用户会以为「刷新了但没变化」是坏了。
        if (PluginLoader.instance.plugins.isNotEmpty) {
          return PluginSyncResult.failure(
              '拉取失败，继续使用本地缓存（$why）');
        }
        return PluginSyncResult.failure('拉取失败：$why');
      }

      apply();

      // 预热放在刷新成功之后：配置都没拉到通常意味着网络不通，
      // 这时候 spawn 一个 JS 引擎也做不了什么，纯属浪费。
      unawaited(PluginRuntime.instance.warmUp());

      return PluginSyncResult.success(
        PluginLoader.instance.plugins.length,
        usedCache: PluginLoader.instance.usedCache,
      );
    } catch (e) {
      debugPrint('[PLUGIN] refresh threw: $e');
      return PluginSyncResult.failure('刷新出错：$e');
    }
  }

  /// 给设置页展示的当前状态（不发请求）。
  static String get statusLine {
    final loader = PluginLoader.instance;
    final n = loader.plugins.length;
    if (n == 0) {
      return loader.lastError == null ? '尚未拉取' : '不可用';
    }
    return '$n 个源';
  }
}