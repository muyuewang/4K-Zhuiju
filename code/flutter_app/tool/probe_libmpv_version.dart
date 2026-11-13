/// 读 libmpv 自身的 `mpv-version` / `ffmpeg-version`。
///
/// ## 为什么必须问它自己，而不是猜
///
/// 项目里 `libmpv-2.dll` 的文件时间是 2023-09-24，但**文件时间不等于内部
/// FFmpeg 的版本** —— media_kit 的分发包是重新打包的，DLL 时间戳只反映打包
/// 时刻，可能内嵌比文件时间新得多的 FFmpeg。
///
/// libmpv 内置两个只读属性直接把答案给出来，不需要反汇编也不需要 strings：
///   - `mpv-version`    → 如 `mpv v0.37.0`
///   - `ffmpeg-version` → 如 `N-112000-g...` 或 `6.1.1`
///
/// 这个结果是「升级 FFmpeg」这件事的**基线**：不知道现在是多少，就无法判断
/// 升级到底升到了什么、有没有必要升。
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

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : _dll;
  final lib = DynamicLibrary.open(path);
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
    final np = name.toNativeUtf8();
    final p = getStr(ctx, np);
    calloc.free(np);
    if (p == nullptr || p.address == 0) return null;
    final s = p.toDartString();
    free(p);
    return s;
  }

  print('DLL: $path');
  print('');
  for (final k in [
    'mpv-version',
    'ffmpeg-version',
    'libavformat-version',
    'libavcodec-version',
    'libavutil-version',
  ]) {
    print('  ${k.padRight(20)} = ${read(k) ?? '<该版本无此属性>'}');
  }

  destroy(ctx);
}