/// 注入给插件的能力：加密原语 + XML 解析。
///
/// ## 为什么需要这一层
///
/// QuickJS 是个纯解析引擎，没有 crypto、没有二进制处理、连 `base64Decode`
/// 都不存在。而现实里的源站大量依赖这些东西：
///
///   | 源类型 | 依赖 |
///   | --- | --- |
///   | 橘汁 | AES-256-ECB + RSA 签名 + 自定义 protobuf |
///   | 看剧 | HMAC-SHA256 签名 |
///   | 多数 MacCMS XML 站 | XML 解析（不是 JSON） |
///
/// 之前的评估（`doc/源插件化评估.md`）结论是「这类源不能插件化，
/// 只能保持内置硬编码」。那个结论建立在 dart_eval 上——它的
/// `base64Decode` 都调不通。
///
/// **但 QuickJS 这边实测出了关键能力**：`sendMessage` 通道的返回值
/// 能**同步**透回 JS（`RET={"echo":{"x":1},"n":42}`，单次往返 0.15ms）。
/// 也就是说，宿主可以把 Dart 函数挂给 JS，JS 像调本地函数一样同步调用：
///
/// ```js
/// var sig = host.md5('ts=1&key=x');        // 同步拿到 hex
/// var enc = host.aesEcbEncrypt({...});     // 同步拿到 base64
/// ```
///
/// 于是「需要加密的源」也能插件化了。前置条件从「有没有 crypto」变成
/// 「宿主愿不愿意提供 crypto」，而后者是我们自己决定的事。
///
/// ## 安全边界没有变松
///
/// 这一层全是**纯计算**：输入字符串、输出字符串，不碰网络、不碰文件、
/// 不起进程。所以「插件的 IO 能力被封死」这条前提完全保留：
///
///   - 插件要发请求 → 只能求宿主，宿主做 SSRF 校验
///   - 插件要加密 → 可以自己做，但算完还是得走宿主的请求通道
///
/// 换句话说，注入 crypto 只放开了「算」，没有放开「连」。
///
/// ## 为什么放在 worker isolate 里跑
///
/// 这些函数由 worker isolate 注册（见 `plugin_runtime.dart` 的
/// [_registerHostFunctions]）。放主 isolate 是行不通的：
/// `sendMessage` 的同步返回依赖「同一个 isolate 内的直接函数调用」，
/// 跨 isolate 只能走异步消息，那就破坏了同步语义。
///
/// worker 里跑的成本是每个 worker 一份 crypto 代码（几百 KB 的
/// pointycastle），换来的是同步语义——这个交换值得，因为同步是
/// 「插件入口强制同步」这条设计的根基。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

/// 把十六进制串解成字节。非法输入返回 null。
Uint8List? _hexToBytes(String hex) {
  var h = hex.trim();
  if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
  // 允许带分隔符（`aa:bb:cc` / `aa-bb-cc`），密钥常这么写
  h = h.replaceAll(RegExp(r'[:\-\s]'), '');
  if (h.length.isOdd) return null;
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// 按声明的格式把字符串解成字节。
///
/// 插件里密钥/明文可能是三种形态：原文、hex、base64。
/// 不显式声明就只能猜，而猜错的表现是「加密结果和服务端对不上」——
/// 这种问题极难排查，所以这里强制要求调用方说明格式。
Uint8List _decode(String s, String fmt) {
  switch (fmt) {
    case 'hex':
      final b = _hexToBytes(s);
      if (b == null) throw ArgumentError('不是合法的 hex：${_short(s)}');
      return b;
    case 'base64':
      return Uint8List.fromList(base64.decode(s.trim()));
    case 'utf8':
    default:
      return Uint8List.fromList(utf8.encode(s));
  }
}

/// 按声明的格式把字节编成字符串。
String _encode(List<int> bytes, String fmt) {
  switch (fmt) {
    case 'hex':
      return _bytesToHex(bytes);
    case 'base64':
      return base64.encode(bytes);
    case 'utf8':
    default:
      // 二进制数据不能当 utf8 解，那会产生替换字符
      return utf8.decode(bytes, allowMalformed: true);
  }
}

String _short(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

// ---------------- 摘要 ----------------

String md5Hex(String s) => c.md5.convert(utf8.encode(s)).toString();
String sha1Hex(String s) => c.sha1.convert(utf8.encode(s)).toString();
String sha256Hex(String s) => c.sha256.convert(utf8.encode(s)).toString();

String hmacHex(String algo, String key, String msg) {
  final k = utf8.encode(key);
  final m = utf8.encode(msg);
  final h = switch (algo.toLowerCase()) {
    'md5' => c.md5,
    'sha1' => c.sha1,
    'sha512' => c.sha512,
    _ => c.sha256,
  };
  return c.Hmac(h, k).convert(m).toString();
}

// ---------------- AES ----------------

/// AES-ECB 加密（PKCS7 填充）。
///
/// ECB 本身不安全（相同明文块产生相同密文），但**这是对接现实**：
/// 橘汁等站方的接口就是 ECB，客户端没有选择权。这里只做「按对方
/// 协议算」这一件事，不做密码学建议。
String aesEcbEncrypt({
  required String key,
  String keyFmt = 'utf8',
  required String plain,
  String plainFmt = 'utf8',
  String outFmt = 'base64',
}) {
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(_decode(key, keyFmt)));
  final input = _decode(plain, plainFmt);
  final padded = _pkcs7Pad(input);
  final out = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    cipher.processBlock(padded, off, out, off);
  }
  return _encode(out, outFmt);
}

