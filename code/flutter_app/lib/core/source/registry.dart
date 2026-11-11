/// 数据源注册表：运行时切换 + 记住选择。
///
/// 页面不再直接持有某个具体数据源，统一从这里取当前源。这样：
///   1. 加源只要在 [_all] 里登记，界面自动多一个选项；
///   2. 收藏/历史记住条目的 `sourceId`，回详情页时按条目自己的源去取，
///      而不是按「当前全局源」——否则用户切了源，旧收藏全都打不开。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_source.dart';
import 'kanju_source.dart';
import 'keke1_source.dart';
import 'site_sources.dart';
import 'zhuiju_source.dart';

class SourceRegistry {
  SourceRegistry._();
  static final SourceRegistry instance = SourceRegistry._();

  static const String _prefKey = 'app.dataSourceId';

  /// 全部可用数据源。顺序即设置页展示顺序，第一个是默认。
  ///
  /// 加源的完整清单：
  ///   1. MacCMS 类站点 → 在 `site_sources.dart` 加一条 [MacCmsConfig]；
  ///   2. 自定义程序   → 新建一个 `implements DataSource` 的类，
  ///      声明 id / displayName / categories / lineOrderPolicy /
  ///      supportsDanmaku，实现 search / category / detail / resolveUrl；
  ///   3. 在这里登记（或运行时调 [register]）。
  /// 页面、收藏、历史、播放器都不需要改：它们只依赖 [DataSource] 契约。
  static final List<DataSource> _all = <DataSource>[
    ZhuijuSource.instance,
    KanjuSource.instance,
    kBofengSource,
    kLiangziSource,
    kPiankuSource,
    Keke1Source.instance,
  ];

  static List<DataSource> get all => List.unmodifiable(_all);

  /// 运行时登记一个数据源（幂等）。
  ///
  /// 编译期写死在 [_all] 已经够用，留这个入口是为了以后做「自定义源
  /// 导入」时不必再改注册表：从配置读出来直接 register 即可。
  static void register(DataSource s) {
    if (_all.any((e) => e.id == s.id)) return;
    _all.add(s);
  }

  /// 当前选中的数据源；未选择过时是第一个（橘汁）。
  final ValueNotifier<DataSource> current =
      ValueNotifier<DataSource>(_all.first);

  bool _loaded = false;

  /// 启动时读回上次的选择。失败一律退回默认，不让 App 起不来。
  Future<void> restore() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final id = sp.getString(_prefKey);
      if (id == null || id.isEmpty) return;
      final hit = _all.where((e) => e.id == id);
      if (hit.isNotEmpty) current.value = hit.first;
    } catch (e) {
      debugPrint('[SRC] restore failed: $e');
    }
  }

  /// 切换数据源并持久化。
  Future<void> select(DataSource s) async {
    if (identical(current.value, s)) return;
    current.value = s;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefKey, s.id);
    } catch (e) {
      debugPrint('[SRC] persist failed: $e');
    }
  }

  Future<void> selectById(String id) async {
    final hit = _all.where((e) => e.id == id);
    if (hit.isNotEmpty) await select(hit.first);
  }

  /// 按 id 找源。未知 id（含空串 = 老数据）一律按橘汁处理。
  ///
  /// 这就是「收藏/历史里的老条目在升级后仍能打开」的兜底：
  /// 它们存的 sourceId 是空串，而空串必然来自升级前的橘汁。
  DataSource byId(String? id) {
    if (id == null || id.isEmpty) return ZhuijuSource.instance;
    final hit = _all.where((e) => e.id == id);
    return hit.isEmpty ? ZhuijuSource.instance : hit.first;
  }

  /// 当前源
  DataSource get now => current.value;
}