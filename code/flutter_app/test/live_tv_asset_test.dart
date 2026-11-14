/// 打包资源能否真正被加载的回归（**不联网**）。
///
/// 这一组测试存在的理由：前面所有解析测试都是喂字符串进去，
/// 就算 `pubspec.yaml` 里漏了 assets 声明、或者文件名写错了，
/// 那些测试照样全绿 —— 而实际运行时直播页会一片空白。
///
/// 这里直接走 `rootBundle.loadString`，把「声明 → 打包 → 读取 → 解析」
/// 整条链路走一遍，漏配会在这里红。
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/live_tv_source.dart';

void main() {
  // rootBundle 需要 binding；纯 dart 测试里不初始化会报
  // "Binding has not yet been initialized"
  TestWidgetsFlutterBinding.ensureInitialized();

  group('打包资源 live_channels.json', () {
    test('资源文件能被 pubspec 声明并读到（漏配 assets 会在这里红）', () async {
      final text = await rootBundleKey();
      expect(text.isNotEmpty, isTrue, reason: '资源读不到，检查 pubspec.yaml 的 assets');
      expect(text.trimLeft().startsWith('['), isTrue, reason: '顶层必须是数组');
    });

    test('解析出的频道数量合理（不是 0，也不像被截断）', () async {
      final list = await LiveTvLibrary.all();
      expect(list.length, greaterThan(2000),
          reason: '实测探活存活 2553 个，明显偏少说明资源不完整');
    });

    test('每条频道都有 id / name / url 三要素', () async {
      final list = await LiveTvLibrary.all();
      final bad = list
          .where((c) => c.id.isEmpty || c.name.isEmpty || c.url.isEmpty)
          .toList();
      expect(bad, isEmpty,
          reason: '缺字段的条目会导致列表出现点不开的空白卡片');
    });

    test('id 全部唯一（重复会让收藏互相覆盖）', () async {
      final list = await LiveTvLibrary.all();
      final ids = list.map((c) => c.id).toSet();
      expect(ids.length, list.length);
    });

    test('url 全部唯一（打包时已去重）', () async {
      final list = await LiveTvLibrary.all();
      final urls = list.map((c) => c.url).toSet();
      expect(urls.length, list.length);
    });

    test('栏目名都在约定的 7 个之内，不出现打包脚本漏映射的裸分组名', () async {
      final list = await LiveTvLibrary.all();
      final sections = list.map((c) => c.section).toSet();
      for (final s in sections) {
        expect(kLiveSections.contains(s), isTrue,
            reason: '出现了未归类的栏目「$s」，打包脚本的 section_of 需要补');
      }
    });

    test('每个栏目都非空（kLiveSections 里列了但没数据的要删掉）', () async {
      final bySection = await LiveTvLibrary.bySection();
      expect(bySection.keys.toSet(), kLiveSections.toSet(),
          reason: '栏目列表与实际数据不一致');
      for (final e in bySection.entries) {
        expect(e.value, isNotEmpty, reason: '「${e.key}」是空栏目');
      }
    });

    test('栏目分组求和等于总数（没有频道在分组时丢失）', () async {
      final all = await LiveTvLibrary.all();
      final bySection = await LiveTvLibrary.bySection();
      final sum = bySection.values.fold<int>(0, (a, b) => a + b.length);
      expect(sum, all.length);
    });

    test('央卫视栏目里必须有 CCTV 或卫视类频道（这是刚需栏目）', () async {
      final bySection = await LiveTvLibrary.bySection();
      final cctv = bySection['央卫视'] ?? const <LiveChannel>[];
      expect(cctv, isNotEmpty);
      // 不硬编码具体台名（会随探活结果变），只要求存在含 CCTV/卫视 的条目
      final hit = cctv.where((c) =>
          c.name.toUpperCase().contains('CCTV') || c.name.contains('卫视'));
      expect(hit, isNotEmpty, reason: '央卫视栏目里一个央视/卫视都没有，分类映射错了');
    });
  });

  group('LiveTvLibrary 查询能力', () {
    test('搜索命中中文频道名', () async {
      final r = await LiveTvLibrary.search('CCTV');
      expect(r, isNotEmpty);
      expect(
        r.every((c) => c.name.toUpperCase().contains('CCTV') ||
            c.group.toUpperCase().contains('CCTV')),
        isTrue,
      );
    });

    test('空关键词返回空列表（不能返回全部，否则搜索页一进去就糊满）', () async {
      expect(await LiveTvLibrary.search(''), isEmpty);
      expect(await LiveTvLibrary.search('   '), isEmpty);
    });

    test('搜不到时返回空列表而不是抛异常', () async {
      final r = await LiveTvLibrary.search('这个频道名一定不存在zzz999');
      expect(r, isEmpty);
    });

    test('多次调用命中同一份缓存（不是每次都重新解析 631 KB）', () async {
      final a = await LiveTvLibrary.all();
      final b = await LiveTvLibrary.all();
      expect(identical(a, b), isTrue);
    });
  });
}

/// 直接读资源原文，用于断言「能读到」这件事本身。
Future<String> rootBundleKey() async {
  return rootBundle.loadString(kLiveChannelsAsset);
}
