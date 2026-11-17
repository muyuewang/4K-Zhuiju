/// 注册表的整体替换逻辑。
///
/// ## 这套用例的前提（2026-11-17 起）
///
/// 注册表**不内置任何源**。所有源都由远程插件配置提供，运行时经
/// `replacePlugins` 整体装入。所以这里没有「内置源」与「插件源」之分，
/// 只有「装进来了的源」和「配置里已经没有的源」。
///
/// 为什么这块值得单独测：`replacePlugins` 会**真的删掉**数据源，而它的
/// 三种出错方式在界面上都不报错，只表现为诡异现象：
///
///   1. 没删旧源 → 配置里已下线的源还在列表里，点进去必然失败
///   2. 没回退 current → 标题显示着已删除源的名字，但请求打到失效域名
///   3. 空列表没兜底 → `_all.first` 抛 `Bad state: No element`，首启即崩
///
/// 第 2 条尤其隐蔽：界面看起来完全正常，只是永远没数据。
/// 第 3 条是首次启动的必经路径，必须钉死。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/offline_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/models.dart';

/// 最小可用的假数据源，只为测注册表行为。
///
/// [group] 模拟配置里的 `group` 字段：为空表示不声明，注册表按
/// 「采集站（直连）」处理；否则原样归到该分组。
class _FakeSource implements DataSource, SourceGrouped {
  _FakeSource(this.id, {this.group = ''});

  @override
  final String id;

  @override
  final String group;

  @override
  String get displayName => '假源 $id';

  @override
  String get description => '测试用';

  @override
  List<SourceCategory> get categories => const <SourceCategory>[];

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async => [];

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async => [];

  @override
  Future<DramaDetail> detail(String dramaId) async =>
      DramaDetail(id: dramaId, name: '');

  @override
  Future<String> resolveUrl(DramaVideo video) async => video.path;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  bool get supportsDanmaku => false;
}

