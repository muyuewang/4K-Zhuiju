/// 缓存清理
///
/// 清的是 `getTemporaryDirectory()` 下的东西——封面图缓存、HLS 代理切出来的
/// 临时分片、播放器解出来的缩略图，全都在这个目录里。
///
/// 为什么不用 `DefaultCacheManager().emptyCache()`：
///   1. flutter_cache_manager 只是 cached_network_image 的传递依赖，
///      直接 import 会触发 `depend_on_referenced_packages` 警告；
///   2. 它只管图片缓存，清不到 HLS 代理的 m4s 分片。那些分片按「集」堆，
///      追两三部剧就能攒出几百兆，比图片缓存大得多；
///   3. 直接扫目录还能顺带算出「占了多少」，界面才有东西可显示。
///
/// **绝对不碰下载目录**：那是用户主动保存的 MP4，删了等于删文件。
/// 临时目录和下载目录在 Android 上分属 cacheDir 与外部存储，天然隔离；
/// 这里也只遍历临时目录，不做任何跨目录操作。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 一次扫描的结果
class CacheUsage {
  /// 已占用字节数
  final int bytes;

  /// 文件个数
  final int files;

  const CacheUsage({required this.bytes, required this.files});

  static const CacheUsage zero = CacheUsage(bytes: 0, files: 0);

  /// 人类可读的体积：B / KB / MB / GB
  ///
  /// 整数就不拖小数点（200 MB 而不是 200.0 MB），非整数保留一位
  /// （50.5 MB）。原来 KB 档和 MB 档的取整规则不一致，导致 50.5 MB
  /// 被渲染成「51 MB」，白扔了半兆的精度——测试就是这么抓到的。
  String get human {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${_fmt(kb)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${_fmt(mb)} MB';
    return '${_fmt(mb / 1024)} GB';
  }

  /// 整数显示整数，否则保留一位小数
  static String _fmt(double v) {
    final rounded = v.roundToDouble();
    if ((v - rounded).abs() < 0.05) return rounded.toInt().toString();
    return v.toStringAsFixed(1);
  }
}

class CacheCleaner {
  CacheCleaner._();

  /// 统计缓存占用
  ///
  /// 遍历时容忍单个文件读取失败（并发删除、权限问题）：
  /// 统计不是关键路径，为了一个读不到的条目整体报错反而更糟。
  static Future<CacheUsage> measure() async {
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return CacheUsage.zero;
      var bytes = 0;
      var files = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          bytes += await e.length();
          files++;
        } catch (_) {
          // 遍历期间被别的 isolate 删掉了，跳过
        }
      }
      return CacheUsage(bytes: bytes, files: files);
    } catch (e) {
      debugPrint('[CACHE] measure failed: $e');
      return CacheUsage.zero;
    }
  }

  /// 清空缓存，返回清理前后的对比（用于告诉用户「释放了多少」）
  ///
  /// 只删临时目录**里面**的内容，不删目录本身——有些插件（HLS 代理、
  /// 播放器）会缓存目录路径、假定它一直存在，把目录删了会让它们
  /// 下次写文件时直接失败。
  static Future<CacheUsage> clear() async {
    var freed = 0;
    var removed = 0;
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return CacheUsage.zero;

      await for (final e in dir.list(followLinks: false)) {
        try {
          if (e is File) {
            final len = await e.length();
            await e.delete();
            freed += len;
            removed++;
          } else if (e is Directory) {
            // 子目录先算体积再整体删，删完就统计不到了
            final usage = await _measureDir(e);
            await e.delete(recursive: true);
            freed += usage.bytes;
            removed += usage.files;
          }
        } catch (e) {
          // 个别文件被占用（正在播放的分片）删不掉，跳过继续，
          // 不能因为一个文件失败就放弃整次清理
          debugPrint('[CACHE] skip ${e.runtimeType}: $e');
        }
      }
    } catch (e) {
      debugPrint('[CACHE] clear failed: $e');
    }
    return CacheUsage(bytes: freed, files: removed);
  }

  static Future<CacheUsage> _measureDir(Directory dir) async {
    var bytes = 0;
    var files = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          bytes += await e.length();
          files++;
        } catch (_) {}
      }
    } catch (_) {}
    return CacheUsage(bytes: bytes, files: files);
  }
}