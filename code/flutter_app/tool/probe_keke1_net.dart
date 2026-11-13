/// 可可影视故障定位。前三轮结果：
///   代理 → `Proxy failed to establish tunnel (502)`
///   直连 www → 80/443 均 10~12s 超时
///   直连裸域 → http 403（openresty），https 握手失败
///   DNS www → 185.216.116.26；裸域 → 123.108.109.72
///
/// 这说明**不是** PoW 准入的问题（PoW 在 TCP 建立之后才开始），
/// 而是连 TCP 都握不上手。本轮要分辨的是：
///
///   A. 裸域那个 123.108.109.72 是活的（能给 403 就说明端口通），
///      那它是不是**换域名了**？用 Host 头去试 www.keke1.app，
///      如果 CDN 按 Host 路由，就能借这个 IP 打通。
///
///   B. www 的 185.216.116.26 除了 443/80，其它端口呢？全不通 = 整机不可达。
///
///   C. 常见镜像/备用域名是否还能用（可可影视历史上换过多次域名）。
///      这里只测**已知的候选**，不做全网猜测。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _ua =
    'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

/// 裸 socket 探端口，绕开 HTTP 层直接看 TCP 通不通
Future<String> _tcp(String host, int port) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port,
        timeout: const Duration(seconds: 6));
    s.destroy();
    return '通 (${sw.elapsedMilliseconds}ms)';
  } catch (e) {
    final m = '$e'.split('\n').first;
    return '不通 (${sw.elapsedMilliseconds}ms) ${m.length > 60 ? m.substring(0, 60) : m}';
  }
}

/// 指定 IP + Host 头请求，用来判断 CDN 是否按 Host 路由
Future<String> _viaIp(String ip, String host, {bool https = false}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = _ua
    ..badCertificateCallback = (_, __, ___) => true;
  // 注意：不能写成 `..findProxy = (_) => 'DIRECT' ..其它级联`。
  // 箭头函数体会把后面的 `..` 一起吃进去，解析成 `'DIRECT'..xxx`，
  // 报「setter 未定义在 String 上」。拆成独立语句最稳。
  client.findProxy = (_) => 'DIRECT';
  final scheme = https ? 'https' : 'http';
  try {
    final req = await client
        .getUrl(Uri.parse('$scheme://$ip/'))
        .timeout(const Duration(seconds: 10));
    req.headers.set('Host', host);
    final res = await req.close().timeout(const Duration(seconds: 10));
    final body = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final text = utf8.decode(body, allowMalformed: true);
    final flat = text.replaceAll(RegExp(r'\s+'), ' ');
    return 'HTTP ${res.statusCode}  ${body.length} B  '
        '${flat.substring(0, flat.length > 100 ? 100 : flat.length)}';
  } catch (e) {
    final m = '$e'.split('\n').first;
    return 'ERR ${m.length > 90 ? m.substring(0, 90) : m}';
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  print('══ A. TCP 端口连通性 ══');
  print('');
  for (final h in ['185.216.116.26', '123.108.109.72']) {
    for (final p in [80, 443, 8080]) {
      print('  $h:$p → ${await _tcp(h, p)}');
    }
  }

  print('');
  print('══ B. 借裸域 IP 用 www 的 Host 头去试（判断是否按 Host 路由）══');
  print('');
  for (final host in ['www.keke1.app', 'keke1.app']) {
    print('  Host: $host  via 123.108.109.72');
    print('    http  → ${await _viaIp('123.108.109.72', host)}');
    print('    https → ${await _viaIp('123.108.109.72', host, https: true)}');
  }

  print('');
  print('══ C. 已知候选域名是否存活 ══');
  print('');
  // 可可影视历史上用过/见过的域名，逐个看 DNS + HTTP，不做猜测性穷举
  const candidates = [
    'www.keke1.app',
    'keke1.app',
    'www.kekys.com',
    'kekys.com',
    'www.kekeys.com',
  ];
  for (final h in candidates) {
    List<InternetAddress> addrs = const [];
    try {
      addrs = await InternetAddress.lookup(h).timeout(const Duration(seconds: 6));
    } catch (_) {}
    if (addrs.isEmpty) {
      print('  $h → DNS 无结果');
      continue;
    }
    final ip = addrs.first.address;
    print('  $h → $ip');
    print('     :443 ${await _tcp(ip, 443)}');
  }

  print('');
  print('══ D. 走系统代理时 dns 解析到哪（对比是否被代理改写）══');
  print('');
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final req = await client
        .getUrl(Uri.parse('https://www.keke1.app/'))
        .timeout(const Duration(seconds: 12));
    final res = await req.close().timeout(const Duration(seconds: 12));
    print('  代理路径 HTTP ${res.statusCode}');
    await res.drain<void>();
    client.close(force: true);
  } catch (e) {
    print('  代理路径失败：${"$e".split("\n").first}');
  }
}