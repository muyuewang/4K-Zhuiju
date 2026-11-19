/// 两个「静默失败」的回归护栏（2026-11-19）。
///
/// 用户报的现象是：切到橘汁后所有分类都显示「这个分类暂时没有内容」，
/// **一个字的报错都没有**。查下来是两个独立的宿主级问题叠在一起，
/// 而且两个都「错了不报错」，所以必须各留一条测试钉住。
///
/// ## 坑 1：签名脚本写的 Content-Type 被静默覆盖
///
/// `fetch()` 原先只认 `req.contentType`（由清单 `bodyType` 推导，
/// 默认 form 时是空串），空串就补成 `application/x-www-form-urlencoded`，
/// 于是签名钩子写在 headers 里的 `application/x-protobuf` **被无声丢弃**。
///
/// 橘汁的服务端按 Content-Type 选解析器：拿到表单类型就不认那个 protobuf
/// 体，读不出时间戳，回 `code=100001 请求时间戳过期`。
///
/// 实测对照（同一个签名、同一份字节，只改 Content-Type）：
///   form-urlencoded      → 27 字节  code=100001
///   application/x-protobuf → 15471 字节 正常数据
///   application/json / octet-stream → 同样正常
/// 所以坏的不是「非表单」这一类，而是**宿主把作者写的头改掉了**。
///
/// ## 坑 2：hex→文本解码走宿主，详情页撞穿 5000 次预算
///
/// 原先 `text()` 用 `host.b64e` + `host.b64d` 两次跨 FFI 完成一次解码。
/// 列表页（20 条 × 3 字段）只要 120 次看不出问题，但详情页是
/// **线路 × 集数**的乘积：《兰香如故》47 集 × 14 线路 = 658 条 video，
/// 每条 3 个字段就是 3900+ 次，整个 `parseDetail` 直接抛
/// 「host 调用次数超出上限（5000 次）」。
///
/// 表现同样是「详情页坏了、列表页好的」——极易误判成接口不支持。
/// 现在 `text()` 是纯 JS 实现，宿主调用数与集数无关。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/plugin/remote_js_source.dart';

import 'support/quickjs_env.dart';

/// 一个记录请求头、返回固定应答的假站点。
class _Recorder {
  _Recorder._(this._server);

  final HttpServer _server;
  final List<Map<String, String>> received = <Map<String, String>>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_Recorder> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final r = _Recorder._(s);
    s.listen((req) async {
      final h = <String, String>{};
      req.headers.forEach((name, values) {
        h[name.toLowerCase()] = values.join(',');
      });
      r.received.add(h);
      // **必须把 body 读完**，否则 keep-alive 复用时会读到半截请求，
      // 下一个请求的表现完全对不上（曾经误判成「头丢了」）。
      await req.drain<void>();
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.binary
        ..add(const <int>[0x08, 0xC8, 0x01]);
      await req.response.close();
    });
    return r;
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