void main() {
  // `select()` 会往 SharedPreferences 落盘。测试环境没有平台通道，
  // 会打出一段 MissingPluginException 噪音（内部已 catch，不影响断言）。
  // 给一份内存实现，让失败信息不被淹没。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  // 这些用例会改动全局注册表（静态 List），所以在同一个 group 里
  // 顺序执行，并在每个用例末尾清空，避免污染其他测试文件。
  // （不同测试文件跑在各自 isolate 里，跨文件不会串。）
  group('replacePlugins', () {
    tearDown(() {
      // 清空即「配置里一个源都没有」，这是合法的初始态
      SourceRegistry.replacePlugins(const <DataSource>[]);
    });

    test('加入源后能按 id 取到', () {
      final p = _FakeSource('src_a');
      SourceRegistry.replacePlugins(<DataSource>[p]);

      expect(SourceRegistry.all.any((e) => e.id == 'src_a'), isTrue);
      expect(SourceRegistry.instance.byId('src_a').id, 'src_a');
      expect(SourceRegistry.pluginCount, 1);
      expect(SourceRegistry.isEmpty, isFalse);
    });

    test('没有声明分组的源归到「采集站（直连）」', () {
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('src_a')]);
      final s = SourceRegistry.instance.byId('src_a');
      expect(SourceRegistry.groupOf(s), '采集站（直连）');
      expect(SourceRegistry.needsProxy(s), isFalse);
    });

    test('分组由配置声明，不靠宿主猜 id', () {
      // 这是本次架构反转的核心：源全在远端，宿主不可能预知会下发
      // 哪些 id。硬编码 id 表一旦对不上，「需代理」的源会被静默
      // 归到「采集站」，用户点进去只看到「无法连接」且看不出原因。
      SourceRegistry.replacePlugins(<DataSource>[
        _FakeSource('anything_at_all', group: '需系统代理'),
        _FakeSource('src_common', group: '常用'),
      ]);

      expect(
        SourceRegistry.groupOf(SourceRegistry.instance.byId('anything_at_all')),
        '需系统代理',
      );
      // needsProxy 由分组推导，两者必须是同一个语义来源
      expect(
        SourceRegistry.needsProxy(
            SourceRegistry.instance.byId('anything_at_all')),
        isTrue,
      );
      expect(
        SourceRegistry.groupOf(SourceRegistry.instance.byId('src_common')),
        '常用',
      );
    });

    test('配置里删掉的源会从列表消失', () {
      SourceRegistry.replacePlugins(
          <DataSource>[_FakeSource('src_a'), _FakeSource('src_b')]);
      expect(SourceRegistry.pluginCount, 2);

      // 新一轮配置只剩 src_a
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('src_a')]);

      final ids = SourceRegistry.all.map((e) => e.id).toList();
      expect(ids.contains('src_b'), isFalse, reason: '已下线的源必须消失，否则留下一个永远打不开的条目');
      expect(ids.contains('src_a'), isTrue);
      expect(SourceRegistry.pluginCount, 1);
    });

    test('全部清空后返回占位源，不抛异常', () {
      // 首次启动必然走这条路（配置还没拉到）。这里曾经是
      // `_all.first`，直接在空列表上抛 `Bad state: No element`。
      SourceRegistry.replacePlugins(
          <DataSource>[_FakeSource('src_a'), _FakeSource('src_b')]);
      SourceRegistry.replacePlugins(const <DataSource>[]);

      expect(SourceRegistry.isEmpty, isTrue);
      expect(SourceRegistry.pluginCount, 0);
      // all 必须给一个可渲染的占位，而不是空列表——否则页面没东西可画
      expect(SourceRegistry.all.length, 1);
      expect(SourceRegistry.all.first, isA<OfflineSource>());
      expect(SourceRegistry.instance.now, isA<OfflineSource>());
    });

    test('当前选中的源被删掉时，回退到占位', () async {
      final p = _FakeSource('src_a');
      SourceRegistry.replacePlugins(<DataSource>[p]);
      await SourceRegistry.instance.select(p);
      expect(SourceRegistry.instance.now.id, 'src_a');

      // 配置里把它删了
      SourceRegistry.replacePlugins(const <DataSource>[]);

      // 必须回退，不能停在已被移除的对象上
      expect(SourceRegistry.instance.now.id, isNot('src_a'),
          reason: 'current 指向已删除的源会导致「界面正常但永远没数据」');
      expect(SourceRegistry.instance.now, isA<OfflineSource>());
    });

    test('同 id 换实例：保持选中，但换成新对象', () async {
      // 站点换域名后重新下发配置，id 不变、baseUrl 变了。
      // 这里如果因为「id 一样」就跳过替换，用户还是拿着旧域名，
      // 刷新配置等于没生效。
      final old = _FakeSource('src_a');
      SourceRegistry.replacePlugins(<DataSource>[old]);
      await SourceRegistry.instance.select(old);

      final fresh = _FakeSource('src_a');
      SourceRegistry.replacePlugins(<DataSource>[fresh]);

      expect(SourceRegistry.instance.now.id, 'src_a');
      expect(identical(SourceRegistry.instance.now, old), isFalse,
          reason: '必须换成新实例，否则域名变更不生效');
      expect(identical(SourceRegistry.instance.now, fresh), isTrue);
    });

    test('当前选中的源还在新配置里时不会被顶掉', () async {
      final a = _FakeSource('src_a');
      final b = _FakeSource('src_b');
      SourceRegistry.replacePlugins(<DataSource>[a, b]);
      await SourceRegistry.instance.select(b);

      // 新一轮配置顺序变了，但 b 还在
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('src_b'), a]);

      expect(SourceRegistry.instance.now.id, 'src_b',
          reason: '用户的选择不该因为配置调整顺序就丢掉');
    });

    test('重复调用幂等（不会出现两个同 id 源）', () {
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('src_a')]);
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('src_a')]);

      final count = SourceRegistry.all.where((e) => e.id == 'src_a').length;
      expect(count, 1);
    });

    test('源的相对顺序与传入顺序一致', () {
      // 用户在切源面板里看到的顺序应当跟配置里的顺序一致，
      // 否则「我调了 index.json 的顺序但 App 里没变」
      SourceRegistry.replacePlugins(<DataSource>[
        _FakeSource('src_c'),
        _FakeSource('src_a'),
        _FakeSource('src_b'),
      ]);

      final ids = SourceRegistry.all.map((e) => e.id).toList();
      expect(ids, <String>['src_c', 'src_a', 'src_b']);
    });

    test('byId 找不到时返回占位，不退回别的源', () {
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('src_a')]);

      // 典型场景：一条来自已删源的收藏记录
      final s = SourceRegistry.instance.byId('gone_forever');
      expect(s, isA<OfflineSource>(),
          reason: '拿已删源的 id 去请求另一个源，多半取回不相干的片子，比明确报错更难查');

      // 空 id 退到第一个，这是「没记住选择」的正常路径
      expect(SourceRegistry.instance.byId('').id, 'src_a');
      expect(SourceRegistry.instance.byId(null).id, 'src_a');
    });
  });

  group('分组顺序', () {
    test('四个分组按固定顺序展示', () {
      // 「插件（在线更新）」这一组已随架构反转删掉：现在所有源都是
      // 从远端配置装进来的，「插件」不再是一个有意义的分组——把它
      // 留着会让每个源都落进同一组，等于没有分组。
      expect(SourceRegistry.groupOrder, <String>[
        '默认',
        '常用',
        '采集站（直连）',
        '需系统代理',
      ]);
    });

    test('groupOrder 覆盖了 groupOf 的所有返回值', () {
      // 配置声明了一个 groupOrder 里没有的分组时，界面按 groupOrder
      // 渲染会把它整组漏掉——源在列表里查不到，但 all 里又确实存在。
      // 这里把常见的几种分组名都过一遍，确认没有「声明了但展示不出来」。
      for (final g in <String>['', '默认', '常用', '采集站（直连）', '需系统代理']) {
        final s = _FakeSource('src_x', group: g);
        expect(SourceRegistry.groupOrder, contains(SourceRegistry.groupOf(s)),
            reason: '分组「${SourceRegistry.groupOf(s)}」必须能展示出来');
      }
    });
  });
}