/// 数据源展示名与能力描述的回归（设置页「数据源」弹层）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/kanju_source.dart';
import 'package:zhuiju/core/source/keke1_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source/site_sources.dart';
import 'package:zhuiju/core/source/zhuiju_source.dart';

void main() {
  test('kanju 在界面上叫「看剧」，不再露出内部代号', () {
    expect(KanjuSource.instance.displayName, contains('看剧'));
    expect(KanjuSource.instance.displayName, isNot(contains('kanju')));
  });

  test('每个源都有非空的展示名与说明', () {
    for (final s in SourceRegistry.all) {
      expect(s.displayName.trim(), isNotEmpty, reason: '${s.id} 没有展示名');
      expect(s.description.trim(), isNotEmpty, reason: '${s.id} 没有说明');
    }
  });

  test('描述必须与实际能力一致：不支持弹幕的源不能写「支持弹幕」', () {
    for (final s in SourceRegistry.all) {
      if (!s.supportsDanmaku) {
        expect(s.description, isNot(contains('支持弹幕')),
            reason: '${s.id} 不支持弹幕，说明却写了「支持弹幕」');
      }
    }
    expect(ZhuijuSource.instance.supportsDanmaku, isTrue);
    expect(kPiankuSource.supportsDanmaku, isFalse);
    expect(Keke1Source.instance.supportsDanmaku, isFalse);
  });

  test('注册表的展示名不重复', () {
    final names = SourceRegistry.all.map((s) => s.displayName).toList();
    expect(names.toSet().length, names.length);
  });

  test('contract 强制每个实现类声明 description，没有可绕过的默认值', () {
    // 用桩类验证契约完整性：漏写 description 会直接编译失败。
    // 这里只确认桩类按要求实现后能正常参与多态。
    final DataSource stub = _StubSource();
    expect(stub.description, isNotEmpty);
    expect(stub.displayName, '桩');
  });
}

class _StubSource implements DataSource {
  @override
  String get id => 'stub';
  @override
  String get displayName => '桩';
  @override
  String get description => '桩源，仅用于测试契约';
  @override
  List<SourceCategory> get categories => const [];
  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async => [];
  @override
  Future<List<Drama>> category(String id, {int page = 1}) async => [];
  @override
  Future<DramaDetail> detail(String id) async => DramaDetail(
        id: id,
        name: '',
        videos: const [],
      );
  @override
  Future<String> resolveUrl(DramaVideo v) async => '';
  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;
  @override
  bool get supportsDanmaku => false;
}