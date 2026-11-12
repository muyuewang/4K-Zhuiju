// cdndefend 准入的「连接亲和」契约回归（全离线，不联网）。
//
// 回归背景：v1.10.5 及之前，CdndefendGate 用「单个 HttpClient 串行发两次请求」
// 指望它复用 keep-alive 连接。2026-11-12 实测这条路走不通：
// 客户端收到 850 这个非标准状态码后直接丢弃了连接，
// 响应上的 connectionInfo.localPort 第一次 5571、第二次 5573 —— 端口变了，
// 连接根本没被复用。而服务端认的恰恰是「这条连接上刚算出的那个前缀」，
// 换连接一律重发 850，且每次换一个新前缀，看起来就像 PoW 算错了。
//
// 实测三种客户端的通过率：Python 裸 socket 同连接 4/4 成功；curl 新进程
// （必然新连接）5 次只偶然过 1 次；同一 Cookie 换新连接的通过率 1/4，
// 延迟 1 秒即失效。
//
// 下面用本地假源站把这套行为逐条复刻（同连接放行、换连接拒绝），
// 这样即使不联网也能锁死这个契约。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';
import 'package:zhuiju/core/source/site_http.dart';

/// 40 位 hex 前缀，首字符 'A' → n1 = 10，与线上同构。
const String _prefix = 'A1B2C3D4E5F60718293A4B5C6D7E8F9012345678';
const int _n1 = 10;
const String _cookieName = 'cdndefend_js_cookie';

/// 复刻线上挑战页：三元素数组 + `0x178` 旋转。
/// 376 % 3 == 1，旋转后顺序变成 [cookie 名, 方法名, 前缀]，
/// 正好是 [CdndefendGate] 解析时依赖的布局。
String _challengePage() => '<!DOCTYPE html><html><body><script>'
    "const a0_0x2a54=['$_prefix','$_cookieName=','array'];"
    '(function(_a,_b){}(a0_0x2a54,0x178));'
    '</script></body></html>';

/// 假源站：把「Cookie 只认发挑战的那条连接」这一行为照原样实现。
class _FakeSite {
  _FakeSite(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeSite> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeSite(s);
  }

  final HttpServer _server;

  /// 已经给它发过挑战的连接（用对端端口标识，一条 TCP 连接对应一个端口）。
  final Set<int> challenged = <int>{};

  /// 成功放行过的连接，用来断言「两次请求确实是同一条连接」。
  final Set<int> passed = <int>{};

  /// 收到过的请求数，用来断言并发请求没有丢。
  int hits = 0;

  /// 期望的 Cookie 值：解 PoW 得到的最小 i。
  late final String expectedCookie =
      '$_cookieName=$_prefix${CdndefendGate.proofOfWork(_prefix, _n1)}';

  int get port => _server.port;

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    hits++;
    final conn = req.connectionInfo!.remotePort;
    final cookie = req.headers.value('cookie') ?? '';

    // 这个连接还没拿过挑战：无论如何先发挑战（线上行为就是这样）
    if (!challenged.contains(conn)) {
      challenged.add(conn);
      await _challenge(req);
      return;
    }

    if (cookie != expectedCookie) {
      await _challenge(req);
      return;
    }

    passed.add(conn);
    await _ok(req);
  }

  Future<void> _challenge(HttpRequest req) async {
    final body = utf8.encode(_challengePage());
    req.response
      ..statusCode = 850
      ..headers.contentType = ContentType.html
      ..contentLength = body.length;
    req.response.add(body);
    await req.response.close();
  }

  Future<void> _ok(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/search') {
      // 搜索页在线上是 chunked（不设 contentLength 即自动 chunked）
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html;
      req.response.write('<html><body>'
          '搜索"${req.uri.queryParameters['k'] ?? ''}"，'
          '<a href="/detail/222.html">结果一</a>'
          '</body></html>');
      await req.response.close();
      return;
    }

    if (path == '/gzip') {
      // 线上开了 gzip，通道必须能解
      final raw = utf8.encode('<html><body>'
          '<a href="/detail/333.html">压缩页</a>'
          '</body></html>');
      final gz = gzip.encode(raw);
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..headers.set('content-encoding', 'gzip')
        ..contentLength = gz.length;
      req.response.add(gz);
      await req.response.close();
      return;
    }

    if (path == '/weird') {
      // 850 但页面结构不认识：必须明确报错，不能静默返回空
      final body = utf8.encode('<html><body>not a challenge</body></html>');
      req.response
        ..statusCode = 850
        ..headers.contentType = ContentType.html
        ..contentLength = body.length;
      req.response.add(body);
      await req.response.close();
      return;
    }

    final body = utf8.encode('<html><body>'
        '<a href="/detail/111.html">首页剧集</a>'
        '</body></html>');
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..contentLength = body.length;
    req.response.add(body);
    await req.response.close();
  }
}

