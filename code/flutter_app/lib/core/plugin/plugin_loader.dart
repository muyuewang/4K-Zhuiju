/// 插件配置的远程加载通道。
///
/// ## 它解决什么问题
///
/// 采集站换域名、换接口路径、改分类 id 是**每周都在发生**的事。以前每遇到
/// 一次就得发一个版本，而用户手机上的旧包装的根本改不了，只能干等。
///
/// 这里把「源是怎么配置的」从代码里挪到仓库的 JSON 里，App 启动时拉一次。
/// 之后源失效，只要改仓库里的 JSON，用户下次启动就自动好了。
///
/// ## 为什么必须走国内镜像
///
/// 配置和脚本都托管在 GitHub。实测（2026-11-17，本机直连）：
///
///   | 地址 | 结果 |
///   | --- | --- |
///   | `raw.githubusercontent.com` | **HTTP 000**（连不上） |
///   | `cdn.jsdelivr.net` | **HTTP 000**（连不上） |
///   | `raw.gitmirror.com` | **HTTP 000**（连不上） |
///   | `ghproxy.net` | 200，1.37s |
///   | `gh-proxy.com` | 200，1.05s |
///
/// 也就是说**三个原始/常见 CDN 地址在国内全部拉不到**。如果只写原始地址，
/// 绝大多数用户永远拿不到配置，这个功能等于没做。所以镜像不是优化项，
/// 是能否 work 的前提。
///
/// 镜像逐个尝试，第一个成功的记住——**脚本也从同一个镜像取**。
/// 这点很关键：如果 index 从 ghproxy 拿到了、脚本却去 raw 拿，
/// 那脚本必然 000，表现为「配置里有源，但一个个都坏」。
///
/// ## 为什么下载要「去重 + 并行」
///
/// 早期实现是**逐条源串行下载**，每个源单独发一次请求。两个问题叠在一起：
///
///   1. **重复下载**：19 个源里 `maccms-json.js` 被 **11 个源共用**，
///      实际只有 9 个不同文件。串行版把这 1 个文件拉了 11 遍。
///   2. **串行等待**：单个脚本约 1.1s（代理下 0.95s），19 个串起来 ≈ 21s，
///      用户点「刷新插件配置」要干等半分钟，看着像卡死。
///
/// 实测（2026-11-18，ghproxy 镜像、预热后）：串行 19 个 10~11s，
/// 并行 9 个唯一脚本 **1.2s**。所以现在按**唯一路径**去重，
/// 再用有界并发（[_maxConcurrent]）同时拉。
///
/// 代理不是瓶颈：`NetProxy` 的 `HttpOverrides` 覆盖所有 dart:io 请求，
/// 走代理后单请求 1.6s → 0.95s，只是把这 21s 变成 19s，救不了串行。
///
/// ## 缓存策略
///
/// 远端 → 本地缓存 → 空（不注册任何远程源）。
///
/// 本地缓存是必须的：镜像偶尔抖动、用户在地铁里没网，都不该让
/// 「本来能用的源」突然消失。缓存里存完整可用集（清单 + 脚本），
/// 所以离线时远程源照样能用。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_manifest.dart';

/// 仓库中配置目录的相对路径（相对仓库根，也相对镜像基址）。
const String kPluginConfigDir = 'config/plugins';

/// 一个已就绪的插件包：清单 + 脚本源码。
///
/// 两者绑在一起是因为「有清单没脚本」和「有脚本没清单」都无法工作，
/// 分开传递只会让调用方到处判空。
class LoadedPlugin {
  const LoadedPlugin({required this.manifest, required this.script});

  final PluginManifest manifest;
  final String script;

  String get id => manifest.id;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'manifest': manifest.toJson(),
        'script': script,
      };

  /// 从缓存恢复。结构不对返回 null（由调用方跳过这一条）。
  static LoadedPlugin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = PluginManifest.fromJson(raw['manifest']);
    final s = raw['script'];
    if (m == null || s is! String || s.isEmpty) return null;
    // 缓存里的内容也要过校验：缓存可能来自旧版本，字段含义可能已变
    if (m.validate() != null) return null;
    return LoadedPlugin(manifest: m, script: s);
  }
}

class PluginLoader {
  PluginLoader._();
  static final PluginLoader instance = PluginLoader._();

  static const String _prefKey = 'app.plugins.v1';