  group('坑 1：签名脚本写的 Content-Type 不能被覆盖', () {
    /// 造一个「签名钩子只改 Content-Type」的源。
    /// 清单 bodyType 保持默认（form）—— 这正是橘汁的配置形态，
    /// 也是原先触发覆盖的条件。
    PluginManifest manifestFor(String baseUrl) {
      return PluginManifest.fromJson(<String, dynamic>{
        'id': 'ct_probe',
        'name': 'ContentType 探针源',
        'baseUrl': baseUrl,
        'script': 'config/plugins/ct-probe.js',
        'signEntry': 'sign',
        'categories': <Map<String, String>>[
          <String, String>{'id': '21', 'name': '测试'},
        ],
        'list': <String, dynamic>{
          'path': '/api/proto/v5/drama/category',
          'method': 'POST',
          'body': '',
          'bodyFormat': 'hex',
          'responseType': 'bin',
          'query': <String, String>{'typeId1': '{category}', 'page': '{page}'},
        },
      })!;
    }

    const script = r'''
function sign(req) {
  return {
    headers: {
      'Content-Type': 'application/x-protobuf',
      'Accept': 'application/x-protobuf'
    },
    body: '0801'
  };
}
function parseList(body, ctx) { return { items: [] }; }
''';

    test('签名钩子声明 x-protobuf 时，服务端收到的就是 x-protobuf', () async {
      final site = await _Recorder.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(
          LoadedPlugin(manifest: manifestFor(site.baseUrl), script: script));
      await src.category('21');

      expect(site.received, hasLength(1), reason: '服务端没收到请求');
      final ct = site.received.first['content-type'];

      // 这条是本轮的核心断言。改回「空串就补表单类型」会让它立刻红。
      expect(ct, 'application/x-protobuf',
          reason: '签名脚本写的 Content-Type 被覆盖了，实际收到：$ct');
    });

    test('对照：签名钩子不写 Content-Type 时，仍按清单默认发表单类型', () async {
      // 不能为了修橘汁就把所有源的默认行为改掉 —— JSON 源、表单源
      // 都依赖「空串 → form」。这条防的是修过头。
      final site = await _Recorder.start();
      addTearDown(site.stop);

      final src = RemoteJsSource(LoadedPlugin(
        manifest: manifestFor(site.baseUrl),
        script: 'function sign(req) { return { body: "0801" }; }\n'
            'function parseList(body, ctx) { return { items: [] }; }',
      ));
      await src.category('21');

      expect(site.received, hasLength(1));
      final ct = site.received.first['content-type'];
      expect(ct, contains('application/x-www-form-urlencoded'),
          reason: '没声明 Content-Type 时应保持原来的表单默认，实际：$ct');
    });

    test('清单 bodyType=json 时仍发 application/json', () async {
      // bodyType 是清单级声明，优先级低于签名钩子，但自身不能被破坏。
      final site = await _Recorder.start();
      addTearDown(site.stop);

      final m = PluginManifest.fromJson(<String, dynamic>{
        'id': 'json_probe',
        'name': 'JSON 探针源',
        'baseUrl': site.baseUrl,
        'script': 'config/plugins/json-probe.js',
        'categories': <Map<String, String>>[
          <String, String>{'id': '21', 'name': '测试'},
        ],
        'list': <String, dynamic>{
          'path': '/api/proto/v5/drama/category',
          'method': 'POST',
          'body': '{}',
          'bodyType': 'json',
          'query': <String, String>{'typeId1': '{category}'},
        },
      })!;

      final src = RemoteJsSource(LoadedPlugin(
        manifest: m,
        script: 'function parseList(body, ctx) { return { items: [] }; }',
      ));
      await src.category('21');

      expect(site.received, hasLength(1));
      expect(site.received.first['content-type'], contains('application/json'));
    });
  });

