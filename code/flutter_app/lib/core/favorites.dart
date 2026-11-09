/// 追剧收藏（本机）
///
/// 这是主流影视 App 的标配：看到一部想追的剧，先收藏，之后从「我的」
/// 直接进，不用每次重新搜索。这个 App 之前只有「最近观看」——
/// 那是「已经看过的」，收藏是「打算看的」，两者不能互相替代。
///
/// 存储与 [HistoryStore] 刻意分开：
///   - 历史会被自动裁剪、会被「清空观看记录」清掉，而收藏是用户的
///     主动决策，不该被历史的一键清空连带删除；
///   - 收藏条目少（几十部），变更频率极低，不需要历史那套节流。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 一部被收藏的剧
///
/// 只存列表页展示需要的字段，不回存 DramaDetail：详情里的剧集地址带
/// 时效签名，改了源就失效，存下来只会变成一堆过期数据。
/// 真正播放还是回详情页重新拉一次。
class FavoriteItem {
  final int dramaId;
  final String name;
  final String cover;
  final int year;
  final String area;
  final String remark;

  /// 收藏时间（毫秒），用于「最近收藏」排序
  final int addedAt;

  const FavoriteItem({
    required this.dramaId,
    required this.name,
    this.cover = '',
    this.year = 0,
    this.area = '',
    this.remark = '',
    this.addedAt = 0,
  });

  /// 卡片副标题：年份 · 地区 · 备注，空项自动跳过
  String get subtitle {
    final parts = <String>[];
    if (year > 0) parts.add('$year');
    if (area.isNotEmpty) parts.add(area);
    if (remark.isNotEmpty) parts.add(remark);
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'dramaId': dramaId,
        'name': name,
        'cover': cover,
        'year': year,
        'area': area,
        'remark': remark,
        'addedAt': addedAt,
      };

  static FavoriteItem? fromJson(Map<String, dynamic> m) {
    final id = (m['dramaId'] as num?)?.toInt() ?? 0;
    final name = m['name'] as String? ?? '';
    // id 和名字都没有的记录没有任何用处，直接丢弃（防手改坏的 prefs）
    if (id == 0 || name.isEmpty) return null;
    return FavoriteItem(
      dramaId: id,
      name: name,
      cover: m['cover'] as String? ?? '',
      year: (m['year'] as num?)?.toInt() ?? 0,
      area: m['area'] as String? ?? '',
      remark: m['remark'] as String? ?? '',
      addedAt: (m['addedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class FavoriteStore {
  FavoriteStore._();
  static final FavoriteStore instance = FavoriteStore._();

  /// 条目很少（几十部），不做上限裁剪：用户主动收藏的东西
  /// 被悄悄删掉比列表长一点更让人恼火。
  final ValueNotifier<List<FavoriteItem>> items =
      ValueNotifier<List<FavoriteItem>>([]);

  bool _loaded = false;
  String _path = '';
  bool _saving = false;
  bool _dirty = false;

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
      final out = <FavoriteItem>[];
      for (final e in list) {
        try {
          final it = FavoriteItem.fromJson(e as Map<String, dynamic>);
          if (it != null) out.add(it);
        } catch (err) {
          debugPrint('[FAV] restore item failed: $err');
        }
      }
      out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      items.value = out;
      debugPrint('[FAV] restored ${out.length} items');
    } catch (e) {
      debugPrint('[FAV] restore failed: $e');
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
    _path = '$base/.favorites.json';
    return _path;
  }

  bool contains(int dramaId) =>
      items.value.any((e) => e.dramaId == dramaId);

  /// 切换收藏状态，返回切换后是否已收藏（用于提示文案）
  bool toggle({
    required int dramaId,
    required String name,
    String cover = '',
    int year = 0,
    String area = '',
    String remark = '',
  }) {
    if (contains(dramaId)) {
      remove(dramaId);
      return false;
    }
    add(
      dramaId: dramaId,
      name: name,
      cover: cover,
      year: year,
      area: area,
      remark: remark,
    );
    return true;
  }

  void add({
    required int dramaId,
    required String name,
    String cover = '',
    int year = 0,
    String area = '',
    String remark = '',
  }) {
    if (dramaId == 0 || name.isEmpty) return;
    // 已存在就只更新元信息（封面/备注可能变了），不动排序时间
    final list = List<FavoriteItem>.from(items.value);
    final i = list.indexWhere((e) => e.dramaId == dramaId);
    final item = FavoriteItem(
      dramaId: dramaId,
      name: name,
      cover: cover,
      year: year,
      area: area,
      remark: remark,
      addedAt: i >= 0
          ? list[i].addedAt
          : DateTime.now().millisecondsSinceEpoch,
    );
    if (i >= 0) {
      list[i] = item;
    } else {
      list.insert(0, item);
    }
    items.value = list;
    _scheduleSave();
  }

  void remove(int dramaId) {
    final list = List<FavoriteItem>.from(items.value)
      ..removeWhere((e) => e.dramaId == dramaId);
    if (list.length == items.value.length) return;
    items.value = list;
    _scheduleSave();
  }

  void clear() {
    if (items.value.isEmpty) return;
    items.value = const [];
    _scheduleSave();
  }

  void _scheduleSave() {
    unawaited(_save());
  }

  /// 串行写盘 + 以最新快照为准
  ///
  /// 与 SearchHistory 同一个坑：连续点两次收藏会并发两次写盘，
  /// 先发起的那次若最后落盘，会把新状态覆盖回去。
  Future<void> _save() async {
    if (_saving) {
      _dirty = true;
      return;
    }
    _saving = true;
    try {
      do {
        _dirty = false;
        final data = items.value.map((e) => e.toJson()).toList();
        final p = await _filePath();
        final tmp = File('$p.tmp');
        await tmp.writeAsString(jsonEncode(data), flush: true);
        await tmp.rename(p);
      } while (_dirty);
    } catch (e) {
      debugPrint('[FAV] save failed: $e');
    } finally {
      _saving = false;
    }
  }
}