/// 加载器的缓存往返与容错。
///
/// 为什么不测网络：`refresh()` 依赖真实镜像，把它写进测试会让 CI 因为
/// 「GitHub 今天不通」而红——那种红没有信息量，也不代表代码有问题。
/// 网络链路由 `plugin_script_test.dart`（真实脚本 + 真实应答结构）和
/// 手工验证覆盖。
///
/// 这里只测**纯函数部分**，而它们恰好是最容易静默出错的地方：
/// 缓存读写如果不等价，用户重启后会发现「源变了样」（分类丢了、
/// POST 变 GET），而这一切都不会有任何报错。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_loader.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';

LoadedPlugin _mk({String id = 'js_a', bool enabled = true}) {
  final m = PluginManifest.fromJson(<String, dynamic>{
    'id': id,
    'name': '源 $id',
    'baseUrl': 'https://api.example.com',
    'script': 'config/plugins/maccms-json.js',
    'description': '说明',
    'version': 3,
    'enabled': enabled,
    'vars': <String, String>{'key': 'v1'},
    'defaultHeaders': <String, String>{'Referer': 'https://r/'},
    'categories': [
      {'id': '26', 'name': '电影'},
      {'id': '31', 'name': '国产剧'},
    ],
    'list': {
      'path': '/api/vod/',
      'query': {'ac': 'list', 'pg': '{page}'},
    },
    'search': {
      'path': '/api/vod/',
      'method': 'POST',
      'body': 'wd={keyword}&pg={page}',
    },
    'detail': {
      'path': '/api/vod/',
      'query': {'ids': '{id}'},
    },
    'resolve': {
      'path': '/api/play/',
      'query': {'id': '{id}'},
    },
  })!;
  expect(m.validate(), isNull, reason: '测试夹具本身要合法');
  return LoadedPlugin(manifest: m, script: 'function parseList(){return {"items":[]}}');
}

void main() {
  group('LoadedPlugin 缓存往返', () {
    test('存进去再读出来完全等价', () {
      final p1 = _mk();
      // 走一遍真实的落盘/读盘路径：toJson → jsonEncode → jsonDecode → fromJson
      final wire = jsonDecode(jsonEncode(p1.toJson()));
      final p2 = LoadedPlugin.fromJson(wire);

      expect(p2, isNotNull);
      final a = p1.manifest;
      final b = p2!.manifest;

      expect(b.id, a.id);
      expect(b.name, a.name);
      expect(b.baseUrl, a.baseUrl);
      expect(b.script, a.script);
      expect(b.description, a.description);
      expect(b.version, a.version);
      expect(b.enabled, a.enabled);
      expect(b.vars, a.vars);
      expect(b.defaultHeaders, a.defaultHeaders);
      expect(b.categories.map((e) => '${e.id}:${e.name}'),
          a.categories.map((e) => '${e.id}:${e.name}'));

      // 请求必须逐项等价：POST 变 GET 会让搜索静默失效
      expect(b.listRequest!.path, a.listRequest!.path);
      expect(b.listRequest!.query, a.listRequest!.query);
      expect(b.searchRequest!.method, 'POST');
      expect(b.searchRequest!.body, a.searchRequest!.body);
      expect(b.detailRequest!.query, a.detailRequest!.query);
      expect(b.resolveRequest!.path, a.resolveRequest!.path);

      // 脚本内容原样保留
      expect(p2.script, p1.script);
      // 读回来之后仍然合法
      expect(b.validate(), isNull);
    });

    test('缓存里的坏条目被丢掉，不抛异常', () {
      // 这条是「用户升级后插件全没了」的防线：旧版本缓存的结构
      // 可能和新版本不同，读的时候必须能跳过而不是崩。
      for (final bad in <Object?>[
        null,
        'string',
        123,
        <String, dynamic>{}, // 空 map
        <String, dynamic>{'manifest': null, 'script': 'x'},
        <String, dynamic>{'manifest': {'id': 'x'}, 'script': 'y'}, // 清单残缺
        <String, dynamic>{'manifest': _mk().manifest.toJson(), 'script': ''},
        <String, dynamic>{'manifest': _mk().manifest.toJson(), 'script': 123},
      ]) {
        expect(LoadedPlugin.fromJson(bad), isNull,
            reason: '应跳过坏缓存：$bad');
      }
    });

    test('缓存里不合法的清单（id 有空格）也被拒', () {
      final json = _mk().toJson();
      (json['manifest'] as Map)['id'] = 'js a';
      expect(LoadedPlugin.fromJson(json), isNull);
    });
  });

  group('镜像配置', () {
    test('国内镜像排在原始地址之前', () {
      const mirrors = PluginLoader.kMirrors;
      expect(mirrors.length, greaterThanOrEqualTo(2));

      // 原始地址在国内不通（实测 HTTP 000），必须排在最后当兜底
      expect(mirrors.last, startsWith('https://raw.githubusercontent.com/'));
      for (var i = 0; i < mirrors.length - 1; i++) {
        expect(mirrors[i].contains('ghproxy') || mirrors[i].contains('gh-proxy'),
            isTrue,
            reason: '第 ${i + 1} 个应是国内镜像：${mirrors[i]}');
      }
    });

    test('每个镜像基址都以斜杠结尾（后面直接拼相对路径）', () {
      for (final m in PluginLoader.kMirrors) {
        expect(m.endsWith('/'), isTrue, reason: '缺结尾斜杠会拼出错误 URL：$m');
        expect(m.startsWith('https://'), isTrue, reason: '配置必须走 HTTPS：$m');
      }
    });

    test('镜像指向本仓库的 main 分支', () {
      for (final m in PluginLoader.kMirrors) {
        expect(m, contains('muyuewang/4K-Zhuiju'));
        expect(m, contains('/main/'));
      }
    });
  });

  group('配置目录', () {
    test('配置目录常量与 README/索引一致', () {
      expect(kPluginConfigDir, 'config/plugins');
    });
  });

  group('破缓存时间戳', () {
    final t1 = DateTime(2026, 11, 17, 18, 0, 0, 123, 456);

    test('强制刷新用微秒级，同一小时内也能拿到不同 URL', () {
      // 手动刷新必须每次都换戳，否则 CDN 回缓存的旧 index，
      // 表现就是「提示已更新，源却没变」。
      final a = PluginLoader.cacheBustStamp(force: true, now: t1);
      final b = PluginLoader.cacheBustStamp(
          force: true, now: t1.add(const Duration(microseconds: 1)));
      expect(a, isNot(b));
      expect(a.length, greaterThan(10), reason: '应是微秒时间戳而非小时取整');
    });

    test('自动刷新用小时级，同一小时内复用同一戳以省流量', () {
      final a = PluginLoader.cacheBustStamp(force: false, now: t1);
      final b = PluginLoader.cacheBustStamp(
          force: false, now: t1.add(const Duration(minutes: 30)));
      expect(a, b, reason: '启动自动刷新不必每次回源');
    });

    test('两种方式的时间戳都是纯数字，能安全拼进 query', () {
      for (final force in [true, false]) {
        final s = PluginLoader.cacheBustStamp(force: force, now: t1);
        expect(RegExp(r'^\d+$').hasMatch(s), isTrue);
      }
    });
  });
}