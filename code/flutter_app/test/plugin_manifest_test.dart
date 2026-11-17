/// 插件清单的解析与校验。
///
/// 这些用例的意义：清单是**远程下发**的，写错一个字段的现象是
/// 「源静默不可用」——用户看到的是转圈然后失败，日志里什么都没有。
/// 所以每条校验都值得钉住，尤其是「该拒的必须拒」这部分。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';

/// 一份最小可用配置，各用例在它基础上改。
Map<String, dynamic> minimalJson() => <String, dynamic>{
      'id': 'js_demo',
      'name': '示例源',
      'baseUrl': 'https://api.example.com',
      'script': 'config/plugins/maccms-json.js',
      'categories': [
        {'id': '26', 'name': '电影'},
      ],
      'list': {
        'path': '/api.php/provide/vod/',
        'query': {'ac': 'list', 't': '{category}', 'pg': '{page}'},
      },
      'search': {
        'path': '/api.php/provide/vod/',
        'query': {'ac': 'detail', 'wd': '{keyword}', 'pg': '{page}'},
      },
      'detail': {
        'path': '/api.php/provide/vod/',
        'query': {'ac': 'detail', 'ids': '{id}'},
      },
    };

void main() {
  group('PluginManifest.fromJson', () {
    test('最小配置能解析', () {
      final m = PluginManifest.fromJson(minimalJson());
      expect(m, isNotNull);
      expect(m!.id, 'js_demo');
      expect(m.name, '示例源');
      expect(m.baseUrl, 'https://api.example.com');
      expect(m.categories.length, 1);
      expect(m.categories.first.id, '26');
      expect(m.canBrowse, isTrue);
      expect(m.canSearch, isTrue);
      expect(m.validate(), isNull);
    });

    test('缺必填字段返回 null（不是抛异常）', () {
      for (final field in ['id', 'name', 'baseUrl', 'script']) {
        final j = minimalJson()..remove(field);
        expect(PluginManifest.fromJson(j), isNull, reason: '缺 $field 应返回 null');
      }
    });

    test('分类支持简写（直接给字符串 id）', () {
      final j = minimalJson()
        ..['categories'] = ['26', '31'];
      final m = PluginManifest.fromJson(j)!;
      expect(m.categories.map((e) => e.id), ['26', '31']);
      // 简写时名字用 id 顶替
      expect(m.categories.first.name, '26');
    });

    test('request 的 method 只接受 GET/POST', () {
      for (final bad in ['PUT', 'DELETE', 'PATCH', 'HEAD']) {
        final j = minimalJson();
        (j['list'] as Map)['method'] = bad;
        final m = PluginManifest.fromJson(j);
        // fromJson 里 PluginRequest 返回 null → listRequest 为 null，
        // 于是 canBrowse 为 false，validate 会报「既不能浏览也不能搜索」
        expect(m!.listRequest, isNull, reason: '$bad 应被拒绝');
      }
    });

    test('method 大小写不敏感', () {
      final j = minimalJson();
      (j['search'] as Map)['method'] = 'post';
      final m = PluginManifest.fromJson(j)!;
      expect(m.searchRequest!.isPost, isTrue);
    });
  });

  group('validate 拒绝坏配置', () {
    test('id 为空', () {
      final m = PluginManifest.fromJson(minimalJson()..['id'] = '')!;
      expect(m.validate(), contains('id'));
    });

    test('id 含非法字符（会破坏收藏里的 sourceId 比较）', () {
      for (final bad in ['js demo', 'js/demo', 'JS_DEMO', 'js.demo', 'js 示例']) {
        final m = PluginManifest.fromJson(minimalJson()..['id'] = bad)!;
        expect(m.validate(), isNotNull, reason: '"$bad" 应被拒绝');
      }
    });

    test('id 过长', () {
      final m = PluginManifest.fromJson(
          minimalJson()..['id'] = 'a' * 41)!;
      expect(m.validate(), contains('过长'));
    });

    test('name 为空', () {
      final m = PluginManifest.fromJson(minimalJson()..['name'] = '   ')!;
      expect(m.validate(), contains('name'));
    });

    test('既不能浏览也不能搜索 —— 用户切过去是空白页', () {
      final j = minimalJson()
        ..['categories'] = <Object>[]
        ..remove('list')
        ..remove('search');
      final m = PluginManifest.fromJson(j)!;
      expect(m.canBrowse, isFalse);
      expect(m.canSearch, isFalse);
      expect(m.validate(), contains('空白页'));
    });

    test('只有搜索没有分类列表 → 允许（搜索结果仍可用）', () {
      final j = minimalJson()
        ..['categories'] = <Object>[]
        ..remove('list');
      final m = PluginManifest.fromJson(j)!;
      expect(m.validate(), isNull);
    });
  });

  group('validateBaseUrl', () {
    test('接受 http / https', () {
      expect(PluginManifest.validateBaseUrl('https://a.com'), isNull);
      expect(PluginManifest.validateBaseUrl('http://a.com'), isNull);
      expect(PluginManifest.validateBaseUrl('https://a.com:8443'), isNull);
    });

    test('允许带路径前缀（接口挂在子路径下的站）', () {
      expect(PluginManifest.validateBaseUrl('https://cdn.a.com/api/'), isNull);
      expect(PluginManifest.validateBaseUrl('https://a.com/api/v2'), isNull);
    });

    test('拒绝非 http(s)', () {
      for (final bad in [
        'ftp://a.com',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'a.com',
        '',
      ]) {
        expect(PluginManifest.validateBaseUrl(bad), isNotNull,
            reason: '"$bad" 应被拒绝');
      }
    });

    test('拒绝带用户名密码（凭证泄漏形态）', () {
      expect(PluginManifest.validateBaseUrl('https://u:p@a.com'), isNotNull);
    });

    test('拒绝超长', () {
      expect(
          PluginManifest.validateBaseUrl('https://a.com/${'x' * 250}'), isNotNull);
    });
  });

  group('请求头禁用项', () {
    test('defaultHeaders 里出现 Host/Cookie/Authorization 一律拒绝', () {
      for (final bad in ['Host', 'Cookie', 'Authorization', 'cookie']) {
        final j = minimalJson()
          ..['defaultHeaders'] = <String, String>{bad: 'x'};
        final m = PluginManifest.fromJson(j)!;
        expect(m.validate(), contains('不允许出现'),
            reason: '$bad 应被拒绝');
      }
    });

    test('单条 request 的 headers 同样受限', () {
      final j = minimalJson();
      (j['detail'] as Map)['headers'] = <String, String>{'Host': 'evil.com'};
      final m = PluginManifest.fromJson(j)!;
      expect(m.validate(), contains('不允许出现'));
    });

    test('普通头（UA/Referer）允许', () {
      final j = minimalJson()
        ..['defaultHeaders'] = <String, String>{
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://a.com/',
        };
      final m = PluginManifest.fromJson(j)!;
      expect(m.validate(), isNull);
    });
  });

  group('toJson 往返', () {
    test('存进去再读出来完全等价', () {
      final j = minimalJson()
        ..['vars'] = <String, String>{'key': 'abcd'}
        ..['defaultHeaders'] = <String, String>{'Referer': 'https://a.com/'}
        ..['resolve'] = <String, dynamic>{'path': '/play', 'query': {'id': '{id}'}};
      final m1 = PluginManifest.fromJson(j)!;
      final json2 = jsonDecode(jsonEncode(m1.toJson()));
      final m2 = PluginManifest.fromJson(json2)!;

      expect(m2.id, m1.id);
      expect(m2.name, m1.name);
      expect(m2.baseUrl, m1.baseUrl);
      expect(m2.script, m1.script);
      expect(m2.categories.map((e) => e.id), m1.categories.map((e) => e.id));
      expect(m2.vars, m1.vars);
      expect(m2.defaultHeaders, m1.defaultHeaders);
      expect(m2.listRequest!.path, m1.listRequest!.path);
      expect(m2.listRequest!.query, m1.listRequest!.query);
      expect(m2.resolveRequest!.path, '/play');
      expect(m2.validate(), isNull);
    });
  });

  group('仓库里的真实配置必须合法', () {
    /// 这条最重要：配置写错了，App 侧的表现是「这个源不出现」，
    /// 而没人会去看日志。测试里直接读仓库文件，把问题挡在推送之前。
    test('index.json 每条都通过校验', () {
      final file = File('../../config/plugins/index.json');
      expect(file.existsSync(), isTrue,
          reason: '找不到 ${file.absolute.path}');

      final root = jsonDecode(file.readAsStringSync()) as Map;
      final list = root['plugins'] as List;
      expect(list, isNotEmpty, reason: 'plugins 不能为空');

      final seenIds = <String>{};
      for (final raw in list) {
        final m = PluginManifest.fromJson(raw);
        expect(m, isNotNull, reason: '解析失败：$raw');
        final err = m!.validate();
        expect(err, isNull, reason: '${m.id} 校验失败：$err');
        expect(seenIds.add(m.id), isTrue, reason: 'id 重复：${m.id}');
      }
    });

    test('index.json 里引用的脚本文件都存在且非空', () {
      final file = File('../../config/plugins/index.json');
      final root = jsonDecode(file.readAsStringSync()) as Map;
      for (final raw in root['plugins'] as List) {
        final m = PluginManifest.fromJson(raw)!;
        // script 是相对仓库根的路径
        final scriptFile = File('../../${m.script}');
        expect(scriptFile.existsSync(), isTrue,
            reason: '${m.id} 引用的脚本不存在：${m.script}');
        expect(scriptFile.readAsStringSync().trim(), isNotEmpty,
            reason: '${m.id} 的脚本是空的');
      }
    });

    test('脚本必须位于 config/plugins 下（防止下载仓库其他文件）', () {
      final file = File('../../config/plugins/index.json');
      final root = jsonDecode(file.readAsStringSync()) as Map;
      for (final raw in root['plugins'] as List) {
        final m = PluginManifest.fromJson(raw)!;
        expect(m.script.startsWith('config/plugins/'), isTrue,
            reason: '${m.id} 的 script 越界：${m.script}');
        expect(m.script.contains('..'), isFalse);
      }
    });
  });
}