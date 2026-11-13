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
import 'ddys_source.dart';
import 'jisu_source.dart';
import 'kanju_source.dart';
import 'kvm4k_source.dart';
import 'site_sources.dart';
import 'yuny_source.dart';
import 'zhuiju_source.dart';

class SourceRegistry {
  SourceRegistry._();
  static final SourceRegistry instance = SourceRegistry._();

  static const String _prefKey = 'app.dataSourceId';

  /// 全部可用数据源。顺序即设置页/快切面板的展示顺序，第一个是默认。
  ///
  /// 加源的完整清单：
  ///   1. MacCMS 类站点 → 在 `site_sources.dart` 加一条 [MacCmsConfig]；
  ///   2. 自定义程序   → 新建一个 `implements DataSource` 的类，
  ///      声明 id / displayName / categories / lineOrderPolicy /
  ///      supportsDanmaku，实现 search / category / detail / resolveUrl；
  ///   3. 在这里登记（或运行时调 [register]）。
  /// 页面、收藏、历史、播放器都不需要改：它们只依赖 [DataSource] 契约。
  ///
  /// ## 排序规则（用户 2026-11-13 明确指定）
  ///
  ///   1. 橘汁（默认，恒第一）
  ///   2. 追剧 / 暴风 / 量子 / 片库 —— 这 4 个相对次序不变
  ///   3. 采集站 —— 按**实测首页响应中位数**从快到慢
  ///   4. 需要代理的源 —— 全部沉到最后
  ///
  /// 为什么代理源必须垫底：它们的源站国内直连不通，没开代理时
  /// 点进去只能看到「无法连接」。把不能用的源排在能用的源前面，
  /// 等于每次换源都先让用户撞一次墙。
  ///
  /// ## 2026-11-13 剔除的两个源
  ///
  /// **可可影视**（keke1）：站是活的，但 App 侧拿不到数据。
  /// 实测详情页的 `source-list-box-main` / `episode-list-box-main`
  /// 两个容器是**空的**，播放页 `playSource.src` 是**硬编码空串**，
  /// 选集与地址全部改由 `kkys.min.js` 通过 HmacSHA1 签名 API
  /// （`43.248.100.69:51080`）异步取，而该 API 直连超时、
  /// 经代理 https 握手失败 / http 502。浏览器能播是因为它跑得动那套 JS，
  /// App 拿到的静态 HTML 里这两块就是空的 —— 确定性失效，不是偶发。
  ///
  /// **樱花资源**（yinghua）：用户反馈「大部分不能看、更新慢」，站方采集节奏问题，
  /// 客户端无法解决。
  static final List<DataSource> _all = <DataSource>[
    // ① 默认
    ZhuijuSource.instance,
    // ② 既有 4 个，相对次序由用户指定，不要动
    KanjuSource.instance,
    kBofengSource,
    kLiangziSource,
    kPiankuSource,
    // ③ 采集站，按实测首页耗时升序（数字为 2026-11-13 实测中位数）
    kDyttSource, //  213ms
    kGuangsuSource, //  224ms
    kFeifanSource, //  228ms
    kMaoyanSource, //  264ms
    // ④ 需系统代理，国内直连不通，全部最后
    Kvm4kSource.instance,
    JisuSource.instance,
    YunySource.instance,
    DdysSource.instance,
  ];

  static List<DataSource> get all => List.unmodifiable(_all);

  /// 某个源属于哪一组（只用于界面分组展示，不参与任何逻辑）。
  ///
  /// 为什么不在 [DataSource] 上加一个 `group` 字段：那要求每个源实现类
  /// 都提供 getter，改一遍 15 个类，且以后加源容易漏。这里按 id 查表，
  /// 集中在一处维护，加源时只要在这里补一行。
  ///
  /// 分组的意义：现在有 15 个源，平铺成一个列表用户根本挑不动。
  /// 分成「默认 / 常用 / 采集站（直连）/ 需代理」四组后，
  /// 用户能立刻明白「为什么这 4 个要开代理」「哪几个是新的」。
  static String groupOf(DataSource s) {
    if (_groupProxy.contains(s.id)) return '需系统代理';
    if (_groupDefault.contains(s.id)) return '默认';
    if (_groupBuiltin.contains(s.id)) return '常用';
    return '采集站（直连）';
  }

  /// 分组展示顺序。界面上按这个顺序渲染分组标题。
  static const List<String> groupOrder = ['默认', '常用', '采集站（直连）', '需系统代理'];

  static const Set<String> _groupDefault = {'zhuiju'};
  static const Set<String> _groupBuiltin = {
    'kanju',
    'bofeng',
    'liangzi',
    'pianku',
  };

  /// 源站国内直连不通、必须走系统代理的源。
  ///
  /// 与各源 description 里写的「需系统代理」必须一致；这里独立维护是因为
  /// 界面要在**不发请求**的前提下就知道谁需要代理（不能靠探测）。
  static const Set<String> _groupProxy = {
    'kvm4k',
    'jisu',
    'yuny',
    'ddys',
  };

  /// 该源是否依赖系统代理。用于在切换面板上打标记。
  static bool needsProxy(DataSource s) => _groupProxy.contains(s.id);

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