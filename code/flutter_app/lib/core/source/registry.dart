/// 数据源注册表：运行时切换 + 记住选择。
///
/// ## 所有源都来自远程配置
///
/// 这个类**不内置任何源**。所有源都由 `config/plugins/*.js` 提供，
/// 启动时从远端拉取后调 [replacePlugins] 装进来。
///
/// ### 为什么改成这样
///
/// 源的域名、分类 id、接口路径是最容易变的东西。它们被编译进安装包，
/// 就意味着**改一个域名要发一次版**。2026-11-17 橘汁主域名整站 502 时，
/// 官方已在换服务器，而用户手里是旧包、旧包里是旧域名，只能吃一整片
/// 「连接失败」——这类问题不该再发生。
///
/// 反过来，只要源是远端配置，改域名、改分类、甚至整个换掉解析方式，
/// 推一次仓库就生效，不用等发版。
///
/// ### 代价与应对
///
/// 「装上就有片看」变成了「装上先拉配置」。所以：
///
///   - 配置落本地缓存，第二次启动起立刻可用（`PluginLoader.restore`）；
///   - 一个源都没有时返回 [OfflineSource] 占位，界面据此提示
///     「正在获取源配置」，既不白屏也不崩；
///   - 拉取失败**不清缓存**，用户手里的源照常可用。
///
/// ## 页面怎么用
///
/// 页面只从 [current] 取当前源、从 [all] 取全部源，永远不直接持有
/// 某个具体实现。收藏/历史记住条目的 `sourceId`，回详情页时按条目
/// 自己的源去取，而不是按「当前全局源」——否则切了源，旧收藏全打不开。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_source.dart';
import 'offline_source.dart';

class SourceRegistry {
  SourceRegistry._();
  static final SourceRegistry instance = SourceRegistry._();

  static const String _prefKey = 'app.dataSourceId';

  /// 当前生效的源。**空表示配置还没拉到**，这是合法的初始状态。
  ///
  /// 用空列表而不是塞一个占位进去：占位混在真实源里，会让
  /// 「现在能用哪些源」这个判断变得不可靠（数出来的 1 个其实是假的）。
  /// 占位只在 [all] / [now] / [byId] 这几个对外的出口按需生成。
  static final List<DataSource> _all = <DataSource>[];

  /// 全部可用源。空列表时给一个占位，让界面有东西可渲染。
  static List<DataSource> get all =>
      _all.isEmpty ? const <DataSource>[OfflineSource.instance] : List.unmodifiable(_all);

  /// 是否还没加载到任何源（配置未拉到 / 首次启动）
  static bool get isEmpty => _all.isEmpty;

  /// 某个源属于哪一组（只用于界面分组展示，不参与任何逻辑）。
  ///
  /// 分组信息现在**由清单自己声明**（`group` 字段），不再在这里维护
  /// 一张 id 表。理由：源全在远端，注册表不可能知道未来会出现什么 id；
  /// 硬编码的 id 表一旦对不上，新源就会被静默归到「采集站」，
  /// 而它实际可能需要代理——用户点进去只会看到「无法连接」。
  ///
  /// 走可选能力（[SourceGrouped]）而不是写进 [DataSource] 必选契约：
  /// 后者要求每个实现类都补一行 getter，而绝大多数源就是「采集站」，
  /// 加一个恒返回同一个值的成员只是噪音。与 [SectionedFeed] 同一套做法。
  static String groupOf(DataSource s) {
    final g = s is SourceGrouped ? (s as SourceGrouped).group : '';
    return g.isEmpty ? '采集站（直连）' : g;
  }

  /// 该源是否依赖系统代理。用于在切换面板上打标记。
  ///
  /// 由分组推导，不再维护一张 id 表：源全在远端，id 表迟早会漏。
  /// 「需系统代理」这个分组本身就是配置声明的，两者语义完全一致。
  static bool needsProxy(DataSource s) => groupOf(s) == '需系统代理';

  /// 分组展示顺序。界面上按这个顺序渲染分组标题。
  ///
  /// 顺序有语义：能用的、常用的在前面，需要额外条件（代理）的沉底。
  static const List<String> groupOrder = <String>[
    '默认',
    '常用',
    '采集站（直连）',
    '需系统代理',
  ];

