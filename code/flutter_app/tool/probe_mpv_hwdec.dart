/// 读 libmpv 在「未做任何配置」时的默认解码参数。
///
/// 动机：媒体库 `media_kit` 的整个 lib 目录里搜不到 `hwdec` 一个字，
/// 而 `video_player_media_kit` 桥接层内部是 `Player()` 无参构造。
/// 这意味着 Windows 端跑的是 libmpv 的默认值 —— 但默认值到底是不是硬解，
/// 不能猜，直接问它。
///
/// 这个结果决定一件事：Windows 端 4K/HEVC 到底是硬解还是纯 CPU 软解。
/// 如果是软解，那它和 Android 的 MediaCodec 就是实质差距，且能解释
/// 「高码率片源在 PC 上掉帧/发热」，但与之前修好的「转圈」是两回事。
library;

// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();
typedef _Int1Native = Int32 Function(Pointer<Void>);
typedef _Int1Dart = int Function(Pointer<Void>);
typedef _GetStrNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStrDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

const String _dll =
    r'C:\Users\fengxin\WorkBuddy\vivos7\code\flutter_app\build\win_out\libmpv-2.dll';

void main() {
  final lib = DynamicLibrary.open(_dll);
  final create = lib.lookupFunction<_CreateNative, _CreateDart>('mpv_create');
  final init = lib.lookupFunction<_Int1Native, _Int1Dart>('mpv_initialize');
  final getStr =
      lib.lookupFunction<_GetStrNative, _GetStrDart>('mpv_get_property_string');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_free');
  final destroy =
      lib.lookupFunction<_Int1Native, _Int1Dart>('mpv_terminate_destroy');

  final ctx = create();
  init(ctx);

  String? read(String name) {
    final p = getStr(ctx, name.toNativeUtf8());
    if (p == nullptr || p.address == 0) return null;
    final s = p.toDartString();
    free(p);
    return s;
  }

  print('--- libmpv 默认值（未做任何配置）---');
  for (final k in [
    'hwdec', // 硬解开关：no / auto / auto-safe / d3d11va ...
    'hwdec-current', // 当前实际生效的硬解后端
    'vo', // 视频输出驱动
    'gpu-api',
    'vd-lavc-threads', // 解码线程数，0=自动按核数
    'cache', // 是否启用流缓存
    'cache-secs', // 缓存秒数
    'demuxer-max-bytes', // 解复用缓冲上限
    'stop-screensaver', // 是否阻止息屏
  ]) {
    print('  $k = ${read(k) ?? '<读取失败>'}');
  }

  destroy(ctx);
  print('');
  print('对照：Android 端由 ExoPlayer + MediaCodec 硬件解码');
}