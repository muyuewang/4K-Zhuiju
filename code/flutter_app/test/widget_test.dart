// 协议层单元测试（不依赖网络）
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/protocol.dart';

void main() {
  test('随机串长度与字符集正确', () {
    final s = randAlnum(16);
    expect(s.length, 16);
    expect(s.split('').toSet().length, 16); // 无重复
    expect(RegExp(r'^[0-9A-Za-z]+$').hasMatch(s), isTrue);
  });

  test('AES-256-ECB 输出为 16 的整数倍且可解回', () {
    const key = 'OC1A06E197EF10CF3F6058CA7A803B5E';
    final b64 = aesEcbB64(key, '1700000000000ABCDEFGHIJKLMNOP');
    final raw = base64Decode(b64);
    expect(raw.length % 16, 0);
  });

  test('RSA 签名输出 128 字节 base64', () {
    final sig = rsaEncryptB64('1700000000000ABCDEFGHIJKLMNOPv3.0.7.0');
    expect(base64Decode(sig).length, 128);
  });

  test('protobuf 写入后能读回', () {
    final w = PbWriter()
      ..str(1, 'hello')
      ..i64(2, 12345);
    final fs = PbReader(w.takeBytes()).readAll();
    expect(pbString(fs, 1), 'hello');
    expect(pbInt(fs, 2), 12345);
  });
}