  /// 把所有实际出现的分组排成展示顺序。
  ///
  /// 已知分组按 [groupOrder] 排；**没见过的分组一律追加到末尾，绝不丢弃**。
  ///
  /// 为什么必须有这个兜底：源全在远端配置里，清单可以随时新增一个
  /// 从没见过的 group（比如片库的「网页模板（直连）」、看剧的「直连」）。
  /// 界面若只遍历写死的 groupOrder，这些源会「加载成功、计数里算数，
  /// 但切换面板里根本不显示」——表现为「提示 19 个源，却找不到某两个」。
  /// 这种漏显示没有任何报错，最难查。
  static List<String> orderedGroups(Iterable<String> present) {
    final seen = present.toSet();
    return <String>[
      ...groupOrder.where(seen.contains),
      ...seen.where((g) => !groupOrder.contains(g)),
    ];
  }

  /// 运行时登记一个数据源（幂等）。
  static void register(DataSource s) {
    if (_all.any((e) => e.id == s.id)) return;
    _all.add(s);
  }

  /// 用一批源**整体替换**当前列表。
  ///
  /// 为什么是整体替换而不是增量合并：配置里删掉一个源后，用户端必须
  /// 跟着消失，否则会留下一个永远打不开的条目（域名已经不在配置里了）。
  /// 增量合并做不到「消失」。
  ///
  /// ## 当前选中的源怎么办
  ///
  /// 三种情况必须分开处理，混在一起会出现「标题显示 A、请求打到 B」：
  ///
  ///   1. 新列表里有同 id 的源 → 换成新实例（域可能变了），但保持选中；
  ///   2. 没有同 id → 回退到新列表第一个；
  ///   3. 新列表为空 → 回退到占位，界面提示「配置未就绪」。
  static void replacePlugins(List<DataSource> plugins) {
    _all
      ..clear()
      ..addAll(plugins);

    final cur = instance.current.value;
    final same = _all.where((e) => e.id == cur.id);
    if (same.isNotEmpty) {
      // 同 id 换实例：不能因为 identical 判断而跳过，否则用户还是
      // 拿着旧对象、旧域名，刷新配置等于没生效。
      instance.current.value = same.first;
    } else if (_all.isNotEmpty) {
      instance.current.value = _all.first;
    } else {
      instance.current.value = OfflineSource.instance;
    }
  }

  /// 当前已注册的源数量（设置页展示用）
  static int get pluginCount => _all.length;

  /// 当前选中的数据源。
  ///
  /// 初始值是占位而不是 `_all.first`——后者在空列表上会直接
  /// `Bad state: No element`，而首次启动必然是空的。
  final ValueNotifier<DataSource> current =
      ValueNotifier<DataSource>(OfflineSource.instance);

  bool _loaded = false;

  /// 启动时读回上次的选择。失败一律退回默认，不让 App 起不来。
  ///
  /// 注意它的调用时机：必须在源装进注册表**之后**。
  /// 反过来的话，用户选的源此刻还不在列表里，会被判成「已失效」
  /// 而退回第一个——表现就是「我明明选了 A，每次重启都变回默认」。
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
    // 占位源不写进持久化：它不是一个真的源，存下来只会在下次启动时
    // 变成一个「找不到」的 id，白白多一条日志。
    if (s is OfflineSource) return;
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

  /// 按 id 找源。找不到时返回占位，**不**返回某个真实源。
  ///
  /// 这里刻意不做「找不到就当默认源」的兜底：那会让一条来自已删源的
  /// 收藏记录，悄悄用另一个源的 id 去请求详情——多半取回一部不相干的
  /// 片子，比明确报错更难查。返回占位则会让界面如实说「这个源不可用」。
  DataSource byId(String? id) {
    if (id == null || id.isEmpty) {
      return _all.isEmpty ? OfflineSource.instance : _all.first;
    }
    final hit = _all.where((e) => e.id == id);
    return hit.isEmpty ? OfflineSource.instance : hit.first;
  }

  /// 当前源
  DataSource get now => current.value;
}