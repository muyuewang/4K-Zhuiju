// ignore_for_file: avoid_print
/// 站点型数据源联网探针（pianku）
///
/// 断网时安静跳过，不把全量套件弄红。
/// 手动跑：flutter test test/integration/site_sources_test.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source/site_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Future<T?> guard<T>(String name, Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      print('[$name] 网络或站点不可用，跳过：$e');
      return null;
    }
  }

  test('注册表包含两个新站，且默认源仍是橘汁', () {
    final ids = SourceRegistry.all.map((e) => e.id).toList();
    print('已注册数据源：$ids');
    expect(ids, contains('zhuiju'));
    expect(ids, contains('kanju'));
    expect(ids, contains('pianku'));
    expect(ids.first, 'zhuiju');
    expect(kPiankuSource.lineOrderPolicy.name, 'sourceOrder');
  });

  test('片库 4K：搜索 → 详情 → 首页线路必须是直出线', () async {
    final list = await guard('pk.search', () => kPiankuSource.search('沙海'));
    if (list == null || list.isEmpty) return;
    print('搜索结果 ${list.length} 条，首条「${list.first.name}」id=${list.first.id}');
    expect(list.first.name.trim(), isNotEmpty);

    final d = await guard(
        'pk.detail', () => kPiankuSource.detail(list.first.id));
    if (d == null) return;
    final m = d.sourcesByCn;
    print('线路 ${m.length} 条：${m.keys.toList()}，总条目 ${d.videos.length}');
    expect(m, isNotEmpty);
    print('默认线路：${m.keys.first}');

    // 默认线路必须能解析出可播地址；解析不出来就试下一条，
    // 但首页线路失败要报出来（排序策略就是为它服务的）
    String? good;
    String firstErr = '';
    for (final e in m.entries) {
      try {
        final url = await kPiankuSource.resolveUrl(e.value.first);
        print('  [ok] ${e.key} -> ${url.substring(0, url.length.clamp(0, 90))}');
        good ??= url;
        if (e.key == m.keys.first) break;
      } catch (err) {
        print('  [skip] ${e.key}: $err');
        if (e.key == m.keys.first) firstErr = '$err';
      }
    }
    expect(firstErr, isEmpty,
        reason: '默认线路「${m.keys.first}」解析失败，说明网页源没被沉底');
    expect(good, isNotNull);
    expect(good, matches(RegExp(r'\.(m3u8|mp4)')));
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('片库 4K：网页源必须排在任何直出线路之后', () async {
    // id=100 实测 4 条线：腾讯/奇异/B站 是网页源（from=qq/qiyi/bilibili），
    // 备用线路(wsym3u8) 与 自营4K60帧(mjzy) 是直出，实测均可拉 m3u8。
    // 断言只要求「网页源不在首位」——站点自己把备用线路排前面是合理的，
    // 硬要求自营第一反而会误伤。
    final d = await guard('pk.detail100', () => kPiankuSource.detail('100'));
    if (d == null || d.videos.isEmpty) return;
    final names = d.sourcesByCn.keys.toList();
    print('线路顺序：$names');
    const webNames = ['腾讯', '奇异', 'B站', '爱奇艺', '优酷', '芒果'];
    expect(webNames.any((w) => names.first.contains(w)), isFalse,
        reason: '首位是网页源「${names.first}」，用户第一次点播放必定失败');
    for (final web in webNames) {
      final wi = names.indexWhere((n) => n.contains(web));
      if (wi < 0) continue;
      expect(wi, greaterThan(0), reason: '$web 是网页源，不该排第一');
    }
    // 直出线路要真的能解析出地址
    final direct = names.firstWhere(
        (n) => !webNames.any((w) => n.contains(w)));
    final url = await guard('pk.resolve100',
        () => kPiankuSource.resolveUrl(d.sourcesByCn[direct]!.first));
    if (url == null) return;
    print('直出「$direct」-> ${url.substring(0, url.length.clamp(0, 90))}');
    expect(url, matches(RegExp(r'\.(m3u8|mp4)')));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
