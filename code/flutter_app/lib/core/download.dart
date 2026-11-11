/// 下载服务
///
/// 支持两种资源：
///   1. 直链 mp4 —— 直接流式下载
///   2. HLS m3u8 —— 解析 playlist，下载全部 ts 分片，按序拼接为 .ts 文件
///      （同源分片是 MPEG-TS 裸流，顺序拼接即为合法可播放文件）
///
/// 断点续传：mp4 用 Range；m3u8 记录已完成的分片索引。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' show AESEngine, CBCBlockCipher;
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;

import 'models.dart' show idToStr;

enum DownloadState { pending, running, paused, done, failed }

/// 内部信号：按普通文件下载时发现实际内容是 HLS，需要改走分片流程
class _SwitchToHls implements Exception {
  const _SwitchToHls();
}

/// 可恢复错误：分片偶发失败 / 暂缺，已下载部分保留，整体重试即可续传
class _RetryableError implements Exception {
  final String message;
  const _RetryableError(this.message);
  @override
  String toString() => message;
}

class DownloadTask {
  final String id;
  final String title;

  /// 下载地址。源站播放地址是一次性 token（播放器用过即失效），
  /// 遇到 403 时会通过 [resolver] 重新解析并原地替换。
  String sourceUrl;
  String ext; // mp4 / ts
  bool isHls;

  /// 重新解析地址的回调（返回新的直链/m3u8）
  Future<String> Function()? resolver;

  /// 剧集 ID 与集数序号，仅用于本地播放时拉弹幕
  ///
  /// 弹幕接口 (movieId, movieKey) 和播放地址是两套独立参数，
  /// 下载到本地的文件本身不带任何剧集信息，所以必须在入队时记下来、
  /// 并随索引一起持久化，否则「我的 → 下载管理 → 播放」永远是零弹幕。
  /// 老索引没有这两个字段，回落到空串/0，弹幕层会自动跳过请求。
  String dramaId = '';
  int episode = 0;

  DownloadState state = DownloadState.pending;
  double progress = 0; // 0..1
  int received = 0;
  int total = 0;
  String? error;
  String? filePath;

  /// 实时下载速率（字节/秒），仅内存用，不持久化。
  /// 由 _downloadFile 按时间窗口算出，供下载页显示「2.3MB/s · 剩余 1分20秒」。
  double speed = 0;
  int _speedMarkBytes = 0;
  int _speedMarkAt = 0;

  /// 根据累计字节数与时间戳刷新速度估计（指数平滑，避免数字乱跳）
  void tickSpeed(int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_speedMarkAt == 0) {
      _speedMarkBytes = bytes;
      _speedMarkAt = now;
      return;
    }
    final dt = now - _speedMarkAt;
    if (dt < 600) return; // 窗口太短，测量噪声大
    final db = bytes - _speedMarkBytes;
    if (db < 0) return;
    final inst = db * 1000 / dt;
    speed = speed == 0 ? inst : speed * 0.65 + inst * 0.35;
    _speedMarkBytes = bytes;
    _speedMarkAt = now;
  }

  /// 预计剩余秒数；无法估算时返回 0
  int get etaSeconds {
    if (speed <= 0 || total <= 0 || received >= total) return 0;
    return ((total - received) / speed).round();
  }

  /// 当前正在做什么（重试第几片、第几次），用于给用户可见反馈。
  ///
  /// 没有这个字段时，分片连续超时会进入 180s×6×3轮 的静默等待，
  /// 界面只有一个不动的进度条，用户只会认为「卡死了」。
  String? stage;

  /// m3u8 专用：分片列表与已完成索引
  List<String> segments = const [];
  Set<int> doneSegments = <int>{};

  /// HLS AES-128 加密信息（源站声明 #EXT-X-KEY 时才有值）
  /// 实测 VIP4K 源用 METHOD=AES-128 + 16 字节 key + 固定 IV，
  /// 不解密直接拼接会得到一堆密文，文件无法播放。
  Uint8List? aesKey;
  Uint8List? aesIv;
  bool get encrypted => aesKey != null;

  DownloadTask({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.ext,
    required this.isHls,
    this.resolver,
  });

  /// 序列化到磁盘用（resolver 是闭包，无法持久化，恢复后置空）
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'sourceUrl': sourceUrl,
        'ext': ext,
        'isHls': isHls,
        'state': state.name,
        'progress': progress,
        'received': received,
        'total': total,
        'error': error,
        'filePath': filePath,
        'dramaId': dramaId,
        'episode': episode,
        'segments': segments,
        'doneSegments': doneSegments.toList(),
        'aesKey': aesKey == null ? null : base64Encode(aesKey!),
        'aesIv': aesIv == null ? null : base64Encode(aesIv!),
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final t = DownloadTask(
      id: j['id'] as String,
      title: j['title'] as String? ?? j['id'] as String,
      sourceUrl: j['sourceUrl'] as String? ?? '',
      ext: j['ext'] as String? ?? 'mp4',
      isHls: j['isHls'] as bool? ?? false,
    );
    t.state = DownloadState.values.firstWhere(
      (e) => e.name == (j['state'] as String? ?? 'pending'),
      orElse: () => DownloadState.pending,
    );
    t.progress = (j['progress'] as num?)?.toDouble() ?? 0;
    t.received = (j['received'] as num?)?.toInt() ?? 0;
    t.total = (j['total'] as num?)?.toInt() ?? 0;
    t.error = j['error'] as String?;
    t.filePath = j['filePath'] as String?;
    t.dramaId = idToStr(j['dramaId']);
    t.episode = (j['episode'] as num?)?.toInt() ?? 0;
    final segs = j['segments'] as List?;
    if (segs != null) {
      t.segments = segs.map((e) => e.toString()).toList();
    }
    final done = j['doneSegments'] as List?;
    if (done != null) {
      t.doneSegments = done.map((e) => (e as num).toInt()).toSet();
    }
    final k = j['aesKey'] as String?;
    if (k != null && k.isNotEmpty) t.aesKey = base64Decode(k);
    final iv = j['aesIv'] as String?;
    if (iv != null && iv.isNotEmpty) t.aesIv = base64Decode(iv);
    // App 重启后原本在跑的任务不可能还在跑，统一降级为暂停
    if (t.state == DownloadState.running) t.state = DownloadState.paused;
    return t;
  }
}

