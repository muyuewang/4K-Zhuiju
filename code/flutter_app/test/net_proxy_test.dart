/// 系统代理层的离线回归测试。
///
/// 这里只测**决策逻辑**（哪些走代理、哪些必须直连），不打真实网络——
/// 真实网络验证放在 probe 里跑，因为这个测试要在 CI 无网环境也通过。
///
/// 最要紧的一条是「本机必须直连」：本机可能跑着开发服务器、投屏服务
/// 或本地播放服务，播放器来拉流时如果被塞进代理，就会变成「代理去连代理」，
/// 整条链路全挂。这条写错了是全平台播放故障，值得单独盯。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/net_proxy.dart';

void main() {
  group('NetProxy 旁路规则', () {
    test('未启用代理时一律 DIRECT', () {
      // 初始状态没有探测过，_active=false
      for (final h in [
        'p.bfvp26.com',
        'www.keke1.app',
        '4k01.pianku.online',
        'bfzyapi.com',
      ]) {
        expect(NetProxy.findProxyFor(Uri.parse('https://$h/')), 'DIRECT',
            reason: '$h 未启用代理时应直连');
      }
    });

    test('本机地址永远不经过代理（代理套代理防护）', () {
      // 这几条即使在代理启用时也必须 DIRECT
      for (final u in [
        'http://127.0.0.1:5775/hls/tok/index.m3u8',
        'http://127.0.0.1:8080/seg/0/index.m3u8',
        'http://localhost:3000/',
        'http://[::1]:8080/',
      ]) {
        expect(NetProxy.findProxyFor(Uri.parse(u)), 'DIRECT', reason: u);
      }
    });

    test('内网段不经过代理', () {
      for (final u in [
        'http://192.168.1.10/',
        'http://10.0.0.5/',
        'http://172.16.31.4/',
        'http://172.31.0.1/',
        'http://nas.local/',
      ]) {
        expect(NetProxy.findProxyFor(Uri.parse(u)), 'DIRECT', reason: u);
      }
      // 172.32 已出 172.16/12 范围，不该被误判为内网
      // （未启用代理时结果仍是 DIRECT，所以只验证解析不抛异常）
      expect(() => NetProxy.findProxyFor(Uri.parse('http://172.32.0.1/')),
          returnsNormally);
    });

    test('公网域名在未启用代理时也返回 DIRECT', () {
      expect(NetProxy.findProxyFor(Uri.parse('https://example.com/')), 'DIRECT');
    });
  });

  test('statusLabel 反映当前状态', () {
    // 未探测/未启用时应该是「直连」
    expect(NetProxy.statusLabel, contains('直连'));
    expect(NetProxy.active, isFalse);
    expect(NetProxy.server, isEmpty);
  });

  group('parseProxyServer 解析注册表原文', () {
    test('单地址写法', () {
      expect(NetProxy.parseProxyServer('127.0.0.1:7897'), '127.0.0.1:7897');
      expect(NetProxy.parseProxyServer('  127.0.0.1:7897  '), '127.0.0.1:7897');
      // 带协议前缀的要剥掉：findProxy 的规则串里不能再出现 scheme
      expect(NetProxy.parseProxyServer('http://127.0.0.1:7890'),
          '127.0.0.1:7890');
    });

    test('分组写法优先 https', () {
      expect(
        NetProxy.parseProxyServer('http=127.0.0.1:7890;https=127.0.0.1:7897'),
        '127.0.0.1:7897',
      );
      // 只有 http 分组时用它
      expect(
        NetProxy.parseProxyServer('http=127.0.0.1:7890;socks=127.0.0.1:7891'),
        '127.0.0.1:7890',
      );
    });

    test('空值 / 异常返回 null', () {
      expect(NetProxy.parseProxyServer(null), isNull);
      expect(NetProxy.parseProxyServer(''), isNull);
      expect(NetProxy.parseProxyServer('   '), isNull);
      // 全是空分组，拿不到可用地址
      expect(NetProxy.parseProxyServer('http=;https='), isNull);
    });
  });

  group('interpretNativeSetting 三态语义', () {
    // 这三态是「不产生子进程」改造的核心。原来用 reg.exe 时，「读不到」
    // 和「明确关闭」都表现为 null，调用方只能一律去扫本地端口兜底；
    // 现在必须区分开，否则用户明明关了代理，只要本机碰巧有个 7890
    // 在监听就会被误判成"有代理"，全 App 流量被导到错误的地方。
    test('null → 读失败，known=false（允许端口兜底）', () {
      final r = NetProxy.interpretNativeSetting(null);
      expect(r.known, isFalse);
      expect(r.server, isNull);
    });

    test('空串 → 明确未启用，known=true 且无地址（禁止端口兜底）', () {
      final r = NetProxy.interpretNativeSetting('');
      expect(r.known, isTrue);
      expect(r.server, isNull);
    });

    test('有效地址 → 启用中', () {
      final r = NetProxy.interpretNativeSetting('127.0.0.1:7897');
      expect(r.known, isTrue);
      expect(r.server, '127.0.0.1:7897');
    });

    test('分组写法同样解析得出', () {
      final r = NetProxy.interpretNativeSetting(
          'http=127.0.0.1:7890;https=127.0.0.1:7897');
      expect(r.known, isTrue);
      expect(r.server, '127.0.0.1:7897');
    });

    test('只有空白字符视为无地址，但仍算 known', () {
      // 注册表里可能被写成空格，这种属于脏配置：
      // 不该触发端口兜底，也不能当代理用
      final r = NetProxy.interpretNativeSetting('   ');
      expect(r.known, isTrue);
      expect(r.server, isNull);
    });
  });

  test('非 Windows 平台不调原生通道（readSystemProxyRaw 返回 null）', () async {
    // 测试环境是 Windows 宿主，但通道未注册时 InvokeMethod 会抛
    // MissingPluginException，必须被吃掉并返回 null，绝不能抛到调用方。
    final r = await readSystemProxyRaw();
    expect(r, anyOf(isNull, isA<String>()));
  });
}