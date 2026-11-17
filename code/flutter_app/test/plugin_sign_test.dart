/// 签名钩子的端到端验证：**真的发一次请求，看服务端收到什么**。
///
/// ## 为什么这条测试非要有真实服务端
///
/// 「签名逻辑正确」这件事有两种验证方式：
///
///   ① 读代码确认「它调了 host.hmac，返回值合并进 headers 了」——
///      这只能证明代码路径存在，证明不了头发出去了。
///   ② 起一个真实 HTTP 服务，把收到的请求头原样打印出来——
///      这才叫验证。
///
/// 选 ②。因为签名链路上有一堆「看着对但实际不对」的坑：
///   - 头被 SSRF 黑名单误删
///   - 合并顺序把签好的值覆盖回原值
///   - URL 重建时 query 丢失
///   - 签名函数返回的对象没被正确取出
///
/// 这些全都只在「实际发出的报文」里才看得出来。
///
/// ## 关于回环地址
///
/// 测试的服务端只能是 `127.0.0.1`，而线上 SSRF 防护会拒绝它。
/// 所以这里打开 `kAllowLoopbackForTest`——这个开关默认关闭，
/// 线上没有任何代码路径会打开它（见 plugin_fetch.dart 的注释）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';

import 'support/quickjs_env.dart';

/// 一个只记录请求、返回固定应答的假站点。
class _FakeSite {
  _FakeSite._(this._server);

  final HttpServer _server;

  /// 收到的每个请求的关键信息，按到达顺序记录。
  final List<Map<String, String>> received = <Map<String, String>>[];

