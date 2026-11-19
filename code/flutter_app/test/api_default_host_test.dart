/// 橘汁接口根地址的内置值。
///
/// 2026-11-19「远端下发」整套机制已下线（`RemoteEndpoints` +
/// `config/endpoints.json` + `config/README.md` 全删）。原因有二：
///
///   1. 那份配置下发的 `juziapp.hzhcbkj.cn` 自己已经 502 了；
///   2. 域名换过一次，靠的还是发版 —— 机制没解决它声称要解决的问题，
///      却让「请求发去哪」多出一条远端可改的路径，还多一层启动顺序约束。
///
/// 下线后 [ZhuijuApi.defaultHost] 就是唯一来源。这里钉住三件事：
/// 它本身合法、`host` 与它同步、`baseUrl` 初始指向它。
///
/// 原 `remote_endpoints_test.dart` 里 17 条 `isValidBase` 用例随实现一起删除
/// —— 校验器已经不存在了，留着测一个不存在的函数没有意义。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/api.dart';

void main() {
  group('内置接口域名', () {
    test('defaultHost 是合法的 http/https 绝对地址', () {
      final uri = Uri.tryParse(ZhuijuApi.defaultHost);
      expect(uri, isNotNull);
      expect(uri!.isScheme('http') || uri.isScheme('https'), isTrue,
          reason: 'scheme 只能是 http/https');
      expect(uri.host, isNotEmpty, reason: '必须有主机名');
      expect(uri.userInfo, isEmpty, reason: '不允许带用户名密码');
      expect(uri.path.isEmpty || uri.path == '/', isTrue,
          reason: '接口路径由代码拼接，base 里不能带路径前缀');
    });

    test('defaultHost 必须是当前实测可用的域名', () {
      expect(ZhuijuApi.defaultHost, 'http://juziappcc.hzhcbkj.cn',
          reason: '旧域名 juziapp.hzhcbkj.cn 已 502，别再写回去');
    });

    test('host 与 defaultHost 是同一个值（兼容旧引用）', () {
      expect(ZhuijuApi.host, ZhuijuApi.defaultHost);
    });

    test('baseUrl 初始指向 defaultHost', () {
      expect(ZhuijuApi.baseUrl, ZhuijuApi.defaultHost);
    });
  });
}