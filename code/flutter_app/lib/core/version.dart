/// 版本号的单一来源
///
/// 为什么不引 package_info_plus：它要走一次平台通道 + 读 AndroidManifest，
/// 只为在「关于」里显示一行版本号，不值得为它多一个原生依赖（而且首帧
/// 之后才能拿到，UI 还得为「版本未知」写一套占位逻辑）。
///
/// 代价是改版本时要手动同步 pubspec.yaml 的 version 字段——两处都在同一次
/// 提交里改，成本可控，而且比「显示错了却没人发现」要好。
/// 原来的实现是把 '1.0.0' 直接写死在两处 UI 里，升到 1.0.1 后界面还在
/// 显示 v1.0.0，就是这个坑。
library;

/// 应用显示名（单一来源）
///
/// 窗口标题、关于对话框、Android label 都从这里取，改名时只改这一处。
const String kAppTitle = '4K追剧';

/// 展示用版本号（与 pubspec.yaml 的 version 的 `+` 之前部分保持一致）
const String kAppVersion = '1.1.0';

/// 构建号（pubspec.yaml 的 version 中 `+` 之后部分）
const String kAppBuild = '3';

/// 完整标识，如 `1.1.0 (3)`
const String kAppVersionFull = '$kAppVersion ($kAppBuild)';