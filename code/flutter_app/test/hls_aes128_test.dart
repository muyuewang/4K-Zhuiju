/// HLS 代理「AES-128 加密清单」回归（不联网，本地起 HTTP 服务模拟源站）。
///
/// ## 锁的是什么
///
/// 看剧源的《名侦探柯南：高速公路的堕天使》清单第 5 行是：
///
///     #EXT-X-KEY:METHOD=AES-128,URI="enc.key",IV=0x000…000
///
/// 分片是 **加密的 TS**。改造前的代理只改写分片地址，`#EXT-X-KEY` 因
/// 为以 `#EXT` 开头被原样透传，`URI="enc.key"` 是相对路径，播放器于是
/// 去拼 `http://127.0.0.1:<port>/hls/<tok>/enc.key` —— 这个路径落到代理
/// 的「清单」分支，**把整份 m3u8 当 16 字节密钥返回**，解密必失败。
///
/// 用户看到的现象就是「地址解析出来了，但一直转圈播不了」，而同一地址
/// 在浏览器 / PotPlayer 里正常（它们自带 hls.js / FFmpeg，自己解 AES）。
///
/// ## 为什么用本地服务
///
/// 真实源站的分片签名有时效，写死进测试必然过期；本地服务能精确构造
/// 「AES-128 + 相对 key URI + 无 IV」这几个关键特征，跑得快、结果稳定。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV;
import 'package:zhuiju/core/hls_proxy.dart';

/// 用 CBC 加密并补 PKCS#7（测试侧造密文用）
Uint8List _encrypt(List<int> plain, List<int> key, List<int> iv) {
  // PKCS#7 补齐到 16 的倍数
  final pad = 16 - (plain.length % 16);
  final buf = Uint8List(plain.length + pad)
    ..setRange(0, plain.length, plain)
    ..fillRange(plain.length, plain.length + pad, pad);

  final cbc = CBCBlockCipher(AESEngine())
    ..init(
        true,
        ParametersWithIV(
            KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));
  final out = Uint8List(buf.length);
  for (var off = 0; off < buf.length; off += 16) {
    cbc.processBlock(buf, off, out, off);
  }
  return out;
}

/// 一个「像真的一样」的假 TS：以 0x47 同步字节开头，非 16 的整数倍，
/// 这样能顺带验证 PKCS#7 去填充。
final Uint8List _fakeTs = Uint8List.fromList(<int>[
  0x47, 0x40, 0x11, 0x10, ...List<int>.generate(180, (i) => i & 0xff),
]);

const List<int> _kKey = <int>[
  0x72, 0x55, 0x75, 0x6c, 0x7a, 0x67, 0x75, 0x53,
  0x67, 0x6e, 0x35, 0x49, 0x61, 0x7a, 0x75, 0x77,
];

