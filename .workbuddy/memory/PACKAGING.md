# 打包步骤（Windows 与 APK）

> 最后实测：2026-11-18，v1.11.13 / build 38。
> 本文只记**可复现的命令**和**踩过的坑**，不写推测。
> 环境：Windows + Git Bash / CMake 在 `C:\Program Files\CMake\bin`、Flutter 在 `C:\flutter_sdk`。

仓库根：`C:\Users\fengxin\WorkBuddy\vivos7`，Flutter 工程在 `code/flutter_app`。

---

## 零、先决条件

| 依赖 | 路径 | 说明 |
| --- | --- | --- |
| Flutter SDK | `C:\flutter_sdk` | 只用它的 `flutter.bat`、`dart.exe`、`tool_backend.dart` |
| CMake | `C:\Program Files\CMake\bin\cmake.exe` | 不在 PATH 里，用全路径 |
| VS 2022 Community | `C:\Program Files\Microsoft Visual Studio\2022\Community` | 生成器 `Visual Studio 17 2022`，平台 `x64` |
| Python | 任意，能跑 `code/tools/*.py` | 打 zip、发 Release 用 |

**关键前提**：`code/flutter_app/build/windows/x64/CMakeCache.txt` 必须已存在。
这份缓存由**某次成功的** `flutter build windows` 生成过，之后就一直可用。
如果 `build/` 被整体删除，CMake 三步法就失效了 —— 那时只剩「让 `reg.exe` 能被调用」
这一条路（见第五节）。

---

## 一、APK 打包（正常路径，没坑）

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7/code/flutter_app
/c/flutter_sdk/bin/flutter.bat build apk --release
```

产物在 `build/app/outputs/flutter-apk/`：

| 文件 | 大小 | 用途 |
| --- | --- | --- |
| `app-release.apk` | ~60.7 MB | **通用包，发布用这个**（四种 ABI 合一） |
| `app-arm64-v8a-release.apk` | ~22 MB | 分架构（不发） |
| `app-armeabi-v7a-release.apk` | ~20 MB | 分架构（不发） |
| `app-x86_64-release.apk` | ~24 MB | 分架构（不发） |

`--split-per-abi` 会额外产出分架构包；不带该参数时 `app-release.apk` 就是全 ABI 通用包。
发布只取 `app-release.apk`，改名为 `4KZhuiju-v{版本}-release.apk`。

归档：

```bash
mkdir -p dist/v1.11.13
cp build/app/outputs/flutter-apk/app-release.apk \
   dist/v1.11.13/4KZhuiju-v1.11.13-release.apk
