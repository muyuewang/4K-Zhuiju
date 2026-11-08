# 4K追剧 · Flutter 工程

这是「4K追剧」的 Flutter 源码目录，同一套代码产出 Android 和 Windows 两个平台的安装包。

面向用户的介绍、卖点和下载链接在仓库根目录的 [README.md](../../README.md)。这里只写开发和构建相关的东西。

## 目录

```
lib/
  core/          协议、加密、API、数据模型、下载、历史、弹幕、平台差异
  pages/         首页、详情、播放、本地播放、下载管理、历史、我的
  widgets/       弹幕层、海报卡、加载态等复用组件
  main.dart      入口，含启动期的后台恢复逻辑
android/         Android 工程（applicationId: com.zhuiju.app）
windows/         Windows 工程（可执行文件名: zhuiju.exe）
docs/images/     README 用的横幅与图标素材
screenshots/     README 用的真机界面截图
tools/           图标生成、图标铺图、ADB 操作等脚本
```

## 构建

### Android

```bash
flutter pub get
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

### Windows

正常情况：

```bash
flutter build windows --release
```

如果报 `Unable to find suitable Visual Studio toolchain`，先排查环境变量。MSBuild 的字典不区分大小写，环境里同时存在 `HTTPS_PROXY` 和 `https_proxy` 时会抛
`System.ArgumentException: 已添加项`，导致 `cl.exe` 根本没被执行，CMake 便认为找不到编译器。

清掉重复的那一组，再直接用 CMake 构建（`flutter build windows` 走的是同一套 CMake，只是多了个 VS 探测前置）：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

cmake -G "Visual Studio 17 2022" -A x64 -S windows -B build/windows/x64
cmake --build build/windows/x64 --config Release
cmake --install build/windows/x64 --config Release
```

产物：`build/windows/x64/runner/Release/`，内含 `zhuiju.exe`、`flutter_windows.dll`、插件 dll 和 `data/` 目录。**打包时必须整个目录一起，只拷 exe 无法运行。**

## 环境要求

- Flutter 3.x（本项目在 3.47.9 上验证）
- Android：Android SDK + JDK 17
- Windows：Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载、Windows 10 SDK

## 平台差异

桌面端和移动端的差异集中在 `lib/core/platform.dart` 里，业务代码不写 `if (Platform.isWindows)`：

- `isDesktop` / `isMobile`：判断平台大类
- `setFullscreen(bool)` / `restorePortrait()`：移动端切横屏沉浸式，桌面端是显式 no-op（桌面没有横竖屏概念）

播放后端通过 `video_player` 的接口统一。`video_player_win` 用 `implements: video_player` 提供 Windows 实现，所以播放页的代码两个平台完全一致。

## 图标

图标由脚本生成，不要手工改 png：

```bash
python tools/make_icon.py      # 生成 1024px 主图标、圆形、自适应前景/背景
python tools/install_icons.py  # 铺到 Android 各密度、自适应双层、Windows ICO
```

## 调试

`tools/ui.sh` 封装了常用的 ADB 操作（按文本找控件、点击、截图），调试定位问题时用：

```bash
./tools/ui.sh desc          # 打印当前界面的语义树
./tools/ui.sh shot out.png  # 截图
```

注意：播放中 `uiautomator dump` 可能报 `could not get idle state`（视频持续刷新），先暂停再 dump；全屏沉浸式下 Flutter 语义树为空，只能靠坐标和截图判断。