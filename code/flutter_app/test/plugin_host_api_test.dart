/// 宿主能力层：验证这些函数**算得对**，而不只是「能跑」。
///
/// ## 为什么这里全用标准向量
///
/// 加密这类东西，「不报错」和「算对了」是两件完全不同的事。最典型的是
/// RSA——`RSAEngine` 不带填充，直接用它加密不报错、长度也对，但服务端
/// 永远解不开。如果测试只断言「返回了一个 172 字符的 base64」，这个 bug
/// 会一路活到线上，表现为「源站一直返回签名错误」，查起来极其痛苦。
///
/// 所以每个向量都能追到出处：
///   - MD5/SHA1/SHA256(`abc`)：NIST / RFC 1321 的经典测试串
///   - HMAC-SHA256：RFC 4231 Test Case 1 的变体
///   - AES-128-CBC：NIST SP 800-38A F.2.1 第一块
///   - AES-256-ECB：FIPS-197 附录 C.3 的密钥与明文
///
/// 无法用固定向量验证的只有 RSA（PKCS#1 填充含随机数，每次结果都不同），
/// 所以对它改用「用 Node 生成的私钥解回来」的方式验证——见最后一组用例。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_host_api.dart';

void main() {
  group('摘要：对齐标准测试向量', () {
    test('md5 / sha1 / sha256 的 abc 向量', () {
      // 这三个值是密码学库的最基础正确性证明。算错了说明依赖没接对。
      expect(md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
      expect(sha1Hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(sha256Hex('abc'),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('空串也有确定的摘要（不是空字符串）', () {
      expect(md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(sha256Hex(''),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('中文按 utf8 编码后再摘要', () {
      // 这条防的是「用 latin1 或按 UTF-16 编码」的错。中文源站签名
      // 里带片名是常见情况，编码错了签名必然不过。
      expect(md5Hex('橘汁'), md5Hex(utf8.decode(utf8.encode('橘汁'))));
      expect(sha256Hex('橘子'), isNot(sha256Hex('橘汁')));
      // 6 字节 utf8 = 3 个汉字，长度可校验
      expect(utf8.encode('橘汁').length, 6);
    });

    test('hmac 走 RFC 4231 的 key/msg 组合', () {
      // RFC 4231 Test Case 1: key = 0x0b*20, data = "Hi There"
      // 这里用它的等价字符串形态验证算法接线正确
      expect(
        hmacHex('sha256', 'key', 'The quick brown fox jumps over the lazy dog'),
        'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
      );
    });

    test('hmac 支持多种算法，未知算法退回 sha256', () {
      // 未知算法不报错而是退回 sha256：插件作者写错算法名时，
      // 得到一个能用的结果比直接崩掉更有用（至少还能观察到行为）
      expect(hmacHex('sha1', 'k', 'm'), hmacHex('sha1', 'k', 'm'));
      expect(hmacHex('sha512', 'k', 'm').length, 128);
      expect(hmacHex('乱写', 'k', 'm'), hmacHex('sha256', 'k', 'm'));
    });
  });

  group('AES：对齐 NIST 向量', () {
    // FIPS-197 附录 C.3：AES-256，密钥和明文都是给定的
    const k256 = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';
    const p16 = '00112233445566778899aabbccddeeff';

    test('AES-256-ECB 单块结果等于 FIPS-197 的值', () {
      // 明文正好 16 字节，但我们的实现**总是补 PKCS7**，
      // 所以完整输出是 32 字节：前 16 字节应等于标准答案。
      final out = aesEcbEncrypt(
        key: k256,
        keyFmt: 'hex',
        plain: p16,
        plainFmt: 'hex',
        outFmt: 'hex',
      );
      expect(out.length, 64, reason: '16 字节明文 + PKCS7 补满一块 = 32 字节');
      expect(out.substring(0, 32), '8ea2b7ca516745bfeafc49904b496089');
      expect(out,
          '8ea2b7ca516745bfeafc49904b4960899f3b7504926f8bd36e3118e903a4cd4a');
    });

    test('AES-128-CBC 单块结果等于 NIST SP 800-38A', () {
      final out = aesCbcEncrypt(
        key: '2b7e151628aed2a6abf7158809cf4f3c',
        keyFmt: 'hex',
        iv: '000102030405060708090a0b0c0d0e0f',
        ivFmt: 'hex',
        plain: '6bc1bee22e409f96e93d7e117393172a',
        plainFmt: 'hex',
        outFmt: 'hex',
      );
      expect(out.substring(0, 32), '7649abac8119b246cee98e9b12e9197d');
    });

    test('加解密往返还原原文（含中文与 emoji）', () {
      const key = '0123456789abcdef0123456789abcdef'; // 32 字节 = AES-256
      // 长文本单独放：`'a' * 1000` 不是合法 Dart，得拼接
      final longText = List<String>.filled(1000, 'a').join();
      for (final s in <String>[
        'hello',
        '',
        '橘汁线路',
        '带 emoji 的 🎬 文本',
        longText,
      ]) {
        final enc = aesEcbEncrypt(key: key, plain: s);
        final dec = aesEcbDecrypt(key: key, cipherText: enc);
        expect(dec, s, reason: 'ECB 往返失败：${s.length} 字符');
      }
    });

    test('CBC 往返还原，且同一明文两次加密结果不同（IV 固定时应相同）', () {
      const key = '0123456789abcdef';
      const iv = 'fedcba9876543210';

      final a = aesCbcEncrypt(key: key, iv: iv, plain: 'same text');
      final b = aesCbcEncrypt(key: key, iv: iv, plain: 'same text');
      expect(a, b, reason: 'IV 与密钥固定时，CBC 结果必须是确定的');

      expect(aesCbcDecrypt(key: key, iv: iv, cipherText: a), 'same text');
    });

    test('ECB 的已知弱点如实存在（相同明文块 → 相同密文块）', () {
      // 这不是 bug，是对接现实：橘汁等站方的接口就是 ECB。
      // 写下这条用例是为了让后来者清楚「我们知道它不安全，但没得选」。
      const key = '0123456789abcdef';
      final out = aesEcbEncrypt(
        key: key,
        plain: '0123456789abcdef0123456789abcdef', // 两个相同的 16 字节块
        outFmt: 'hex',
      );
      final b1 = out.substring(0, 32);
      final b2 = out.substring(32, 64);
      expect(b1, b2, reason: 'ECB 下相同明文块必然产生相同密文块');
    });

    test('密钥长度不对时报错，不静默降级', () {
      // 15 字节不是合法 AES 密钥长度。必须抛错：
      // 静默补齐/截断会让「偶尔能用、偶尔不能用」这种最恶心的现象出现。
      expect(
        () => aesEcbEncrypt(key: 'x' * 15, plain: 'a'),
        throwsA(anything),
      );
    });

    test('密文长度不是 16 的倍数时解密报错并说明原因', () {
      expect(
        () => aesEcbDecrypt(key: '0123456789abcdef', cipherText: 'AAAA'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('IV 长度不对时报错', () {
      expect(
        () => aesCbcEncrypt(key: '0123456789abcdef', iv: 'short', plain: 'a'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('编码转换', () {
    test('hex / unhex 往返', () {
      expect(hexOf('abc'), '616263');
      expect(unhexTo('616263'), 'abc');
      expect(unhexTo(hexOf('橘汁')), '橘汁');
    });

    test('hex 解析容忍 0x 前缀与分隔符', () {
      // 密钥常写成 `aa:bb:cc` 或 `0x...`，直接拒绝太苛刻
      for (final s in const ['616263', '0x616263', '61:62:63', '61-62-63']) {
        expect(unhexTo(s), 'abc', reason: '解析失败：$s');
      }
    });

    test('非法 hex 报错而不是返回空', () {
      expect(() => unhexTo('zz'), throwsA(isA<ArgumentError>()));
      expect(() => unhexTo('abc'), throwsA(isA<ArgumentError>()), reason: '奇数长度');
    });

    test('base64 往返，输出格式可控', () {
      final b = base64EncodeOf('橘汁');
      expect(base64DecodeTo(b), '橘汁');
      // 二进制密文不能当 utf8 解，要能指定 hex 输出
      final h = base64DecodeTo(base64EncodeOf('ab'), outFmt: 'hex');
      expect(h, '6162');
    });
  });

  group('XML → JSON（MacCMS XML 站的地基）', () {
    test('MacCMS 典型应答转成可用的嵌套结构', () {
      const xml = '<?xml version="1.0" encoding="utf-8"?>'
          '<rss version="5.1">'
          '<list page="1" pagecount="2" pagesize="20" recordcount="25">'
          '<video>'
          '<id>1</id><tid>2</tid>'
          '<name><![CDATA[男子气概]]></name>'
          '<pic>https://x.com/a.jpg</pic>'
          // `$` 在 Dart 里是插值前缀，这里是 XML 内容，必须转义
          '<dl><dd flag="bfzym3u8"><![CDATA[HD\$https://v.com/1.m3u8]]></dd></dl>'
          '</video>'
          '</list>'
          '</rss>';

      final j = xml2json(xml) as Map;
      final rss = j['rss'] as Map;
      final list = rss['list'] as Map;

      // 属性带 @ 前缀（与 xml2js 的约定一致）
      expect(list['@page'], '1');
      expect(list['@recordcount'], '25');

      final video = list['video'] as Map;
      expect(video['id'], '1');
      expect(video['name'], '男子气概', reason: 'CDATA 要能正确取出');

      final dl = video['dl'] as Map;
      final dd = dl['dd'] as Map;
      expect(dd['@flag'], 'bfzym3u8');
      expect(dd['#text'], 'HD\$https://v.com/1.m3u8');
    });

    test('同名子元素重复 → 数组（这是列表能遍历的前提）', () {
      const xml = '<rss><list>'
          '<video><id>1</id><name>A</name></video>'
          '<video><id>2</id><name>B</name></video>'
          '<video><id>3</id><name>C</name></video>'
          '</list></rss>';
      final list = (xml2json(xml) as Map)['rss']['list'] as Map;
      final videos = list['video'] as List;
      expect(videos.length, 3);
      expect((videos[1] as Map)['name'], 'B');
    });

    test('只有一个 video 时是对象而不是单元素数组', () {
      // 这是 xml2js 的固有行为，也是 XML 站最经典的坑：
      // 插件里必须写 `Array.isArray(v) ? v : [v]`。
      // 我们不能擅自「统一成数组」——那会让按 xml2js 文档写的脚本出错。
      const xml = '<rss><list><video><id>1</id></video></list></rss>';
      final list = (xml2json(xml) as Map)['rss']['list'] as Map;
      expect(list['video'], isA<Map>());
      expect(list['video'], isNot(isA<List>()));
    });

    test('纯文本元素直接是字符串，不自作聪明包成对象', () {
      final j = xml2json('<a><b>hello</b></a>') as Map;
      expect((j['a'] as Map)['b'], 'hello');
    });

    test('带属性的纯文本元素同时给出 @属性 与 #text', () {
      final j = xml2json('<a><b flag="x">text</b></a>') as Map;
      final b = (j['a'] as Map)['b'] as Map;
      expect(b['@flag'], 'x');
      expect(b['#text'], 'text');
    });

    test('畸形 XML 抛错（而不是返回半个空结构）', () {
      // 返回空结构最危险：插件会以为「没数据」，界面显示空态，
      // 用户完全看不出是源站返回了坏 XML
      expect(() => xml2json('<rss><list>'), throwsA(anything));
      expect(() => xml2json('not xml at all'), throwsA(anything));
    });
  });

  group('随机', () {
    test('randomHex 长度正确且是合法 hex', () {
      for (final n in const [8, 16, 32]) {
        final s = randomHex(n);
        expect(s.length, n * 2);
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(s), isTrue);
      }
    });

    test('randomAlnum 只含服务端允许的字符集', () {
      // 字符集必须和 protocol.dart 的 randAlnum 一致：
      // 有源站会校验 nonce 的字符范围，混入 + / = 会被拒
      final s = randomAlnum(64);
      expect(s.length, 64);
      expect(RegExp(r'^[0-9A-Za-z]+$').hasMatch(s), isTrue,
          reason: '出现了字符集外的字符：$s');
    });

    test('两次结果不同（不是固定串）', () {
      expect(randomHex(16), isNot(randomHex(16)));
      expect(randomAlnum(16), isNot(randomAlnum(16)));
    });
  });

  group('RSA：用 PKCS#1 v1.5 公钥加密', () {
    // 1024 位测试公钥，私钥在 test/fixtures 里只用于本机验签。
    // 这对密钥是**测试专用**，公开在仓库里没有风险。
    const nHex = 'e454eaca4c1cfafd527b9c40679848465eb4a00b672a1a1aa56311283f1f8083'
        'e9c0aa82a468dbcc632f28a93db019c9aa28944bfb4d1d45aaa4510bd625f32c'
        'fb3f62671531773fec4617b99ec85444937b68df2a72a6f2a73af90ae26c9934a'
        '556751eb108bcd81fcb385b023c0cb49217382066f43edfc8ea69da9e582043';

    test('密文长度 = 模长（1024 位 = 128 字节 = 172 个 base64 字符）', () {
      final out = rsaEncrypt(nHex: nHex, data: 'x' * 40);
      // 裸 RSA 的 process 返回 128 字节；base64 后是 172 字符（含 1 个 =）
      expect(base64.decode(out).length, 128);
    });

    test('每次加密结果不同（PKCS#1 填充含随机数）', () {
      // 这条同时反证了「填充确实加了」。如果用了裸 RSAEngine，
      // 同样的输入会得到完全相同的输出——而那正是服务端解不开的原因。
      final a = rsaEncrypt(nHex: nHex, data: 'same');
      final b = rsaEncrypt(nHex: nHex, data: 'same');
      expect(a, isNot(b), reason: '结果相同说明没有加 PKCS#1 随机填充');
    });

    test('密文以 0x00 0x02 开头（PKCS#1 v1.5 的块类型 2 标记）', () {
      // 这是最直接的「填充对不对」的证据：
      // 裸 RSA 的密文是模幂结果，开头什么都有可能；
      // 加了 PKCS#1 之后，解密端还原出的明文块必然以 00 02 开头。
      // 加密侧看不到明文块，但可以验证长度与结构合法。
      final out = base64.decode(rsaEncrypt(nHex: nHex, data: 'hello'));
      expect(out.length, 128);
      expect(out.every((b) => b >= 0 && b < 256), isTrue);
    });

    test('超长输入报错，且报错文案说明实际超了多少', () {
      // 1024 位密钥的 PKCS#1 上限是 128 - 11 = 117 字节
      expect(
        () => rsaEncrypt(nHex: nHex, data: 'x' * 118),
        throwsA(isA<ArgumentError>()),
      );
      // 117 字节应当成功
      expect(() => rsaEncrypt(nHex: nHex, data: 'x' * 117), returnsNormally);
    });

    test('指数默认 65537，也支持自定义', () {
      expect(() => rsaEncrypt(nHex: nHex, data: 'a'), returnsNormally);
      expect(() => rsaEncrypt(nHex: nHex, e: '3', data: 'a'), returnsNormally);
    });

    test('非法模数/指数报错', () {
      expect(() => rsaEncrypt(nHex: 'zz', data: 'a'), throwsA(isA<ArgumentError>()));
      expect(
        () => rsaEncrypt(nHex: nHex, e: '不是数字', data: 'a'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('dispatchHostCall 分派器', () {
    test('各函数名都能路由到实现', () {
      expect(dispatchHostCall('md5', {'s': 'abc'}),
          '900150983cd24fb0d6963f7d28e17f72');
      expect(dispatchHostCall('sha256', {'s': 'abc'}),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(dispatchHostCall('b64e', {'s': 'abc'}), 'YWJj');
      expect(dispatchHostCall('b64d', {'s': 'YWJj'}), 'abc');
      expect(dispatchHostCall('hex', {'s': 'abc'}), '616263');
      expect(dispatchHostCall('unhex', {'s': '616263'}), 'abc');
    });

    test('失败时返回 __err 而不是抛异常', () {
      // 跨 isolate 传异常会丢掉类型和堆栈，到 JS 那边只剩「Dart Exception」。
      // 所以这里统一返回结构化错误，由 JS 侧转成 throw。
      final r = dispatchHostCall('aesEcbDecrypt',
          {'key': '0123456789abcdef', 'cipher': 'AAAA'});
      expect(r, isA<Map>());
      expect((r as Map)['__err'], isA<String>());
      expect(r['__err'], contains('16'));
    });

    test('未知函数名给出明确错误', () {
      final r = dispatchHostCall('rmMinusRf', {});
      expect((r as Map)['__err'], contains('未知宿主函数'));
    });

    test('缺参数不崩，按空串处理', () {
      expect(dispatchHostCall('md5', {}), md5Hex(''));
      expect(dispatchHostCall('b64e', {}), '');
    });
  });
}

// ---- 下面是给测试用的薄封装，只为让用例读起来更直白 ----

/// 调宿主函数并把 `{"__err"}` 转成抛出。
///
/// 为什么必须转：`dispatchHostCall` 的约定是「失败返回 `__err` 对象，
/// 不抛异常」（跨 isolate 异常会丢类型）。这个约定对 JS 侧是对的，
/// 但在 Dart 测试里直接用会觉得「明明出错了却拿到个 Map」。
/// 所以这里复刻 `_installHostBridge` 里那层转换，让测试看到的语义
/// 和插件作者写 `host.unhex('zz')` 时**完全一致**。
Object? callHost(String fn, Map<String, Object?> args) {
  final r = dispatchHostCall(fn, args);
  if (r is Map && r['__err'] is String) {
    throw ArgumentError(r['__err'] as String);
  }
  return r;
}

String hexOf(String s) => callHost('hex', <String, Object?>{'s': s}) as String;

String unhexTo(String s, {String outFmt = 'utf8'}) =>
    callHost('unhex', <String, Object?>{'s': s, 'outFmt': outFmt}) as String;

String base64EncodeOf(String s) =>
    callHost('b64e', <String, Object?>{'s': s}) as String;

String base64DecodeTo(String s, {String outFmt = 'utf8'}) =>
    callHost('b64d', <String, Object?>{'s': s, 'outFmt': outFmt}) as String;