String aesEcbDecrypt({
  required String key,
  String keyFmt = 'utf8',
  required String cipherText,
  String inFmt = 'base64',
  String outFmt = 'utf8',
}) {
  final engine = ECBBlockCipher(AESEngine())
    ..init(false, KeyParameter(_decode(key, keyFmt)));
  final input = _decode(cipherText, inFmt);
  if (input.length % 16 != 0) {
    throw ArgumentError('密文长度必须是 16 的倍数（实际 ${input.length}）');
  }
  final out = Uint8List(input.length);
  for (var off = 0; off < input.length; off += 16) {
    engine.processBlock(input, off, out, off);
  }
  return _encode(_pkcs7Unpad(out), outFmt);
}

String aesCbcEncrypt({
  required String key,
  String keyFmt = 'utf8',
  required String iv,
  String ivFmt = 'utf8',
  required String plain,
  String plainFmt = 'utf8',
  String outFmt = 'base64',
}) {
  final ivBytes = _decode(iv, ivFmt);
  if (ivBytes.length != 16) {
    throw ArgumentError('IV 必须是 16 字节（实际 ${ivBytes.length}）');
  }
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(_decode(key, keyFmt)), ivBytes));
  final padded = _pkcs7Pad(_decode(plain, plainFmt));
  final out = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    cipher.processBlock(padded, off, out, off);
  }
  return _encode(out, outFmt);
}

String aesCbcDecrypt({
  required String key,
  String keyFmt = 'utf8',
  required String iv,
  String ivFmt = 'utf8',
  required String cipherText,
  String inFmt = 'base64',
  String outFmt = 'utf8',
}) {
  final ivBytes = _decode(iv, ivFmt);
  if (ivBytes.length != 16) {
    throw ArgumentError('IV 必须是 16 字节（实际 ${ivBytes.length}）');
  }
  final engine = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(_decode(key, keyFmt)), ivBytes));
  final input = _decode(cipherText, inFmt);
  if (input.length % 16 != 0) {
    throw ArgumentError('密文长度必须是 16 的倍数（实际 ${input.length}）');
  }
  final out = Uint8List(input.length);
  for (var off = 0; off < input.length; off += 16) {
    engine.processBlock(input, off, out, off);
  }
  return _encode(_pkcs7Unpad(out), outFmt);
}

Uint8List _pkcs7Pad(Uint8List data) {
  final padLen = 16 - (data.length % 16);
  final out = Uint8List(data.length + padLen)..setAll(0, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = padLen;
  }
  return out;
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) return data;
  final pad = data.last;
  // 填充值非法时原样返回：解密出来的东西已经不对了，
  // 这时候抛异常不如把原始字节交出去让人排查
  if (pad < 1 || pad > 16 || pad > data.length) return data;
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) return data;
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}

// ---------------- RSA ----------------

