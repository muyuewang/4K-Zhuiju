/// 验证**最终要写进 `no_proxy` 的那条串**到底有没有效。
///
/// 前面两轮已经把 FFmpeg 的 no_proxy 语义钉死了：
///   精确域名/IP  → 有效
///   `*.a.b.c`   → 有效（星号只能在前缀，做后缀匹配）
///   `10.*`      → **无效**（尾星不认）
///   CIDR / `<local>` / `127.*` → 全部无效
///
/// 所以 `bypass` 里不能出现任何「前缀固定 + 尾星」的写法。这个探针
/// 只验一件事：换成 `localhost,127.0.0.1,::1,*.local` 之后，
/// 该排的排得掉、且不会误伤公网域名。
///
/// 同时确认一条**已知边界**：IP 段无法表达，`10.x` 仍会被送进代理 ——
/// 这不是靠串能解决的，必须由 Dart 侧按播放地址提前判掉（见 MpvProxyEnv）。
///
/// 这是个命令行探针，`print` 就是它的输出方式，不是遗留的调试语句。
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();
typedef _Int1Native = Int32 Function(Pointer<Void>);
typedef _Int1Dart = int Function(Pointer<Void>);
typedef _CmdNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _CmdDart = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _PutenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PutenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

const String _dll =
    r'C:\Users\fengxin\WorkBuddy\vivos7\code\flutter_app\build\windows\x64\runner\Release\libmpv-2.dll';

/// 候选串本身 —— 必须和 `MpvProxyEnv.bypass` 逐字一致。
const String _candidate = 'localhost,127.0.0.1,::1,*.local';

Future<String> _probe({
  required String target,
  required String noProxy,
}) async {
  final hits = <String>[];
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((s) {
    final buf = <int>[];
    s.listen((d) {
      buf.addAll(d);
      if (buf.length < 4) return;
      hits.add(latin1.decode(buf.take(80).toList()));
      try {
        s.write('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n');
      } catch (_) {}
      s.destroy();
    }, onError: (_) {}, cancelOnError: true);
  });

  final ucrt = DynamicLibrary.open('ucrtbase.dll');
  final putenv = ucrt.lookupFunction<_PutenvNative, _PutenvDart>('_putenv_s');
  putenv('http_proxy'.toNativeUtf8(),
      'http://127.0.0.1:${srv.port}'.toNativeUtf8());
  putenv('no_proxy'.toNativeUtf8(), noProxy.toNativeUtf8());

  final lib = DynamicLibrary.open(_dll);
  final create = lib.lookupFunction<_CreateNative, _CreateDart>('mpv_create');
  final init = lib.lookupFunction<_Int1Native, _Int1Dart>('mpv_initialize');
  final cmd = lib.lookupFunction<_CmdNative, _CmdDart>('mpv_command');
  final destroy =
      lib.lookupFunction<_Int1Native, _Int1Dart>('mpv_terminate_destroy');

  final ctx = create();
  init(ctx);
  final a = calloc<Pointer<Utf8>>(4);
  a[0] = 'loadfile'.toNativeUtf8();
  a[1] = target.toNativeUtf8();
  a[2] = 'replace'.toNativeUtf8();
  a[3] = nullptr;
  cmd(ctx, a);
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  destroy(ctx);
  await srv.close();
  return hits.isEmpty ? '已旁路' : '走了代理 (${hits.first.split('\r\n').first})';
}

Future<void> main() async {
  // 每条都写清楚「期望」，跑完能直接看出是不是符合预期。
  final cases = <({String url, String expect, String note})>[
    (
      url: 'http://127.0.0.1:9/x.m3u8',
      expect: '已旁路',
      note: '回环 IPv4，精确项',
    ),
    (
      url: 'http://localhost:9/x.m3u8',
      expect: '已旁路',
      note: '回环域名',
    ),
    (
      url: 'http://[::1]:9/x.m3u8',
      expect: '已旁路',
      note: '回环 IPv6，看 ::1 这一项认不认',
    ),
    (
      url: 'http://nas.local:9/x.m3u8',
      expect: '已旁路',
      note: 'mDNS 局域网名，靠 *.local',
    ),
    (
      url: 'http://10.1.2.3:9/x.m3u8',
      expect: '走了代理',
      note: '已知边界：IP 段无法表达，必须由 Dart 侧兜',
    ),
    (
      url: 'https://vip.dytt-tvs.com/x.m3u8',
      expect: '走了代理',
      note: '公网源站，必须走代理（不能被 *.local 误伤）',
    ),
  ];

  print('no_proxy = "$_candidate"');
  print('');
  var bad = 0;
  for (final c in cases) {
    final r = await _probe(target: c.url, noProxy: _candidate);
    final ok = r == c.expect;
    if (!ok) bad++;
    print('${ok ? "OK  " : "FAIL"} ${c.url}');
    print('      实际=$r  期望=${c.expect}');
    print('      ${c.note}');
  }
  print('');
  print(bad == 0 ? '全部符合预期' : '$bad 条不符合预期');
}