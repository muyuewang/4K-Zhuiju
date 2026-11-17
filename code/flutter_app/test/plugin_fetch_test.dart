/// SSRF 防护与 URL 拼装。
///
/// 为什么这块要单独测：清单是**远程下发**的，一个 `baseUrl` 被改成
/// `http://192.168.1.1/` 就会让用户手机去请求自己家路由器。这类问题
/// 在浏览器里是漏洞，在客户端里同样——只是后果从「读后台」变成
/// 「探测用户局域网」。
///
/// 拼装逻辑也必须测：一个占位符替换错，现象是「这个源永远搜不到东西」，
/// 而且看日志只看到 200 响应，很难往「URL 拼错了」上想。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';

void main() {
  group('urlRejectionReason 挡住内网', () {
    test('放行正常的公网 http/https', () {
      expect(urlRejectionReason('https://api.example.com/a'), isNull);
      expect(urlRejectionReason('http://1.2.3.4/x'), isNull);
      expect(urlRejectionReason('https://a.com:8443/x?y=1'), isNull);
    });

    test('拒绝本机回环', () {
      for (final u in [
        'http://127.0.0.1/',
        'http://127.0.0.1:8080/x',
        'http://localhost/',
        'http://localhost:3000/api',
        'http://[::1]/',
      ]) {
        expect(urlRejectionReason(u), isNotNull, reason: '$u 应被拒绝');
      }
    });

    test('拒绝私有网段', () {
      for (final u in [
        'http://10.0.0.1/',
        'http://10.255.255.255/',
        'http://192.168.1.1/',
        'http://172.16.0.1/',
        'http://172.31.255.255/',
        'http://172.20.10.1/',
      ]) {
        expect(urlRejectionReason(u), isNotNull, reason: '$u 应被拒绝');
      }
    });

    test('172.32 是公网，不能误伤', () {
      // 172.16–31 才是私有段，172.32 是公网地址
      expect(urlRejectionReason('http://172.32.0.1/'), isNull);
      expect(urlRejectionReason('http://172.15.0.1/'), isNull);
    });

    test('拒绝链路本地（云元数据服务在这个段）', () {
      // 169.254.169.254 是 AWS/阿里云的实例元数据，经典 SSRF 目标
      expect(urlRejectionReason('http://169.254.169.254/latest/meta-data/'),
          isNotNull);
      expect(urlRejectionReason('http://169.254.0.1/'), isNotNull);
    });

    test('拒绝非 http(s) 协议', () {
      for (final u in [
        'file:///etc/passwd',
        'ftp://a.com/x',
        'gopher://a.com/',
        'javascript:alert(1)',
        'data:text/html,<script>',
      ]) {
        expect(urlRejectionReason(u), isNotNull, reason: '$u 应被拒绝');
      }
    });

    test('拒绝 0.0.0.0', () {
      expect(urlRejectionReason('http://0.0.0.0/'), isNotNull);
    });

    test('拒绝 IPv6 唯一本地地址', () {
      expect(urlRejectionReason('http://[fd00::1]/'), isNotNull);
      expect(urlRejectionReason('http://[fe80::1]/'), isNotNull);
    });
  });

  group('prepareRequest 拼装', () {
    PluginManifest mk({
      String baseUrl = 'https://api.example.com',
      Map<String, String>? vars,
      Map<String, String>? headers,
    }) =>
        PluginManifest.fromJson(<String, dynamic>{
          'id': 'js_t',
          'name': 't',
          'baseUrl': baseUrl,
          'script': 'config/plugins/x.js',
          'categories': [
            {'id': '1', 'name': 'a'},
          ],
          'vars': vars ?? <String, String>{},
          'defaultHeaders': headers ?? <String, String>{},
          'list': {'path': '/api.php/provide/vod/'},
        })!;

    test('相对 path 拼到 baseUrl 后', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(
          path: '/api.php/provide/vod/',
          query: {'ac': 'list', 'pg': '{page}'},
        ),
        params: {'page': '2'},
      );
      expect(p.url, 'https://api.example.com/api.php/provide/vod/?ac=list&pg=2');
    });

    test('baseUrl 带路径前缀时不丢前缀', () {
      final p = prepareRequest(
        manifest: mk(baseUrl: 'https://cdn.example.com/api/'),
        req: const PluginRequest(path: 'vod/'),
        params: {},
      );
      expect(p.url, 'https://cdn.example.com/api/vod/');
    });

    test('绝对 path 直接用，不被 baseUrl 改写', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(path: 'https://other.com/x'),
        params: {},
      );
      expect(p.url, 'https://other.com/x');
    });

    test('占位符正确替换（page / category / keyword / id）', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(
          path: '/s',
          query: {
            't': '{category}',
            'pg': '{page}',
            'wd': '{keyword}',
            'ids': '{id}',
          },
        ),
        params: {
          'page': '3',
          'category': '26',
          'keyword': '斗罗大陆',
          'id': '12345',
        },
      );
      // 值会被 URL 编码，中文变成 %XX
      expect(p.url, contains('pg=3'));
      expect(p.url, contains('t=26'));
      expect(p.url, contains('ids=12345'));
      expect(p.url, contains('wd=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86'));
    });

    test('未知占位符原样保留（写错了能一眼看出来）', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(path: '/s', query: {'pg': '{pag}'}),
        params: {'page': '1'},
      );
      expect(p.url, contains('pg=%7Bpag%7D'));
    });

    test('vars 以 vars.x 形式可用', () {
      final p = prepareRequest(
        manifest: mk(vars: {'key': 'secret123'}),
        req: const PluginRequest(path: '/s', query: {'k': '{vars.key}'}),
        params: {'vars.key': 'secret123'},
      );
      expect(p.url, contains('k=secret123'));
    });

    test('POST 时 body 也做占位符替换', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(
          path: '/s',
          method: 'POST',
          body: 'wd={keyword}&pg={page}',
        ),
        params: {'keyword': 'abc', 'page': '1'},
      );
      expect(p.method, 'POST');
      expect(p.body, 'wd=abc&pg=1');
    });

    test('GET 时忽略 body', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(path: '/s', body: 'x=1'),
        params: {},
      );
      expect(p.body, '');
    });

    test('默认带 UA（采集站对空 UA 会 403）', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(path: '/s'),
        params: {},
      );
      expect(p.headers['User-Agent'], contains('Mozilla'));
    });

    test('清单的 defaultHeaders 覆盖默认 UA，单请求又覆盖清单', () {
      final manifest = mk(headers: {
        'User-Agent': 'from-manifest',
        'Referer': 'https://ref/',
      });
      final p1 = prepareRequest(
        manifest: manifest,
        req: const PluginRequest(path: '/s'),
        params: {},
      );
      expect(p1.headers['User-Agent'], 'from-manifest');
      expect(p1.headers['Referer'], 'https://ref/');

      final p2 = prepareRequest(
        manifest: manifest,
        req: const PluginRequest(
          path: '/s',
          headers: {'User-Agent': 'from-request'},
        ),
        params: {},
      );
      expect(p2.headers['User-Agent'], 'from-request');
    });

    test('危险头即使绕过 validate 也会被 prepareRequest 剥掉', () {
      // 直接构造带 Cookie 的 request，不经过 validate
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(
          path: '/s',
          headers: {'Cookie': 'session=abc', 'Host': 'evil.com'},
        ),
        params: {},
      );
      expect(p.headers.containsKey('Cookie'), isFalse);
      expect(p.headers.containsKey('Host'), isFalse);
    });

    test('内网 baseUrl 在 prepareRequest 阶段就被拒', () {
      expect(
        () => prepareRequest(
          manifest: mk(baseUrl: 'http://192.168.1.1'),
          req: const PluginRequest(path: '/x'),
          params: {},
        ),
        throwsA(isA<PluginFetchException>()),
      );
    });

    test('绝对 path 指向内网也被拒', () {
      expect(
        () => prepareRequest(
          manifest: mk(),
          req: const PluginRequest(path: 'http://127.0.0.1:6379/'),
          params: {},
        ),
        throwsA(isA<PluginFetchException>()),
      );
    });

    test('path 里已有 query 时与清单 query 合并', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(
          path: '/api.php/provide/vod/?ac=list',
          query: {'pg': '{page}'},
        ),
        params: {'page': '2'},
      );
      expect(p.url, contains('ac=list'));
      expect(p.url, contains('pg=2'));
    });

    test('特殊字符被正确编码，不会拼坏 query', () {
      final p = prepareRequest(
        manifest: mk(),
        req: const PluginRequest(path: '/s', query: {'wd': '{keyword}'}),
        params: {'keyword': 'a&b=c d'},
      );
      // & 和 = 必须被编码，否则会被当成新的参数
      expect(p.url, contains('a%26b%3Dc+d'));
    });
  });
}