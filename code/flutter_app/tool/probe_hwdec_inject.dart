/// 验证「把硬解打开」的可行路径，而不是凭推测。
///
/// 前面已实测：libmpv 未做配置时 `hwdec = no`（纯软解）。而 Android
/// 走 ExoPlayer + MediaCodec 是硬解 —— 这就是两端最实质的差距。
///
/// 这个探针回答两件事：
///   1. libmpv 认不认 `hwdec` 这个选项（initialize **之前**设置）
///   2. 能不能不改播放器代码，只靠 `MPV_HOME` + `mpv.conf` 注入
///
/// 第 2 条决定改动成本：
///   成立 → 复用已有的 _putenv_s 机制写个配置文件即可，业务代码零改动
///   不成立 → 必须绕开 video_player_media_kit，直接用 media_kit API
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
typedef _SetOptNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetOptDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _PutenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PutenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

const String _dll =
    r'C:\Users\fengxin\WorkBuddy\vivos7\code\flutter_app\build\win_out\libmpv-2.dll';

class _Mpv {
  final _CreateDart create;
  final _Int1Dart init;
  final _GetStrDart getStr;
  final _SetOptDart setOpt;
  final _FreeDart free;
  final _Int1Dart destroy;

  _Mpv(DynamicLibrary lib)
      : create = lib.lookupFunction<_CreateNative, _CreateDart>('mpv_create'),
        init = lib.lookupFunction<_Int1Native, _Int1Dart>('mpv_initialize'),
        getStr = lib
            .lookupFunction<_GetStrNative, _GetStrDart>('mpv_get_property_string'),
        setOpt = lib.lookupFunction<_SetOptNative, _SetOptDart>(
            'mpv_set_option_string'),
        free = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_free'),
        destroy = lib
            .lookupFunction<_Int1Native, _Int1Dart>('mpv_terminate_destroy');

  String? read(Pointer<Void> ctx, String name) {
    final p = getStr(ctx, name.toNativeUtf8());
    if (p == nullptr || p.address == 0) return null;
    final s = p.toDartString();
    free(p);
    return s;
  }
}

void main() {
  final lib = DynamicLibrary.open(_dll);
  final m = _Mpv(lib);

  print('=== 候选 1：mpv_set_option_string("hwdec") 在 initialize 之前 ===');
  {
    final ctx = m.create();
    final rc = m.setOpt(ctx, 'hwdec'.toNativeUtf8(), 'auto-safe'.toNativeUtf8());
    m.init(ctx);
    print('  set_option 返回码 = $rc   (0=接受, 负数=不认)');
    print('  initialize 后 hwdec = ${m.read(ctx, 'hwdec') ?? '<读取失败>'}');
    print('  hwdec-current      = ${m.read(ctx, 'hwdec-current') ?? '<尚未起播，空属正常>'}');
    m.destroy(ctx);
  }

  print('');
  print('=== 候选 2：MPV_HOME + mpv.conf 注入（不改业务代码的路径）===');
  {
    final home = Directory.systemTemp.createTempSync('mpv_home_probe');
    File('${home.path}/mpv.conf')
        .writeAsStringSync('hwdec=auto-safe\ncache-secs=20\n');

    final ucrt = DynamicLibrary.open('ucrtbase.dll');
    final putenv =
        ucrt.lookupFunction<_PutenvNative, _PutenvDart>('_putenv_s');
    putenv('MPV_HOME'.toNativeUtf8(), home.path.toNativeUtf8());

    final ctx = m.create();
    m.init(ctx);
    final hw = m.read(ctx, 'hwdec');
    final cs = m.read(ctx, 'cache-secs');
    print('  MPV_HOME = ${home.path}');
    print('  hwdec      = ${hw ?? '<读取失败>'}   ${hw == 'auto-safe' ? '← 配置生效' : '← 没读到配置'}');
    print('  cache-secs = ${cs ?? '<读取失败>'}   ${cs == '20' || cs == '20.000000' ? '← 配置生效' : '← 没读到配置'}');
    m.destroy(ctx);

    try {
      home.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('');
  print('=== 候选 3：hwdec 各取值的实际含义 ===');
  print('  no           纯软解（当前状态）');
  print('  auto         总是尝试硬解，失败不回落（更激进）');
  print('  auto-safe    仅在解码器白名单内尝试硬解（推荐，失败自动回落软解）');
  print('  d3d11va      Windows 专用，D3D11 硬解');
  print('  dxva2        老式 API，Win7 时代，现在不用');
}