/// 远程插件配置的测试辅助。
///
/// ## 为什么需要它
///
/// 2026-11-17 的架构反转后，注册表**不内置任何源**：所有源都由
/// `config/plugins/index.json` 声明、运行时装入。所以「源是否已登记」
/// 这个问题的答案不再在 Dart 代码里，而在那份 JSON 里。
///
/// 由此测试断言也要换个方向：不再问「注册表的 `_all` 里有它吗」，
/// 而是问「`index.json` 里声明了它吗」。后者才是真正的不变量——
/// 一个源可以在代码里写得很完整，但配置里漏了它就等于不存在，
/// 而现象是「用户在切源面板里根本看不到这个源」，没有任何报错。
///
/// ## 为什么直接读文件
///
/// 这些是**离线契约测试**：不联网、不启动 QuickJS、不构造 RemoteJsSource。
/// 直接读仓库里的 JSON 既快又准，坏处只是路径依赖（相对 `flutter test`
/// 的工作目录）。路径写错会立刻报 FileSystemException，不会静默通过。
library;

import 'dart:convert';
import 'dart:io';

/// 索引文件路径。`flutter test` 的当前目录是 `code/flutter_app`。
const String kIndexPath = '../../config/plugins/index.json';

/// 索引里声明的全部源 id。
Set<String> declaredSourceIds() {
  final file = File(kIndexPath);
  if (!file.existsSync()) {
    throw StateError('找不到 $kIndexPath，测试的当前目录不对？');
  }
  final raw = jsonDecode(file.readAsStringSync());
  if (raw is! Map) throw StateError('index.json 不是对象');
  final list = raw['plugins'];
  if (list is! List) throw StateError('index.json 缺 plugins 数组');

  final out = <String>{};
  for (final one in list) {
    if (one is Map && one['id'] is String) {
      out.add(one['id'] as String);
    }
  }
  return out;
}

/// 索引里某个源的原始条目（Map）。找不到返回 null。
Map<String, dynamic>? declaredEntry(String id) {
  final file = File(kIndexPath);
  final raw = jsonDecode(file.readAsStringSync());
  if (raw is! Map) return null;
  final list = raw['plugins'];
  if (list is! List) return null;
  for (final one in list) {
    if (one is Map && one['id'] == id) {
      return Map<String, dynamic>.from(one);
    }
  }
  return null;
}