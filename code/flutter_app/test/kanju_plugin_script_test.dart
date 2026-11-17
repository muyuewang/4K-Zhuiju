/// 看剧插件在真实 QuickJS 里的离线验证。
///
/// 签名对拍是重点：`buildSignature` 与 Dart 的 `KanjuSource.signHex`
/// 用固定四行串逐字节比较。签名错和服务端改版都表现成 401，
/// 不对比就只能靠猜。
///
/// 接口 JSON 样本按 `.tmp/kanju/probe*.txt` 里真实响应确认过的字段构造
/// （仓库里的抓包记录把 JSON 截断了，不能直接当夹具）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';
import 'package:zhuiju/core/source/kanju_source.dart';

import 'support/quickjs_env.dart';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  const token = 'av_13MgWpKHqKMBQMZ01SYGtUmG2qPRjyQJD2xiAGTO1FeF7jUj_9OgBB9BWU_9h-nCJTY0R-sHllwjm_VWhey4KR0';

  final catalog = jsonEncode({
    'id': 'av_work_1',
    'title': '沙海',
    'poster_url': 'https://img.example.com/poster.webp',
    'description': '一段&lt;简介&gt;',
    'remarks': '盗墓笔记',
    'area': '中国大陆',
    'year': 2024,
    'directors': ['甲', '乙'],
    'actors': ['丙', '丁', '戊'],
    'content_kind': 'series',
    'episodes': [
      {'token': token, 'number': 1, 'title': '第1集'},
      {'token': '${token}_2', 'number': 2, 'title': '第2集'},
    ],
  });

  final resolve = jsonEncode({
    'line_options': [
      {
        'label': '官方线路', 'play_from': 'official',
        'url': 'resolve://TICKET123', 'resolve_required': true,
        'selected': true,
      },
      {
        'label': '采集线A', 'play_from': 'cja',
        'url': 'https://cdn.example.com/a/index.m3u8',
        'resolve_required': false, 'selected': false,
      },
      {
        'label': '采集线B', 'play_from': 'cjb',
        'url': 'https://cdn.example.com/b/index.m3u8',
        'resolve_required': false, 'selected': false,
      },
    ],
  });

  setUpAll(() {
    expect(ensureQuickJsLibrary(), isTrue);
    final f = File('../../config/plugins/kanju.js');
    expect(f.existsSync(), isTrue);
    script = f.readAsStringSync();
    expect(looksLikeInfiniteLoop(script), isFalse);

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://kanju.ai',
      'finalUrl': 'https://kanju.ai/v1/catalog/av_work_1',
      'sourceId': 'kanju',
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
    // 返回字符串的函数（buildSignature / pathQueryOf）原样传回，
    // 不是 JSON 对象，不能无脑 jsonDecode。
    if (entry == 'buildSignature' || entry == 'pathQueryOf') {
      return <String, Object>{'v': r.value};
    }
    return jsonDecode(r.value) as Map;
  }

  test('签名与内置实现逐字节一致', () async {
    const method = 'GET';
    const pathQuery = '/v1/browse/catalog?page=1&limit=20&q=%E6%B2%99';
    const ts = '1763370000123';
    const nonce = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    final expected = KanjuSource.signHex('$method\n$pathQuery\n$ts\n$nonce');
    final out = await call('buildSignature', [method, pathQuery, ts, nonce]);
    expect(out is String ? out : out['v'], expected);
  });

  test('pathQueryOf 保留编码后的中文参数', () async {
    final out = await call('pathQueryOf', [
      'https://kanju.ai/v1/browse/catalog?page=1&q=%E6%B2%99'
    ]);
    expect(out is String ? out : out['v'],
        '/v1/browse/catalog?page=1&q=%E6%B2%99');
  });

  test('sign 钩子输出三个签名头', () async {
    final out = await call('sign', [
      <String, dynamic>{
        'url': 'https://kanju.ai/v1/browse/catalog?page=1&limit=20',
        'method': 'GET',
        'query': <String, dynamic>{'page': '1', 'limit': '20'},
        'headers': <String, dynamic>{},
        'body': '',
        'vars': <String, dynamic>{},
        'ctx': <String, dynamic>{},
      }
    ]);
    final h = out['headers'] as Map;
    expect(h['x-ai-movie-timestamp'], isNotEmpty);
    expect(h['x-ai-movie-nonce'].toString().length, 32);
    expect(h['x-ai-movie-signature'].toString().length, 64);
  });

  test('parseList 解析 catalog 与首页分区流', () async {
    final catalogBody = jsonEncode({
      'cards': [
        {
          'id': 'a1', 'title': '沙海', 'poster_url': 'https://x/a.jpg',
          'genres': ['冒险', '悬疑'], 'year': 2024, 'score': 9.2,
        }
      ]
    });
    final feedBody = jsonEncode({
      'sections': [
        {
          'title': '大家都在看',
          'cards': [
            {'id': 'b1', 'title': '庆余年', 'poster_url': 'https://x/b.jpg'},
          ],
        }
      ]
    });

    final c = await call('parseList', [catalogBody, ctx]);
    expect((c['items'] as List).length, 1);
    expect((c['items'] as List).first['stars'], 9.2);

    final f = await call('parseList', [feedBody, ctx]);
    expect((f['items'] as List).length, 1);
    expect((f['items'] as List).first['id'], 'b1');
  });

  test('parseDetail 给每集生成 resolve:// 入口', () async {
    final out = await call('parseDetail', [catalog, ctx]);
    expect(out['name'], '沙海');
    expect(out['director'], '甲 / 乙');
    final lines = out['lines'] as List;
    expect(lines.length, 1);
    final eps = (lines.first as Map)['episodes'] as List;
    expect(eps.length, 2);
    expect((eps.first as Map)['url'], 'resolve://$token');
    expect((eps.first as Map)['token'], token);
  });

  test('parseResolve 挑直出线路，不被 selected 的官方线带偏', () async {
    final out = await call('parseResolve', [resolve, ctx]);
    expect(out['url'], 'https://cdn.example.com/a/index.m3u8');
  });

  test('parseResolve 官方线单独应答给出可操作提示', () async {
    final body = jsonEncode({
      'code': 'playback_user_session_required',
      'line_options': [
        {
          'label': '官方线路', 'play_from': 'official',
          'url': 'resolve://T', 'resolve_required': true,
        }
      ]
    });
    final out = await call('parseResolve', [body, ctx]);
    expect(out['url'], '');
    expect(out['error'], contains('换一条线路'));
  });
}