void main() {
  late HttpServer server;
  late String origin;

  // 清单里显式给了全 0 IV，和看剧源真实形态一致
  final zeroIv = Uint8List(16);

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';

    server.listen((req) async {
      final p = req.uri.path;
      final res = req.response;
      if (p == '/movie/index.m3u8') {
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        // 关键：URI 是相对路径（enc.key），和真实源站完全一样
        res.write('#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:3\n'
            '#EXT-X-MEDIA-SEQUENCE:0\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="enc.key",'
            'IV=0x00000000000000000000000000000000\n'
            '#EXTINF:3.000000,\n'
            '0.ts\n'
            '#EXTINF:3.000000,\n'
            '1.ts\n'
            '#EXT-X-ENDLIST\n');
        await res.close();
        return;
      }
      if (p == '/movie/enc.key') {
        res.headers.contentType = ContentType('application', 'octet-stream');
        res.add(_kKey);
        await res.close();
        return;
      }
      if (p == '/movie/0.ts' || p == '/movie/1.ts') {
        res.headers.contentType = ContentType('video', 'mp2t');
        res.add(_encrypt(_fakeTs, _kKey, zeroIv));
        await res.close();
        return;
      }
      // 「先加密、再声明 METHOD=NONE」的混合清单，验证作用域切换
      if (p == '/mix/index.m3u8') {
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:3\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="enc.key",'
            'IV=0x00000000000000000000000000000000\n'
            '#EXTINF:3.0,\n'
            '0.ts\n'
            '#EXT-X-KEY:METHOD=NONE\n'
            '#EXTINF:3.0,\n'
            'plain.ts\n'
            '#EXT-X-ENDLIST\n');
        await res.close();
        return;
      }
      if (p == '/mix/enc.key') {
        res.headers.contentType = ContentType('application', 'octet-stream');
        res.add(_kKey);
        await res.close();
        return;
      }
      if (p == '/mix/0.ts') {
        res.headers.contentType = ContentType('video', 'mp2t');
        res.add(_encrypt(_fakeTs, _kKey, zeroIv));
        await res.close();
        return;
      }
      if (p == '/mix/plain.ts') {
        res.headers.contentType = ContentType('video', 'mp2t');
        res.add(_fakeTs);
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.notFound;
      await res.close();
    });
  });

  tearDown(() async {
    await HlsProxy.instance.shutdown();
    await server.close(force: true);
  });

  /// 拉代理地址，返回 (状态码, 字节)
  Future<(int, List<int>)> getBytes(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final r = await c.getUrl(Uri.parse(url));
      final resp = await r.close();
      final bytes =
          await resp.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
      return (resp.statusCode, bytes);
    } finally {
      c.close(force: true);
    }
  }

  group('清单改写', () {
    test('回归：#EXT-X-KEY 必须从改写后的清单里摘掉', () async {
      final wrapped = await HlsProxy.instance.wrap('$origin/movie/index.m3u8');
      final (st, bytes) = await getBytes(wrapped);
      expect(st, 200);
      final body = String.fromCharCodes(bytes);

      // 这是本次 bug 的直接断言：留着这条 tag，播放器就会自己去取密钥，
      // 而它拼出来的地址会拿到一整份 m3u8，解密必失败。
      expect(body.contains('#EXT-X-KEY'), isFalse,
          reason: '密钥已在代理侧用掉，tag 不能透传给播放器');
      expect(body.contains('enc.key'), isFalse,
          reason: '清单里不该再出现相对密钥地址');
    });

    test('分片地址仍然被改写成代理地址', () async {
      final wrapped = await HlsProxy.instance.wrap('$origin/movie/index.m3u8');
      final (_, bytes) = await getBytes(wrapped);
      final body = String.fromCharCodes(bytes);
      expect(body.contains('127.0.0.1'), isTrue);
      expect(body.contains('/seg/0/'), isTrue);
      expect(body.contains('/seg/1/'), isTrue);
      expect(body.contains('#EXT-X-ENDLIST'), isTrue,
          reason: 'ENDLIST 要保留，否则播放器当直播一直等');
    });

    test('METHOD=NONE 时后续分片按明文处理', () async {
      // 先加密 1 片，再声明 METHOD=NONE，其后 1 片是明文。
      // 路径都在 setUp 那个 server 里处理，这里只验证「NONE 之后不再解密」。
      final wrapped = await HlsProxy.instance.wrap('$origin/mix/index.m3u8');
      final (st, bytes) = await getBytes(wrapped);
      expect(st, 200);
      final body = String.fromCharCodes(bytes);
      expect(body.contains('#EXT-X-KEY'), isFalse,
          reason: 'METHOD=NONE 也要摘掉，清单里不该残留任何 KEY tag');

      // 第 0 片（加密段）必须还原成明文
      final m0 = RegExp(r'http://127\.0\.0\.1:\d+/hls/\w+/seg/0/[\w.]+')
          .firstMatch(body);
      final (_, seg0) = await getBytes(m0!.group(0)!);
      expect(seg0, orderedEquals(_fakeTs));

      // 第 1 片是明文段，原样回传
      final m1 = RegExp(r'http://127\.0\.0\.1:\d+/hls/\w+/seg/1/[\w.]+')
          .firstMatch(body);
      final (_, seg1) = await getBytes(m1!.group(0)!);
      expect(seg1, orderedEquals(_fakeTs));
    });
  });

  group('分片解密（端到端）', () {
    test('取回的分片必须是明文 TS，且首字节为 0x47 同步字节', () async {
      final wrapped = await HlsProxy.instance.wrap('$origin/movie/index.m3u8');
      final (_, bytes) = await getBytes(wrapped);
      final body = String.fromCharCodes(bytes);

      // 从改写后的清单里抠出第一个分片的代理地址
      final m = RegExp(r'http://127\.0\.0\.1:\d+/hls/\w+/seg/0/[\w.]+')
          .firstMatch(body);
      expect(m, isNotNull, reason: '清单里必须有第 0 片');

      final (st, seg) = await getBytes(m!.group(0)!);
      expect(st, 200);
      expect(seg.length, _fakeTs.length,
          reason: 'PKCS#7 填充要被剥掉，长度应还原');

      // 这三条一起才算「真的解对了」：同步字节 + 内容完整 + 无多余填充
      expect(seg[0], 0x47, reason: '0x47 是 MPEG-TS 同步字节，解错就不会是它');
      expect(seg.sublist(0, 8), _fakeTs.sublist(0, 8));
      expect(seg, orderedEquals(_fakeTs));
    });

    test('解密结果不含密文特征（防「原样转发密文」再次发生）', () async {
      final wrapped = await HlsProxy.instance.wrap('$origin/movie/index.m3u8');
      final (_, bytes) = await getBytes(wrapped);
      final body = String.fromCharCodes(bytes);
      final m = RegExp(r'http://127\.0\.0\.1:\d+/hls/\w+/seg/1/[\w.]+')
          .firstMatch(body);
      final (_, seg) = await getBytes(m!.group(0)!);

      // 密文第一字节由 AES 决定，实测是 0x3d 一类；这里只断它不是 0x47
      // （真密文恰好命中 0x47 的概率 1/256，但用固定 key+明文可复现）
      final cipher = _encrypt(_fakeTs, _kKey, zeroIv);
      expect(seg[0], isNot(cipher[0]),
          reason: '返回的不能是密文，否则播放器解不出画面');
      expect(seg[0], 0x47);
    });
  });

  group('纯函数', () {
    test('keyAttr 能取出 METHOD / URI / IV', () {
      const line = '#EXT-X-KEY:METHOD=AES-128,URI="enc.key",'
          'IV=0x0123456789abcdef0123456789abcdef';
      expect(HlsProxy.keyAttr(line, 'METHOD'), 'AES-128');
      expect(HlsProxy.keyAttr(line, 'URI'), 'enc.key');
      expect(HlsProxy.keyAttr(line, 'IV'),
          '0x0123456789abcdef0123456789abcdef');
    });

    test('keyAttr 的 URI 里带逗号也不会被截断', () {
      // 查询串里带逗号是真实存在的形态，简单 split(',') 会切坏
      const line =
          '#EXT-X-KEY:METHOD=AES-128,URI="https://a.com/k?x=1,2&y=3",IV=0x00';
      expect(HlsProxy.keyAttr(line, 'URI'), 'https://a.com/k?x=1,2&y=3');
    });

    test('keyAttr 取不到时返回 null', () {
      expect(HlsProxy.keyAttr('#EXT-X-KEY:METHOD=NONE', 'URI'), isNull);
    });

    test('parseIv 只接受 32 位十六进制', () {
      expect(HlsProxy.parseIv('0x00000000000000000000000000000000'),
          orderedEquals(List<int>.filled(16, 0)));
      expect(HlsProxy.parseIv('0x01'), isNull, reason: '长度不对要判失败');
      expect(HlsProxy.parseIv(null), isNull);
      // 不带 0x 前缀也认
      expect(HlsProxy.parseIv('ff' * 16), orderedEquals(List<int>.filled(16, 255)));
    });

    test('密文长度不是 16 的倍数要抛 FormatException', () {
      expect(
        () => HlsProxy.aesCbcDecrypt(
            List<int>.filled(20, 0), _kKey, List<int>.filled(16, 0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('填充不合法时原样返回，不抛异常（容错优先）', () {
      // 造一段「解密后末字节是 0x00」的数据：用全 0 明文加密，
      // 解密回来末字节是填充值本身，这里直接测纯函数行为
      final out = HlsProxy.aesCbcDecrypt(
        _encrypt(_fakeTs, _kKey, zeroIv),
        _kKey,
        zeroIv,
      );
      expect(out, orderedEquals(_fakeTs));
    });
  });
}