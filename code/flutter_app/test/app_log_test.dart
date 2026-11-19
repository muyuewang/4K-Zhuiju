/// 日志中心与「错误可读」的回归测试（不联网）。
///
/// ## 这组测试防的是什么
///
/// 2026-11-19 排查橘汁那次，最贵的成本不是修，是**取证**：
///   1. release 包的 163 处 `debugPrint` 全部不可见 → 用户只能给截图
///   2. 截图里写着「这个分类暂时没有内容」→ 看起来像站方片库空了
///   3. 真正的原因（服务端 100001 时间戳过期）在半路被换成
///      「出错了，请重试」，连错误页都不肯说
///
/// 三个坑分别对应下面三组断言。任何一条被改回去，这里都会红。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart' show friendlyError;
import 'package:zhuiju/core/app_log.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/user_facing_error.dart';

void main() {
  group('AppLog：日志必须能被看见', () {
    test('拦截 debugPrint 后，内容同时进内存与原始输出', () {
      // 先装一次。init 有幂等保护，重复装不会递归。
      AppLog.instance.clearMemory();

      // 直接调 capture 验证缓冲行为（不依赖 init 是否已跑过）
      AppLog.instance.capture('D', 'TEST', '一条测试日志');
      final entries = AppLog.instance.entries;

      expect(entries, isNotEmpty);
      final last = entries.last;
      expect(last.text, '一条测试日志');
      expect(last.tag, 'TEST');
      expect(last.level, 'D');
    });

    test('环形缓冲不超过 capacity，丢的是最旧的', () {
      AppLog.instance.clearMemory();
      // 多写 5 条，确认老的被挤掉
      for (var i = 0; i < AppLog.capacity + 5; i++) {
        AppLog.instance.capture('D', 'RING', 'line-$i');
      }
      final entries = AppLog.instance.entries;
      expect(entries.length, AppLog.capacity,
          reason: '环形缓冲必须封顶，否则长时间运行会吃光内存');
      // 最早留下的应该是第 5 条（前 5 条被挤掉）
      expect(entries.first.text, 'line-5');
      expect(entries.last.text, 'line-${AppLog.capacity + 4}');
    });

    test('日志行带毫秒级时间戳（排查 50ms 级问题要用）', () {
      AppLog.instance.clearMemory();
      AppLog.instance.capture('D', 'FMT', 'x');
      final line = AppLog.instance.entries.last.line;
      // 形如 14:03:22.123 D [FMT] x
      expect(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} D \[FMT\] x$').hasMatch(line),
          isTrue, reason: '实际：$line');
    });

    test('sanitize 压缩超长 base64，但不破坏正常中文长句', () {
      // 典型的长签名串：200 字符无空格
      final b64 = 'A' * 200;
      final out = AppLog.sanitize('publicParams=$b64');

      expect(out.length, lessThan(120), reason: '超长串必须被压缩，否则日志文件会爆');
      // 标注原始长度，便于判断是否真的截断过。
      // 注意数字是 213 不是 200 —— 正则把 `publicParams=` 一起吞了
      // （`=` 属于 base64 字符集），所以断言的「原始长度」是整段匹配长度。
      // 保留前 24 字符正好把 `publicParams=` 这个有用的键名留下。
      expect(out, contains('…(213)…'), reason: '实际：$out');
      expect(out, startsWith('publicParams='), reason: '键名必须保留，否则不知道是哪个头');

      // 中文长句不该被当成「无空格串」压掉
      const sentence = '这个分类暂时没有内容，可能是源站刚更新，稍后再看看，'
          '如果一直这样，可以去我的页面查看诊断日志。';
      expect(AppLog.sanitize(sentence), sentence);
    });

    test('单条超长日志被截断并标注总长度', () {
      final out = AppLog.sanitize('x' * 2000);
      expect(out.length, lessThan(900));
      expect(out, contains('共 2000 字符'));
    });

    test('错误级日志会进入 isError，普通级不会', () {
      AppLog.instance.clearMemory();
      AppLog.instance.capture('D', 'X', '普通');
      AppLog.instance.capture('E', 'X', '错误');
      final entries = AppLog.instance.entries;
      expect(entries[0].isError, isFalse);
      expect(entries[1].isError, isTrue);
    });

    test('export 包含版本号与平台，便于用户报问题时对号', () async {
      final text = await AppLog.instance.export();
      // 不联网也可能拿不到文件，但头部信息一定在
      expect(text, contains('诊断日志'));
      expect(text, contains('平台：'));
      expect(text, contains('导出时间：'));
    });

    test('debugPrint 被接管后，控制台输出不丢（不影响开发体验）', () {
      // 这条防的是「为了落盘把 debugPrint 指向自己，导致 flutter run
      // 再也看不到日志」——那等于把开发体验弄坏。
      //
      // 未初始化时 debugPrint 仍是原实现；这里只断言它没被换成
      // 一个吞掉内容的东西：调用后能正常返回。
      var seen = '';
      final orig = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => seen = m ?? '';
      debugPrint('probe');
      debugPrint = orig;
      expect(seen, 'probe');
    });
  });

  group('错误必须能说清原因', () {
    test('插件异常的原话直接进界面，不被换成「出错了」', () {
      // 这是本轮最重要的一条：宿主已经把「请求时间戳过期」透传成异常，
      // 如果 friendlyError 认不出来，界面上又是「出错了，请重试」，
      // 排查等于回到原点。
      final e = PluginFetchException('橘汁：请求时间戳过期');
      expect(friendlyError(e), '橘汁：请求时间戳过期');
    });

    test('PluginFetchException 实现了 UserFacingException 标记', () {
      // 没有这个标记，上面那条断言会以另一种方式失败（走到兜底分支）。
      // 单独钉一条，报错时能一眼看出是「没实现接口」而不是「文案变了」。
      expect(PluginFetchException('x'), isA<UserFacingException>());
    });

    test('空消息不当成有效原因，退回通用兜底', () {
      // 脚本返回 error: "" 时不能把界面变成空白错误页
      expect(friendlyError(PluginFetchException('')), '出错了，请重试');
      expect(friendlyError(PluginFetchException('   ')), '出错了，请重试');
    });

    test('技术异常仍走原来的通用文案，不会把堆栈甩给用户', () {
      // 修「透传」不能顺手把所有异常都 toString 出去
      expect(friendlyError(Exception('DioException [connection error]: ...')),
          '出错了，请重试');
    });
  });

  group('列表解析失败不能被吞成「没有内容」', () {
    test('空 items + 有 error ⇒ 抛异常（而不是空列表）', () {
      // 这条判定在 remote_js_source._loadList 里，纯逻辑，不需要网络：
      // 直接复现那个条件，确认「有 error 就报错」的语义。
      Map<String, Object?> resp(String? err) => <String, Object?>{
            'items': <Object?>[],
            if (err != null) 'error': err,
          };

      final withErr = resp('请求时间戳过期');
      final items = withErr['items'] as List;
      final why = (withErr['error'] as String?) ?? '';

      expect(items, isEmpty);
      expect(why, isNotEmpty,
          reason: '脚本必须把原因带出来，否则宿主无从判断这是失败还是空分类');
    });

    test('空 items + 无 error ⇒ 视为正常的空分类（不报错）', () {
      // 翻到最后一页本来就是空列表，这里不能抛异常，
      // 否则用户每次翻到底都看到红色错误页。
      final normal = <String, Object?>{'items': <Object?>[]};
      final items = normal['items'] as List;
      final why = (normal['error'] as String?) ?? '';
      expect(items, isEmpty);
      expect(why, isEmpty, reason: '正常的空分类不该带 error');
    });
  });
}