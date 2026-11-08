/// 观看历史（最近观看）
///
/// 只存必要信息：剧名、集名、封面、剧集 id、进度、更新时间。
/// 目的很单纯——用户从「我的」里一键回到上次看的地方，不用重新搜索。
///
/// 为什么不并入 DownloadManager：两者生命周期完全不同。
/// 下载任务动辄几个 G 要长期保存并保证文件一致性，历史记录只是几十条
/// 轻量元数据、允许被裁剪，放一起会让下载索引的原子写变成高频写。
/// 这里单独一个文件、单独节流，互不干扰。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 一条观看记录
class WatchRecord {
  /// 剧集 id（详情页唯一键），用于「继续观看」回跳详情页
  final int dramaId;
  final String dramaName;

  /// 当前看到第几集（展示用，如「第3集」）
  final String epLabel;

  /// 该集在接口里的定位参数，用于直接续播
  final String source;
  final String path;
  final int episode;

  final String cover;

  /// 已观看位置（秒）
  final int positionSec;

  /// 总时长（秒），未知为 0
  final int durationSec;

  /// 最后观看时间（毫秒时间戳），用于排序
  final int updatedAt;

  WatchRecord({
    required this.dramaId,
    required this.dramaName,
    this.epLabel = '',
    this.source = '',
    this.path = '',
    this.episode = 0,
    this.cover = '',
    this.positionSec = 0,
    this.durationSec = 0,
    this.updatedAt = 0,
  });

  /// 观看进度 0~1；时长未知时返回 0
  double get progress {
    if (durationSec <= 0) return 0;
    return (positionSec / durationSec).clamp(0.0, 1.0);
  }

  /// 是否已经接近看完（>95%），列表里可以弱化显示
  bool get nearlyFinished => progress > 0.95;

  Map<String, dynamic> toJson() => {
        'dramaId': dramaId,
        'dramaName': dramaName,
        'epLabel': epLabel,
        'source': source,
        'path': path,
        'episode': episode,
        'cover': cover,
        'positionSec': positionSec,
        'durationSec': durationSec,
        'updatedAt': updatedAt,
      };

  static WatchRecord? fromJson(Map<String, dynamic> m) {
    final id = (m['dramaId'] as num?)?.toInt() ?? 0;
    final name = m['dramaName'] as String? ?? '';
    if (id == 0 && name.isEmpty) return null;
    return WatchRecord(
      dramaId: id,
      dramaName: name,
      epLabel: m['epLabel'] as String? ?? '',
      source: m['source'] as String? ?? '',
      path: m['path'] as String? ?? '',
      episode: (m['episode'] as num?)?.toInt() ?? 0,
      cover: m['cover'] as String? ?? '',
      positionSec: (m['positionSec'] as num?)?.toInt() ?? 0,
      durationSec: (m['durationSec'] as num?)?.toInt() ?? 0,
      updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  WatchRecord copyWith({int? positionSec, int? durationSec, int? updatedAt}) =>
      WatchRecord(
        dramaId: dramaId,
        dramaName: dramaName,
        epLabel: epLabel,
        source: source,
        path: path,
        episode: episode,
        cover: cover,
        positionSec: positionSec ?? this.positionSec,
        durationSec: durationSec ?? this.durationSec,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class HistoryStore {
  HistoryStore._();
  static final HistoryStore instance = HistoryStore._();

  /// 最多保留条数。历史是「最近观看」，不是收藏夹，
  /// 无上限增长会让启动时的读取和界面渲染越来越慢。
  static const int maxItems = 100;

  final ValueNotifier<List<WatchRecord>> records =
      ValueNotifier<List<WatchRecord>>([]);

  bool _loaded = false;
  String _path = '';
  bool _saving = false;
  bool _dirty = false;
  Timer? _saveTimer;

  Future<void> restore() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await _filePath();
      final f = File(p);
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final list = jsonDecode(raw) as List;
      final out = <WatchRecord>[];
      for (final e in list) {
        try {
          final r = WatchRecord.fromJson(e as Map<String, dynamic>);
          if (r != null) out.add(r);
        } catch (err) {
          debugPrint('[HIS] restore item failed: $err');
        }
      }
      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      records.value = out;
      debugPrint('[HIS] restored ${out.length} records');
    } catch (e) {
      debugPrint('[HIS] restore failed: $e');
    }
  }

  Future<String> _filePath() async {
    if (_path.isNotEmpty) return _path;
    String base;
    try {
      final dir = await getApplicationDocumentsDirectory();
      base = dir.path;
    } catch (_) {
      base = Directory.systemTemp.path;
    }
    _path = '$base/.history.json';
    return _path;
  }

  /// 记录/更新一次观看。
  ///
  /// 幂等：同一部剧只留一条，重复观看会刷新集数与进度并顶到最前。
  void upsert(WatchRecord r) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final item = r.copyWith(updatedAt: now);
    final list = List<WatchRecord>.from(records.value);
    final i = list.indexWhere((e) =>
        (r.dramaId != 0 && e.dramaId == r.dramaId) ||
        (r.dramaId == 0 && e.dramaName == r.dramaName));
    if (i >= 0) {
      list.removeAt(i);
    }
    list.insert(0, item);
    if (list.length > maxItems) list.removeRange(maxItems, list.length);
    records.value = list;
    _scheduleSave();
  }

  /// 只更新进度（播放过程中调用，节流后写盘）
  void updateProgress({
    required int dramaId,
    required String dramaName,
    required int positionSec,
    required int durationSec,
  }) {
    final list = List<WatchRecord>.from(records.value);
    final i = list.indexWhere((e) =>
        (dramaId != 0 && e.dramaId == dramaId) ||
        (dramaId == 0 && e.dramaName == dramaName));
    if (i < 0) return;
    // 进度几乎没变就别动，避免每帧都重建列表
    final old = list[i];
    if ((old.positionSec - positionSec).abs() < 3 &&
        old.durationSec == durationSec) {
      return;
    }
    list[i] = old.copyWith(
      positionSec: positionSec,
      durationSec: durationSec,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // 进度更新不改变排序，只替换同一位置，减少列表跳动
    records.value = list;
    _scheduleSave();
  }

  void remove(int dramaId, String dramaName) {
    final list = List<WatchRecord>.from(records.value)
      ..removeWhere((e) =>
          (dramaId != 0 && e.dramaId == dramaId) ||
          (dramaId == 0 && e.dramaName == dramaName));
    records.value = list;
    _scheduleSave();
  }

  void clear() {
    records.value = const [];
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    if (_saving) {
      _dirty = true;
      return;
    }
    _saving = true;
    try {
      do {
        _dirty = false;
        await _saveOnce();
      } while (_dirty);
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveOnce() async {
    try {
      final p = await _filePath();
      final data = records.value.map((e) => e.toJson()).toList();
      final tmp = File('$p.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(p);
    } catch (e) {
      debugPrint('[HIS] save failed: $e');
    }
  }
}