/// 守住「超时必须能真的取消」这条铁律。
///
/// ## 为什么用扫源码而不是跑网络
///
/// 真正的行为回归在 `api_cancel_on_timeout_test.dart` 里（起一个只收不回
/// 的服务器，数连接有没有被放掉）。但这个项目有 11 个 Dio 实例、3 个裸
/// `HttpClient`，以后还会加源。每加一个出口就可能重新引入同一个坑，
/// 而那个坑**在开发机上几乎看不出来**——它是靠「用久了连接攒满」才
/// 显形的，本地随便跑几次都是通的。
///
/// 所以再加一道纯静态的闸：把「哪些文件开了网络出口」和「它有没有
/// 配套的取消/关闭语句」对齐检查。它不验证运行行为，只保证**写法**
/// 不倒退——发现得快、成本几乎为零。
///
/// ## 背景：这个坑长什么样
///
/// 橘汁源曾经这样写：
///
/// ```dart
/// return await _postOnce(path, params).timeout(remain);
/// ```
///
/// `.timeout()` 只让**等待方**放弃，Dart 的 Future 没有取消语义，底层
/// 请求会带着 socket 继续跑。界面上早就报错了，进程里还挂着一条真实
/// 连接。用户反复下拉刷新 → 僵尸连接越攒越多 → 本地端口和 NAT 会话表
/// 被占满 → 新的 connect 卡满超时 → 「连接超时，请检查网络」；
/// 杀掉 App 会把所有 socket 一次性还给系统，所以「重开就秒出」。
///
/// 实测（`api_cancel_on_timeout_test.dart`）：修之前连续 5 次超时会留下
/// 5 条僵尸连接，修之后为 0。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 逐文件读取 lib 下的所有 Dart 源码
///
/// 注意：**不能在 main() 顶层调用**。`expect` 需要测试运行上下文，
/// 在 test() 之外用它只有两条路——要么抛 OutsideTestException 直接
/// 让整个文件加载失败，要么静默不报（更糟）。所以放在 setUpAll 里。
Map<String, String> _readLib() {
  final root = Directory('lib');
  final out = <String, String>{};
  for (final f in root.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    out[f.path.replaceAll(r'\', '/')] = f.readAsStringSync();
  }
  return out;
}

/// 去掉注释行，只留真正的代码。
///
/// 不这样做会误报：`net_proxy.dart` 的文档注释里就写着
/// 「`HttpOverrides.global` 卡在 `HttpClient()` 工厂这一层」，
/// 按纯字符串搜会把这段说明当成一次真实创建，逼着人去改注释迁就测试
/// ——那是本末倒置。测试要盯的是代码，注释怎么描述都无所谓。
String _codeOnly(String src) {
  final out = <String>[];
  for (final line in src.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('//')) continue;
    out.add(line);
  }
  return out.join('\n');
}

void main() {
  late Map<String, String> files;

  setUpAll(() {
    expect(Directory('lib').existsSync(), isTrue,
        reason: '测试必须从 flutter_app 目录运行');
    files = _readLib().map((k, v) => MapEntry(k, _codeOnly(v)));
    expect(files, isNotEmpty);
  });

  test('用 Dio 且外包 .timeout() 的文件必须带 CancelToken', () {
    final offenders = <String>[];

    files.forEach((path, src) {
      // 只看「自己 new 了 Dio」的文件：这些才有连接池，才谈得上泄漏
      if (!src.contains('Dio(')) return;
      // 没有外包 .timeout() 的，靠 dio 内建超时；
      // dio 到点会调 request.abort()，是安全的
      if (!src.contains('.timeout(')) return;

      final hasToken = src.contains('CancelToken');
      final hasCancel = src.contains('.cancel(');
      if (!hasToken || !hasCancel) {
        offenders.add('$path  (CancelToken=$hasToken, cancel()=$hasCancel)');
      }
    });

    expect(
      offenders,
      isEmpty,
      reason: '这些文件在 Dio 请求外面套了 .timeout()，却没有 CancelToken：\n'
          '${offenders.join('\n')}\n\n'
          '.timeout() 只让等待方放弃，底层请求和 socket 还活着。超时后必须\n'
          'token.cancel()，否则每次失败都漏一条连接，攒满后整个 App 连不出去。',
    );
  });

  test('自己 new HttpClient 的文件必须在 finally 里 close', () {
    final offenders = <String>[];

    files.forEach((path, src) {
      // 只认「直接用构造器创建」的：HttpOverrides 里那种是覆写工厂，不在此列
      if (!src.contains('HttpClient()')) return;
      // force: true 是关键：温和的 close 会等已有连接自然结束，
      // 半死不活的连接会把端口一直占着，等价于没关。
      if (!src.contains('close(force: true)')) {
        offenders.add(path);
      }
    });

    expect(
      offenders,
      isEmpty,
      reason: '这些文件创建了 HttpClient 却没有 close(force: true)：\n'
          '${offenders.join('\n')}\n\n'
          'HttpClient 不关闭就一直占着本地端口，反复换源/重试后会耗尽。',
    );
  });

  test('这些关键出口确实已经被覆盖到（防止上面两个断言因改名而失效）', () {
    // 如果哪天有人重命名了这些文件，上面两条会「一个都没检查到」而
    // 静默通过——那是假绿。这里钉住必须存在的出口清单。
    for (final must in [
      'lib/core/api.dart',
      'lib/core/source/maccms_api_source.dart',
      'lib/core/source/site_http.dart',
    ]) {
      expect(files.containsKey(must), isTrue, reason: '$must 不见了，检查是否改名');
      expect(
        files[must]!.contains('CancelToken'),
        isTrue,
        reason: '$must 的取消机制丢了',
      );
    }
  });
}