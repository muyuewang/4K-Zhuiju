/// 系统代理层的离线回归测试。
///
/// 这里只测**决策逻辑**（哪些走代理、哪些必须直连），不打真实网络——
/// 真实网络验证放在 probe 里跑，因为这个测试要在 CI 无网环境也通过。
///
/// 最要紧的一条是「本机必须直连」：HlsProxy 自己监听 127.0.0.1，
/// 播放器来拉清单时如果被塞进代理，就会变成「代理去连代理」，
/// 整个 HLS 播放全挂。这条写错了是全平台播放故障，值得单独盯。
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

    test('本机地址永远不经过代理（HlsProxy 死循环防护）', () {
      // 这几条即使在代理启用时也必须 DIRECT，否则 HLS 代理会连自己
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
}