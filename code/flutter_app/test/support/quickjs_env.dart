/// 测试用的 QuickJS 原生库准备。
///
/// ## 为什么需要这一步
///
/// `flutter_js` 在 Windows 上通过 `DynamicLibrary.open('quickjs_c_bridge.dll')`
/// 加载引擎，而这个名字只按**当前工作目录**和 PATH 查找。
///
/// 三种运行方式下它的位置完全不同：
///
///   | 方式 | dll 从哪来 |
///   | --- | --- |
///   | `flutter run` / 打包 | CMake 的 install 规则把它拷进 bundle 目录，同目录加载 ✅ |
///   | **`flutter test`** | 跑在主机 Dart VM 里，**没有任何人拷过它** ❌ |
///   | Node / 纯 Dart 脚本 | 同样没有 ❌ |
///
/// 所以测试必须自己保证 dll 在 cwd。不处理的话，每一个碰到
/// [PluginRuntime] 的用例都会报：
///
///     Failed to load dynamic library 'quickjs_c_bridge.dll':
///     The specified module could not be found. (error code: 126)
///
/// ## 为什么不把 dll 提交进仓库
///
/// 677 KB 的二进制，来自第三方包。提交进来就等于把一个「会随
/// flutter_js 版本变化」的产物钉死在我们的 git 历史里——将来升级
/// 包版本时，旧 dll 还在，会出现「代码用新 API、dll 是旧的」这种
/// 极难排查的组合。所以从 pub cache 现取。
library;

import 'dart:io';

/// 确保当前目录下有 quickjs_c_bridge.dll，没有就从 pub cache 复制。
///
/// 返回 true 表示可用。调用方拿 false 时应让用例失败并给出明确原因——
/// 缺库是「环境不具备」，不是「插件系统坏了」，两者在 CI 上必须能区分开，
/// 否则红得没有信息量。
bool ensureQuickJsLibrary() {
  if (!Platform.isWindows) {
    // macOS/iOS 用系统 JavaScriptCore（DynamicLibrary.process），
    // Android 用 aar 里的 .so，都不需要这个 dll。
    // Android 的 .so 在真机上才加载，host 测试跑不了——
    // 由真机验证覆盖，这里直接放行。
    return Platform.isLinux ? _linuxLibReady() : true;
  }

  const libName = 'quickjs_c_bridge.dll';
  final cwdLib = File(libName);
  if (cwdLib.existsSync()) return true;

  final src = _findInPubCache(libName);
  if (src == null) return false;

  try {
    src.copySync(libName);
    return File(libName).existsSync();
  } catch (_) {
    return false;
  }
}

bool _linuxLibReady() {
  if (File('libquickjs_c_bridge_plugin.so').existsSync()) return true;
  final src = _findInPubCache('libquickjs_c_bridge_plugin.so');
  if (src == null) return false;
  try {
    src.copySync('libquickjs_c_bridge_plugin.so');
    return true;
  } catch (_) {
    return false;
  }
}

/// 在 pub cache 里找 flutter_js 包自带的库。
///
/// 路径形如：
///   `<pub-cache>/hosted/pub.dev/flutter_js-0.8.7/windows/shared/quickjs_c_bridge.dll`
///
/// 不写死版本号：升级 flutter_js 后目录名会变，写死会在升级那天静默失效。
File? _findInPubCache(String libName) {
  final cacheRoots = <String>[];

  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    cacheRoots.add('$localAppData\\Pub\\Cache');
  }
  final pubCache = Platform.environment['PUB_CACHE'];
  if (pubCache != null && pubCache.isNotEmpty) cacheRoots.add(pubCache);
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty) {
    cacheRoots.add('$home/.pub-cache');
    cacheRoots.add('$home\\AppData\\Local\\Pub\\Cache');
  }

  for (final root in cacheRoots) {
    final dir = Directory('$root\\hosted\\pub.dev');
    if (!dir.existsSync()) continue;
    // 目录名带版本号，用前缀匹配找最新的那个
    final candidates = dir
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split(Platform.pathSeparator).last
            .startsWith('flutter_js-'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    for (final c in candidates) {
      for (final rel in <String>[
        'windows\\shared\\$libName',
        'linux\\$libName',
      ]) {
        final f = File('${c.path}\\$rel');
        if (f.existsSync()) return f;
      }
    }
  }
  return null;
}