/// RSA 公钥加密（PKCS#1 v1.5），输出 base64。
///
/// ## 为什么是「加密」而不是「签名」
///
/// 橘汁协议的注释写的是：
///
///     sig = Base64_NO_WRAP(RSA/ECB/PKCS1(ts + random16 + vApp))
///
/// 名字叫 `sig`，但**实现是公钥加密**：客户端拿公钥加密一段拼接串，
/// 服务端用私钥解出来校验。所以客户端只需要公钥（模数 + 指数），
/// 不需要任何私钥。这一点很关键——
///
///   - 「签名」（需要私钥）在客户端侧是不可能的，会泄漏私钥；
///   - 「公钥加密」（需要公钥）是标准用法，公钥本来就在 APK 里。
///
/// 之前评估文档说「签名类源不能插件化」，一半原因是当时用 dart_eval
/// 连 base64 都调不通；另一半就是没分清这两者。
String rsaEncrypt({
  required String nHex,
  String e = '65537',
  required String data,
  String dataFmt = 'utf8',
  String outFmt = 'base64',
}) {
  final nBytes = _hexToBytes(nHex);
  if (nBytes == null) throw ArgumentError('RSA 模数不是合法 hex');
  final eInt = int.tryParse(e.trim());
  if (eInt == null) throw ArgumentError('RSA 指数不是整数：$e');

  final pub = RSAPublicKey(
    BigInt.parse(_bytesToHex(nBytes), radix: 16),
    BigInt.from(eInt),
  );

  final input = _decode(data, dataFmt);

  // **必须外套 PKCS1Encoding。**
  //
  // pointycastle 的 `RSAEngine` 只做裸 RSA（直接对整数做模幂），
  // 不带任何填充。直接拿它加密出来的 128 字节，服务端按 PKCS#1 v1.5
  // 解包时会发现开头不是 0x00 0x02，直接判失败。
  //
  // 这个坑很隐蔽：加密本身不报错、输出长度也对，只是结果永远对不上。
  final engine = PKCS1Encoding(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(pub));

  // 单块能加密的长度上限由引擎自己算（模长 - 11）。这里显式校验：
  // 超长时 PKCS1Encoding 会抛异常，但它的报错文案是
  // `input too large for RSA cipher`，不告诉作者实际超了多少，
  // 对排查毫无帮助。
  final maxLen = engine.inputBlockSize;
  if (input.length > maxLen) {
    throw ArgumentError(
        '待加密数据 ${input.length} 字节，超出单块 RSA 上限 $maxLen 字节。'
        '橘汁的拼接串（ts+随机16+vApp）通常在 50 字节内，超这么多说明拼错了');
  }

  // 用 process() 而不是 processBlock()：它内部按 outputBlockSize
  // 分配缓冲区再回填，省掉自己算密文块长度（算错就是越界写）。
  return _encode(engine.process(input), outFmt);
}

// ---------------- XML ----------------

/// XML → JSON（Map/List/String）。
///
/// 转换约定（与主流 xml2js 一致，作者不需要额外学习）：
///   - 纯文本元素 → 字符串
///   - 有子元素 → 对象，子元素名作 key
///   - 同名子元素重复 → 数组（这是 MacCMS 的 `<video>` 列表形态）
///   - 属性 → `@属性名`
///
/// MacCMS 的 XML 应答长这样：
/// ```xml
/// <rss><list page="1"><video><id>1</id><name><![CDATA[剧]]></name>
///   <dl><dd flag="bfzym3u8"><![CDATA[第1集$http://...]]></dd></dl>
/// </video></list></rss>
/// ```
/// 转成 `{"rss":{"list":{"video":[{...}]}}}`，插件里就是普通的 JS 取值。
Object? xml2json(String xmlText) {
  final doc = XmlDocument.parse(xmlText);
  final root = doc.rootElement;
  return <String, Object?>{root.name.local: _nodeToJson(root)};
}

Object? _nodeToJson(XmlElement el) {
  final hasChildElements = el.children.any((n) => n is XmlElement);
  final attrs = <String, Object?>{
    for (final a in el.attributes) '@${a.name.local}': a.value,
  };

  if (!hasChildElements) {
    final text = el.innerText.trim();
    if (attrs.isEmpty) return text;
    return <String, Object?>{...attrs, '#text': text};
  }

  final map = <String, Object?>{...attrs};
  for (final child in el.children.whereType<XmlElement>()) {
    final key = child.name.local;
    final val = _nodeToJson(child);
    final existing = map[key];
    if (existing == null) {
      map[key] = val;
    } else if (existing is List) {
      existing.add(val);
    } else {
      // 第二个同名子元素出现 → 升级成数组。
      // 这是必须的：MacCMS 的 <video> 列表就是靠这个变成数组的
      map[key] = <Object?>[existing, val];
    }
  }
  return map;
}

// ---------------- 杂项 ----------------

String randomHex(int bytes) {
  final rnd = Random.secure();
  final out = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    out[i] = rnd.nextInt(256);
  }
  return _bytesToHex(out);
}

/// 生成 n 位大小写字母+数字（用于 nonce）。
///
/// 与 `protocol.dart` 的 `randAlnum` 保持同样的字符集，因为服务端
/// 对字符集有校验的源会拒掉其他字符。
String randomAlnum(int n) {
  const chars = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < n; i++) {
    buf.write(chars[rnd.nextInt(chars.length)]);
  }
  return buf.toString();
}

