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

### Windows 播放内核（FFmpeg）

Windows 端的解码器是 libmpv 内嵌的 FFmpeg。它的版本**不由 `pubspec.yaml` 的版本号决定**，而是由
`media_kit_libs_windows_video` 的 `windows/CMakeLists.txt` 里硬编码的 libmpv 归档地址决定：

```cmake
set(LIBMPV "mpv-dev-x86_64-20261111-git-bcde6b93cc.7z")
```

该包已被 vendor 到 `packages/media_kit_libs_windows_video/`，通过 `pubspec.yaml` 的
`dependency_overrides` 指过去。**不要改回 pub 上的版本**：上游 `media-kit/libmpv-win32-video-build`
的 release 只到 2023-09-24（FFmpeg n6.0），而 pub 上这个包最新就是 1.0.11 —— 把版本号改高不会有任何变化，
因为根本没有更高的版本。

当前版本：FFmpeg `N-128766` / mpv `v0.42.0-38`。升级方式是把 CMakeLists 里的 `LIBMPV`、`LIBMPV_URL`、
`LIBMPV_MD5` 三行换成新构建（取自 [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake)），
然后**删掉 `build/windows/x64/libmpv/` 再重新 configure**。不删这个目录，CMake 的
`check_directory_exists_and_not_empty` 会认为已经解压过而跳过，构建会静默沿用旧 DLL —— 版本号看着变了，实际没变。

代价提醒：当前用的是全功能构建，`libmpv-2.dll` 有 116 MB（旧版 28 MB），发布包约 +33 MB。
想压体积需要自己交叉编译裁掉未用的编解码器。

核对当前实际版本（不要靠文件时间戳，media_kit 的分发包时间戳只反映打包时刻）：

```bash
dart run tool/probe_libmpv_version.dart build/windows/x64/runner/Release/libmpv-2.dll
```

### Windows 硬解

`hwdec` 默认值是 `auto`（来自 `media_kit_video` 的 `NativeVideoController`：
`configuration.hwdec ?? 'auto'`，而 `video_player_media_kit` 内部是无参构造）。

**不要显式改成 `d3d11va`。** 实测写死 `d3d11va` 反而退回软解（`hwdec-current = no`），
交给 `auto` 协商才落到 `d3d11va-copy`。H.264 与 HEVC 都验证过。

验证硬解是否真的生效，要读**运行时**属性（起播前读一律为空）：

```bash
dart run tool/probe_hwdec_runtime.dart C:/path/to/video.mp4
```

`MPV_HOME` + `mpv.conf` 这条路不通（libmpv 默认 `config=no`，压根不加载配置文件），别再试。

## 环境要求

- Flutter 3.x（本项目在 3.47.9 上验证）
- Android：Android SDK + JDK 17
- Windows：Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载、Windows 10 SDK

若 `flutter build windows` 报 `Building with plugins requires symlink support`：Flutter 建插件目录链接
需要符号链接特权，未开开发者模式时会失败（errno 1314）。可以用**目录联接（junction）**绕过，
它不需要特权，且 Dart 会把 junction 正确识别为 `FileSystemEntityType.link`，Flutter 的复用分支能命中：

```powershell
New-Item -Path "windows\flutter\ephemeral\.plugin_symlinks\<插件名>" -ItemType Junction -Target "<插件真实路径>"
```

## 平台差异

桌面端和移动端的差异集中在 `lib/core/platform.dart` 里，业务代码不写 `if (Platform.isWindows)`：

- `isDesktop` / `isMobile`：判断平台大类
- `setFullscreen(bool)` / `restorePortrait()`：移动端切横屏沉浸式，桌面端是显式 no-op（桌面没有横竖屏概念）

播放后端通过 `video_player` 的接口统一。Windows 端由 `video_player_media_kit` 提供实现（底层
media_kit + libmpv + FFmpeg），Android 端是 ExoPlayer，所以播放页的代码两个平台完全一致。

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