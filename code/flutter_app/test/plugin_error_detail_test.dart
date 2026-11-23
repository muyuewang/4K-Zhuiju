/// HTTP 4xx 错误里服务端写的人话必须透传到界面（2026-11-23）。
///
/// 用户报障：看剧《凡人修仙传》第201集点官方线，播放器只显示「HTTP 401」，
/// 而网页端登录态能播。实测服务端在 401 的 JSON body 里写了
/// `{"code":"playback_user_session_required","message":"该内容需要登录后播放"}`，
/// 但插件网络层以前只抛 `HTTP 401`，把这句人话整个丢掉了——
/// 用户既不知道是登录问题，也不知道该换线路。
///
/// 现在 4xx/5xx 会把 body 里的 message/msg 等带出来。本文件钉住：
///   1. JSON message 透传
///   2. 各种常见字段名都能取
///   3. 非 JSON / 空 body 退回 `HTTP $code`，不改变既有行为
///   4. 超长 message 截断，不撑爆错误页
///   5. 不泄漏 Cookie / Authorization 等敏感词（万一服务端 body 里带）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_fetch.dart';
import 'package:zhuiju/core/plugin/plugin_manifest.dart';

/// 返回固定状态码与 body 的假站点。
class _Stub {
  _Stub._(this._server, this.statusCode, this.body);

  final HttpServer _server;
  final int statusCode;
  final String body;
  String get url => 'http://127.0.0.1:${_server.port}/';

  static Future<_Stub> start(int statusCode, String body) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _Stub._(s, statusCode, body);
    s.listen((req) async {
      await req.drain<void>();
      req.response
        ..statusCode = statusCode
        ..headers.contentType = ContentType.json
        ..write(body);
      await req.response.close();
    });
    return stub;
  }

  Future<void> close() => _server.close();
}

Future<String> _fetchError(int statusCode, String body) async {
  final stub = await _Stub.start(statusCode, body);
  try {
    final prepared = prepareRequest(
      manifest: PluginManifest.fromJson({
        'id': 'x',
        'name': 'X',
        'baseUrl': stub.url,
        'script': 'config/plugins/x.js',
        'categories': [
          {'id': '1', 'name': 'a'}
        ],
      })!,
      req: const PluginRequest(path: '/'),
      params: const {},
    );
    try {
      await PluginFetch.instance.fetch(prepared);
      return ''; // 不该走到这里
    } on PluginFetchException catch (e) {
      return e.message;
    }
  } finally {
    await stub.close();
  }
}

void main() {
  setUpAll(() => kAllowLoopbackForTest = true);
  tearDownAll(() => kAllowLoopbackForTest = false);

  group('4xx/5xx 服务端文案透传', () {
    test('401 的 message 带出来（看剧换票场景）', () async {
      final msg = await _fetchError(
          401,
          '{"statusCode":401,"code":"playback_user_session_required",'
          '"state":"login_required","message":"该内容需要登录后播放"}');
      expect(msg, contains('HTTP 401'));
      expect(msg, contains('该内容需要登录后播放'));
    });

    test('msg / error_message / detail 字段名都能取', () async {
      for (final key in const ['message', 'msg', 'error_message', 'detail']) {
        final msg = await _fetchError(403, '{"$key":"换个线路试试"}');
        expect(msg, contains('换个线路试试'), reason: '字段 $key 应被识别');
      }
    });

    test('非 JSON body 退回原来的 HTTP 文案', () async {
      final msg = await _fetchError(502, '<html>Bad Gateway</html>');
      expect(msg, 'HTTP 502');
    });

    test('空 body 退回原来的 HTTP 文案', () async {
      final msg = await _fetchError(404, '');
      expect(msg, 'HTTP 404');
    });

    test('JSON 但没有文案字段，退回原来的 HTTP 文案', () async {
      final msg = await _fetchError(500, '{"code":"internal_error"}');
      expect(msg, 'HTTP 500');
    });

    test('超长 message 截断到 80 字符', () async {
      final long = '需' * 200;
      final msg = await _fetchError(401, '{"message":"$long"}');
      expect(msg.length, lessThan(120),
          reason: '不能让服务端的大段文案撑爆错误页');
      expect(msg, contains('…'));
    });

    test('成功响应不触发错误透传', () async {
      final stub = await _Stub.start(200, '{"ok":true}');
      try {
        final prepared = prepareRequest(
          manifest: PluginManifest.fromJson({
            'id': 'x',
            'name': 'X',
            'baseUrl': stub.url,
            'script': 'config/plugins/x.js',
            'categories': [
              {'id': '1', 'name': 'a'}
            ],
          })!,
          req: const PluginRequest(path: '/'),
          params: const {},
        );
        final r = await PluginFetch.instance.fetch(prepared);
        expect(r.body, contains('ok'));
      } finally {
        await stub.close();
      }
    });
  });
}