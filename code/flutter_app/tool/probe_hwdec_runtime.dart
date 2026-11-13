/// 真实起播后读 `hwdec-current`，回答「auto 到底有没有落到 d3d11va」。
///
/// ## 为什么要单独造一个探针
///
/// 前两个探针只读了**未起播**时的静态值：
///   - `probe_mpv_hwdec.dart`   → 裸 libmpv 默认 `hwdec = no`
///   - `probe_hwdec_inject.dart` → `mpv_set_option_string` 生效、`MPV_HOME` 不生效
///
/// 但这两个值都不能直接套到 App 上，原因是 App 并不走裸 `mpv_create`：
/// `media_kit_video` 的 `NativeVideoController.create` 会显式写
/// `hwdec: configuration.hwdec ?? 'auto'`，而 `video_player_media_kit`
/// 内部是 `VideoController(player)` 无参构造 —— 于是 App 拿到的是 `auto`。
///
/// `hwdec-current` 是**运行时**属性：只有真正解出一帧之后才有值，起播前读
/// 一律是空。所以判断「有没有硬解」只能真载入一段视频再读，不能看配置。
///
/// ## 为什么用 vo=null 而不是复刻 App 的 vo=libmpv
///
/// App 的 `vo=libmpv` 需要先由 `video_output.cc` 创建 OpenGL(ANGLE) 渲染上下文，
/// 那是 Flutter 插件里的 C++ 侧，控制台进程里没有窗口、也没有 GL 上下文，
/// 复刻不了。`vo=null` 是 mpv 自带的无输出驱动，仍然会实例化解码器并把帧
/// 解出来（解完丢弃），因此 **`hwdec-current` 依然能反映解码器选择**。
///
/// 这一点必须在结论里写明：它证明的是「解码器层面自动选择会不会选中
/// d3d11va」，而不是「App 的纹理上传路径一定走 D3D11」。后者由
/// `VideoControllerConfiguration.enableHardwareAcceleration`（默认 true）
/// 与 ANGLE 决定，是另一层。
library;

// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();
typedef _Int1Native = Int32 Function(Pointer<Void>);
typedef _Int1Dart = int Function(Pointer<Void>);
typedef _Str1Native = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _Str1Dart = int Function(Pointer<Void>, Pointer<Utf8>);
// mpv_set_option_string 是 **三个**参数（ctx, name, data），
// 和 mpv_command_string 的（ctx, cmd）不是一个签名。
// 混用一个 typedef 的后果是编译期报 Too many positional arguments。
typedef _Str2Native = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Str2Dart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _PutenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PutenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _GetStrNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStrDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

const String _dll =
    r'C:\Users\fengxin\WorkBuddy\vivos7\code\flutter_app\build\win_out\libmpv-2.dll';

/// 默认测试流（Big Buck Bunny，H.264）。
///
/// 选它而不是项目里的源站地址：探针只关心解码器选择，源站随时可能失效或
/// 需要代理，会让「解不出来」和「硬解失败」混在一起，分不清原因。
const String _defaultStream =
    'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

/// 实际使用的流。可用 `dart run tool/probe_hwdec_runtime.dart <url>` 覆盖，
/// 用来换片源验证不同编码（H.264 / HEVC）下硬解是否都成立。
///
/// 做成参数而不是写死两份：H.264 和 HEVC 走的是 d3d11va 里**不同的解码器
/// 配置**，只测一个就下结论会把「HEVC 没硬解」漏掉。
late final String _stream;

class _Mpv {
  final _CreateDart create;
  final _Int1Dart init;
  final _Str2Dart setOpt;
  final _Str1Dart cmdString;
  final _GetStrDart getStr;
  final _FreeDart free;
  final _Int1Dart destroy;

  _Mpv(DynamicLibrary lib)
      : create = lib.lookupFunction<_CreateNative, _CreateDart>('mpv_create'),
        init = lib.lookupFunction<_Int1Native, _Int1Dart>('mpv_initialize'),
        setOpt = lib
            .lookupFunction<_Str2Native, _Str2Dart>('mpv_set_option_string'),
        cmdString = lib
            .lookupFunction<_Str1Native, _Str1Dart>('mpv_command_string'),
        getStr = lib
            .lookupFunction<_GetStrNative, _GetStrDart>('mpv_get_property_string'),
        free = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_free'),
        destroy = lib
            .lookupFunction<_Int1Native, _Int1Dart>('mpv_terminate_destroy');

  String? read(Pointer<Void> ctx, String name) {
    final np = name.toNativeUtf8();
    final p = getStr(ctx, np);
    calloc.free(np);
    if (p == nullptr || p.address == 0) return null;
    final s = p.toDartString();
    free(p);
    return s;
  }

  int set(Pointer<Void> ctx, String k, String v) {
    final kp = k.toNativeUtf8();
    final vp = v.toNativeUtf8();
    final rc = setOpt(ctx, kp, vp);
    calloc.free(kp);
    calloc.free(vp);
    return rc;
  }

  int cmd(Pointer<Void> ctx, String line) {
    final p = line.toNativeUtf8();
    final rc = cmdString(ctx, p);
    calloc.free(p);
    return rc;
  }
}