  /// 镜像基址，**末尾必须带斜杠**（后面直接拼相对路径）。
  ///
  /// 顺序 = 实测速度顺序。ghproxy 1.37s、gh-proxy 1.05s，两者都返回 200。
  /// 原始地址放最后：它在国内基本不通，但海外用户/开了代理的能直连，
  /// 留着不吃亏（前两个都失败才会走到它，不拖慢正常路径）。
  static const List<String> kMirrors = <String>[
    'https://ghproxy.net/https://raw.githubusercontent.com/'
        'muyuewang/4K-Zhuiju/main/',
    'https://gh-proxy.com/https://raw.githubusercontent.com/'
        'muyuewang/4K-Zhuiju/main/',
    'https://raw.githubusercontent.com/muyuewang/4K-Zhuiju/main/',
  ];

  /// 单次请求超时。配置是启动后台任务，慢点无所谓，但不能一直挂着。
  static const Duration _timeout = Duration(seconds: 10);

  /// 脚本单文件大小上限。正常脚本几 KB，超这个数说明配置写错了
  /// （比如把整个 HTML 存进去了），直接拒掉比下载完再崩强。
  static const int _maxScriptBytes = 512 * 1024;

  /// 脚本并发下载上限。
  ///
  /// 为什么不干脆 `Future.wait` 全开：唯一脚本目前是 9 个，全开没事；
  /// 但配置里的源以后可能涨到几十上百（同一脚本被多个源复用时不会增加
  /// 下载数，真正会涨的是「不同脚本」的数量）。同时开 100 条连接到
  /// 镜像站，容易被限流甚至 429，反而更慢。6 是在「够快」和「别惹恼
  /// 镜像」之间的折中：9 个唯一脚本只需两轮，实测 1.2s。
  static const int _maxConcurrent = 6;

  /// 当前可用的镜像基址（上一次成功的那个）。null 表示还没成功过。
  String? _activeMirror;
  String? get activeMirror => _activeMirror;

  /// 本次运行是否从远端刷新成功（设置页展示用）
  bool _refreshedFromRemote = false;
  bool get refreshedFromRemote => _refreshedFromRemote;

  /// 最后一次失败原因（供设置页/日志展示，不参与逻辑判断）
  String? lastError;

  /// 所有镜像都失败、当前用的是缓存
  bool _usedCache = false;
  bool get usedCache => _usedCache;

  final List<LoadedPlugin> _plugins = <LoadedPlugin>[];
  List<LoadedPlugin> get plugins => List.unmodifiable(_plugins);

  bool _restored = false;

  /// 复用一个 Dio 实例，而不是每次请求 new 一个。
  ///
  /// 每次 new 都会丢连接池：串行老实现里 19 次请求 = 19 次 TLS 握手
  /// （跨境镜像上单次握手 0.4~1.1s，占了大头）。复用之后除首个请求外
  /// 都走 keep-alive，省掉重复握手。
  Dio? _dio;

  Dio _client() => _dio ??= Dio(BaseOptions(
          connectTimeout: _timeout,
          receiveTimeout: _timeout,
          // 状态码自己判，避免 404 也抛异常、多一层 try
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
          headers: {
            // GitHub 系对无 UA 的请求会 403
            'User-Agent': '4KZhuiju/plugin-loader',
            'Accept': '*/*',
          },
        ));

  /// 读本地缓存并**立即可用**。启动时最先调。
  ///
  /// 只读 SharedPreferences，不发请求，所以很快。必须在首屏请求之前完成，
  /// 否则用户第一眼看到的还是「没有远程源」的列表。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;

      final mirror = map['mirror'];
      if (mirror is String && _isPlausibleMirror(mirror)) {
        _activeMirror = mirror;
      }