void main() {
  late _FakeSite site;
  late CdndefendGate gate;
  late SiteHttp http;

  setUp(() async {
    site = await _FakeSite.start();
    gate = CdndefendGate('127.0.0.1', port: site.port, tls: false);
    http = SiteHttp(
      baseUrl: 'http://127.0.0.1:${site.port}',
      gate: gate,
    );
  });

  tearDown(() async {
    gate.invalidate();
    await site.stop();
  });

  test('收到 850 后在同一条连接上重发，必须拿到正文', () async {
    final body = await http.get('/');
    expect(body, contains('/detail/111.html'));
    expect(body, isNot(contains('cdndefend')));
  });

  test('过闸用到的是同一条 TCP 连接（不是换了条连接碰运气）', () async {
    await http.get('/');

    expect(site.passed, hasLength(1), reason: '应当只有一条连接被放行');
    expect(site.challenged, site.passed,
        reason: '被放行的连接必须正是发过挑战的那条；'
            '若这里不相等，说明实现换了连接去验证 Cookie');
  });

  test('同一条连接上连续多次请求都放行，不会第二次又弹挑战', () async {
    final a = await http.get('/');
    final b = await http.get('/');
    final c = await http.get('/');
    for (final body in [a, b, c]) {
      expect(body, contains('/detail/111.html'));
      expect(body, isNot(contains('cdndefend')));
    }
    expect(site.passed, hasLength(1), reason: '三次请求应当复用同一条连接');
  });

  test('夹具保真性：同一条 Cookie 换新连接会被拒（线上就是这样）', () async {
    // 先在同一条连接上把 Cookie 解出来
    await http.get('/');
    final cookie = site.expectedCookie;

    // 另起一条全新连接，带同一个 Cookie 直接请求
    final client = HttpClient();
    try {
      final rq = await client.getUrl(Uri.parse('http://127.0.0.1:${site.port}/'));
      rq.headers.set('Cookie', cookie);
      final rp = await rq.close();
      final body = await rp.transform(utf8.decoder).join();

      expect(rp.statusCode, 850,
          reason: '假源站必须复刻「Cookie 绑定连接」这一行为，'
              '否则本文件其它用例会在实现退化时依然通过');
      expect(body, contains('cdndefend'));
    } finally {
      client.close(force: true);
    }
  });

  test('并发请求被串行化，不会互相截断', () async {
    final bodies = await Future.wait([
      http.get('/'),
      http.get('/'),
      http.get('/'),
    ]);
    for (final b in bodies) {
      expect(b, contains('/detail/111.html'));
    }
    expect(site.passed, hasLength(1), reason: '并发也要落在同一条连接上');
  });

  test('chunked 响应能完整读出（搜索页就是 chunked）', () async {
    final body = await http.get('/search', query: {'k': '庆余年'});
    expect(body, contains('庆余年'));
    expect(body, contains('/detail/222.html'));
  });

  test('gzip 响应能正确解码（线上开了压缩）', () async {
    final body = await http.get('/gzip');
    expect(body, contains('/detail/333.html'));
  });

  test('挑战页结构变化时明确报错，不静默返回空串', () async {
    await expectLater(
      http.get('/weird'),
      throwsA(isA<ApiException>().having(
        (e) => e.msg,
        'msg',
        contains('准入'),
      )),
    );
  });
}