  /// 收到的原始 query 串（用来断言签名参数有没有拼进去）。
  final List<String> queries = <String>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeSite> start({String body = '{"code":1,"list":[]}'}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _FakeSite._(s);
    s.listen((req) async {
      // 把所有头摊平成小写 key 的 map（HTTP 头大小写不敏感，
      // 用原样比较会写出「明明发了却断言不到」的假失败）
      final h = <String, String>{};
      req.headers.forEach((name, values) {
        h[name.toLowerCase()] = values.join(',');
      });
      site.received.add(h);
      site.queries.add(req.uri.query);

      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(body);
      await req.response.close();
    });
    return site;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue, reason: 'quickjs_c_bridge.dll 不可用');
    kAllowLoopbackForTest = true;
  });

  tearDownAll(() {
    kAllowLoopbackForTest = false;
    PluginRuntime.instance.resetForTest();
  });

  late String signScript;

  setUpAll(() {
    final f = File('../../config/plugins/signed-demo.js');
    expect(f.existsSync(), isTrue, reason: '找不到签名示例脚本：${f.absolute.path}');
    signScript = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(signScript), isFalse,
        reason: '签名脚本含疑似死循环');
  });

  /// 造一个带签名钩子的源。
  PluginManifest manifestFor(String baseUrl, {String? signEntry = 'sign'}) {
    return PluginManifest.fromJson(<String, dynamic>{
      'id': 'signed_demo',
      'name': '签名测试源',
      'baseUrl': baseUrl,
      'script': 'config/plugins/signed-demo.js',
      if (signEntry != null) 'signEntry': signEntry,
      'vars': <String, String>{'secret': 'test-secret-key'},
      'categories': <Map<String, String>>[
        <String, String>{'id': '13', 'name': '大陆剧'},
      ],
      'list': <String, dynamic>{
        'path': '/api.php/provide/vod/',
        'query': <String, String>{'ac': 'list', 'pg': '{page}'},
      },
      // 签名脚本不提供解析函数，这里补一个最小实现
      // （RemoteJsSource 会调 parseList，缺了会报错）
    })!;
  }

  /// 脚本要在签名之外还能解析，所以拼一段 parseList 上去。
  ///
  /// 注意这是**局部函数**而不是 `String get fullScript`——Dart 不支持
  /// 在函数体内声明 getter，写成 getter 会变成语法错误，并连带导致
  /// 后面所有引用处的类型推断全崩（报一堆莫名其妙的
  /// `String Function() can't be assigned to String`）。
  String fullScript() => '$signScript\n'
      'function parseList(body, ctx) { return { items: [] }; }\n';

  group('签名头真的到达服务端', () {
    test('x-timestamp / x-nonce / x-sign 三个头都发出去了', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: fullScript(),
      ));

      await src.category('13');

      expect(site.received, hasLength(1), reason: '服务端没收到请求');
      final h = site.received.first;

      expect(h.containsKey('x-timestamp'), isTrue,
          reason: '签名头没发出去。实际收到的头：${h.keys.toList()}');
      expect(h.containsKey('x-nonce'), isTrue);
      expect(h.containsKey('x-sign'), isTrue);

      // 时间戳必须是 13 位毫秒（10 位秒级会让服务端判过期）
      expect(h['x-timestamp']!.length, 13,
          reason: '时间戳是 ${h['x-timestamp']}，不是毫秒级');
      expect(int.tryParse(h['x-timestamp']!), isNotNull);

      // nonce 是 16 位字母数字
      expect(h['x-nonce']!.length, 16);
      expect(RegExp(r'^[0-9A-Za-z]{16}$').hasMatch(h['x-nonce']!), isTrue);

      // 签名是 sha256 的 hex（64 字符）
      expect(h['x-sign']!.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h['x-sign']!), isTrue);
    });

    test('签名值可由服务端独立复算出来', () async {
      // 这条才是真正的「算对了」：用服务端视角，拿收到的
      // path/query/ts/nonce 自己算一遍 HMAC，必须和客户端一致。
      // 只断言「是个 64 位 hex」证明不了算法对。
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: fullScript(),
      ));
      await src.category('13');

      final h = site.received.first;
      final ts = h['x-timestamp']!;
      final nonce = h['x-nonce']!;
      final gotSig = h['x-sign']!;

      // 服务端复算：path + '?' + 排序后的 query + ts + nonce
      // 注意 query 的取值来自**实际收到**的那份，不是客户端声称的
      final qp = Uri.splitQueryString(site.queries.first);
      final keys = qp.keys.toList()..sort();
      final parts = <String>[for (final k in keys) '$k=${qp[k]}'];
      final toSign = '/api.php/provide/vod/?${parts.join('&')}$ts$nonce';

      final expectSig = _hmacSha256Hex('test-secret-key', toSign);
      expect(gotSig, expectSig,
          reason: '客户端签名与服务端复算不一致\n'
              '待签串：$toSign');
    });

    test('query 参数完整保留（签名不能把原来的参数搞丢）', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: fullScript(),
      ));
      await src.category('13');

      final qp = Uri.splitQueryString(site.queries.first);
      expect(qp['ac'], 'list', reason: '清单声明的 query 丢了');
      expect(qp['pg'], '1');
    });

    test('每次请求的 nonce 都不同（防重放的前提）', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: fullScript(),
      ));
      await src.category('13');
      await src.category('14');

      expect(site.received.length, 2);
      expect(site.received[0]['x-nonce'], isNot(site.received[1]['x-nonce']),
          reason: 'nonce 重复，服务端会判重放');
      expect(site.received[0]['x-sign'], isNot(site.received[1]['x-sign']));
    });
  });

  group('未配签名时不受影响', () {
    test('signEntry 为 null 时不发签名头', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl, signEntry: null),
        script: fullScript(),
      ));
      await src.category('13');

      final h = site.received.first;
      expect(h.containsKey('x-sign'), isFalse,
          reason: '没配 signEntry 却发了签名头，说明钩子被无条件调用了');
    });

    test('未配 secret 时不打签名头（而不是打一个错的）', () async {
      // 打错的签名比不打的更难排查：服务端只回 401，
      // 看不出是「密钥没配」还是「算法不对」。
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      final m = PluginManifest.fromJson(<String, dynamic>{
        'id': 'signed_demo',
        'name': '无密钥源',
        'baseUrl': site.baseUrl,
        'script': 'config/plugins/signed-demo.js',
        'signEntry': 'sign',
        // 刻意不给 secret
        'categories': <Map<String, String>>[
          <String, String>{'id': '13', 'name': '大陆剧'},
        ],
        'list': <String, dynamic>{
          'path': '/api.php/provide/vod/',
          'query': <String, String>{'ac': 'list', 'pg': '{page}'},
        },
      })!;

      final src = RemoteJsSource(LoadedPlugin(manifest: m, script: fullScript()));
      await src.category('13');

      expect(site.received.first.containsKey('x-sign'), isFalse);
    });
  });

  group('安全边界：签名脚本不能为所欲为', () {
    test('试图设置 Host 会被拒绝，整个请求作废', () async {
      // Host 会打乱 SNI 与证书校验，等于把请求伪装到别的站。
      // 签名脚本是远程代码，和清单一样不可信，必须拦。
      //
      // 关键设计：拦下来是**整个请求作废**，不是「过滤掉这个头继续发」。
      // 后者会让作者以为签名生效了，实际发出去的是没签的报文。
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      const evil = '''
function sign(req) {
  return { headers: { 'Host': 'evil.example.com' } };
}
function parseList(body, ctx) { return { items: [] }; }
''';

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: evil,
      ));

      await expectLater(
        src.category('13'),
        throwsA(isA<PluginFetchException>()),
      );
      // 请求根本没发出去
      expect(site.received, isEmpty, reason: '带 Host 的请求被发出去了');
    });

    test('试图设置 Cookie / Authorization 也会被拒绝', () async {
      for (final name in const ['Cookie', 'Authorization']) {
        final site = await _FakeSite.start();
        addTearDown(site.stop);

        final evil = '''
function sign(req) {
  return { headers: { '$name': 'stolen' } };
}
function parseList(body, ctx) { return { items: [] }; }
''';

        final src = RemoteJsSource(LoadedPlugin(
          manifest: manifestFor(site.baseUrl),
          script: evil,
        ));

        await expectLater(
          src.category('13'),
          throwsA(isA<PluginFetchException>()),
          reason: '$name 应当被拒绝',
        );
        expect(site.received, isEmpty);
      }
    });

    test('签名函数返回非对象时报错，不静默放过', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      const bad = '''
function sign(req) { return 'not an object'; }
function parseList(body, ctx) { return { items: [] }; }
''';

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: bad,
      ));

      await expectLater(
        src.category('13'),
        throwsA(isA<PluginFetchException>()),
      );
      expect(site.received, isEmpty);
    });

    test('签名函数抛异常时请求不发出', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      const bad = '''
function sign(req) { throw new Error('故意炸'); }
function parseList(body, ctx) { return { items: [] }; }
''';

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: bad,
      ));

      await expectLater(
        src.category('13'),
        throwsA(isA<PluginFetchException>()),
      );
      expect(site.received, isEmpty);
    });
  });

  group('签名脚本能改 query', () {
    test('返回的 query 会合并进 URL', () async {
      final site = await _FakeSite.start();
      addTearDown(site.stop);

      const q = '''
function sign(req) {
  return { query: { sig: 'abc123', ts: '999' } };
}
function parseList(body, ctx) { return { items: [] }; }
''';

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: q,
      ));
      await src.category('13');

      final qp = Uri.splitQueryString(site.queries.first);
      expect(qp['sig'], 'abc123');
      expect(qp['ts'], '999');
      // 原有参数不能被冲掉
      expect(qp['ac'], 'list');
      expect(qp['pg'], '1');
    });
  });
}

/// 独立算一遍 HMAC-SHA256，用来做「服务端复算」。
///
/// 刻意**不走** `plugin_host_api.dart` 的 `hmacHex`：如果两边调同一个
/// 实现，就算实现本身是错的也会「一致通过」，那这条测试就白写了。
/// 这里直接用 `package:crypto`，是独立的一条路径。
String _hmacSha256Hex(String key, String msg) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(msg)).toString();