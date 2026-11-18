/// 插件索引的整体校验：19 个源必须全部能被宿主接受。
///
/// 单个源的脚本测试只验证「解析逻辑」，这里验证的是「配置本身」——
/// id 重复、脚本路径写错、signEntry 拼错、请求头黑名单命中……
/// 任何一种都会让该源在应用里凭空消失，而且没有任何提示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

void main() {
  test('index.json 里 19 个源全部合法且脚本齐全', () {
    final index = File('../../config/plugins/index.json');
    expect(index.existsSync(), isTrue);
    final raw = jsonDecode(index.readAsStringSync()) as Map;
    final list = raw['plugins'] as List?;
    expect(list, isNotNull);

    final ids = <String>{};
    for (final entry in list!) {
      final m = PluginManifest.fromJson(entry);
      expect(m, isNotNull, reason: '配置无法解析：$entry');
      expect(m!.id, isNotEmpty);
      expect(ids.add(m.id), isTrue, reason: 'id 重复：${m.id}');
      expect(m.validate(), isNull, reason: '${m.id} 校验失败：${m.validate()}');

      final script = File('../../${m.script}');
      expect(script.existsSync(), isTrue,
          reason: '${m.id} 的脚本不存在：${script.path}');
      final code = script.readAsStringSync();
      expect(code.trim().isNotEmpty, isTrue, reason: '${m.id} 的脚本是空的');
      expect(looksLikeInfiniteLoop(code), isFalse,
          reason: '${m.id} 的脚本含疑似死循环，宿主会拒绝装载');
    }

    expect(list.length, 19, reason: '19 个源必须全部插件化，一个都不能漏');
    // 用户明确点名的 6 个曾缺失源（橘汁已按用户要求移除）
    for (final id in const [
      'pianku', 'jisu', 'kvm4k', 'kanju', 'ddys', 'sanjiaozhou'
    ]) {
      expect(ids.contains(id), isTrue, reason: '$id 仍然缺失');
    }
  });
}