/// 跑一组配置：设置选项 → init → loadfile → 轮询 hwdec-current。
///
/// 轮询而不是固定 sleep：流是网络的，起播时间不可预测。固定等 5 秒要么白等、
/// 要么在慢网下误判「没解出来」。这里以 `video-params/pixelformat` 出现作为
/// 「已经解码」的判据（它只在有视频帧输出后才非空），再读 hwdec-current。
Map<String, String?> _run(_Mpv m, String label, String hwdec, {String? vo}) {
  final ctx = m.create();
  m.set(ctx, 'hwdec', hwdec);
  if (vo != null) m.set(ctx, 'vo', vo);
  // 探针不需要声音，也避免没有音频设备时报错刷屏。
  m.set(ctx, 'ao', 'null');
  m.set(ctx, 'cache', 'yes');
  m.set(ctx, 'network-timeout', '10');
  m.init(ctx);
  final initHwdec = m.read(ctx, 'hwdec');
  final loadRc = m.cmd(ctx, 'loadfile "$_stream"');

  String? pixfmt;
  String? hwCurrent;
  String? codec;
  var waited = 0;
  // 最多等 20 秒：首个分片要走网络，慢的时候 5~8 秒很正常。
  while (waited < 20000) {
    sleep(const Duration(milliseconds: 500));
    waited += 500;
    pixfmt = m.read(ctx, 'video-params/pixelformat');
    if (pixfmt != null && pixfmt.isNotEmpty) {
      // 再多等 300ms 让解码器初始化完全落定，避免读到中间态。
      sleep(const Duration(milliseconds: 300));
      hwCurrent = m.read(ctx, 'hwdec-current');
      codec = m.read(ctx, 'video-codec');
      break;
    }
  }

  // 没解出帧时必须能说清是哪一环断的，否则「空值」会被误读成「软解」。
  final path = m.read(ctx, 'path');
  final idleActive = m.read(ctx, 'idle-active');
  final coreIdle = m.read(ctx, 'core-idle');

  print('--- $label ---');
  print('  设置 hwdec=$hwdec   init 后读回 = ${initHwdec ?? '<空>'}'
      '   loadfile rc = $loadRc');
  print('  等待解码耗时       = ${waited}ms');
  print('  video-codec        = ${codec ?? '<空>'}');
  print('  video-params/pixelformat= ${pixfmt ?? '<空>'}');
  print('  hwdec-current      = ${hwCurrent ?? '<空>'}');
  if (pixfmt == null || pixfmt.isEmpty) {
    print('  [诊断] path        = ${path ?? '<空>'}');
    print('  [诊断] idle-active = ${idleActive ?? '<空>'}');
    print('  [诊断] core-idle   = ${coreIdle ?? '<空>'}');
  }
  m.destroy(ctx);
  print('');
  return {'hwdec-current': hwCurrent, 'pixfmt': pixfmt, 'codec': codec};
}

void main(List<String> args) {
  _stream = args.isNotEmpty ? args.first : _defaultStream;

  // 第二个参数可覆盖 DLL 路径，用来验证「换新 libmpv 之后硬解是否仍成立」。
  // 默认用项目已装的旧版（FFmpeg n6.0）；升级验证时传新版路径即可，
  // 不需要把新 DLL 先塞进构建目录 —— 那会在验证失败时留下脏产物。
  final dllPath = args.length > 1 ? args[1] : _dll;
  final lib = DynamicLibrary.open(dllPath);
  print('libmpv: $dllPath');

  // FFmpeg 走自己的网络栈，**不读 Windows 系统代理**，只认环境变量。
  // 不注入这一段，探针在代理后面会一个分片都拉不到 —— 表现和「硬解失败」
  // 完全一样（pixfmt 空、超时），分不清是网络还是解码。项目里
  // `MpvProxyEnv` 就是为这件事存在的，这里复刻同一套 `_putenv_s`。
  const proxy = 'http://127.0.0.1:7897';
  final ucrt = DynamicLibrary.open('ucrtbase.dll');
  final putenv = ucrt.lookupFunction<_PutenvNative, _PutenvDart>('_putenv_s');
  for (final kv in [
    ('http_proxy', proxy),
    ('https_proxy', proxy),
  ]) {
    final kp = kv.$1.toNativeUtf8();
    final vp = kv.$2.toNativeUtf8();
    putenv(kp, vp);
    calloc.free(kp);
    calloc.free(vp);
  }
  print('已注入 http_proxy / https_proxy = $proxy （供 libmpv 的 FFmpeg 使用）');
  print('');

  final m = _Mpv(lib);

  print('=== 真实起播后读 hwdec-current ===');
  print('流：$_stream');
  print('');

  _run(m, 'A. App 实际配置（media_kit 兜底 hwdec=auto）', 'auto', vo: 'null');
  _run(m, 'B. 对照组（hwdec=no，强制软解）', 'no', vo: 'null');
  _run(m, 'C. 显式指定（hwdec=d3d11va）', 'd3d11va', vo: 'null');
  _run(m, 'D. 建议值（hwdec=auto-safe）', 'auto-safe', vo: 'null');

  print('判读：');
  print('  hwdec-current = d3d11va / d3d11va-copy  → 确实走到 D3D11 硬解');
  print('  hwdec-current = no                      → 实际是软解');
  print('  hwdec-current = <空> 且 pixfmt 也空     → 没解出帧，本结论不成立，需换流');
}