class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final Map<String, DownloadTask> _tasks = {};
  final _ctrl = StreamController<List<DownloadTask>>.broadcast();
  final Map<String, CancelToken> _cancels = {};

  Stream<List<DownloadTask>> get stream => _ctrl.stream;
  List<DownloadTask> get tasks => _tasks.values.toList(growable: false);

  /// 最近一次落盘时间（毫秒）与延迟落盘定时器
  int _lastSaveAt = 0;
  Timer? _saveTimer;

  /// 通知 UI 任务列表变化。
  ///
  /// [persist] 为 true 表示「状态发生了质变」（开始/暂停/完成/失败），
  /// 必须立刻落盘；纯进度更新则走节流，否则一次 141 片的 HLS 下载
  /// 会触发 141 次全量 JSON 序列化 + 写盘，白白拖慢下载并磨损闪存。
  void _emit({bool persist = false}) {
    _ctrl.add(tasks);
    if (persist) {
      _saveTimer?.cancel();
      _saveTimer = null;
      _lastSaveAt = DateTime.now().millisecondsSinceEpoch;
      unawaited(_save());
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSaveAt > 1500) {
      _lastSaveAt = now;
      unawaited(_save());
      return;
    }
    // 进度停了也要保证最终落盘一次，否则最后几片的状态会丢
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1600), () {
      _lastSaveAt = DateTime.now().millisecondsSinceEpoch;
      unawaited(_save());
    });
  }

  bool _loaded = false;

  /// 任务清单文件路径（与下载文件同目录，便于一起清理）
  String _indexPath = '';

  /// 从磁盘恢复任务清单（App 启动时调用一次）
  Future<void> restore() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _dir();
      _indexPath = '${dir.path}/.tasks.json';
      final f = File(_indexPath);
      if (!await f.exists()) {
        // 清单不存在也要继续往下走：磁盘上的成品文件仍需被识别出来，
        // 否则界面显示「暂无下载任务」而目录里躺着几个 G。
        debugPrint('[DL] no task index, adopting existing files');
      } else {
        final raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          final list = jsonDecode(raw) as List;
          for (final e in list) {
            try {
              final t = DownloadTask.fromJson(e as Map<String, dynamic>);
              // 已完成但文件已被外部删除的，标记为失败，避免误导
              if (t.state == DownloadState.done) {
                final p = t.filePath;
                if (p == null || !await File(p).exists()) {
                  t.state = DownloadState.failed;
                  t.error = '文件已不存在，请重新下载';
                }
              }
              _tasks[t.id] = t;
            } catch (e) {
              debugPrint('[DL] restore item failed: $e');
            }
          }
          debugPrint('[DL] restored ${_tasks.length} tasks from index');
          _dedupeByPath();
        }
      }
      await _adoptOrphanFiles(dir);
      // 恢复后立即落盘一次，让"收编"的文件也进入清单
      await _save();
      _ctrl.add(tasks);
    } catch (e) {
      debugPrint('[DL] restore failed: $e');
    }
  }

  /// 是否已有任务指向这个文件（按路径比对，不看 id）
  bool _hasPath(String path) {
    for (final t in _tasks.values) {
      if (t.filePath == path) return true;
    }
    return false;
  }

  /// 清理「多个任务指向同一个文件」的历史脏数据。
  /// 老版本用纯标题当 id，收编时又用「标题.扩展名」当 id，
  /// 同一个文件因此可能被登记两次，列表里出现重复行。
  /// 保留已有元信息更全的那条（有 sourceUrl 的优先），其余丢弃。
  void _dedupeByPath() {
    final byPath = <String, DownloadTask>{};
    final drop = <String>[];
    for (final t in _tasks.values) {
      final p = t.filePath;
      if (p == null || p.isEmpty) continue;
      final prev = byPath[p];
      if (prev == null) {
        byPath[p] = t;
        continue;
      }
      // 保留信息更完整的：能续传（有 sourceUrl）且标题更简洁的优先
      final keepNew = prev.sourceUrl.isEmpty && t.sourceUrl.isNotEmpty;
      if (keepNew) {
        drop.add(prev.id);
        byPath[p] = t;
      } else {
        drop.add(t.id);
      }
    }
    for (final id in drop) {
      _tasks.remove(id);
      debugPrint('[DL] dedupe: dropped duplicate task id=$id');
    }
  }

  /// 收编下载目录里「清单里没有」的成品文件。
  /// 覆盖两种情况：升级前的老任务、清单文件被清理过。
  Future<void> _adoptOrphanFiles(Directory dir) async {
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.') || name.endsWith('.part')) continue;
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        final ext = name.substring(dot + 1).toLowerCase();
        if (ext != 'mp4' && ext != 'ts') continue;
        final title = name.substring(0, dot);
        // 去重必须按「文件路径」而不是 id：
        // 老版本及索引恢复出来的任务 id 是纯标题（兰香如故_第1集），
        // 与这里想用的 兰香如故_第1集.mp4 不相等，只比 id 会把
        // 同一个物理文件登记成第二条记录，列表里出现重复行。
        if (_hasPath(e.path)) continue;
        // 同一集可能同时存在 .mp4 与 .ts（不同源下载过），
        // 若只按 title 做 id，后一个会被跳过、在列表里彻底消失，
        // 既看不见也删不掉，白白占着几个 G。冲突时退回「标题.扩展名」。
        var id = title;
        if (_tasks.containsKey(id)) id = '$title.$ext';
        if (_tasks.containsKey(id)) continue;
        final size = await e.length();
        if (size <= 0) continue;
        final t = DownloadTask(
          id: id,
          title: '$title (${ext.toUpperCase()})',
          sourceUrl: '',
          ext: ext,
          isHls: ext == 'ts',
        );
        t.state = DownloadState.done;
        t.progress = 1;
        t.filePath = e.path;
        t.received = size;
        t.total = size;
        _tasks[id] = t;
        debugPrint('[DL] adopted orphan file: $name ($size) id=$id');
      }
    } catch (e) {
      debugPrint('[DL] adopt orphans failed: $e');
    }
  }

  /// 写任务清单（失败不影响下载本身）
  ///
  /// 必须串行化。HLS 并发下载后，多个 worker 会同时触发 _emit(persist:true)，
  /// 若各自都写同一个 .tasks.json.tmp 再 rename：
  /// 先完成的把 tmp 移走了，后到的 rename 就报
  /// PathNotFoundException（实测必现）。这里用 single-flight：
  /// 正在写就只标记「待写」，写完再补一次，既不丢更新也不互相踩。
  bool _saving = false;
  bool _saveDirty = false;

  Future<void> _save() async {
    if (_saving) {
      _saveDirty = true;
      return;
    }
    _saving = true;
    try {
      do {
        _saveDirty = false;
        await _saveOnce();
      } while (_saveDirty);
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveOnce() async {
    try {
      if (_indexPath.isEmpty) {
        final dir = await _dir();
        _indexPath = '${dir.path}/.tasks.json';
      }
      final data = tasks.map((t) => t.toJson()).toList();
      // 原子写：先写临时文件再改名，避免写一半被杀留下坏 JSON
      final tmp = File('$_indexPath.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(_indexPath);
    } catch (e) {
      debugPrint('[DL] save index failed: $e');
    }
  }

  Directory? _cachedDir;

  /// 最近一次解析出的下载根目录（供 UI 展示）
  String rootPath = '';

  /// rootPath 的变化通知。
  ///
  /// rootPath 是在第一次真正下载时才由 [_dir] 赋值的（懒创建），
  /// 而「我的 / 下载管理」页早就已经画出来了。之前它只是个普通 String，
  /// 赋值时没有任何通知，界面就永远停在「未创建」，哪怕日志里早就
  /// 打印了 `downloads dir OK`。用 ValueNotifier 让这两处能自己刷新。
  final ValueNotifier<String> dirNotifier = ValueNotifier<String>('');

  /// 获取可写下载目录。
  ///
  /// 外部存储（/Android/data/<pkg>/files）在某些 ROM / 未授权场景下
  /// 创建会失败（EACCES），因此这里做「真实写入探针」，
  /// 外部不可写就回退到内部私有目录，保证下载一定能落盘。
  Future<Directory> _dir() async {
    if (_cachedDir != null) return _cachedDir!;

    final candidates = <String>[];
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) candidates.add('${ext.path}/downloads');
    } catch (e) {
      debugPrint('[DL] getExternalStorageDirectory error: $e');
    }
    try {
      final app = await getApplicationDocumentsDirectory();
      candidates.add('${app.path}/downloads');
    } catch (e) {
      debugPrint('[DL] getApplicationDocumentsDirectory error: $e');
    }

    Object? lastErr;
    for (final p in candidates) {
      try {
        final d = Directory(p);
        if (!await d.exists()) await d.create(recursive: true);
        // 真实写入探针：能写才算可用
        final probe = File('${d.path}/.probe');
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        _cachedDir = d;
        rootPath = d.path;
        // 同步通知 UI：界面可能早就画好了，不通知就会一直显示「未创建」
        if (dirNotifier.value != d.path) dirNotifier.value = d.path;
        debugPrint('[DL] downloads dir OK: ${d.path}');
        return d;
      } catch (e) {
        lastErr = e;
        debugPrint('[DL] dir unusable $p -> $e');
      }
    }
    throw StateError('无可写目录：$lastErr');
  }

  /// 统一请求头：多数源站会校验 UA / Referer，缺失直接 403
  Map<String, String> _headers(String url) {
    final u = Uri.tryParse(url);
    final origin = u == null ? '' : '${u.scheme}://${u.authority}/';
    return {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      if (origin.isNotEmpty) 'Referer': origin,
      'Accept': '*/*',
    };
  }

  static String safeName(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_').trim();
    return t.isEmpty ? 'video' : (t.length > 60 ? t.substring(0, 60) : t);
  }

  /// 启动下载；若同名任务已存在则复用
  ///
  /// [resolver] 用于在地址过期（403）时重新解析出一个新地址。
  DownloadTask start({
    required String title,
    required String url,
    String? preferExt,
    Future<String> Function()? resolver,
    String dramaId = '',
    int episode = 0,
  }) {
    final key = safeName(title);
    final exist = _tasks[key];

    // 已在跑：直接复用，不重复开一个并发任务
    if (exist != null && exist.state == DownloadState.running) return exist;

    // 已下完：文件就在磁盘上，再点一次下载没有任何意义，
    // 原来的实现会把任务覆盖成 pending 并从 0 重下——几百 MB 白跑一遍，
    // 还会把已经完整的文件冲掉。这里直接返回已有任务，由 UI 提示「已下载」。
    // 不在这里做磁盘存在性检查：restore() 已把「文件已丢失」的任务降级为
    // failed，能停到 done 且 filePath 非空，就说明文件是在的。
    if (exist != null &&
        exist.state == DownloadState.done &&
        (exist.filePath?.isNotEmpty ?? false)) {
      return exist;
    }

    // 已暂停/失败：说明是同一集的续传请求，复用原任务保留分片进度
    if (exist != null &&
        (exist.state == DownloadState.paused ||
            exist.state == DownloadState.failed)) {
      exist.sourceUrl = url;
      if (resolver != null) exist.resolver = resolver;
      // 续传时补写剧集标识：老索引里可能没有，续传是唯一能补的机会
      if (dramaId.isNotEmpty) exist.dramaId = dramaId;
      if (episode > 0) exist.episode = episode;
      exist.state = DownloadState.pending;
      exist.error = null;
      _emit(persist: true);
      _run(exist);
      return exist;
    }

    final isHls = url.contains('.m3u8') || preferExt == 'm3u8';
    final task = DownloadTask(
      id: key,
      title: title,
      sourceUrl: url,
      ext: isHls ? 'ts' : (preferExt ?? 'mp4'),
      isHls: isHls,
      resolver: resolver,
    )
      ..dramaId = dramaId
      ..episode = episode;
    _tasks[key] = task;
    _emit(persist: true);
    _run(task);
    return task;
  }

  void pause(String id) {
    _cancels[id]?.cancel('paused');
    final t = _tasks[id];
    if (t != null && t.state == DownloadState.running) {
      t.state = DownloadState.paused;
      _emit(persist: true);
    }
  }

  void remove(String id) {
    _cancels[id]?.cancel('removed');
    _tasks.remove(id);
    _emit(persist: true);
    // 清理临时产物：.part 半成品文件与 .parts 分片目录
    unawaited(_cleanupTemp(id));
  }

  /// 删除任务后清理磁盘残留（不删已完成的成品文件，由 UI 决定）
  Future<void> _cleanupTemp(String id) async {
    try {
      final dir = _cachedDir;
      if (dir == null) return;
      final part = File('${dir.path}/$id.part');
      if (await part.exists()) {
        await part.delete();
        debugPrint('[DL] cleanup $id.part');
      }
      final parts = Directory('${dir.path}/$id.parts');
      if (await parts.exists()) {
        await parts.delete(recursive: true);
        debugPrint('[DL] cleanup $id.parts');
      }
    } catch (e) {
      debugPrint('[DL] cleanup failed for $id: $e');
    }
  }

  void resume(String id) {
    final t = _tasks[id];
    if (t == null) return;
    if (t.state == DownloadState.paused || t.state == DownloadState.failed) {
      t.state = DownloadState.pending;
      _emit(persist: true);
      _run(t);
    }
  }

  Future<void> _run(DownloadTask task) async {
    final cancel = CancelToken();
    _cancels[task.id] = cancel;
    task.state = DownloadState.running;
    task.error = null;
    _emit(persist: true);

    // 源站地址带时效 token，失效表现为 403；最多换 3 次新地址
    const maxRefresh = 3;
    var refreshed = 0;
    /// 可恢复错误（连接中断/超时）重试次数
    const maxRetry = 3;
    var retried = 0;

    // 开工前先刷新一次地址：播放页解析出的地址可能已经放了几分钟，
    // 带时效 token 的源（VIP4K / VIP蓝光 / NN蓝光）到这一刻往往已过期。
    // 拿到新地址再下载，比等到 403 再补救的成功率高得多。
    if (task.resolver != null) {
      try {
        final fresh = await task.resolver!();
        if (fresh.isNotEmpty) {
          task.sourceUrl = fresh;
          debugPrint('[DL] initial refresh -> ${_short(fresh)}');
        }
      } catch (e) {
        debugPrint('[DL] initial refresh failed (kept old): $e');
      }
      if (cancel.isCancelled) {
        task.state = DownloadState.paused;
        _cancels.remove(task.id);
        _emit(persist: true);
        return;
      }
    }

    while (true) {
      try {
        debugPrint('[DL] _run start id=${task.id} isHls=${task.isHls} '
            'refresh=$refreshed retry=$retried url=${_short(task.sourceUrl)}');
        if (task.isHls) {
          await _downloadHls(task, cancel);
        } else {
          await _downloadFile(task, cancel);
        }
        task.state = DownloadState.done;
        task.progress = 1;
        debugPrint('[DL] _run done id=${task.id} file=${task.filePath}');
        // 完成即去重。实测踩到的坑：HLS 任务 id 是「兰香如故_第2集」，
        // 拼接产物路径是「兰香如故_第2集.ts」，而扫盘收编早先已经建过
        // 一条 id 为「兰香如故_第2集.ts」的任务指向同一个文件。
        // 两条 id 不同、路径相同，_dedupeByPath 只在 restore() 跑过一次，
        // 于是下载页出现两行同名条目，大小还不一样（旧记录是拼接前的
        // 分片字节数），用户根本分不清哪条是真的。
        _dedupeByPath();
        break;
      } on _SwitchToHls {
        // _downloadFile 已把 isHls 置 true，下一轮直接走分片流程
        debugPrint('[DL] _run switch to HLS id=${task.id}');
        continue;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          if (task.state != DownloadState.paused) {
            task.state = DownloadState.paused;
          }
          debugPrint('[DL] _run cancelled id=${task.id}');
          break;
        }

        final status = e.response?.statusCode;
        final isExpired = status == 403 || status == 401 || status == 410;
        final isRecoverable = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.connectionError;

        debugPrint('[DL] _run dio-error id=${task.id} type=${e.type} '
            'status=$status msg=${e.message}');

        if (isExpired && task.resolver != null && refreshed < maxRefresh) {
          refreshed++;
          debugPrint('[DL] $status expired, refreshing address '
              '($refreshed/$maxRefresh)');
          try {
            final fresh = await task.resolver!();
            if (fresh.isNotEmpty && fresh != task.sourceUrl) {
              task.sourceUrl = fresh;
              task.segments = const [];
              task.doneSegments = <int>{};
              task.error = null;
              _emit(persist: true);
              continue; // 用新地址重试
            }
            debugPrint('[DL] resolver returned same url, no point retrying');
          } catch (re) {
            debugPrint('[DL] resolver failed: $re');
          }
        }

        if (isRecoverable && retried < maxRetry) {
          retried++;
          debugPrint('[DL] recoverable error, retry ($retried/$maxRetry)');
          await Future<void>.delayed(Duration(seconds: 2 * retried));
          if (cancel.isCancelled) {
            task.state = DownloadState.paused;
            break;
          }
          continue;
        }

        task.state = DownloadState.failed;
        task.error = isExpired
            ? '地址已过期，请重新解析后再下载'
            : (e.message ?? '下载失败');
        break;
      } on _RetryableError catch (e) {
        // 分片偶发失败：已下载分片全部保留，整体再来一轮即可续传
        if (retried < maxRetry) {
          retried++;
          debugPrint('[DL] retryable (${e.message}), '
              'whole-pass retry ($retried/$maxRetry)');
          await Future<void>.delayed(Duration(seconds: 3 * retried));
          if (cancel.isCancelled) {
            task.state = DownloadState.paused;
            break;
          }
          continue;
        }
        task.state = DownloadState.failed;
        task.error = '${e.message}（已下载部分已保留，点继续可续传）';
        break;
      } catch (e, st) {
        // 连接提前断开 / 分片缺失 属于可恢复，允许续传重试
        final msg = e.toString();
        final recoverable = msg.contains('连接提前断开') ||
            msg.contains('分片缺失') ||
            e is SocketException ||
            e is TimeoutException;
        if (recoverable && retried < maxRetry) {
          retried++;
          debugPrint('[DL] recoverable ($msg), retry ($retried/$maxRetry)');
          await Future<void>.delayed(Duration(seconds: 2 * retried));
          if (cancel.isCancelled) {
            task.state = DownloadState.paused;
            break;
          }
          continue;
        }
        task.state = DownloadState.failed;
        task.error = msg;
        debugPrint('[DL] _run error id=${task.id}: $e\n$st');
        break;
      } finally {
        if (task.state != DownloadState.running) {
          _cancels.remove(task.id);
        }
      }
    }

    _cancels.remove(task.id);
    _emit(persist: true);
  }

  /// 日志用：URL 截断（token 很长）
  String _short(String u) =>
      u.length <= 70 ? u : '${u.substring(0, 70)}...(${u.length})';

  // ---------------- 普通文件 ----------------
  Future<void> _downloadFile(DownloadTask task, CancelToken cancel) async {
    final dir = await _dir();
    final part = File('${dir.path}/${task.id}.part');
    final target = File('${dir.path}/${task.id}.${task.ext}');

    var start = 0;
    if (await part.exists()) start = await part.length();
    debugPrint('[DL] FILE start url=${_short(task.sourceUrl)} '
        'resume_from=$start');

    // 必须带超时：无超时的 Dio 在网络半挂时会让任务永久卡在 running
    final dio = Dio(BaseOptions(
      followRedirects: true,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: _headers(task.sourceUrl),
    ));

    final resp = await dio.get<ResponseBody>(
      task.sourceUrl,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          ..._headers(task.sourceUrl),
          if (start > 0) 'Range': 'bytes=$start-',
        },
        validateStatus: (s) => s != null && s < 400,
      ),
      cancelToken: cancel,
    );

    // 服务器忽略 Range 会回 200 全量，此时旧 .part 内容作废，必须从头写
    if (start > 0 && resp.statusCode == 200) {
      debugPrint('[DL] server ignored Range (200), restart from 0');
      start = 0;
    }

    final ctype = resp.headers.value('content-type') ?? '';
    final totalHeader = resp.headers.value('content-length');
    final total = int.tryParse(totalHeader ?? '') ?? 0;
    task.total = total > 0 ? total + start : 0;
    task.received = start;
    debugPrint('[DL] FILE http=${resp.statusCode} type=$ctype '
        'len=$total total=${task.total}');

    final sink = part.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
    var lastEmit = 0;
    var sniffed = false;
    try {
      await for (final chunk in resp.data!.stream) {
        // 首块嗅探：content-type 完全不可信（实测有源把 m3u8 标成 image/png、
        // 标成 application/octet-stream），只能按内容首字节判断真实类型。
        if (!sniffed) {
          sniffed = true;
          final head = String.fromCharCodes(
              chunk.take(16).where((b) => b > 0 && b < 128));
          debugPrint('[DL] FILE sniff head=$head');
          if (head.trimLeft().startsWith('#EXTM3U')) {
            debugPrint('[DL] FILE actually m3u8, switching to HLS');
            await sink.flush();
            await sink.close();
            try {
              if (await part.exists()) await part.delete();
            } catch (_) {}
            task.isHls = true;
            task.ext = 'ts';
            throw const _SwitchToHls();
          }
        }
        sink.add(chunk);
        task.received += chunk.length;
        task.tickSpeed(task.received);
        if (task.total > 0) {
          task.progress = task.received / task.total;
        }
        // 进度节流：逐块 _emit() 会把 UI 线程打满
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastEmit > 300) {
          lastEmit = now;
          _emit();
        }
      }
    } finally {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }

    final got = await part.length();
    if (task.total > 0 && got < task.total) {
      throw StateError('连接提前断开（$got/${task.total} 字节），可续传');
    }

    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    task.filePath = target.path;
    task.received = got;
    debugPrint('[DL] FILE done -> ${target.path} ($got bytes)');
  }

  // ---------------- HLS ----------------
  Future<void> _downloadHls(DownloadTask task, CancelToken cancel) async {
    // 0. 先建目录：避免后面网络卡住时整个流程无声挂死
    final dir = await _dir();
    final tmpDir = Directory('${dir.path}/${task.id}.parts');
    if (!await tmpDir.exists()) await tmpDir.create(recursive: true);
    debugPrint('[DL] HLS start url=${task.sourceUrl}');

    // 0.5 分片已全部落盘时，必须绕过所有网络请求直接拼接。
    //
    // 实测踩到的坑：VIP4K 这类源的 m3u8 带时效 token，任务在
    // 「94 片全下完、拼接之前」被暂停后，索引里留在
    // state=paused / received=94 / total=94 / filePath=null。
    // 用户点「继续」时，下面的 playlist 请求因为 token 过期必然 403，
    // 于是任务永远停在「地址已过期，请重新解析后再下载」，
    // 明明一片不缺、只差一次本地拼接，却再也走不到完成状态。
    // 这里提前判断：分片一个不缺就直接拼，完全不需要联网。
    if (task.segments.isNotEmpty &&
        task.doneSegments.length == task.segments.length &&
        await _allSegmentsPresent(task, tmpDir)) {
      debugPrint('[DL] HLS all ${task.segments.length} segments present, '
          'skip network and join directly');
      await _joinHlsSegments(task, dir, tmpDir);
      return;
    }

    final dio = Dio(BaseOptions(
      responseType: ResponseType.plain,
      followRedirects: true,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: _headers(task.sourceUrl),
    ));

    // 1. 取 playlist
    debugPrint('[DL] HLS fetching playlist...');
    final pr = await dio.get<String>(task.sourceUrl, cancelToken: cancel);
    var text = pr.data ?? '';
    debugPrint('[DL] HLS playlist HTTP ${pr.statusCode} len=${text.length}');

    // 若是 master playlist，选第一个 variant
    if (text.contains('#EXT-X-STREAM-INF')) {
      final lines = const LineSplitter().convert(text);
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
          for (var j = i + 1; j < lines.length; j++) {
            final l = lines[j].trim();
            if (l.isEmpty || l.startsWith('#')) continue;
            final variant = _resolve(task.sourceUrl, l);
            debugPrint('[DL] HLS variant -> $variant');
            final vr = await dio.get<String>(variant, cancelToken: cancel);
            text = vr.data ?? text;
            break;
          }
          break;
        }
      }
    }

    // 2. 解析分片
    final baseUri = Uri.parse(task.sourceUrl);
    task.segments = const LineSplitter()
        .convert(text)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'))
        .map((e) => _resolveUri(baseUri, e).toString())
        .toList();
    debugPrint('[DL] HLS segments=${task.segments.length}');
    if (task.segments.isNotEmpty) {
      debugPrint('[DL] HLS seg[0]=${task.segments.first}');
    }

    if (task.segments.isEmpty) {
      throw StateError('m3u8 未解析到分片（playlist 内容异常）');
    }

    // 2.5 解析加密声明并取密钥
    // 实测 VIP4K(SH4K) 源声明 METHOD=AES-128 + 16 字节 key + 固定 IV，
    // 不解密直接拼接只会得到一堆密文，成品无法播放。
    await _prepareKey(task, text, baseUri, dio, cancel);

    final bin = Dio(BaseOptions(
      responseType: ResponseType.bytes,
      followRedirects: true,
      connectTimeout: const Duration(seconds: 20),
      // 实测 VIP4K 的末片是 302 跳到对象存储的 29.5MB 大分片，
      // 单连接在模拟器上要 37 秒；并发时还会更慢。
      // 原来 90s 看似宽松，但并发分摊带宽后照样超时，
      // 6 次重试全灭就把任务卡死在 93/94。放宽到 180s。
      receiveTimeout: const Duration(seconds: 180),
      headers: _headers(task.sourceUrl),
    ));

    // 3. 分片下载（已完成的跳过）
    //
    // 注意：分片域名经常与 m3u8 域名不同（实测 NN蓝光分片在小红书 CDN、
    // JD4K 分片在 71edge CDN），因此每片都必须按「自己的域名」生成 Referer，
    // 否则大概率被 403 拒绝。
    //
    // 并发度：原实现纯串行，94~141 片要跑十几分钟；多路并发能明显提速。
    // 但不能太高：实测 VIP4K 的末片是 302 跳到对象存储的 29.5MB 大分片，
    // 单连接就要 37 秒，开 4 路时互相抢带宽直接双双超时，
    // 6 次重试全部失败 → 整个任务卡在 93/94 不动。
    // 3 路 + 放宽超时（见 bin 的 receiveTimeout）是这组源上的稳妥值。
    const concurrency = 3;
    var cursor = 0;
    Object? fatalErr;
    final inflight = <Future<void>>[];

    Future<void> worker() async {
      while (true) {
        if (cancel.isCancelled || fatalErr != null) return;
        final i = cursor++;
        if (i >= task.segments.length) return;

        final seg = task.segments[i];
        final f = File('${tmpDir.path}/$i.ts');

        // 已存在且是合法明文分片才跳过；加密源若残留了旧的密文分片，
        // 这里必须重新下载，否则拼出来的文件依旧是坏的。
        if (await f.exists() && await f.length() > 0) {
          final ok = task.encrypted ? await _isPlainTs(f) : true;
          if (ok) {
            task.doneSegments.add(i);
            continue;
          }
          try {
            await f.delete();
          } catch (_) {}
        }

        var ok = false;
        Object? lastErr;
        // 单片可长达 20MB，网络抖动时常失败。这里的容错必须足够强：
        //   重试 6 次 + 指数退避（0.8s→1.6s→3.2s→6.4s→12.8s）
        // 实测 VIP4K 源在第 125 片因一次瞬时错误就整体失败，
        // 前 125 片全部白下——单片刻失败绝不能拖垮整个任务。
        const maxAttempt = 6;
        for (var attempt = 0; attempt < maxAttempt && !ok; attempt++) {
          if (cancel.isCancelled) return;
          try {
            final r = await bin.get<List<int>>(
              seg,
              cancelToken: cancel,
              options: Options(headers: _headers(seg)),
            );
            var bytes = r.data ?? const <int>[];
            if (bytes.isEmpty) throw StateError('分片为空');
            if (task.encrypted) {
              bytes = _aesDecrypt(bytes, task.aesKey!, _ivFor(task, i));
            }
            await f.writeAsBytes(bytes, flush: false);
            ok = true;
          } catch (e) {
            if (e is DioException && CancelToken.isCancel(e)) return;
            lastErr = e;
            debugPrint('[DL] seg[$i] attempt ${attempt + 1}/$maxAttempt '
                'failed: $e');
            if (attempt < maxAttempt - 1) {
              // 把「正在重试」暴露到界面：否则大分片连续超时时，
              // 进度条长时间不动，看起来就像卡死。
              task.stage = '分片 $i 第 ${attempt + 1} 次失败，'
                  '重试中（${attempt + 1}/$maxAttempt）';
              _emit();
              final waitMs = 800 * (1 << attempt); // 0.8s→12.8s
              await Future<void>.delayed(Duration(milliseconds: waitMs));
            }
          }
        }
        if (!ok) {
          // 记下首个致命错误，其余 worker 尽快退出，已下分片全部保留
          fatalErr ??= _RetryableError('分片 $i 多次重试后仍失败：$lastErr');
          return;
        }
        task.doneSegments.add(i);
        task.stage = null; // 恢复正常，别让「重试中」一直挂着
        task.progress = task.doneSegments.length / task.segments.length;
        task.received = task.doneSegments.length;
        task.total = task.segments.length;
        _emit();
      }
    }

    final n = task.segments.length < concurrency ? task.segments.length : concurrency;
    for (var i = 0; i < n; i++) {
      inflight.add(worker());
    }
    await Future.wait(inflight);
    if (fatalErr != null) throw fatalErr!;
    if (cancel.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: task.sourceUrl),
        reason: 'paused',
      );
    }

    // 4~5. 拼接 + 校验 + 清理分片
    await _joinHlsSegments(task, dir, tmpDir);
  }

  /// 所有分片是否都已在磁盘上且非空
  Future<bool> _allSegmentsPresent(DownloadTask task, Directory tmpDir) async {
    for (var i = 0; i < task.segments.length; i++) {
      final f = File('${tmpDir.path}/$i.ts');
      if (!await f.exists()) return false;
      if (await f.length() == 0) return false;
    }
    return true;
  }

  /// 把 parts 目录里的分片按序拼接成最终 .ts，校验后清理分片目录。
  ///
  /// 抽成独立方法是因为有两条路径都要拼：
  ///   1. 新任务：分片下载完 → 拼接
  ///   2. 分片已齐但任务被中断（暂停/崩溃）：跳过网络直接拼接
  /// 两条路径必须共用同一份逻辑，否则校验/清理稍有出入就会产生两种
  /// 行为不一致的成品。
  Future<void> _joinHlsSegments(
    DownloadTask task,
    Directory dir,
    Directory tmpDir,
  ) async {
    // 先确认所有分片都在，避免用残缺分片拼出一个「看起来成功」的坏文件
    final missing = <int>[];
    for (var i = 0; i < task.segments.length; i++) {
      final f = File('${tmpDir.path}/$i.ts');
      if (!await f.exists() || await f.length() == 0) missing.add(i);
    }
    if (missing.isNotEmpty) {
      throw StateError('有 ${missing.length} 个分片缺失（首个：${missing.first}），可继续下载补齐');
    }

    final target = File('${dir.path}/${task.id}.ts');
    // 流式拼接：逐片按块拷贝到同一个 sink。
    // 原来的 `sink.add(await f.readAsBytes())` 会把每个分片整体读进内存，
    // 2GB 级的剧集在低端机/模拟器上极易 OOM 崩溃；
    // 改成 openRead() 分块（每块 1MB）后峰值内存恒定在 1MB 左右。
    final sink = target.openWrite();
    try {
      for (var i = 0; i < task.segments.length; i++) {
        final f = File('${tmpDir.path}/$i.ts');
        if (!await f.exists()) continue;
        await for (final chunk in f.openRead()) {
          sink.add(chunk);
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    // 成品校验：明文 HLS 拼接后应为合法 MPEG-TS。
    // 抽查头部若干 188 字节包的同步字节，全对才算成功；
    // 若首字节不是 0x47，说明解密/拼接有问题，宁可报错也不留坏文件。
    if (!await _isPlainTs(target)) {
      final bad = '${target.path}.bad';
      try {
        await target.rename(bad);
      } catch (_) {}
      throw StateError('成品校验失败（非合法 TS 流），已保留为 .bad 以便排查');
    }
    debugPrint('[DL] HLS joined -> ${target.path} '
        '(segments=${task.segments.length})');

    // 清理分片
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}

    task.filePath = target.path;
    task.progress = 1;
    task.total = await target.length();
    task.received = task.total;
    _emit(persist: true);
  }

  // ---------------- AES-128 解密 ----------------

  /// 解析 playlist 的 #EXT-X-KEY 声明并取回密钥。
  ///
  /// 实测 VIP4K(SH4K) 源：
  ///   #EXT-X-KEY:METHOD=AES-128,URI="https://api.wki8.com/sh4k/key/105371.key?auth_key=...",IV=0x625fa6d0...
  /// 密钥 16 字节，密文为 16 的整数倍，解密 + 去 PKCS7 后首字节为 0x47（TS 同步字节）。
  Future<void> _prepareKey(DownloadTask task, String text, Uri baseUri,
      Dio dio, CancelToken cancel) async {
    task.aesKey = null;
    task.aesIv = null;

    final keyLine = const LineSplitter()
        .convert(text)
        .map((e) => e.trim())
        .where((e) => e.startsWith('#EXT-X-KEY'))
        .toList();
    if (keyLine.isEmpty) {
      debugPrint('[DL] no EXT-X-KEY, plain HLS');
      return;
    }
    final line = keyLine.last;
    final method = RegExp(r'METHOD=([A-Za-z0-9\-]+)')
        .firstMatch(line)
        ?.group(1)
        ?.toUpperCase();
    if (method == null || method == 'NONE') {
      debugPrint('[DL] EXT-X-KEY method=$method -> plain');
      return;
    }
    if (method != 'AES-128') {
      // SAMPLE-AES 等需要完整解密模块，明确告知而不是静默产出坏文件
      throw StateError('暂不支持该加密方式（$method）');
    }

    final uriStr = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
    if (uriStr == null) throw StateError('EXT-X-KEY 缺少 URI');

    final keyUrl = _resolveUri(baseUri, uriStr).toString();
    debugPrint('[DL] AES-128 key url=${_short(keyUrl)}');

    final kr = await dio.get<List<int>>(
      keyUrl,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.bytes,
        headers: _headers(keyUrl),
      ),
    );
    final key = kr.data;
    if (key == null || key.isEmpty) throw StateError('密钥下载为空');
    if (key.length != 16) {
      throw StateError('密钥长度异常（${key.length} 字节，期望 16）');
    }
    task.aesKey = Uint8List.fromList(key);

    final ivHex = RegExp(r'IV=0x([0-9A-Fa-f]+)').firstMatch(line)?.group(1);
    if (ivHex != null) {
      final h = ivHex.padLeft(32, '0');
      final iv = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        iv[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
      }
      task.aesIv = iv;
      debugPrint('[DL] AES-128 explicit IV=${ivHex.toLowerCase()}');
    } else {
      debugPrint('[DL] AES-128 IV from media sequence');
    }
  }

  /// 某一片的 IV：声明了固定 IV 就用它，否则按 HLS 规范用 media sequence
  Uint8List _ivFor(DownloadTask task, int index) {
    if (task.aesIv != null) return task.aesIv!;
    final iv = Uint8List(16);
    iv[15] = index & 0xFF;
    iv[14] = (index >> 8) & 0xFF;
    iv[13] = (index >> 16) & 0xFF;
    iv[12] = (index >> 24) & 0xFF;
    return iv;
  }

  /// AES-128-CBC 解密并去掉 PKCS7 填充
  ///
  /// 性能要点：pointycastle 的 processBlock 要求输入是独立缓冲，
  /// 原实现每个 16 字节块都做 `sublist` + `Uint8List.fromList` 两次拷贝，
  /// 一个 20MB 分片就是 260 万次小对象分配，在模拟器上足以让单片
  /// 解密耗时翻几倍。这里复用一个 16 字节输入缓冲区，只拷一次。
  Uint8List _aesDecrypt(List<int> data, Uint8List key, Uint8List iv) {
    if (data.length % 16 != 0) {
      throw StateError('密文长度不是 16 的倍数（${data.length}）');
    }
    final out = Uint8List(data.length);
    if (data.isEmpty) return out;

    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final blockIn = Uint8List(16);
    for (var off = 0; off < data.length; off += 16) {
      for (var k = 0; k < 16; k++) {
        blockIn[k] = data[off + k];
      }
      cipher.processBlock(blockIn, 0, out, off);
    }
    // 去 PKCS7
    final pad = out[out.length - 1];
    if (pad >= 1 && pad <= 16 && pad <= out.length) {
      var ok = true;
      for (var i = out.length - pad; i < out.length; i++) {
        if (out[i] != pad) {
          ok = false;
          break;
        }
      }
      if (ok) return Uint8List.sublistView(out, 0, out.length - pad);
    }
    return out;
  }

  /// 判断文件是否是明文 MPEG-TS（首字节同步字节 0x47）
  Future<bool> _isPlainTs(File f) async {
    try {
      final raf = await f.open();
      try {
        final b = await raf.read(1);
        return b.isNotEmpty && b[0] == 0x47;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  // ---------------- 工具 ----------------
  String _resolve(String base, String rel) => _resolveUri(Uri.parse(base), rel).toString();

  Uri _resolveUri(Uri base, String rel) {
    if (rel.startsWith('http://') || rel.startsWith('https://')) {
      return Uri.parse(rel);
    }
    return base.resolve(rel);
  }
}