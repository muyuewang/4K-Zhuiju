/// 远端接口域名配置的校验规则
///
/// ## 为什么这份测试值钱
///
/// `RemoteEndpoints.isValidBase` 是「远端配置能不能生效」的**唯一闸门**。
/// 它挡得太松：一条写坏的配置会把整个橘汁源改成不可用，而且是远程改的，
/// 没法回滚到用户手里。挡得太严：配置永远不生效，等于这个功能不存在，
/// 但表面上一切正常，很难发现。
///
/// 所以这里逐个形态钉死，不用「测几个代表值」的方式糊过去。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/api.dart';
import 'package:zhuiju/core/remote_endpoints.dart';

void main() {
  group('isValidBase 接受', () {
    test('明文 http + 域名', () {
      expect(RemoteEndpoints.isValidBase('http://juziapp.hzhcbkj.cn'), isTrue);
    });

    test('https + 域名', () {
      expect(RemoteEndpoints.isValidBase('https://example.com'), isTrue);
    });

    test('带端口', () {
      expect(
        RemoteEndpoints.isValidBase('http://127.0.0.1:8080'),
        isTrue,
        reason: '本地调试与单测都要用它指向本地 server',
      );
    });

    test('带 IP', () {
      expect(RemoteEndpoints.isValidBase('http://223.106.78.81'), isTrue);
    });

    test('结尾带单个斜杠（等价写法）', () {
      expect(RemoteEndpoints.isValidBase('http://example.com/'), isTrue);
    });
  });

  group('isValidBase 拒绝', () {
    test('空串', () {
      expect(RemoteEndpoints.isValidBase(''), isFalse);
    });

    test('不是 URL 的随手字符串', () {
      expect(RemoteEndpoints.isValidBase('example.com'), isFalse,
          reason: '没有 scheme 会被拼成 example.com/api/... 这种相对地址');
    });

    test('ftp scheme', () {
      expect(RemoteEndpoints.isValidBase('ftp://example.com'), isFalse);
    });

    test('file scheme（本地文件读取风险）', () {
      expect(RemoteEndpoints.isValidBase('file:///C:/Windows'), isFalse);
    });

    test('javascript scheme', () {
      expect(RemoteEndpoints.isValidBase('javascript:alert(1)'), isFalse);
    });

    test('带用户名密码', () {
      expect(
        RemoteEndpoints.isValidBase('http://user:pass@example.com'),
        isFalse,
        reason: '没有正当用途，是配置被劫持时最直接的凭证泄漏形态',
      );
    });

    test('带路径（会拼出双斜杠或错层）', () {
      expect(
        RemoteEndpoints.isValidBase('http://example.com/api'),
        isFalse,
        reason: '接口路径由代码拼接，base 里再带路径会变成 /api/api/proto/...',
      );
    });

    test('缺 host', () {
      expect(RemoteEndpoints.isValidBase('http://'), isFalse);
    });

    test('超长（防把配置当载荷用）', () {
      final long = 'http://${'a' * 300}.com';
      expect(RemoteEndpoints.isValidBase(long), isFalse);
    });
  });

  group('内置默认域名', () {
    test('defaultHost 本身必须能过校验', () {
      expect(
        RemoteEndpoints.isValidBase(ZhuijuApi.defaultHost),
        isTrue,
        reason: '兜底值自己都不合法的话，一层层降级最终会落到一个坏的 base 上',
      );
    });

    test('host 与 defaultHost 是同一个值（兼容旧引用）', () {
      expect(ZhuijuApi.host, ZhuijuApi.defaultHost);
    });

    test('baseUrl 初始指向 defaultHost', () {
      expect(ZhuijuApi.baseUrl, ZhuijuApi.defaultHost);
    });
  });
}