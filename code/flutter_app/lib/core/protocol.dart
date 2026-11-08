/// 4K追剧 App 协议层：加密、签名、protobuf 编解码
///
/// 逆向结论（静态 + 动态验证）：
///   1. 请求体 = SecureRequest{aes_encrypt1,aes_encrypt2,aes_fakestr,timestamp,random_str}
///   2. 明文 = "k=v&k=v" + timestamp(ms)
///   3. 密文 = Base64_NO_WRAP(AES-256-ECB-PKCS7(safeCode, 明文))
///   4. merged = random8 + 密文Base64；enc1 = merged[0:20]，enc2 = merged[20:]
///   5. publicParams = 设备指纹 JSON + sig/sig2/sig3
///      sig  = Base64_NO_WRAP(RSA/ECB/PKCS1(ts + random16 + vApp))
///      sigA = Base64_NO_WRAP(AES-256-ECB(safeSecret, ts + random16))
///      sig2 = sigA[0:8]，sig3 = sigA[8:]
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ============ 运行时抓取到的密钥 ============
/// 请求体加密 key（AES-256，直接用字符串字节，不做 base64 解码）
const String kSafeCode = 'ZU1DSFFWNENKMDYXVUQRN0ZJDUC4PQ==';

/// sig2/sig3 用的 AES-256 key
const String kSafeSecret = 'OC1A06E197EF10CF3F6058CA7A803B5E';

/// RSA 公钥模数（1024 bit）
const String kRsaN =
    'a9f44938c0895002dc059ee05196c162a30dadafee1439c88678d29b63b9cbef'
    '87ad52a51be9fbe939238784511f69695fc14a4e075ef1dc910bdcda35f677e3'
    '09e558ad83e3949720a2a5161ffb5f21f140416bedc4120194a6b3921c3c7770'
    'a1cac5a679646290aaa406c551638a2a34fba3e2c8e6e99ba5b74538238a6b45';

const int kRsaE = 65537;

const String _chars =
    '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

final Random _rnd = Random.secure();

/// 生成 n 个随机字符（原版是 去重 的，服务端不校验去重，这里保持等价行为）
String randAlnum(int n) {
  final buf = StringBuffer();
  final used = <String>{};
  while (buf.length < n) {
    final c = _chars[_rnd.nextInt(_chars.length)];
    if (used.add(c)) buf.write(c);
  }
  return buf.toString();
}

/// OooO0Oo(i)：i-1 位随机 + '='
String randomToken(int len) => '${randAlnum(len - 1)}=';

// ---------------- AES-256-ECB-PKCS7 ----------------
Uint8List aesEcbEncrypt(Uint8List key, Uint8List data) {
  final padLen = 16 - (data.length % 16);
  final padded = Uint8List(data.length + padLen)..setAll(0, data);
  for (var i = data.length; i < padded.length; i++) {
    padded[i] = padLen;
  }
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(key));
  final out = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    cipher.processBlock(padded, off, out, off);
  }
  return out;
}

String aesEcbB64(String keyStr, String plain) => base64Encode(
      aesEcbEncrypt(
        Uint8List.fromList(utf8.encode(keyStr)),
        Uint8List.fromList(utf8.encode(plain)),
      ),
    );

// ---------------- RSA/ECB/PKCS1Padding ----------------
Uint8List _bigIntToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x = x >> 8;
  }
  return out;
}

BigInt _bytesToBigInt(Uint8List b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

/// RSA PKCS#1 v1.5 加密
String rsaEncryptB64(String msg) {
  final n = BigInt.parse(kRsaN, radix: 16);
  final e = BigInt.from(kRsaE);
  final k = (n.bitLength + 7) >> 3; // 128
  final m = utf8.encode(msg);
  final psLen = k - 3 - m.length;
  if (psLen < 8) {
    throw StateError('RSA payload too long: ${m.length}');
  }
  final em = Uint8List(k);
  em[0] = 0x00;
  em[1] = 0x02;
  for (var i = 0; i < psLen; i++) {
    int b;
    do {
      b = _rnd.nextInt(255) + 1; // 1..255，非零
    } while (b == 0);
    em[2 + i] = b;
  }
  em[2 + psLen] = 0x00;
  em.setRange(3 + psLen, k, m);

  final c = _bytesToBigInt(em).modPow(e, n);
  return base64Encode(_bigIntToBytes(c, k));
}

// ---------------- protobuf 写入 ----------------
class PbWriter {
  final BytesBuilder _b = BytesBuilder();

  void _varint(int v) {
    var x = v;
    while (true) {
      final byte = x & 0x7F;
      x >>= 7;
      if (x != 0) {
        _b.addByte(byte | 0x80);
      } else {
        _b.addByte(byte);
        return;
      }
    }
  }

  void str(int field, String? s) {
    if (s == null || s.isEmpty) return;
    final bytes = utf8.encode(s);
    _varint((field << 3) | 2);
    _varint(bytes.length);
    _b.add(bytes);
  }

  void i64(int field, int v) {
    _varint(field << 3);
    _varint(v);
  }

  Uint8List takeBytes() => _b.takeBytes();
}

// ---------------- protobuf 读取 ----------------
class PbField {
  final int number;
  final int wireType;
  final int? asInt;
  final String? asString;
  final Uint8List? asBytes;

  PbField(this.number, this.wireType, {this.asInt, this.asString, this.asBytes});
}

class PbReader {
  final Uint8List d;
  int i = 0;

  PbReader(this.d);

  bool get hasMore => i < d.length;

  int _varint() {
    var r = 0;
    var shift = 0;
    while (true) {
      final b = d[i++];
      r |= (b & 0x7F) << shift;
      shift += 7;
      if ((b & 0x80) == 0) return r;
      if (shift > 63) throw const FormatException('varint too long');
    }
  }

  /// 读取全部字段（不递归）
  List<PbField> readAll() {
    final out = <PbField>[];
    while (hasMore) {
      final key = _varint();
      final num = key >> 3;
      final wt = key & 7;
      if (num == 0) break;
      switch (wt) {
        case 0:
          out.add(PbField(num, 0, asInt: _varint()));
          break;
        case 1:
          if (i + 8 > d.length) return out;
          i += 8;
          break;
        case 2:
          final len = _varint();
          if (i + len > d.length) return out;
          final seg = Uint8List.sublistView(d, i, i + len);
          i += len;
          String? s;
          try {
            s = utf8.decode(seg);
          } catch (_) {
            s = null;
          }
          out.add(PbField(num, 2, asString: s, asBytes: seg));
          break;
        case 5:
          if (i + 4 > d.length) return out;
          i += 4;
          break;
        default:
          return out;
      }
    }
    return out;
  }
}

/// 取某字段最后一个字符串值
String? pbString(List<PbField> fs, int num) {
  for (var i = fs.length - 1; i >= 0; i--) {
    if (fs[i].number == num && fs[i].wireType == 2) return fs[i].asString;
  }
  return null;
}

/// 取某字段最后一个整数值
int? pbInt(List<PbField> fs, int num) {
  for (var i = fs.length - 1; i >= 0; i--) {
    if (fs[i].number == num && fs[i].wireType == 0) return fs[i].asInt;
  }
  return null;
}

/// 取某字段全部字节段
List<Uint8List> pbBytesAll(List<PbField> fs, int num) => fs
    .where((f) => f.number == num && f.wireType == 2 && f.asBytes != null)
    .map((f) => f.asBytes!)
    .toList();