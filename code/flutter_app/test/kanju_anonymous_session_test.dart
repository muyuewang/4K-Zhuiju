/// 真实端点验证：看剧匿名会话解锁官方线（联网探针，2026-11-23）。
///
/// 不是断言型单测，是一份「宿主新能力是否真的生效」的实证：
/// 用真实的 kanju.ai + 真实清单配置 + 真实脚本，走完整宿主链路，
/// 确认 bootstrap 引导拿到 cookie 后官方线换票从 401 变成功。
///
/// 判据刻意宽松（站点每天上新）：只要能换出 http(s) 地址即可。
/// 站点挂了/改签名时会失败——这是探针的意义，不是误报。
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';

import 'support/quickjs_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = null; // 联网探针需要真实网络
    expect(ensureQuickJsLibrary(), isTrue);
    PluginRuntime.instance.resetForTest();
    RemoteJsSource.resetForTest();
  });

  test('真实看剧源：匿名引导后官方线能换出地址', () async {
    // 从真实清单加载 kanju
    final cfg = File('../../config/plugins/index.json').readAsStringSync();
    final list = jsonDecode(cfg)['plugins'] as List;
    final raw = list.firstWhere((e) => e['id'] == 'kanju');
    final manifest = PluginManifest.fromJson(raw)!;

    // 前置校验：清单必须配了引导与 cookieJar（防止有人误删）
    expect(manifest.cookieJar, isTrue, reason: '看剧必须开 cookieJar 才能回送会话');
    expect(manifest.bootstrapRequest, isNotNull,
        reason: '看剧必须配 bootstrap 才能自动建立游客会话');
    expect(manifest.bootstrapRequest!.path, '/v1/users/anonymous');

    final script = File('../../${manifest.script}').readAsStringSync();
    final src = RemoteJsSource(LoadedPlugin(manifest: manifest, script: script));

    // 走真实详情 → 取第201集 → 官方线换票
    const dramaId =
        'av_P-2fvsUWEahkU1ofbAB1UZI7ehaRWVSzZKiwoEzs1_oIaPbKzyKBl17pziV2cPhM9pFDJhgikk983lI';
    final d = await src.detail(dramaId);
    expect(d.videos.isNotEmpty, isTrue, reason: '详情拿不到剧集');

    print('剧名: ${d.name}');
    print('线路数: ${d.videos.map((v) => v.sourceCn).toSet().length}');

    // 找一条官方线（resolveRequired 或 sourceCn 含"官方"）
    final official = d.videos.firstWhere(
      (v) => v.sourceCn.contains('官方'),
      orElse: () => d.videos.first,
    );
    print('测试线路: ${official.sourceCn}');

    final url = await src.resolveUrl(official);
    print('换出的地址: ${url.substring(0, url.length.clamp(0, 120))}');

    expect(url.startsWith('http'), isTrue,
        reason: '官方线换票失败，没拿到 http 地址（可能又回 401 了）');
  }, timeout: const Timeout(Duration(seconds: 90)));
}