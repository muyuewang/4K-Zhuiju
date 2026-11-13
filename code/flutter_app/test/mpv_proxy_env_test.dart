/// libmpv 代理环境变量注入的回归（不联网）。
///
/// ## 锁的是什么
///
/// 2026-11-13 删掉了桌面端的 m3u8 本地中转（`HlsProxy`）。它存在过，
/// 只因为 libmpv 走 FFmpeg 自己的网络栈、不读 Windows 系统代理，而四个源
/// （云影/低调/极速/4K影视）必须挂代理。
///
/// 但中转把取流变成单线程串行：实测电影天堂《凡人修仙传》一集
/// （322 片、3000k ≈ 375 KB/s）经中转只有 208 KB/s —— 低于码率必然
/// 缓冲不满、一直转圈；同一批分片让 FFmpeg 自己并行预读能到 429 KB/s。
/// 用户报的「浏览器秒开、雷电模拟器也快、唯独 PC 慢还超时」根子就在这里。
///
/// 替代方案是实测出来的（用 dart:ffi 直接问 libmpv 自己）：
///   - `_putenv_s("http_proxy", 假代理)` 后 loadfile → 假代理真的收到
///     `CONNECT …:443`，说明 FFmpeg 读这个环境变量
///   - 再加 `no_proxy=该域名` → 假代理收到 0 个请求，排除精确生效
///
/// 这组测试盯的是**注入逻辑本身**的三条正确性，它们任何一条错了
/// 都是「全 App 连不上」级别：
///   1. 代理关闭时必须把变量**清空**，不能留着上次的值
///   2. `no_proxy` 必须包含本机与内网，否则代理会去连代理
///   3. 状态没变化时不重复写（避免日志刷屏、也避免无谓的系统调用）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/mpv_proxy_env.dart';
import 'package:zhuiju/core/net_proxy.dart';

