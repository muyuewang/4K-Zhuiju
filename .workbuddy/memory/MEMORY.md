# 项目长期记忆 —— 4K追剧（vivos7）

仓库根：`C:\Users\fengxin\WorkBuddy\vivos7`，Flutter 工程在 `code/flutter_app`，
GitHub 仓库 `muyuewang/4K-Zhuiju`。

## 索引导航

| 文档 | 内容 |
| --- | --- |
| `.workbuddy/memory/PACKAGING.md` | **打包与发版步骤（APK + Windows）**，含全部踩坑与失败速查表 |
| `.workbuddy/memory/YYYY-MM-DD.md` | 每日工作日志（append-only） |

## 硬性结论（容易重复踩的）

### 构建

- **Windows 一律不用 `flutter build windows`**。本机安全策略把 `reg.exe` 列入程序黑名单，
  `flutter doctor` 的 VS 检测直接崩溃，构建必失败。改用 CMake 三步法，详见 `PACKAGING.md`。
- CMake 三步法的前提是 `code/flutter_app/build/windows/x64/CMakeCache.txt` 存在。
  `build/` 被删除后此路不通，只能先放行 `reg.exe` 重建缓存。
- 构建前必须清掉重复的大小写代理变量（`HTTPS_PROXY` + `https_proxy` 同时存在会让
  MSBuild 抛 `ArgumentException`）。用 `env -u` 包裹命令。
- `data/app.so` 不能依赖 `flutter_assemble` 目标 —— 它会被误判「已是最新」跳过，
  必须直调 `flutter_tools/bin/tool_backend.dart`。
- 安装产物不用 `cmake --install`（不解析生成器表达式而报错），手工 `cp`。

### 发版

- `make_release.py` 会**先删同 tag 的旧 Release 再新建**。只补单个资产用
  `code/tools/upload_asset.py`，只改正文用 `PATCH /releases/{id}`。
- 版本号一律从 `pubspec.yaml` 读，脚本里不硬编码。

### 项目结构要点

- **插件配置不在 APK/zip 里**。`config/plugins/*.js` 与 `index.json` 由
  `plugin_loader.dart` 从 GitHub raw 镜像联网拉取（`kPluginConfigDir = 'config/plugins'`），
  缓存到 SharedPreferences。所以 `flutter_assets` 里没有 `kanju.js` 是正常的。
- 直播频道清单 `assets/live_channels.json` 是**打进去**的（`pubspec.yaml` 的 `assets:`
  唯一声明项），由 `code/tools/probe_live.py` 全量探活后生成。
- `Registry` 不内置任何源，所有源都来自 `config/plugins/*.js`。

### 插件网络层

- **挑战式验证**（首访 403 + `Set-Cookie`，带 cookie 重发才 200）已支持：清单开
  `"cookieJar": true`，宿主自动吸收并重发一次，**默认关闭**。必须「先吸收再看状态码」
  —— 挑战 cookie 恰恰在 403 那次下发，顺序反了永远拿不到。
- 该开关只能做**清单级**（整源共用一套会话），不能按请求开：cookie 是上一次请求
  下发的，两次请求不同步就跟不上。
- 这不违反「脚本不许碰 Cookie」：脚本注入凭证 ≠ 宿主回送服务端下发的会话值。
  `Host`/`Cookie`/`Authorization` 三层拦截照旧。
- **加源必须同步改** `test/plugin_index_validation_test.dart` 里的源总数断言。

### 验证新代码是否真进包

- Dart AOT 会裁掉未被 `is` 检查引用的标识符，**不能靠 grep 字段名判断**。
  要搜字符串字面量，或直接搜类名（如 `plugin_cookie_jar`）。
- **产物体积相同不代表没更新**：v1.11.15 与 v1.11.16 的 APK 字节数完全相同
  （AOT 段对齐所致），但 md5 与关键标识均不同。必须比 md5 / 搜标识，不能看体积。
- 插件脚本里的中文文案（如「加密专线」）在二进制里**搜不到是正常的** ——
  `config/plugins/*.js` 运行时联网拉取，不编译进包。

### 看剧源（kanju）

- 取址是**两阶段**：`resolve/{episodeToken}` 出 33 条 `line_options`，官方线
  （10 条）的 `url` 是 `resolve://<票据>`，需再 POST `resolve-line` 换真实地址。
  别按 `http` 前缀过滤线路 —— 官方线可播率 100%，普通线只有 39%。

## 环境速查

| 项 | 值 |
| --- | --- |
| Flutter SDK | `C:\flutter_sdk` |
| CMake | `C:\Program Files\CMake\bin\cmake.exe`（不在 PATH） |
| VS 2022 | `C:\Program Files\Microsoft Visual Studio\2022\Community`，生成器 `Visual Studio 17 2022` / x64 |
| 雷电模拟器 adb | `D:\leidian\LDPlayer9\adb.exe`，目标 `127.0.0.1:5555` |
| adb 常见坑 | Git Bash 会把 `/data/local/tmp` 转成 Windows 路径 → `export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` |