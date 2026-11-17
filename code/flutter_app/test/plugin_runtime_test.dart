/// 插件运行时的行为。
///
/// 这块的用例几乎都在测**失败路径**，因为正常路径已经由
/// `plugin_script_test.dart` 用真实脚本覆盖了。而失败路径才是这个系统
/// 真正的风险所在——
///
///   实测结论（见 plugin_runtime.dart 顶部）：QuickJS 的死循环
///   **宿主杀不掉**。`timeout` 参数无效，`Isolate.kill()` 也无效。
///   所以「怎么在杀不掉的前提下限制损失」就成了核心逻辑，
///   而这段逻辑一旦错，用户手机就会悄悄发烫。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

void main() {
  group('looksLikeInfiniteLoop 静态筛查', () {
    test('认出三种最常见写法', () {
      expect(looksLikeInfiniteLoop('while(true){}'), isTrue);
      expect(looksLikeInfiniteLoop('while (true) { }'), isTrue);
      expect(looksLikeInfiniteLoop('while(1){}'), isTrue);
      expect(looksLikeInfiniteLoop('while (!!1) {}'), isTrue);
      expect(looksLikeInfiniteLoop('for(;;){}'), isTrue);
      expect(looksLikeInfiniteLoop('for ( ; ; ) { x(); }'), isTrue);
    });

    test('不误伤正常循环', () {
      const ok = [
        'for (var i = 0; i < 10; i++) {}',
        'for (var i in list) {}',
        'while (i < 10) { i++; }',
        'while (node) { node = node.next; }',
        'do { x(); } while (x < 3);',
        // 带条件的 while 是最常见的正常写法
        'while (true !== false) { break; }',
      ];
      for (final code in ok) {
        expect(looksLikeInfiniteLoop(code), isFalse, reason: '误判：$code');
      }
    });

    test('字符串和注释里的 while(true) 不算', () {
      // 这是必须处理的：插件里很可能有一句
      //   var msg = "don't write while(true)";
      // 或者注释里留一句「别写 while(true)」。
      // 不剥离的话，一个注释就能让整个源被拒。
      expect(looksLikeInfiniteLoop('var s = "while(true)";'), isFalse);
      expect(looksLikeInfiniteLoop("var s = 'while(true)';"), isFalse);
      expect(looksLikeInfiniteLoop('// while(true) 千万别这么写'), isFalse);
      expect(looksLikeInfiniteLoop('/* for(;;) */'), isFalse);
    });

    test('真实插件脚本不含死循环', () {
      // 这条是给「有人往正式脚本里加了死循环」兜底的
      final script = _realScript();
      expect(looksLikeInfiniteLoop(script), isFalse);
    });
  });

  group('PluginCallResult', () {
    test('ok / fail 的字段与文案', () {
      final ok = PluginCallResult.ok('hello', const Duration(milliseconds: 12));
      expect(ok.ok, isTrue);
      expect(ok.value, 'hello');
      expect(ok.error, isEmpty);
      expect(ok.toString(), contains('5B'));
      expect(ok.toString(), contains('12ms'));

      final bad = PluginCallResult.fail(
          '超时了', const Duration(milliseconds: 3000));
      expect(bad.ok, isFalse);
      expect(bad.error, '超时了');
      expect(bad.toString(), contains('超时了'));
    });
  });

  group('停用后的行为', () {
    setUp(() => PluginRuntime.instance.resetForTest());
    tearDown(() => PluginRuntime.instance.resetForTest());

    test('初始状态可用', () {
      expect(PluginRuntime.instance.isDisabled, isFalse);
      expect(PluginRuntime.instance.poisonCount, 0);
    });

    test('默认预算是 3 秒', () {
      // 这个值有实际意义：它决定「多慢才算异常」。
      // 实测 20 条解析在几十毫秒内，3 秒是 60 倍余量。
      expect(PluginRuntime.defaultDeadline, const Duration(seconds: 3));
    });
  });
}

/// 读取仓库里的真实插件脚本。
///
/// 测试的 cwd 是 `code/flutter_app`，所以要往上走两层才到仓库根。
/// 两个候选路径都试，是因为将来若把测试跑在别的 cwd 下也能用。
String _realScript() {
  for (final p in const [
    '../../config/plugins/maccms-json.js',
    'config/plugins/maccms-json.js',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f.readAsStringSync();
  }
  fail('找不到插件脚本，cwd=${Directory.current.path}');
}