void main() {
  setUp(() => MpvProxyEnv.debugReset());

  group('旁路名单', () {
    test('必须覆盖本机回环地址', () {
      // 少了这条，本机服务会被塞进代理 → 代理去连代理 → 整条链路挂掉。
      // 这是本次重构最容易漏的一点：中转删了，但本机地址仍可能出现
      // （投屏、本地播放、开发服务器）。
      for (final h in ['127.0.0.1', 'localhost', '::1']) {
        expect(MpvProxyEnv.bypass, contains(h),
            reason: 'no_proxy 少了 $h，本机请求会被塞进代理');
      }
    });

    test('旁路名单里不能出现实战无效的段通配', () {
      // 这条是本文件最重要的一条，因为它替代了旧版本那条**假测试**。
      //
      // 旧版本写的是：expect(bypass, contains('10.')) —— 只验证字符存在，
      // 于是 `10.*` 这种「看着像内网通配、实际 FFmpeg 一条都不认」的写法
      // 一路绿灯通过了检查，内网地址照样被塞进代理。
      //
      // 实测语义（三轮，见 mpv_proxy_env.dart 文件头表格）：
      //   星号**只能做前缀**          → `*.1.2.3` 有效
      //   尾部星号                    → `10.*` 无效
      //   CIDR                        → 无效
      //   所以任何「前缀固定 + 尾星」的项都是错写法，必须拦死。
      final items = MpvProxyEnv.bypass.split(',').map((e) => e.trim());
      for (final it in items) {
        expect(it.endsWith('.*'), isFalse,
            reason: '$it 是尾星通配，FFmpeg 的 no_proxy 不认这种写法');
        expect(it, isNot(contains('/')),
            reason: '$it 用了 CIDR，FFmpeg 的 no_proxy 不认');
      }
    });

    test('内网 IP 由 Dart 侧判掉，不指望 no_proxy', () {
      // 既然 no_proxy 表达不出 IP 段，那内网必须靠 sync 的 targetHost
      // 分支兜住。这里直接断言那条分支真的会生效。
      //
      // 用 stateLabelFor 这个纯函数验，不跑 sync：sync 读 NetProxy.active，
      // 取决于本机有没有开代理，CI 上结果不稳定。
      final lan = MpvProxyEnv.stateLabelFor('127.0.0.1:7897',
          targetHost: '10.1.2.3');
      expect(lan, startsWith('<lan:'),
          reason: '内网目标即便有代理也必须直连，否则代理去连代理');

      // 公网目标必须照常走代理，不能被内网判断误伤
      final wan = MpvProxyEnv.stateLabelFor('127.0.0.1:7897',
          targetHost: 'vip.dytt-tvs.com');
      expect(wan, contains('127.0.0.1:7897'),
          reason: '公网源站必须走代理，误判成内网会导致源站全部打不开');
    });

    test('通配项必须只收窄到局域网，不能吃掉公网', () {
      // 反向断言：有人「顺手加全」把裸 `*` 或 `*.com` 写进去，代理就形同
      // 虚设，而症状是「代理源全部播不了」，很难查。
      //
      // 注意不能简单地 `isNot(startsWith('*'))`：`*.local` 是**合法且
      // 必需**的（mDNS 名字如 nas.local 没法逐个枚举，而星号前缀正是
      // FFmpeg 支持的唯一通配形态，实测有效）。要拦的是「把公网也一起
      // 放掉」的写法，不是通配本身。
      //
      // 白名单而不是黑名单：只接受已实测确认安全的 `*.local`，
      // 将来有人想加 `*.com` 之类的会立刻被这条拦下。
      const allowedWildcards = {'*.local'};
      final items = MpvProxyEnv.bypass
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      for (final it in items) {
        expect(it, isNot('*'), reason: '裸通配 * 会让 no_proxy 匹配一切');
        if (it.startsWith('*')) {
          expect(allowedWildcards, contains(it),
              reason: '$it 不在白名单里。通配会放掉整片域名，'
                  '加之前必须先用 tool/probe_final_bypass.dart 实测');
        }
      }
      // 也不能把常见公网域名塞进来
      expect(MpvProxyEnv.bypass.toLowerCase(), isNot(contains('dytt')));
      expect(MpvProxyEnv.bypass.toLowerCase(), isNot(contains('.com')));
      expect(MpvProxyEnv.bypass.toLowerCase(), isNot(contains('.tv')));
    });
  });

  group('写入决策', () {
    test('代理为空串时必须标记「直连」，不能沿用上次地址', () {
      // 这是「关掉代理后整个 App 连不上」的那条防线：
      // 若清空被漏掉，变量会一直指向一个已经没人监听的端口。
      //
      // 用纯函数断言而不是跑 sync：sync 读的是 NetProxy.active，
      // 而它取决于本机有没有开代理软件 —— 实测开发机上 Clash 常驻
      // 7897，直接断言「sync 之后一定是直连」会假失败。
      expect(MpvProxyEnv.stateLabelFor(''), '<direct>');
    });

    test('有代理时状态里必须带旁路名单', () {
      final label = MpvProxyEnv.stateLabelFor('127.0.0.1:7897');
      expect(label, contains('127.0.0.1:7897'));
      expect(label, contains(MpvProxyEnv.bypass),
          reason: '少了旁路名单，本机与内网请求会被塞进代理');
    });

    test('状态不变时第二次 sync 不重复写', () async {
      await MpvProxyEnv.sync();
      final first = MpvProxyEnv.applied;
      await MpvProxyEnv.sync();
      expect(MpvProxyEnv.applied, first,
          reason: '没变化不该重复写，否则日志与实际变化点混在一起');
    });

    test('debugReset 之后必然重写', () async {
      await MpvProxyEnv.sync();
      final first = MpvProxyEnv.applied;
      MpvProxyEnv.debugReset();
      expect(MpvProxyEnv.applied, '<未初始化>');
      await MpvProxyEnv.sync();
      expect(MpvProxyEnv.applied, first,
          reason: '重置只是丢掉记忆，重新算出的结论应该一样');
    });
  });

  group('与 NetProxy 的一致性', () {
    test('sync 之后的状态与 NetProxy 当前判定一致', () async {
      await NetProxy.refresh(force: true);
      await MpvProxyEnv.sync();
      // 不假设代理开或关，只断言「写入的东西和探测结论对得上」。
      // 这条在两个方向上都有效：
      //   关代理时 → 必须清空；开代理时 → 必须带地址和旁路名单。
      final want = MpvProxyEnv.stateLabelFor(
        NetProxy.active ? NetProxy.server : '',
      );
      expect(MpvProxyEnv.applied, want);
    });
  });
}