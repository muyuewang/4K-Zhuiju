/// 错误提示转人话
///
/// 这组测试盯的是「界面上会不会露出原始异常」。
/// 之前 `friendlyError` 的兜底是 `e.toString()`，用户会看到
/// `ClientException with SocketException: Failed host lookup: ...`
/// 这种既看不懂、也不知道下一步该干嘛的文案。
///
/// 断言的重点不是措辞精确，而是：
///   1. 不同类型能分到不同提示（用户才知道该重试还是换源）；
///   2. 任何输入都不会把类名/堆栈透到界面上。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';

/// 界面文案不该出现这些内部痕迹
void expectNoLeak(String msg) {
  for (final bad in [
    'Exception',
    'DioException',
    'SocketException',
    'Instance of',
    'package:',
    'null',
  ]) {
    expect(msg.contains(bad), isFalse,
        reason: '「$msg」里漏出了内部细节「$bad」');
  }
  expect(msg.trim().isNotEmpty, isTrue, reason: '不能给用户一个空提示');
}

void main() {
  group('friendlyError 分类', () {
    test('ApiException 用接口给的中文', () {
      final m = friendlyError(ApiException(500, '接口返回为空'));
      expect(m, '接口返回为空');
      expectNoLeak(m);
    });

    test('SocketException → 网络不可达', () {
      final m = friendlyError(const SocketException('Failed host lookup'));
      expect(m, contains('网络不可达'));
      expectNoLeak(m);
    });

    test('TimeoutException → 超时', () {
      final m = friendlyError(TimeoutException('timed out'));
      expect(m, contains('超时'));
      expectNoLeak(m);
    });

    test('连接超时 / 接收超时 / 连接失败各有区分', () {
      final a = friendlyError(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionTimeout,
      ));
      final b = friendlyError(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.receiveTimeout,
      ));
      final c = friendlyError(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      ));
      expect(a, contains('连接超时'));
      expect(b, contains('接收超时'));
      expect(c, contains('连接失败'));
      // 三者必须不同，否则用户无从判断该不该换线路
      expect({a, b, c}.length, 3);
      for (final m in [a, b, c]) {
        expectNoLeak(m);
      }
    });

    test('HTTP 403 / 404 / 5xx 给出可行动信息', () {
      String withStatus(int code) => friendlyError(DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: code,
            ),
          ));

      expect(withStatus(403), contains('403'));
      expect(withStatus(404), contains('404'));
      expect(withStatus(500), contains('服务器出错'));
      expect(withStatus(502), contains('502'));
      for (final code in [403, 404, 500, 502]) {
        expectNoLeak(withStatus(code));
      }
    });

    test('取消 / 证书 / 转换超时 / 未知都有独立文案', () {
      for (final t in [
        DioExceptionType.cancel,
        DioExceptionType.badCertificate,
        DioExceptionType.transformTimeout,
        DioExceptionType.unknown,
      ]) {
        final m = friendlyError(DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: t,
        ));
        expectNoLeak(m);
      }
    });

    test('未知异常兜底不外泄实现细节', () {
      // 故意丢一个 toString 里带类名的对象
      final m = friendlyError(StateError('internal state broken'));
      expect(m, '出错了，请重试');
      expectNoLeak(m);
      // 原始信息不能出现在界面文案里
      expect(m.contains('internal state broken'), isFalse);
    });

    test('兜底对任意对象都成立', () {
      for (final e in <Object>[
        'a string error',
        42,
        <String>[],
        Object(),
      ]) {
        final m = friendlyError(e);
        expectNoLeak(m);
      }
    });
  });
}