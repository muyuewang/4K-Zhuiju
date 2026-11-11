/// 会话 Cookie 提取的回归测试。
///
/// 为什么单独为「从 Set-Cookie 里挑一个值」写测试：
///
/// 这段逻辑**错了也不报错**。取错 Cookie 不会抛异常，只会拿到空会话，
/// 之后所有官方线静默回 401 playback_user_session_required —— 这个错误
/// 和「源站改版」「密钥过期」的表现完全一样，只能靠真机点播放才发现。
///
/// 2026-11-11 实测踩过一次：`POST /v1/users/anonymous` 一次下发 5 条
/// 同名 Cookie，前 4 条是空值的删除指令，第 5 条才是真正的会话。
/// 原实现取第一条命中，于是每次都把会话主动删掉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/kanju_source.dart';

void main() {
  group('pickSessionCookie：会话 Cookie 提取', () {
    test('真实响应：跳过 4 条删除指令，取最后那条有效值', () {
      // 这段是 2026-11-11 抓到的真实响应（值做了替换）
      final raw = [
        'ai_movie_session=; Path=/v1; HttpOnly; SameSite=Lax; Max-Age=0; '
            'Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure, '
            'ai_movie_session=; Path=/v1; HttpOnly; SameSite=Lax; Max-Age=0; '
            'Expires=Thu, 01 Jan 1970 00:00:00 GMT; Domain=kanju.ai; Secure, '
            'ai_movie_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; '
            'Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure, '
            'ai_movie_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; '
            'Expires=Thu, 01 Jan 1970 00:00:00 GMT; Domain=kanju.ai; Secure, '
            'ai_movie_session=ums_test_token_value; Path=/; HttpOnly; '
            'SameSite=Lax; Max-Age=31535999; '
            'Expires=Thu, 11 Nov 2027 03:41:34 GMT; Domain=kanju.ai; Secure',
      ];
      expect(
        KanjuSource.pickSessionCookie(raw),
        'ai_movie_session=ums_test_token_value',
        reason: '取到空值就等于把会话删掉，之后所有官方线都会 401',
      );
    });

    test('空列表返回空串，不抛异常', () {
      expect(KanjuSource.pickSessionCookie(const []), '');
    });

    test('只有删除指令时不返回空值 Cookie', () {
      final raw = [
        'ai_movie_session=; Path=/; Max-Age=0',
        'ai_movie_session=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      ];
      expect(KanjuSource.pickSessionCookie(raw), '');
    });

    test('无关 Cookie 不被误取', () {
      final raw = [
        'other_session=abc; Path=/',
        '_ga=GA1.2.3; Path=/',
      ];
      expect(KanjuSource.pickSessionCookie(raw), '');
    });

    test('多条有效值时取最后一条（域名精化后覆盖前一条）', () {
      final raw = [
        'ai_movie_session=first; Path=/; Max-Age=100',
        'ai_movie_session=second; Path=/; Max-Age=100',
      ];
      expect(KanjuSource.pickSessionCookie(raw), 'ai_movie_session=second');
    });

    test('Max-Age 为负数的视为失效', () {
      final raw = [
        'ai_movie_session=bad; Path=/; Max-Age=-1',
        'ai_movie_session=good; Path=/; Max-Age=3600',
      ];
      expect(KanjuSource.pickSessionCookie(raw), 'ai_movie_session=good');
    });
  });
}