```

**校验**（必做，APK 名对不上版本号是最容易漏的一步）：

```bash
ls -l dist/v1.11.13/*.apk
md5sum dist/v1.11.13/*.apk
```

---

## 二、Windows 打包（**不能用 `flutter build windows`**）

### 2.1 为什么禁用 `flutter build windows`

Flutter 在构建前会跑 Visual Studio 检测，检测里调 `reg.exe` 查注册表：

```
[☠] Visual Studio - develop Windows apps (the doctor check crashed)
    X Flutter failed to run "reg query HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
PROGRAM BLOCKED BY SECURITY POLICY: reg.EXE
```

`reg.exe` 在本机被安全策略列入**程序黑名单**，进程直接起不来，检测崩 → 构建中止。
VS 2022 和 C++ 工具链本身是好的（`vswhere` 能查到 17.14.36811.4），**纯粹是检测这一步被拦**。

结论：不要浪费时间重试 `flutter build windows`，也不要指望 `flutter doctor` 修好。
直接走 CMake 三步法。

### 2.2 第一步：编 exe + 插件 dll

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7/code/flutter_app/build/windows/x64

env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY -u all_proxy \
  "/c/Program Files/CMake/bin/cmake.exe" --build . --config Release --target zhuiju
```

> **坑 1：必须 `env -u` 清掉重复的大小写代理变量。**
> 环境里同时有 `HTTPS_PROXY` 和 `https_proxy` 时，MSBuild 内部用**大小写敏感**的字典
> 存环境变量，注入 `CL.exe` 环境时直接抛：
> ```
> MSB6001: "CL.exe"的命令行开关无效
> System.ArgumentException: 已添加项。字典中的关键字:"HTTPS_PROXY"所添加的关键字:"https_proxy"
> ```
> 报错字面看着像编译选项写错了，实际跟编译一点关系没有。
> 注意：这一步**不需要**代理，清掉不影响后续联网步骤。

产物：`build/windows/x64/runner/Release/zhuiju.exe`（约 152 KB）+ 各 `*_plugin.dll`。

### 2.3 第二步：生成 AOT 的 `data/app.so`

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7/code/flutter_app

env -u https_proxy -u http_proxy \
  FLUTTER_ROOT="C:\\flutter_sdk" \
  PROJECT_DIR="C:\\Users\\fengxin\\WorkBuddy\\vivos7\\code\\flutter_app" \
  FLUTTER_EPHEMERAL_DIR="C:\\Users\\fengxin\\WorkBuddy\\vivos7\\code\\flutter_app\\windows\\flutter\\ephemeral" \
  FLUTTER_TARGET="lib\\main.dart" \
  TRACK_WIDGET_CREATION=true \
  TREE_SHAKE_ICONS=true \
  PACKAGE_CONFIG="C:\\Users\\fengxin\\WorkBuddy\\vivos7\\code\\flutter_app\\.dart_tool\\package_config.json" \
  "C:/flutter_sdk/bin/cache/dart-sdk/bin/dart.exe" \
  "C:/flutter_sdk/packages/flutter_tools/bin/tool_backend.dart" windows-x64 Release
```

产物：`build/windows/app.so`（约 8.5 MB）。

> **坑 2：`flutter_assemble` 会被 MSBuild 判定「已是最新」而跳过，`_phony_` 机制失效。**
> `windows/flutter/CMakeLists.txt` 里用一个名为 `_phony_` 的假输出 + `SYMBOLIC TRUE`
> 想强制每次都跑 `tool_backend`，但 MSBuild 后端不认这个把戏：
> 删掉 `_phony_` 文件、删掉 `app.so`、甚至显式 `--target flutter_assemble`，**都还是跳过**。
> 表现是 `zhuiju.exe` 时间戳更新了，`data/app.so` 还是上一次的旧文件 ——
> 这种包发出去，界面是新代码、逻辑是旧代码，极难排查。**必须直调后端脚本**。
>
> **坑 2b：`FLUTTER_TARGET` 等变量的路径要用双反斜杠。**
> Git Bash 会把裸 `/` 开头的串当路径转换。统一写 `C:\\...` 的 Windows 形式最稳。
> 也不要用 MSYS 反斜杠混写，会让 dart 端 `File` 找不到文件而报「目标不存在」。

**校验 `app.so` 是否真的更新了**（别只看命令退出码）：

```bash
ls -l build/windows/app.so
# 应该比 zhuiju.exe 的时间戳新，或至少是本次构建时间

# 确认新逻辑真的编进去了（以 v1.11.13 的官方线修复为例）
grep -c "resolveLine" build/windows/app.so
grep -c "resolveRequired" build/windows/app.so
grep -c "ticket" build/windows/app.so
```

### 2.4 第三步：手工安装（不用 `cmake --install`）

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7/code/flutter_app
REL="build/windows/x64/runner/Release"

cp -f build/windows/app.so "$REL/data/app.so"
rm -rf "$REL/data/flutter_assets"
cp -r build/flutter_assets "$REL/data/flutter_assets"
```

`data/flutter_assets` 正常约 11 个文件：

```
AssetManifest.bin
assets/live_channels.json
FontManifest.json
fonts/MaterialIcons-Regular.otf
NativeAssetsManifest.json
NOTICES.Z
packages/cupertino_icons/assets/CupertinoIcons.ttf
packages/flutter_js/assets/js/fetch.js
packages/media_kit/assets/web/hls1.4.10.js
shaders/ink_sparkle.frag
shaders/stretch_effect.frag
```

> **坑 3：`cmake --install . --config Release` 会失败，`cmake --build --target INSTALL` 也一样。**
> `windows/CMakeLists.txt` 第 159-167 行的 `install(CODE ...)` 里写了生成器表达式
> `${PROJECT_BUILD_DIR}...`，而 `--install` 模式（内部跑 `cmake -P cmake_install.cmake`）
> **不解析生成器表达式**，报：
> ```
> file COPY cannot copy file ".../native_assets.json" ... Invalid argument
> MSB3073: 命令 "setlocal ... cmake -P cmake_install.cmake" 退出，代码为 1
> ```
> 所以安装这一步只能手工 `cp`。`app.so` 和 `flutter_assets` 两个都要，缺一个就是白屏。

**这里有个容易误判的点**：`flutter_assets` 里**没有** `assets/plugins/kanju.js`
和 `config/plugins/index.json` —— 这是**正常的**，不是漏拷。
插件配置由 `lib/core/plugin/plugin_loader.dart` 从 GitHub raw 镜像（`kPluginConfigDir
= 'config/plugins'`）联网拉取并缓存到 SharedPreferences，`pubspec.yaml` 的 `assets:`
只声明了 `assets/live_channels.json`。

### 2.5 打 zip

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7
python code/tools/pack_windows.py
```

版本号自动从 `pubspec.yaml` 读，产物：`dist/v{版本}/4KZhuiju-v{版本}-windows-x64.zip`。

脚本会先校验三个必需文件（`zhuiju.exe`、`flutter_windows.dll`、`data/app.so`）齐全，
缺一个直接退出。用 Python `zipfile` 而不是 `Compress-Archive`，是为了让包内路径
用正斜杠且带顶层目录名 `4KZhuiju-v{版本}-windows-x64/`（解压后就是干净的文件夹）。

实测：37 个文件 / 65.80 MB。

**校验**：

```bash
python -c "
import zipfile
z=zipfile.ZipFile('dist/v1.11.13/4KZhuiju-v1.11.13-windows-x64.zip')
print('完整性:', 'OK' if z.testzip() is None else '损坏')
n=z.namelist(); print('条目数:', len(n))
for k in ('zhuiju.exe','data/app.so','data/flutter_assets/AssetManifest.bin'):
    print(('OK ' if [x for x in n if x.endswith(k)] else '缺失 ')+k)
"
```

---

## 三、写发布说明 + 发 Release

1. 写 `dist/v{版本}/RELEASE_NOTES.md`（正文直接成为 GitHub Release body）
2. 发 Release（**会先删同 tag 的旧 Release 再新建**）：

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7
python code/tools/make_release.py
```

`make_release.py` 要点：
- 版本号从 `pubspec.yaml` 的 `version: 1.11.13+38` 读，不硬编码
- 用 `curl` 而非 urllib（urllib 走代理 POST 会报 `SSL: UNEXPECTED_EOF_WHILE_READING`）
- 代理从 `HTTPS_PROXY`/`https_proxy`/`HTTP_PROXY`/`http_proxy` 依次取，不写死端口
- `ASSETS` 里两个文件：APK + Windows zip，不存在就跳过（打印「跳过（不存在）」）

### 只补传资产、不动 Release

**不要为了补一个 zip 去重跑 `make_release.py`** —— 它会把整个 Release（含下载计数、
发布时间）删掉重建。用：

```bash
python code/tools/upload_asset.py dist/v1.11.13/4KZhuiju-v1.11.13-windows-x64.zip
```

不带参数时默认补传当前版本的 Windows zip。同名资产会先删后传（GitHub 重复上传返回 422）。

### 只改 Release 正文

```bash
cd /c/Users/fengxin/WorkBuddy/vivos7 && python -c "
import sys, os; sys.path.insert(0,'code/tools')
import make_release as mr
body = open(os.path.join(mr.ROOT, mr.NOTES), encoding='utf-8').read()
st, rel = mr.api(f'/releases/tags/{mr.TAG}')
st, res = mr.api(f\"/releases/{rel['id']}\", method='PATCH', payload={'body': body})
print('PATCH', st, len(body), '字符')
"
```

---

## 四、完整发布清单（照着勾）

```
[ ] 1. 改 pubspec.yaml 版本号（version: X.Y.Z+N）
[ ] 2. flutter.bat build apk --release
[ ] 3. cp app-release.apk -> dist/vX.Y.Z/4KZhuiju-vX.Y.Z-release.apk
[ ] 4. Windows: cmake --build ... --target zhuiju         （坑1：env -u 清代理）
[ ] 5. Windows: 直调 tool_backend.dart -> app.so          （坑2：不能靠 flutter_assemble）
[ ] 6. Windows: 手工 cp app.so + flutter_assets           （坑3：不用 cmake --install）
[ ] 7. python code/tools/pack_windows.py
[ ] 8. 写 dist/vX.Y.Z/RELEASE_NOTES.md
[ ] 9. python code/tools/make_release.py
[ ] 10. 核对 Release 页两个资产都在、大小对得上
```

**发版前必查的 3 个时间戳**（漏任何一个都会发出「新旧混杂」的包）：

```bash
ls -l code/flutter_app/build/windows/x64/runner/Release/zhuiju.exe
ls -l code/flutter_app/build/windows/x64/runner/Release/data/app.so
ls -l dist/v1.11.13/*.zip
```

三者应该都是本次构建时间，且 `data/app.so` 不早于 `zhuiju.exe`。

---

## 五、如果 `build/` 被删了怎么办

CMake 三步法依赖已有的 `CMakeCache.txt`（里面记着生成器、VS 实例路径、各依赖库位置）。
一旦 `code/flutter_app/build/` 被整体删除，只能：

1. 让 `reg.exe` 能被调用（安全中心 → 命令安全 → 程序黑名单，把 `reg.EXE` 移出）
2. 跑一次 `flutter build windows --release` 重建缓存
3. 之后又可以回到 CMake 三步法

或者换台没装黑名单的机器构一次，把 `build/windows/` 目录整个带回来。

---

## 六、失败速查表

| 现象 | 真因 | 处理 |
| --- | --- | --- |
| `Unable to find suitable Visual Studio toolchain` / `doctor check crashed` | `reg.exe` 被黑名单 | 走 CMake 三步法，别修 Flutter |
| `MSB6001: CL.exe 命令行开关无效` + `ArgumentException 已添加项 HTTPS_PROXY/https_proxy` | 环境变量大小写重复 | `env -u` 清掉全部代理变量 |
| `zhuiju.exe` 更新了但 `app.so` 是旧的 | `flutter_assemble` 被误判最新 | 直调 `tool_backend.dart` |
| `file COPY cannot copy file ... Invalid argument` | `--install` 不解析生成器表达式 | 手工 `cp`，别用 `cmake --install` |
| 打出的 Windows 包白屏 | `data/flutter_assets` 缺文件或为空 | 重新 `cp -r build/flutter_assets` |
| `pack_windows.py` 报缺少必需文件 | 第三步没做 | 补 `cp app.so` |
| 上传资产 HTTP 422 | 同名资产已存在 | 用 `upload_asset.py`（会先删后传） |
| 上传资产 TLS 断流 / `CONNECT tunnel failed 502` | 代理端口不稳 | 换 `HTTPS_PROXY`（实测 7897 可用） |
| Release 资产里没有 zip | 打包在发版之后才做 | 用 `upload_asset.py` 补传 |