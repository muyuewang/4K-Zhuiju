/// 验证 `host.*` 在真实 QuickJS 里能**同步**返回。
///
/// ## 为什么这条测试是整个插件化方案的前提
///
/// 整套设计有个地基：**插件入口必须是同步函数**。同步的原因是
/// 「宿主做 IO、插件只做解析」——插件没有任何需要 await 的东西，
/// 允许 async 只会让作者误以为能在插件里发请求（那就绕过了 SSRF 防护）。
///
/// 但加密原语是宿主提供的。如果 `host.md5(s)` 返回的是 Promise，
/// 那插件作者就必须 `await`，入口就变成 async，地基就塌了。
///
/// `flutter_js` 的 `sendMessage` 在 QuickJS 里是 JSInvokable，
/// Dart 回调的返回值经 `_dartToJs` 原路返回给 JS——理论上同步。
/// **但这条链路必须实测**：文档没写，社区也没人提，靠推测就是在赌。
///
/// 2026-11-17 本机实测结论：确实同步。Lua 探针拿到
/// `RET={"echo":{"x":1},"n":42}`，单次往返 0.15ms。这里把那个探针
/// 固化成测试，防止将来升级 flutter_js 时静默退化成异步。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  setUpAll(() {
    expect(
      ensureQuickJsLibrary(),
      isTrue,
      reason: 'quickjs_c_bridge.dll 不可用，无法验证宿主通道',
    );
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  /// 跑一段脚本，返回解析后的 JSON。
  Future<Object?> run(String script, String entry, [List<Object?> args = const []]) async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode(args),
    );
    expect(r.ok, isTrue, reason: '插件执行失败：${r.error}');
    return jsonDecode(r.value);
  }

  group('host 通道的同步性', () {
    test('host.md5 返回字符串而不是 Promise', () async {
      // 关键断言：返回的必须是字符串。如果底层退化成异步，
      // 这里拿到的会是 "[object Promise]" 或直接走 Promise 拒绝分支。
      final out = await run('''
        function t() {
          var r = host.md5('abc');
          return JSON.stringify({
            type: typeof r,
            isPromise: (r instanceof Promise),
            value: r
          });
        }
      ''', 't');

      final m = out as Map;
      expect(m['type'], 'string', reason: 'host.md5 返回了 ${m['type']}，说明通道不是同步的');
      expect(m['isPromise'], isFalse);
      expect(m['value'], '900150983cd24fb0d6963f7d28e17f72');
    });

    test('同步返回值能直接参与后续计算（不需要 await）', () async {
      // 这条更接近真实用法：拿 md5 结果拼进下一句，全程同步。
      // 如果通道是异步的，`h.length` 会是 undefined 而不是 32。
      final out = await run('''
        function t() {
          var h = host.md5('abc');
          return JSON.stringify({ len: h.length, upper: h.toUpperCase() });
        }
      ''', 't');
      final m = out as Map;
      expect(m['len'], 32);
      expect(m['upper'], '900150983CD24FB0D6963F7D28E17F72');
    });

    test('单次往返耗时可接受（毫秒级，不是几十毫秒）', () async {
      // 如果每次 host 调用都要一整个事件循环轮转，20 条列表就会卡顿。
      // 这里连调 20 次，确认总耗时在合理范围。
      final sw = Stopwatch()..start();
      final out = await run('''
        function t() {
          var acc = '';
          for (var i = 0; i < 20; i++) { acc = host.md5(acc + i); }
          return JSON.stringify({ n: acc.length });
        }
      ''', 't');
      sw.stop();
      expect((out as Map)['n'], 32);
      // 20 次往返 + 脚本编译（首次），给足余量。真机上远小于此。
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: '20 次宿主往返用了 ${sw.elapsedMilliseconds}ms');
    });
  });

  group('host 各能力在 JS 侧可用', () {
    test('摘要与编码', () async {
      final out = await run('''
        function t() {
          return JSON.stringify({
            md5: host.md5('abc'),
            sha1: host.sha1('abc'),
            sha256: host.sha256('abc'),
            b64: host.b64e('abc'),
            unhex: host.unhex('616263')
          });
        }
      ''', 't');
      final m = out as Map;
      expect(m['md5'], '900150983cd24fb0d6963f7d28e17f72');
      expect(m['sha256'], startsWith('ba7816bf'));
      expect(m['b64'], 'YWJj');
      expect(m['unhex'], 'abc');
    });

    test('AES 加解密（对象参数形式）', () async {
      final out = await run('''
        function t() {
          var key = '0123456789abcdef0123456789abcdef';
          var enc = host.aesEcbEncrypt({ key: key, plain: '橘汁' });
          var dec = host.aesEcbDecrypt({ key: key, cipherText: enc });
          return JSON.stringify({ enc: enc, dec: dec, roundtrip: dec === '橘汁' });
        }
      ''', 't');
      final m = out as Map;
      expect(m['roundtrip'], isTrue);
      expect(m['dec'], '橘汁');
    });

    test('hmac 签名', () async {
      final out = await run('''
        function t() {
          return JSON.stringify({
            s: host.hmac('sha256', 'key',
              'The quick brown fox jumps over the lazy dog')
          });
        }
      ''', 't');
      expect((out as Map)['s'],
          'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8');
    });

    test('xml2json 展开成可遍历的 JS 对象', () async {
      // XML 站支持的核心：脚本里要能像普通对象一样取值
      final out = await run('''
        function t() {
          var xml = '<rss><list page="1"><video><id>1</id>'
            + '<name><![CDATA[剧名]]></name></video>'
            + '<video><id>2</id><name>第二个</name></video></list></rss>';
          var j = host.xml2json(xml);
          var list = j.rss.list;
          // 注意：两个 video 才是数组。一个 video 时是对象，
          // 这是 xml2js 的固有行为，插件要自己兜
          return JSON.stringify({
            page: list['@page'],
            isArray: Array.isArray(list.video),
            n: list.video.length,
            first: list.video[0].name,
            second: list.video[1].id
          });
        }
      ''', 't');
      final m = out as Map;
      expect(m['page'], '1');
      expect(m['isArray'], isTrue);
      expect(m['n'], 2);
      expect(m['first'], '剧名');
      expect(m['second'], '2');
    });

    test('randomAlnum 生成 nonce', () async {
      final out = await run('''
        function t() {
          var a = host.randomAlnum(16);
          return JSON.stringify({ a: a, len: a.length, ok: /^[0-9A-Za-z]+\$/.test(a) });
        }
      ''', 't');
      final m = out as Map;
      expect(m['len'], 16);
      expect(m['ok'], isTrue);
    });
  });

  group('host 的错误处理', () {
    test('失败时抛 JS 异常，能被 try/catch 抓到', () async {
      // 这是设计选择：`{"__err": ...}` 在 JS 侧转成 throw。
      // 作者该看到的是 catch 能抓到的东西，而不是一个看起来
      // 像正常返回值的对象（那种错最难查）。
      final out = await run('''
        function t() {
          var caught = '';
          try {
            host.aesEcbDecrypt({ key: '0123456789abcdef', cipherText: 'AAAA' });
          } catch (e) {
            caught = e.message;
          }
          return JSON.stringify({ caught: caught });
        }
      ''', 't');
      final caught = (out as Map)['caught'] as String;
      expect(caught, isNotEmpty, reason: '没有抛出异常，说明 __err 没被转成 throw');
      expect(caught, contains('aesEcbDecrypt'), reason: '错误信息应指出是哪个函数');
    });

    test('异常不会让脚本崩溃，后续代码照常执行', () async {
      final out = await run('''
        function t() {
          var after = 'not reached';
          try { host.unhex('zz'); } catch (e) {}
          after = 'reached';
          return JSON.stringify({ after: after });
        }
      ''', 't');
      expect((out as Map)['after'], 'reached');
    });

    test('available() 能让脚本自检能力', () async {
      // 作者可以写 `if (!host.available('rsaEncrypt')) { 降级 }`。
      // 这让「插件跑在老版本宿主上」这种情况有优雅退路。
      final out = await run('''
        function t() {
          return JSON.stringify({
            hasRsa: host.available('rsaEncrypt'),
            hasMysql: host.available('mysql'),
            n: host.names().length
          });
        }
      ''', 't');
      final m = out as Map;
      expect(m['hasRsa'], isTrue);
      expect(m['hasMysql'], isFalse);
      expect(m['n'], kHostFunctions.length);
    });

    test('调用次数超上限时报错（防止在循环里狂调）', () async {
      // host 是同步调用，在循环里狂调会把 worker 线程占死——
      // 和死循环一样的后果。给个预算，超了就明确报错。
      //
      // 这里用一个很小的预算测：不断调 md5 直到抛出。
      // 注意上限是 5000，测完会累加，所以要 reset。
      PluginRuntime.instance.resetForTest();

      final out = await run('''
        function t() {
          var i = 0;
          try {
            for (i = 0; i < 20000; i++) { host.md5('x' + i); }
          } catch (e) {
            return JSON.stringify({ stoppedAt: i, msg: e.message });
          }
          return JSON.stringify({ stoppedAt: -1, msg: '没被拦住' });
        }
      ''', 't');
      final m = out as Map;
      expect(m['stoppedAt'], greaterThan(0), reason: '20 万次调用没有被拦住');
      expect(m['msg'], contains('上限'));

      PluginRuntime.instance.resetForTest();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('host 通道不影响既有约束', () {
    test('插件入口仍必须是同步的（返回 Promise 会被拒）', () async {
      // 注入 host 之后，一个重要问题是：作者会不会以为可以 async 了？
      // 不会——入口的 Promise 检查依然生效。这条用例守住这个边界。
      final r = await PluginRuntime.instance.call(
        script: 'function t() { return Promise.resolve(1); }',
        entry: 't',
        argsJson: '[]',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('Promise'));
    });

    test('host 只能算，不能联网（脚本里没有 fetch/XHR）', () async {
      final out = await run('''
        function t() {
          return JSON.stringify({
            fetch: typeof fetch,
            xhr: typeof XMLHttpRequest,
            require: typeof require,
            process: typeof process
          });
        }
      ''', 't');
      final m = out as Map;
      expect(m['fetch'], 'undefined', reason: '插件不该有网络能力');
      expect(m['xhr'], 'undefined');
      expect(m['require'], 'undefined');
      expect(m['process'], 'undefined');
    });
  });
}