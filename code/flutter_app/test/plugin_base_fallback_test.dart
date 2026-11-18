/// 备用根地址（`baseUrlFallbacks`）。
///
/// 为什么值得单独测：采集站「同一份数据多个域名、只有部分可达」是常态
/// （实测非凡 `cj.ffzyapi.com` 被墙而 `api.ffzyapi.com` 正常）。这套兜底
/// 一旦写错，现象是**源静默不可用**——用户看到转圈然后失败，没有任何
/// 提示告诉他是「备用地址根本没被用上」。
///
/// 重点钉三件事：
///   1. 解析：能读出来，非法条目被丢弃而不是让整条源作废；
///   2. 顺序：主地址必须排第一，去重后接备用；
///   3. 拼装：`baseOverride` 真的换了根地址，不是只换了显示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';

Map<String, dynamic> baseJson([Object? fallbacks]) => <String, dynamic>{
      'id': 'js_demo',
      'name': '示例源',
      'baseUrl': 'https://api.example.com',
      if (fallbacks != null) 'baseUrlFallbacks': fallbacks,
      'script': 'config/plugins/maccms-json.js',
      'categories': [
        {'id': '26', 'name': '电影'},
      ],
      'list': {
        'path': '/api.php/provide/vod/',
        'query': {'ac': 'list', 'pg': '{page}'},
      },
    };

void main() {
  group('解析 baseUrlFallbacks', () {
    test('没配时为空，且不影响使用', () {
      final m = PluginManifest.fromJson(baseJson())!;
      expect(m.baseUrlFallbacks, isEmpty);
      expect(m.baseCandidates, ['https://api.example.com']);
    });

    test('正常配置能读出来', () {
      final m = PluginManifest.fromJson(
        baseJson(['http://cj.example.com', 'https://b.example.net']),
      )!;
      expect(m.baseUrlFallbacks,
          ['http://cj.example.com', 'https://b.example.net']);
    });

    test('语法非法的条目被丢弃，但不拖垮整条清单', () {
      // null / 空串 / 非 http 协议，混在合法条目里。
      //
      // 注意 `http://127.0.0.1/` 不在这里测：它**语法合法**，
      // 解析阶段（validateBaseUrl）放行是对的——SSRF 拦截是
      // 请求阶段的事（见下面 prepareRequest 那组用例）。
      final m = PluginManifest.fromJson(baseJson([
        'http://ok.example.com',
        null,
        '   ',
        'ftp://x.com',
        123,
        'https://also-ok.example.com',
      ]))!;
      // 关键：解析器不能返回 null，源还在，只是少了几个备用地址
      expect(m.baseUrlFallbacks,
          ['http://ok.example.com', 'https://also-ok.example.com']);
    });

    test('重复条目只留一份', () {
      final m = PluginManifest.fromJson(baseJson([
        'http://a.example.com',
        'http://a.example.com',
      ]))!;
      expect(m.baseUrlFallbacks, ['http://a.example.com']);
    });
  });

  group('baseCandidates 顺序', () {
    test('主地址永远排第一', () {
      final m = PluginManifest.fromJson(
        baseJson(['http://cj.example.com']),
      )!;
      expect(m.baseCandidates, [
        'https://api.example.com',
        'http://cj.example.com',
      ]);
    });

    test('主地址被误写进备用列表时不会重复', () {
      // 手滑把主地址也抄进 fallback 是常见错，会在同一个死域名上白试两次
      final m = PluginManifest.fromJson(baseJson([
        'https://api.example.com',
        'http://cj.example.com',
      ]))!;
      expect(m.baseCandidates, [
        'https://api.example.com',
        'http://cj.example.com',
      ]);
    });
  });

  group('toJson 往返', () {
    test('备用地址能存进缓存再读回来', () {
      final src = PluginManifest.fromJson(
        baseJson(['http://cj.example.com']),
      )!;
      final round = PluginManifest.fromJson(
        jsonDecode(jsonEncode(src.toJson())),
      )!;
      expect(round.baseUrlFallbacks, ['http://cj.example.com']);
      expect(round.baseCandidates, src.baseCandidates);
    });

    test('没配备用地址时不写进缓存（避免文件变吵）', () {
      final m = PluginManifest.fromJson(baseJson())!;
      expect(m.toJson().containsKey('baseUrlFallbacks'), isFalse);
    });
  });

  group('prepareRequest 真的换根地址', () {
    test('baseOverride 覆盖 manifest.baseUrl', () {
      final m = PluginManifest.fromJson(
        baseJson(['http://cj.example.com']),
      )!;
      final req = m.listRequest!;

      final byDefault = prepareRequest(
        manifest: m,
        req: req,
        params: const {'page': '1'},
      );
      expect(byDefault.url, startsWith('https://api.example.com/api.php'));

      final overridden = prepareRequest(
        manifest: m,
        req: req,
        params: const {'page': '1'},
        baseOverride: 'http://cj.example.com',
      );
      expect(overridden.url, startsWith('http://cj.example.com/api.php'));
      // query 部分必须原样保留：换域名只该换主机，不该丢参数
      expect(overridden.url, contains('pg=1'));
    });

    test('override 也要过 SSRF 校验，不能拿它绕开防护', () {
      final m = PluginManifest.fromJson(baseJson())!;
      expect(
        () => prepareRequest(
          manifest: m,
          req: m.listRequest!,
          params: const {'page': '1'},
          baseOverride: 'http://192.168.1.1',
        ),
        throwsA(isA<PluginFetchException>()),
      );
    });
  });

  group('仓库里的真实配置', () {
    test('配了备用地址的源，每条都合法且不等于主地址', () {
      final root = jsonDecode(
        File('../../config/plugins/index.json').readAsStringSync(),
      ) as Map;
      var withFallback = 0;
      for (final raw in root['plugins'] as List) {
        final m = PluginManifest.fromJson(raw)!;
        if (m.baseUrlFallbacks.isEmpty) continue;
        withFallback++;
        expect(m.baseCandidates.first, m.baseUrl);
        for (final b in m.baseUrlFallbacks) {
          expect(PluginManifest.validateBaseUrl(b), isNull, reason: '${m.id}: $b');
          expect(b, isNot(m.baseUrl), reason: '${m.id} 的备用地址与主地址相同');
        }
      }
      // 目前只有非凡和索尼有可用镜像；为 0 说明配置被改回去了
      expect(withFallback, greaterThan(0));
    });
  });
}
