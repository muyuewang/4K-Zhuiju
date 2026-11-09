/// 版本号一致性
///
/// 这不是「多此一举」的测试：version.dart 里的 kAppVersion/kAppBuild 是
/// 手写常量，pubspec.yaml 的 version 是另一处。两者一旦漂移，界面上
/// （我的 → 关于、桌面侧栏）显示的就是错的版本号，而发版脚本读的是
/// pubspec —— 结果就是「用户报的版本号在发布列表里找不到」。
/// v1.4.0 发版时真的漏改了，界面还显示 1.3.0(5)。这里把它钉死。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/version.dart';

void main() {
  group('版本号与 pubspec 同步', () {
    test('kAppVersion / kAppBuild 与 pubspec.yaml 的 version 一致', () {
      final f = File('pubspec.yaml');
      expect(f.existsSync(), isTrue, reason: '应在 flutter_app 目录下运行测试');
      final raw = f.readAsStringSync();

      // 只认行首的 version:，避免匹配到注释里的示例
      final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)',
              multiLine: true)
          .firstMatch(raw);
      expect(m, isNotNull, reason: 'pubspec.yaml 里应有 version: x.y.z+N');

      final pubVersion = m!.group(1)!;
      final pubBuild = m.group(2)!;

      expect(kAppVersion, pubVersion,
          reason: 'core/version.dart 的 kAppVersion 落后于 pubspec.yaml');
      expect(kAppBuild, pubBuild,
          reason: 'core/version.dart 的 kAppBuild 落后于 pubspec.yaml');
    });

    test('完整版本串格式正确', () {
      expect(kAppVersionFull, '$kAppVersion ($kAppBuild)');
      expect(RegExp(r'^\d+\.\d+\.\d+ \(\d+\)$').hasMatch(kAppVersionFull), isTrue);
    });

    test('应用标题非空且不含版本号', () {
      expect(kAppTitle.trim(), isNotEmpty);
      expect(kAppTitle.contains(kAppVersion), isFalse);
    });
  });
}