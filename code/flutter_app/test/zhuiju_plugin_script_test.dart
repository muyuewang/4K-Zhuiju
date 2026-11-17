/// 橘汁插件在真实 QuickJS 里的离线验证。
///
/// 这个源三步都和别的源不同：protobuf 请求体、RSA/AES 签名头、
/// protobuf 响应。夹具是按 `lib/core/protocol.dart` 的字段号生成的
/// 标准 protobuf 帧（站点当前 502，无法抓新样本）。
///
/// 验证目标：请求体能被宿主按 hex 解码成原始字节、签名头结构正确、
/// 三个接口的 protobuf 解析不丢字段。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  String fixture(String n) => File('test/fixtures/$n').readAsStringSync().trim();

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final f = File('../../config/plugins/zhuiju.js');
    expect(f.existsSync(), isTrue);
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'http://juziapp.hzhcbkj.cn',
      'finalUrl': 'http://juziapp.hzhcbkj.cn/api/proto/v5/drama/search',
      'sourceId': 'zhuiju',
    };
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  Future<Map> call(String entry, List<Object?> args) async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode(args),
    );
    expect(r.ok, isTrue, reason: '$entry 调用失败：${r.error}');
    // buildBody 返回 hex 字符串，原样传回，不是 JSON 对象。
    if (entry == 'buildBody') return <String, Object>{'v': r.value};
    return jsonDecode(r.value) as Map;
  }

  test('buildBody 产出可解码的 protobuf hex 帧', () async {
    final out = await call('buildBody', [
      <String, dynamic>{'page': '1', 'pagesize': '20'}
    ]);
    final hex = out is String ? out : out['v'];
    expect(hex.length % 2, 0);
    final bytes = hexDecode(hex);
    expect(bytes.isNotEmpty, isTrue);
    // 5 个字段：aes1 / aes2 / fake / ts / r8
    var fieldOneCount = 0;
    for (final b in bytes) {
      if (b == 0x0a) fieldOneCount++;
    }
    expect(fieldOneCount, greaterThanOrEqualTo(1));
  });

  test('sign 产出 publicParams 与动态 hex body', () async {
    final out = await call('sign', [
      <String, dynamic>{
        'url': 'http://juziapp.hzhcbkj.cn/api/proto/v5/drama/search',
        'method': 'POST',
        'query': <String, dynamic>{
          'page': '1', 'pagesize': '20', 'searchKeys': '沙海'
        },
        'headers': <String, dynamic>{},
        'body': '',
        'vars': <String, dynamic>{},
        'ctx': <String, dynamic>{},
      }
    ]);
    final h = out['headers'] as Map;
    final pp = jsonDecode(h['publicParams'] as String) as Map;
    expect(pp['vApp'], '3070');
    expect(pp['sig'], isNotEmpty);
    expect(pp['sig2'].toString().length, 8);
    expect(pp['sig3'], isNotEmpty);
    expect(hexDecode(out['body'] as String).isNotEmpty, isTrue);
  });

  test('清单的 bin + hex 组合能被正确解析', () {
    final m = PluginManifest.fromJson(<String, dynamic>{
      'id': 'zhuiju', 'name': '橘汁', 'baseUrl': 'http://juziapp.hzhcbkj.cn',
      'script': 'config/plugins/zhuiju.js',
      'categories': <dynamic>[{'id': '', 'name': '推荐'}],
      'home': <String, dynamic>{'path': '/api/proto/v5/drama/search'},
      'search': <String, dynamic>{
        'path': '/api/proto/v5/drama/search', 'method': 'POST',
        'bodyFormat': 'hex', 'responseType': 'bin',
      },
    })!;
    final req = m.searchRequest!;
    expect(req.bodyFormat, 'hex');
    expect(req.isBinaryResponse, isTrue);

    final prepared = prepareRequest(
      manifest: m,
      req: req,
      params: const <String, String>{},
    );
    // 空 hex 模板解出空字节数组；真正的体由 sign 钩子现算并覆盖。
    expect(prepared.bodyBytes, isEmpty);
    expect(prepared.bodyFormat, 'hex');
  });

  test('parseList 解析 protobuf 列表', () async {
    final out = await call('parseList', [fixture('zhuiju_list.b64'), ctx]);
    final items = out['items'] as List;
    expect(items.length, 2);
    expect((items[0] as Map)['id'], '1001');
    expect((items[0] as Map)['name'], '沙海');
    expect((items[0] as Map)['pic'], 'http://img/a.jpg');
    expect((items[0] as Map)['actor'], '甲 / 乙');
  });

  test('parseDetail 解析分线路选集', () async {
    final out = await call('parseDetail', [fixture('zhuiju_detail.b64'), ctx]);
    expect(out['name'], '沙海');
    final lines = out['lines'] as List;
    expect(lines.length, 1);
    expect((lines.first as Map)['line'], 'bfzym3u8');
    final eps = (lines.first as Map)['episodes'] as List;
    expect(eps.length, 2);
    expect((eps.first as Map)['url'], 'http://cdn/a.m3u8');
    expect((eps.first as Map)['isLive'], false);
  });

  test('parseResolve 解析播放地址', () async {
    final out = await call('parseResolve', [fixture('zhuiju_play.b64'), ctx]);
    expect(out['url'], 'https://cdn.example.com/real/index.m3u8');
  });

  test('坏 base64 不抛异常', () async {
    final out = await call('parseList', ['not-base64!', ctx]);
    expect(out['items'], isEmpty);
  });
}