      final list = map['plugins'];
      if (list is! List) return;
      for (final one in list) {
        final p = LoadedPlugin.fromJson(one);
        if (p != null) _plugins.add(p);
      }
      if (_plugins.isNotEmpty) {
        _usedCache = true;
        debugPrint('[PLUGIN] restored ${_plugins.length} from cache');
      }
    } catch (e) {
      // 缓存损坏（升级残留、手改）直接丢弃，不要让 App 起不来
      debugPrint('[PLUGIN] restore failed: $e');
    }
  }

  /// 从远端拉一次配置 + 所有脚本。
  ///
  /// 调用方**不应该 await**（启动后后台跑）。失败不影响任何现有功能。
  /// 设置页手动刷新时才需要等它返回，以便给出「成功/失败」的反馈。
  /// 生成破缓存时间戳。提成纯函数是为了能在测试里验证两种粒度的区别。
  ///
  /// 自动刷新（force=false）：小时级，同一小时内多个请求共用，省流量。
  /// 手动刷新（force=true）：微秒级，每次都不同，CDN 必然回源拿最新。
  @visibleForTesting
  static String cacheBustStamp({required bool force, DateTime? now}) {
    final t = now ?? DateTime.now();
    return force
        ? t.microsecondsSinceEpoch.toString()
        : (t.millisecondsSinceEpoch ~/ 3600000).toString();
  }

  /// 从一批清单里取出去重后的脚本路径。
  ///
  /// 这是「快」的关键：19 个源里 `maccms-json.js` 被 **11 个源共用**，
  /// 实际只有 9 个不同文件。老实现逐条源下载，同一个文件拉了 11 遍，
  /// 白白多花 10 次 TLS 握手 + 10 次往返。
  ///
  /// 抽成静态纯函数是为了能在测试里锁住：以后谁把 `refresh` 改回
  /// 「逐条下载」，断言 `unique.length < 源数量` 会直接红。
  @visibleForTesting
  static Set<String> uniqueScriptPaths(List<PluginManifest> manifests) =>
      <String>{for (final m in manifests) m.script.trim()};

  /// [force]：手动点「刷新」时为 true，必须绕过 CDN 缓存拿到最新配置。
  ///
  /// 自动刷新（启动时）用小时级时间戳就够了，省流量；但手动刷新若也用
  /// 同一个小时戳，同一小时内再点就是同一个 URL，CDN 直接回缓存的旧
  /// index.json——表现是「提示已更新，源却没变」，用户完全没法自己修。
  /// 强制刷新改用微秒时间戳，每次 URL 都不同，CDN 必然回源。
  Future<bool> refresh({bool force = false}) async {
    lastError = null;

    final stamp = cacheBustStamp(force: force);
    final indexPath = '$kPluginConfigDir/index.json?t=$stamp';

    // 上一轮成功的镜像优先试（省掉一次注定失败的等待），然后是完整列表。
    final order = <String>[
      if (_activeMirror != null) _activeMirror!,
      ...kMirrors.where((m) => m != _activeMirror),
    ];

    for (final mirror in order) {
      final sw = Stopwatch()..start();
      try {
        final indexBody = await _get('$mirror$indexPath');
        if (indexBody == null) continue;

        final decoded = jsonDecode(indexBody);
        if (decoded is! Map) {
          lastError = 'index.json 不是对象';
          continue;
        }
        final rawList = decoded['plugins'];
        if (rawList is! List) {
          lastError = 'index.json 缺 plugins 数组';
          continue;
        }

        // 第一步：把清单全部解析完。**纯 CPU，不发任何请求**。
        //
        // 必须先解析完才知道「到底有几个不同的脚本文件」——这一步是
        // 去重的前提。老实现是「解析一条 → 立刻下一个脚本」，在劫持
        // 网络之前根本无从知道 11 个源共用同一个 maccms-json.js。
        //
        // 逐条解析而不是整份作废：某一条坏了只跳过它，不能连累其他源。
        // 整份作废的话，一次手误会让所有远程源全部消失。
        final manifests = <PluginManifest>[];
        final errors = <String>[];
        for (final raw in rawList) {
          final res = _parseOne(raw);
          if (res is PluginManifest) {
            manifests.add(res);
          } else if (res is String) {
            errors.add(res);
          }
        }

        // 第二步：按**唯一路径**去重后并发下载。
        // 19 个源 → 9 个不同脚本，省的 10 次请求是纯赚。
        final paths = uniqueScriptPaths(manifests);
        final batch = await _downloadAll(mirror, stamp, paths);

        // 第三步：把正文装配回各条源（同一脚本的多个源共用同一份正文）。
        final loaded = <LoadedPlugin>[];
        for (final m in manifests) {
          final path = m.script.trim();
          final body = batch.bodies[path];
          if (body != null) {
            loaded.add(LoadedPlugin(manifest: m, script: body));
          } else {
            errors.add('${m.id}: ${batch.errors[path] ?? '脚本下载失败（$path）'}');
          }
        }

        if (loaded.isEmpty && errors.isNotEmpty) {
          // 一条都没成功，多半是整份配置格式变了。此时**保留旧缓存**
          // 比清空好——旧源至少还能用，而新配置是坏的。
          lastError = '全部失败：${errors.take(2).join('; ')}';
          debugPrint('[PLUGIN] $mirror: $lastError');
          continue;
        }

        _activeMirror = mirror;
        _refreshedFromRemote = true;
        _usedCache = false;
        _plugins
          ..clear()
          ..addAll(loaded);
        if (errors.isNotEmpty) {
          lastError = '${errors.length} 条被跳过：${errors.first}';
          debugPrint('[PLUGIN] $lastError');
        }
        await _persist();
        debugPrint('[PLUGIN] loaded ${loaded.length} from $mirror '
            '(${paths.length} scripts, ${sw.elapsedMilliseconds}ms)');
        return true;
      } catch (e) {
        lastError = '$mirror: $e';
        debugPrint('[PLUGIN] $mirror failed: $e');
      }
    }
    // 全挂：保持缓存（或空），不报错给用户
    return false;
  }

  /// 解析单条清单。**不发请求**（脚本路径的合法性检查是纯字符串操作）。
  ///
  /// 返回 [PluginManifest]=该下载脚本，String=该条的错误原因，
  /// null=按配置跳过（未启用）。用三种类型区分，是为了让「跳过」和
  /// 「出错」在日志里不混在一起。
  Object? _parseOne(Object? raw) {
    final manifest = PluginManifest.fromJson(raw);
    if (manifest == null) {
      return '清单结构不完整（${raw is Map ? raw['id'] : '非对象'}）';
    }

    final err = manifest.validate();
    if (err != null) return err;

    if (!manifest.enabled) return null;

    final scriptPath = manifest.script.trim();

    // 脚本必须落在配置目录下。允许任意路径等于让远程配置能下载仓库里
    // 任何文件（含 .env、CI 配置），没有正当用途只有风险。
    if (!scriptPath.startsWith('$kPluginConfigDir/')) {
      return '${manifest.id}: script 必须位于 $kPluginConfigDir/ 下';
    }
    if (scriptPath.contains('..')) {
      return '${manifest.id}: script 不允许包含 ..';
    }

    return manifest;
  }

  /// 并发下载一批脚本，按路径去重。
  ///
  /// 有界并发（[_maxConcurrent]）而不是无条件全开：唯一脚本现在只有 9 个，
  /// 全开无所谓；但源数量以后可能涨，同时开几十条连接容易被镜像限流。
  ///
  /// 用「多个 worker 抢同一个队列」而不是切分成固定批次：某个脚本慢
  /// （跨境镜像偶发）时，空闲的 worker 会继续取下一个，不会被慢的那个拖住。
  Future<_ScriptBatch> _downloadAll(
    String mirror,
    String stamp,
    Set<String> paths,
  ) async {
    final batch = _ScriptBatch();
    if (paths.isEmpty) return batch;

    final queue = paths.toList();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        // 单 isolate，`next++` 之间没有 await，不存在竞态
        final i = next++;
        if (i >= queue.length) return;
        final path = queue[i];
        try {
          final body = await _get('$mirror$path?t=$stamp');
          if (body == null) {
            batch.errors[path] = '下载失败';
          } else if (body.length > _maxScriptBytes) {
            batch.errors[path] = '脚本过大（${body.length} 字节）';
          } else if (body.trim().isEmpty) {
            batch.errors[path] = '脚本为空';
          } else {
            batch.bodies[path] = body;
          }
        } catch (e) {
          batch.errors[path] = '$e';
        }
      }
    }

    final n = queue.length < _maxConcurrent ? queue.length : _maxConcurrent;
    await Future.wait(List<Future<void>>.generate(n, (_) => worker()));
    return batch;
  }

  Future<String?> _get(String url) async {
    final resp = await _client().get<String>(url);
    if (resp.statusCode != 200) {
      debugPrint('[PLUGIN] $url -> HTTP ${resp.statusCode}');
      return null;
    }
    final data = resp.data;
    if (data == null || data.isEmpty) return null;
    return data;
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _prefKey,
        jsonEncode(<String, dynamic>{
          'mirror': _activeMirror,
          'plugins': _plugins.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('[PLUGIN] persist failed: $e');
    }
  }

  static bool _isPlausibleMirror(String s) =>
      s.startsWith('https://') && s.endsWith('/');
}

/// 一批脚本的下载结果：成功的正文 + 失败原因，都按脚本路径索引。
///
/// 为什么按路径而不是按源 id 存：同一 `maccms-json.js` 被 11 个源共用，
/// 正文只该有一份。按源 id 存会让 19 条记录里 11 份内容完全相同，
/// 既费内存也会让「以后改成流式解析」变复杂。
class _ScriptBatch {
  final Map<String, String> bodies = <String, String>{};
  final Map<String, String> errors = <String, String>{};
}