  group('坑 2：橘汁详情页不能撞穿宿主调用预算', () {
    late String script;

    setUpAll(() {
      final f = File('../../config/plugins/zhuiju.js');
      expect(f.existsSync(), isTrue);
      script = f.readAsStringSync();
    });

    test('text() 已改为纯 JS 解码，不再调用 host.b64e / host.b64d', () {
      // 静态判据：`text` 函数体里不该再出现 b64 调用。
      // 这条比跑一次详情页便宜得多，能在改坏时立刻发现。
      final m = RegExp(r'function text\(hexBytes\)\s*\{([\s\S]*?)\n\}')
          .firstMatch(script);
      expect(m, isNotNull, reason: '找不到 text() 函数，正则需要更新');
      final body = m!.group(1)!;
      expect(body.contains('host.b64e'), isFalse,
          reason: 'text() 又在用 host.b64e 了，详情页会撞穿 5000 次预算');
      expect(body.contains('host.b64d'), isFalse,
          reason: 'text() 又在用 host.b64d 了，详情页会撞穿 5000 次预算');
    });

    test('hexToText 对中文 / ASCII / emoji 都能正确解码', () async {
      // 与宿主解码对拍：同一段字节，两条路径必须得到同一串。
      const samples = <String>[
        '兰香如故',
        '全47集',
        'abc123',
        'https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/x.jpg',
        '剧集·第一季（完结）',
      ];

      final hexes = <String>[];
      for (final one in samples) {
        hexes.add(utf8.encode(one).map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      }

      final r = await PluginRuntime.instance.call(
        script: '$script\n'
            'function decodeAll(a) {\n'
            '  var out = [];\n'
            '  for (var i = 0; i < a.length; i++) out.push(hexToText(a[i]));\n'
            '  return JSON.stringify(out);\n'
            '}\n',
        entry: 'decodeAll',
        // **必须再套一层数组**：argsJson 是「位置参数列表」，
        // 直接给 jsonEncode(hexes) 会把 5 个 hex 当成 5 个位置参数，
        // decodeAll 只收到第一个（而且它是字符串，遍历出来是单个字符）。
        argsJson: jsonEncode(<Object?>[hexes]),
      );

      expect(r.ok, isTrue, reason: 'hexToText 调用失败：${r.error}');
      final got = (jsonDecode(r.value) as List).cast<String>();
      expect(got, samples);
    });

    test('hexToText 遇到非法字节不抛异常（返回替换符）', () async {
      // 线上数据偶尔夹坏字节；抛异常会让整页解析失败，
      // 而一个替换符只影响那一个字符。
      final r = await PluginRuntime.instance.call(
        script: '$script\n'
            'function bad(a) { return JSON.stringify(hexToText(a)); }\n',
        entry: 'bad',
        argsJson: jsonEncode(<Object?>['e4bda0fffe']),
      );
      expect(r.ok, isTrue, reason: '非法 hex 不应该抛异常：${r.error}');
      expect(r.value, contains('你'));
    });

    test('parseDetail 不依赖宿主解码：模拟 700 条 video 仍能出结果', () async {
      // 直接构造一个「很多集」的详情响应交给 parseDetail。
      // 每条 video 只需 3 个字段，700 条 = 2100 次文本解码；
      // 旧实现是 2100 × 2 = 4200 次宿主调用（叠加其它开销即超 5000）。
      String hexOf(String t) =>
          utf8.encode(t).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      String varint(int v) {
        var x = v;
        final out = <int>[];
        while (x >= 128) {
          out.add((x % 128) + 128);
          x = x ~/ 128;
        }
        out.add(x);
        return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }

      String fStr(int no, String t) {
        final h = hexOf(t);
        return varint(no * 8 + 2) + varint(h.length ~/ 2) + h;
      }

      // video: token=1(varint 这里用字符串字段代替), name=2, url=4, source=9, ep=13
      // 字段 29 是 videos，重复出现即为数组；29<<3|2 = 234 = 0xea 0x01
      String fVideos(String body) => 'ea01${varint(body.length ~/ 2)}$body';

      final buf = StringBuffer();
      for (var i = 1; i <= 700; i++) {
        buf.write(fVideos(
          fStr(2, '第$i集') +
              fStr(4, 'path-$i') +
              fStr(9, 'line${i % 14}') +
              fStr(13, '$i'),
        ));
      }
      final dataHex = buf.toString();

      // 包一层 ApiResult{code=200, data}
      final api = '08c8011a${varint(dataHex.length ~/ 2)}$dataHex';

      final payload = base64.encode(List<int>.generate(
          api.length ~/ 2,
          (i) => int.parse(api.substring(i * 2, i * 2 + 2), radix: 16)));

      final r = await PluginRuntime.instance.call(
        script: script,
        entry: 'parseDetail',
        argsJson: jsonEncode(<Object?>[
          payload,
          <String, Object?>{'baseUrl': 'http://x', 'sourceId': 'zhuiju'},
        ]),
      );
      expect(r.ok, isTrue,
          reason: '700 条 video 时 parseDetail 失败（宿主调用预算？）：${r.error}');
      final out = jsonDecode(r.value) as Map;
      final lines = out['lines'] as List;
      expect(lines, isNotEmpty, reason: '应该解析出线路');
      final total = lines.fold<int>(
          0, (a, l) => a + ((l as Map)['episodes'] as List).length);
      expect(total, 700, reason: '700 条 video 应全部解析出来');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}