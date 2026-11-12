/// 「超时了但连接没关」的回归测试。
///
/// ## 这个缺陷为什么必须盯住
///
/// 用户现象：橘汁源在分类页反复下拉刷新，越刷越坏，最后稳定报
/// 「连接超时，请检查网络」；而**杀掉 App 重开就秒出**。
///
/// 「重开就好」是决定性判据——网络侧的问题不会因为重启 App 自愈，
/// 所以坏掉的一定是**进程内的资源**。
///
/// 旧实现的写法是：
///
/// ```dart
/// return await _postOnce(path, params).timeout(remain);
/// ```
///
/// `.timeout()` 只让**等待者**不再等，**不会取消底层请求**。Dart 的
/// `Future` 没有取消语义，那个 Dio 请求照样在跑，socket 照样开着：
/// 连接已建立就继续等响应（最长 receiveTimeout 15s），还在握手就继续
/// 握（最长 connectTimeout 8s）。界面早就显示失败了，进程里却还挂着
/// 一条条真实连接。
///
/// 于是每次下拉刷新都在旧连接还没死的时候再叠一条新的。手机上 fd
/// 有配额、NAT 会话表也有配额，攒够就再也连不出去——`connect()` 直接
/// 挂到超时，用户看到的就是「连接超时」；而杀进程会把所有 socket
/// 立刻还给系统，所以「重开秒出」。
///
/// ## 这个测试怎么证明
///
/// 起一个**只收不回**的裸 TCP 服务器（`ServerSocket`），统计它当前
/// 认为还开着的连接数——这等价于「客户端有没有真的把这条连接放掉」。
///
///   - 客户端只 `.timeout()` → 连接数停在 N 不降（僵尸连接）
///   - 客户端 `cancel()`     → 连接数掉回 0（socket 被 abort）
///
/// 断言直接盯 `ZhuijuApi` 的真实实现，不另写一份逻辑，避免「测的是
/// 复制品，不是产品代码」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';

/// 只接收、永不响应的服务器。
///
/// 用 `ServerSocket` 而不是 `HttpServer`：要观测的正是「TCP 连接有没有
/// 被客户端掐掉」，`HttpServer` 会在上层把这种细节抹平。
class _BlackholeServer {
  late final ServerSocket _ss;
  final _live = <Socket>{};

  int get openConnections => _live.length;

  /// 累计接受过的连接数（用来确认「确实连上了」，而不是根本没连）
  int accepted = 0;

  Future<void> start() async {
    _ss = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _ss.listen((s) {
      accepted++;
      _live.add(s);
      // 永不写响应；连接被对端关掉（RST/FIN）时 done 走到这里
      s.listen((_) {}, onDone: () => _live.remove(s), onError: (_) => _live.remove(s));
    });
  }

  int get port => _ss.port;

  /// 等到「服务端认为还开着的连接数」降到 [target] 以下，最多等 [limit]。
  ///
  /// **为什么不用固定 sleep**：连接关闭是异步的——客户端 abort 之后，
  /// FIN/RST 要传到对端，内核才通知 accept 侧的 socket，Dart 再把
  /// `onDone` 排进事件循环。这一串在机器空闲时几十毫秒就走完，但在
  /// 跑着整个测试套件、CPU 被占满时可能拖到几百毫秒。
  ///
  /// 写死 `await Future.delayed(600ms)` 就是在赌这个时间够用：平时必过，
  /// 偶尔就红一次，然后被人当成「测试不稳定」重跑掉——那等于把这道
  /// 防线废了。轮询只等「实际发生」，快的时候 10ms 就返回，慢的时候
  /// 也照样能等到，既稳又不浪费。
  Future<int> waitUntilClosed({
    int target = 0,
    Duration limit = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      if (_live.length <= target) return _live.length;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return _live.length;
  }

  Future<void> stop() async {
    // 先拷一份再销毁：destroy() 会触发 socket 的 onDone 回调，而那个
    // 回调会从 _live 里移除元素。直接在这里 for-in 遍历 _live 就成了
    // 「边遍历边修改」，Dart 会抛 ConcurrentModificationError。
    for (final s in _live.toList()) {
      s.destroy();
    }
    _live.clear();
    await _ss.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late _BlackholeServer server;
  late String originalBaseUrl;
  late Duration originalDeadline;

  setUp(() async {
    originalBaseUrl = ZhuijuApi.baseUrl;
    originalDeadline = ZhuijuApi.retryDeadline;
    server = _BlackholeServer();
    await server.start();
    ZhuijuApi.baseUrl = 'http://127.0.0.1:${server.port}';
    // 把 18 秒的总期限压到 300ms，测试才跑得快；被测逻辑完全一致
    ZhuijuApi.retryDeadline = const Duration(milliseconds: 300);
  });

  tearDown(() async {
    ZhuijuApi.baseUrl = originalBaseUrl;
    ZhuijuApi.retryDeadline = originalDeadline;
    await server.stop();
  });

  test('超时之后必须真的掐断连接，不能留僵尸 socket', () async {
    // 请求必然失败：服务器只收不回
    await expectLater(
      ZhuijuApi.instance.category('21'),
      throwsA(anything),
      reason: '服务器永不响应，请求必须失败',
    );

    expect(server.accepted, greaterThan(0), reason: '先确认请求确实连到了服务器，否则这测试什么都没验证');

    // 轮询等连接真正被放掉，而不是赌一个固定的 sleep 时长
    final left = await server.waitUntilClosed();

    expect(
      left,
      0,
      reason: '超时后连接应当已被 abort。若这里大于 0，说明只是放弃了 await、'
          '底层请求仍在飞——这就是「越刷越糟、重开就好」的根因。',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('连续多次超时不应让连接数累积', () async {
    // 模拟用户连点/连拉：每次都失败，但每次都必须把连接还回去
    for (var i = 0; i < 5; i++) {
      await expectLater(ZhuijuApi.instance.category('21'), throwsA(anything));
    }
    final left = await server.waitUntilClosed();

    expect(server.accepted, greaterThanOrEqualTo(5));
    expect(
      left,
      0,
      reason: '5 次连续超时后连接数必须归零。若随次数增长，就是连接泄漏，'
          '累计到 fd 配额后会表现为「连不出去 = 连接超时」。',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}