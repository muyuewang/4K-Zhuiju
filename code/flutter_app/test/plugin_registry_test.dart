/// 注册表的插件替换逻辑。
///
/// 为什么这块值得单独测：`replacePlugins` 会**真的删掉**数据源，而它的
/// 三种出错方式在界面上都不报错，只表现为诡异现象：
///
///   1. 删了内置源 → 用户发现「我的 19 个源怎么少了几个」
///   2. 没删旧插件 → 配置里已下线的源还在列表里，点进去必然失败
///   3. 没回退 current → 标题显示着已删除源的名字，但请求打到失效域名
///
/// 第 3 条尤其隐蔽：界面看起来完全正常，只是永远没数据。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/models.dart';

/// 最小可用的假数据源，只为测注册表行为。
class _FakeSource implements DataSource {
  _FakeSource(this.id);

  @override
  final String id;

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
  // 顺序执行，并在每个用例末尾把插件清空，避免污染其他测试文件。
  // （不同测试文件跑在各自 isolate 里，跨文件不会串。）
  group('replacePlugins', () {
    tearDown(() {
      // 清掉本组加的插件，恢复成「只有内置源」
      SourceRegistry.replacePlugins(const <DataSource>[]);
    });

    test('加入插件源，且能按 id 取到', () {
      final p = _FakeSource('js_a');
      SourceRegistry.replacePlugins(<DataSource>[p]);

      expect(SourceRegistry.all.any((e) => e.id == 'js_a'), isTrue);
      expect(SourceRegistry.instance.byId('js_a').id, 'js_a');
      expect(SourceRegistry.pluginCount, 1);
    });

    test('归入「插件（在线更新）」分组', () {
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('js_a')]);
      final s = SourceRegistry.instance.byId('js_a');
      expect(SourceRegistry.groupOf(s), '插件（在线更新）');
    });

    test('配置里删掉的插件会从列表消失', () {
      SourceRegistry.replacePlugins(
          <DataSource>[_FakeSource('js_a'), _FakeSource('js_b')]);
      expect(SourceRegistry.pluginCount, 2);

      // 新一轮配置只剩 js_a
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('js_a')]);

      final ids = SourceRegistry.all.map((e) => e.id).toList();
      expect(ids.contains('js_b'), isFalse, reason: '已下线的插件必须消失');
      expect(ids.contains('js_a'), isTrue);
      expect(SourceRegistry.pluginCount, 1);
    });

    test('插件全清空后，内置源一个都不能少', () {
      final before = SourceRegistry.all
          .where((e) => !e.id.startsWith('js_'))
          .map((e) => e.id)
          .toSet();

      SourceRegistry.replacePlugins(
          <DataSource>[_FakeSource('js_a'), _FakeSource('js_b')]);
      SourceRegistry.replacePlugins(const <DataSource>[]);

      final after = SourceRegistry.all
          .where((e) => !e.id.startsWith('js_'))
          .map((e) => e.id)
          .toSet();

      expect(after, before, reason: '内置源必须完全不受插件增删影响');
      expect(SourceRegistry.pluginCount, 0);
    });

    test('当前选中的插件被删掉时，回退到默认源', () async {
      final p = _FakeSource('js_a');
      SourceRegistry.replacePlugins(<DataSource>[p]);
      await SourceRegistry.instance.select(p);
      expect(SourceRegistry.instance.now.id, 'js_a');

      // 配置里把它删了
      SourceRegistry.replacePlugins(const <DataSource>[]);

      // 必须回退，不能停在已被移除的对象上
      expect(SourceRegistry.instance.now.id, isNot('js_a'),
          reason: 'current 指向已删除的源会导致「界面正常但永远没数据」');
      expect(SourceRegistry.all.any((e) => e.id == SourceRegistry.instance.now.id),
          isTrue,
          reason: '回退后的源必须真的在列表里');
    });

    test('当前选中的是内置源时，插件增删不影响它', () async {
      await SourceRegistry.instance.selectById('zhuiju');
      expect(SourceRegistry.instance.now.id, 'zhuiju');

      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('js_a')]);
      expect(SourceRegistry.instance.now.id, 'zhuiju');

      SourceRegistry.replacePlugins(const <DataSource>[]);
      expect(SourceRegistry.instance.now.id, 'zhuiju');
    });

    test('重复调用幂等（不会出现两个同名源）', () {
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('js_a')]);
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('js_a')]);

      final count = SourceRegistry.all.where((e) => e.id == 'js_a').length;
      expect(count, 1);
    });

    test('插件源的相对顺序与传入顺序一致', () {
      // 用户在切源面板里看到的顺序应当跟配置里的顺序一致，
      // 否则「我调了 index.json 的顺序但 App 里没变」
      SourceRegistry.replacePlugins(<DataSource>[
        _FakeSource('js_c'),
        _FakeSource('js_a'),
        _FakeSource('js_b'),
      ]);

      final pluginIds = SourceRegistry.all
          .map((e) => e.id)
          .where((id) => id.startsWith('js_'))
          .toList();
      expect(pluginIds, <String>['js_c', 'js_a', 'js_b']);
    });

    test('插件永远排在内置源之后', () {
      SourceRegistry.replacePlugins(<DataSource>[_FakeSource('js_a')]);
      final ids = SourceRegistry.all.map((e) => e.id).toList();

      final firstPlugin = ids.indexOf('js_a');
      final lastBuiltin = ids.lastIndexWhere((id) => !id.startsWith('js_'));
      expect(firstPlugin, greaterThan(lastBuiltin),
          reason: '插件是附加能力，不该顶掉内置源的位置');
    });
  });
}