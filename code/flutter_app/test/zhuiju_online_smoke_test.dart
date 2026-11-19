/// 橘汁源的联网冒烟：列表 / 搜索 / 详情 / 取址四段真打一遍。
///
/// ## 为什么留着这个探针
///
/// 橘汁是本项目里协议最重的一个源（protobuf + RSA 签名 + AES 分片），
/// 2026-11-19 出过一次「所有分类全空、且不报错」的故障，根因是宿主
/// 把签名脚本写的 `Content-Type` 覆盖成了表单类型 —— 而 `parseList`
/// 又把服务端错误吞成空数组，界面上只剩一句「这个分类暂时没有内容」。
///
/// 那次故障之后，静态护栏放在了 `plugin_content_type_and_budget_test.dart`
/// （不联网）。但这个源依赖站方接口，**站方改协议 / 换域名 / 关签名口径
/// 只有真发一次才知道**，所以保留这一条联网探针。
///
/// 判据刻意宽松（只要求「非空 + 拿到 m3u8」），不比对具体片名 ——
/// 站方每天都在上新，写死剧名会天天误报。
///
/// 这是联网探针，**不放在默认 CI 里**：网络不通时它必然红，而那时
/// 代码是对的。跑法：
///
///     flutter test test/zhuiju_online_smoke_test.dart
///
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';

import 'support/quickjs_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late PluginManifest manifest;
  late String script;
  late RemoteJsSource src;

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final index = jsonDecode(
        File('../../config/plugins/index.json').readAsStringSync()) as Map;
    final raw = (index['plugins'] as List)
        .firstWhere((e) => e is Map && e['id'] == 'zhuiju');
    manifest = PluginManifest.fromJson(Map<String, dynamic>.from(raw as Map))!;
    script = File('../../config/plugins/zhuiju.js').readAsStringSync();
    src = RemoteJsSource(LoadedPlugin(manifest: manifest, script: script));
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  test('分类「电视剧」能出内容且带封面', () async {
    final list = await src.category('21');
    print('分类 21: ${list.length} 条');
    expect(list, isNotEmpty, reason:
        '分类为空。先看服务端是不是回了 code=100001（Content-Type 被覆盖）');

    final withCover = list.where((d) => d.cover.path.isNotEmpty).length;
    print('  有封面: $withCover/${list.length}');
    print(list.take(3).map((d) => '  ${d.id} ${d.name} | ${d.remark}').join('\n'));
    expect(withCover, list.length, reason: '封面字段取错时这里会全空');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('搜索能出内容', () async {
    final list = await src.search('庆余年');
    print('搜索「庆余年」: ${list.length} 条');
    expect(list, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('详情能出线路，且集数不受宿主调用预算限制', () async {
    final list = await src.category('21');
    expect(list, isNotEmpty, reason: '列表为空，无法继续');

    // 挑一部集数多的：集数越多越容易撞穿 5000 次宿主调用预算
    DramaDetail? best;
    var bestCount = 0;
    for (final d in list.take(6)) {
      final det = await src.detail(d.id);
      if (det.videos.length > bestCount) {
        bestCount = det.videos.length;
        best = det;
      }
    }
    expect(best, isNotNull, reason: '前 6 部详情全部解析失败');

    final lineCount =
        best!.videos.map((v) => v.source).toSet().length;
    print('详情 ${best.id} ${best.name}: '
        '${best.videos.length} 集 / $lineCount 条线路');
    print('  地区=${best.area} 年份=${best.year} 备注=${best.remark}');
    expect(lineCount, greaterThan(1), reason: '正常应有多条线路');
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('首集能取到可播地址', () async {
    final list = await src.category('21');
    expect(list, isNotEmpty);

    var got = '';
    // 同一个源里不同线路可用率不同，试前 3 部各取首集
    for (final d in list.take(3)) {
      final det = await src.detail(d.id);
      if (det.videos.isEmpty) continue;
      try {
        final url = await src.resolveUrl(det.videos.first);
        if (url.startsWith('http')) {
          got = url;
          print('取址成功（${d.name}）: '
              '${url.length > 90 ? '${url.substring(0, 90)}…' : url}');
          break;
        }
      } catch (e) {
        print('  ${d.name} 取址失败: $e');
      }
    }
    expect(got, startsWith('http'), reason: '前 3 部都取不到可播地址');
  }, timeout: const Timeout(Duration(seconds: 180)));
}