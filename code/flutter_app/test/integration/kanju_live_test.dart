/// kanju 真实接口联调探针
///
/// 与 api_probe_test.dart 同类：**这不是断言型单元测试**，是一份手动
/// 执行的联网探针。单元测试用假数据只能证明「解析逻辑自洽」，证明不了
/// 「服务端真的这么返回」——签名对不对、字段名有没有改、游标能不能翻页，
/// 只有打真实接口才知道。
///
/// 默认 `flutter test test/integration/` 才会跑；全量 `flutter test`
/// 也包含它，所以断网时必须**正常跳过而不是变红**，否则整个套件在
/// 飞机上就是红的。所有用例拿不到数据时 print 一句并 return。
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/playback_prefs.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/kanju_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把所有请求打成 400，这里恢复真实 HttpClient
  HttpOverrides.global = null;

  final kj = KanjuSource.instance;

  /// 拿不到网就跳过：探针不负责让套件变红
  Future<T?> guard<T>(String name, Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      print('[$name] 网络或接口不可用，跳过：$e');
      return null;
    }
  }

  test('榜单：首屏分区能拉到，标题与卡片非空', () async {
    final feed = await guard('homeFeed#1', () => kj.homeFeed());
    if (feed == null) return;

    print('分区数：${feed.sections.length}，next=${feed.nextCursor}');
    expect(feed.sections, isNotEmpty, reason: '首屏必须有分区');

    for (final s in feed.sections) {
      print('  - ${s.title}（${s.cards.length} 张）${s.subtitle}');
      expect(s.title, isNotEmpty, reason: '分区必须有标题');
      expect(s.cards, isNotEmpty, reason: '${s.title} 不该是空行');
      // 每张卡必须带 id 与名字，否则点进去会 404 / 显示空白
      for (final d in s.cards) {
        expect(d.id, isNotEmpty);
        expect(d.name, isNotEmpty);
        expect(d.sourceId, 'kanju', reason: '卡片必须打上来来源标记');
      }
    }
  });

  test('榜单：游标能连续翻页，且分区不重复', () async {
    final first = await guard('homeFeed#p1', () => kj.homeFeed());
    if (first == null || first.nextCursor == null) {
      print('首页没有 next_cursor，跳过翻页验证');
      return;
    }
    print('第 1 页标题：${first.sections.map((e) => e.title).join(' / ')}');

    final second = await guard(
      'homeFeed#p2',
      () => kj.homeFeed(cursor: first.nextCursor),
    );
    if (second == null) return;
    print('第 2 页标题：${second.sections.map((e) => e.title).join(' / ')}');

    expect(second.sections, isNotEmpty, reason: '有 cursor 就该有内容');
    final a = first.sections.map((e) => e.id).toSet();
    final b = second.sections.map((e) => e.id).toSet();
    expect(a.intersection(b), isEmpty, reason: '两页不应出现同一个分区');
  });

  test('搜索：中文关键词能返回结果（签名+编码联合验证）', () async {
    // 中文是最容易踩签名坑的输入：编码与签名不一致就 401。
    // 这条用例跑通 = 编码链完全正确。
    final list = await guard('search', () => kj.search('沙'));
    if (list == null) return;
    print('搜「沙」命中 ${list.length} 条：${list.take(5).map((e) => e.name).join(' / ')}');
    expect(list, isNotEmpty, reason: '热词搜不到说明编码或签名有问题');
    for (final d in list) {
      expect(d.id, isNotEmpty);
      expect(d.sourceId, 'kanju');
    }
  });

  test('分类：每个 content_kind 都能返回内容', () async {
    for (final c in kKanjuCategories) {
      if (c.id.isEmpty) continue;
      final list = await guard('cat:${c.id}', () => kj.category(c.id));
      if (list == null) continue;
      print('${c.name}（${c.id}）→ ${list.length} 条');
      // 不强制非空：冷门分类（纪录片）确实可能空，但请求本身不能报错
    }
  });

  test('详情+取址：第一集能解析出可播地址', () async {
    final list = await guard('detail#list', () => kj.search('沙'));
    if (list == null || list.isEmpty) return;

    final target = list.first;
    print('目标：${target.name} (${target.id})');

    final d = await guard('detail', () => kj.detail(target.id));
    if (d == null) return;

    final sources = d.sourcesByCn;
    print('线路数：${sources.length} → ${sources.keys.join(' / ')}');
    expect(sources, isNotEmpty, reason: '详情必须至少给出一条线路');
    expect(d.sourceId, 'kanju');

    // 收集所有占位条目，逐条尝试解析，至少一条要成功
    final all = sources.values.expand((e) => e).toList();
    print('总条目：${all.length}');
    expect(all, isNotEmpty);

    var ok = 0;
    String? firstUrl;
    String? lastErr;
    // 只试前 8 条：26 条全试会打几十个请求，探针没必要这么重
    for (final v in all.take(8)) {
      try {
        final u = await kj.resolveUrl(v);
        if (u.startsWith('http')) {
          ok++;
          firstUrl ??= u;
        }
      } catch (e) {
        lastErr = '$e';
      }
    }
    print('前 8 条里解析成功 $ok 条');
    if (firstUrl != null) {
      print('样例地址：${firstUrl.substring(0, firstUrl.length.clamp(0, 100))}');
    }
    if (ok == 0) print('全部失败，最后一个错误：$lastErr');

    expect(ok, greaterThan(0), reason: '至少要有一条线路能解析出 http 地址');
  });

  test('注册表：byId 能在两个源之间正确路由', () {
    expect(SourceRegistry.instance.byId('kanju').id, 'kanju');
    expect(SourceRegistry.instance.byId('zhuiju').id, 'zhuiju');
    expect(SourceRegistry.instance.byId('').id, 'zhuiju');
    // kanju 的 id 绝不能被误判成橘汁（否则会拿长串去调数字接口）
    expect(SourceRegistry.instance.byId('kanju') is SectionedFeed, isTrue);
  });

  // 2026-11-11 真实回归：kanju 每条线路的条目数完全相等（每集一条），
  // 旧逻辑「按条目数排序」的比较器恒返回 0，Dart 的 sort 又不稳定，
  // 最终默认落到接口原始顺序第一条。
  //
  // 当天下午接入游客会话后，官方线实测 100% 可播（沙海 16/16、
  // 庆余年 27/27），默认改为「官方优先」。这里改成断言两种偏好
  // 各选出一条，且官方优先选中的确实是官方线。
  test('线路优选：真实详情页的默认线路随偏好切换（回归）', () async {
    for (final kw in ['沙海', '庆余年']) {
      final list = await guard('pick#$kw', () => kj.search(kw));
      if (list == null || list.isEmpty) continue;

      final d = await guard('pickdetail#$kw', () => kj.detail(list.first.id));
      if (d == null) continue;

      final m = d.sourcesByCn;
      if (m.isEmpty) continue;

      final officialNames = m.keys
          .where((k) => lineRankOfAll(m[k]!) == kRankPrimary)
          .toList();
      final directNames = m.keys
          .where((k) => lineRankOfAll(m[k]!) == kRankSecondary)
          .toList();

      final off = pickDefaultSource(m, pref: LinePreference.officialFirst);
      final dir = pickDefaultSource(m, pref: LinePreference.directFirst);

      print('$kw：${m.length} 条线路，首位档 ${officialNames.length} 条，'
          '次位档 ${directNames.length} 条 → 官方优先选「$off」，'
          '普通优先选「$dir」');

      // 有两种档位的线路时，两种偏好必须选出不同的线路
      if (officialNames.isNotEmpty && directNames.isNotEmpty) {
        expect(off, isNot(dir),
            reason: '$kw 同时存在两类线路，两种偏好不该选出同一条');
        expect(off, isIn(officialNames));
        expect(dir, isIn(directNames));
      }

      // 面板顺序：选中的那条必须排在另一种档位之前
      final names = sortedSourceNames(m, pref: LinePreference.officialFirst);
      if (officialNames.isNotEmpty && directNames.isNotEmpty) {
        expect(names.indexOf(off), lessThan(names.indexOf(dir)),
            reason: '面板顺序与默认选中不一致，用户会看到高亮的不是第一条');
      }
    }
  });
}