/// 统一入口：把 JS 发来的 `{fn, args}` 分派到具体实现。
///
/// 参数用 `Map<String, Object?>` 而不是位置参数，因为大部分函数都有
/// 好几个可选项（格式、输出编码），位置参数在 JS 里写起来极易错位。
///
/// 返回值约定：成功返回结果本身，失败返回 `{"__err": "人话原因"}`。
/// 不抛异常是因为**异常跨 isolate 会丢掉类型**，到 JS 那边只剩
/// 一句「Dart Exception」，对排查毫无帮助。
Object? dispatchHostCall(String fn, Map<String, Object?> a) {
  try {
    switch (fn) {
      case 'md5':
        return md5Hex('${a['s'] ?? ''}');
      case 'sha1':
        return sha1Hex('${a['s'] ?? ''}');
      case 'sha256':
        return sha256Hex('${a['s'] ?? ''}');
      case 'hmac':
        return hmacHex('${a['algo'] ?? 'sha256'}', '${a['key'] ?? ''}',
            '${a['msg'] ?? ''}');

      case 'aesEcbEncrypt':
        return aesEcbEncrypt(
          key: '${a['key'] ?? ''}',
          keyFmt: '${a['keyFmt'] ?? 'utf8'}',
          plain: '${a['plain'] ?? ''}',
          plainFmt: '${a['plainFmt'] ?? 'utf8'}',
          outFmt: '${a['outFmt'] ?? 'base64'}',
        );
      case 'aesEcbDecrypt':
        return aesEcbDecrypt(
          key: '${a['key'] ?? ''}',
          keyFmt: '${a['keyFmt'] ?? 'utf8'}',
          // 同时接受 cipherText 和 cipher。
          // 前者是 Dart API 的参数名（作者照文档写就对），后者是早期
          // 的简写。只认一个的后果很隐蔽：取不到密文 → 空串 →
          // 长度为 0 → 走「空输入」分支返回空串，看起来像「解密成功
          // 但内容没了」，而不是报错。
          cipherText: '${a['cipherText'] ?? a['cipher'] ?? ''}',
          inFmt: '${a['inFmt'] ?? 'base64'}',
          outFmt: '${a['outFmt'] ?? 'utf8'}',
        );
      case 'aesCbcEncrypt':
        return aesCbcEncrypt(
          key: '${a['key'] ?? ''}',
          keyFmt: '${a['keyFmt'] ?? 'utf8'}',
          iv: '${a['iv'] ?? ''}',
          ivFmt: '${a['ivFmt'] ?? 'utf8'}',
          plain: '${a['plain'] ?? ''}',
          plainFmt: '${a['plainFmt'] ?? 'utf8'}',
          outFmt: '${a['outFmt'] ?? 'base64'}',
        );
      case 'aesCbcDecrypt':
        return aesCbcDecrypt(
          key: '${a['key'] ?? ''}',
          keyFmt: '${a['keyFmt'] ?? 'utf8'}',
          iv: '${a['iv'] ?? ''}',
          ivFmt: '${a['ivFmt'] ?? 'utf8'}',
          // 同 aesEcbDecrypt：两个名字都认
          cipherText: '${a['cipherText'] ?? a['cipher'] ?? ''}',
          inFmt: '${a['inFmt'] ?? 'base64'}',
          outFmt: '${a['outFmt'] ?? 'utf8'}',
        );

      case 'b64e':
        return base64.encode(_decode('${a['s'] ?? ''}', '${a['fmt'] ?? 'utf8'}'));
      case 'b64d':
        return _encode(
            Uint8List.fromList(base64.decode('${a['s'] ?? ''}')),
            '${a['outFmt'] ?? 'utf8'}');
      case 'hex':
        return _bytesToHex(_decode('${a['s'] ?? ''}', '${a['fmt'] ?? 'utf8'}'));
      case 'unhex':
        return _encode(_decode('${a['s'] ?? ''}', 'hex'),
            '${a['outFmt'] ?? 'utf8'}');

      case 'xml2json':
        return xml2json('${a['xml'] ?? ''}');

      case 'randomHex':
        return randomHex(int.tryParse('${a['bytes'] ?? 8}') ?? 8);
      case 'randomAlnum':
        return randomAlnum(int.tryParse('${a['n'] ?? 8}') ?? 8);

      default:
        return <String, Object?>{'__err': '未知宿主函数：$fn'};
    }
  } catch (e) {
    return <String, Object?>{'__err': '$e'};
  }
}