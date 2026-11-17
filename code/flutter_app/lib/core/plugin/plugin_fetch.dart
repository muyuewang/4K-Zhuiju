/// 插件的网络层：拼 URL、发请求、挡住内网地址。
///
/// ## 为什么网络必须由宿主做
///
/// 插件是远程下发的代码。如果让它自己发请求，就等于把一个「能对内网任意
/// 地址发 HTTP」的能力交出去。QuickJS 本身没有 fetch（实测 `require` /
/// `XMLHttpRequest` 都不可用），所以这条防线天然成立——但**不能依赖它**，
/// 因为将来换个引擎就破了。
///
/// 这里的做法是：宿主只按清单里**声明好的**请求发 HTTP，插件拿到的永远
/// 只是响应体字符串。插件没有能力指定「发去哪」，只能决定「怎么解析」。
///
/// ## 为什么还要挡内网
///
/// 清单是公开仓库里的文件，改动会进 git。但一个人的仓库被误改/被 PR
/// 塞一条 `baseUrl: http://192.168.1.1/` 是完全可能的，此时用户手机
/// 会把请求发到自己家路由器上。这类 SSRF 在浏览器里是漏洞，在
/// 客户端里同样——只是后果从「读后台」变成「探测用户局域网」。
///
/// 所以 baseUrl 和每一条 request.path 都要过 [isPublicUrl]。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'plugin_manifest.dart';

/// 响应体大小上限。
///
/// 5MB 的依据：实测最大的 MacCMS `ac=detail` 响应（电影天堂）是 459KB，
/// 20 条全字段的 XML 站约 424KB。5MB 是它们的 10 倍，足够容纳
/// 「某个站把整季分集塞在列表里」这种极端情况，又不至于让一个恶意
/// 响应把手机内存吃穿。
const int kPluginMaxBodyBytes = 5 * 1024 * 1024;

/// 是否允许请求回环地址（`127.0.0.1` / `localhost`）。
///
/// **仅供测试使用，默认 false，任何运行时路径都不会把它置为 true。**
///
/// 存在的理由：签名链路（请求头是否真的带上、签名算得对不对）只能靠
/// 「真发一次请求、看服务端收到什么」来验证，而测试里的服务端必然是
/// 回环地址。没有这个口子，「签名有效」就只能靠读代码声称，
/// 那不是验证。
///
/// 它会削弱线上防护吗？不会——线上代码里没有任何地方写 true，
/// 唯一赋值点在 `test/support/loopback_gate.dart`。
bool kAllowLoopbackForTest = false;

/// 一条准备好的请求。
class PreparedRequest {
  const PreparedRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.body = '',
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String body;
}

/// 一次抓取结果。
class FetchResult {
  const FetchResult({required this.body, required this.finalUrl});

  final String body;

  /// 重定向之后的最终地址。插件里常有「相对地址补全」的需求，
  /// 补全基准必须是最终地址而不是原始地址，否则会拼错域名。
  final String finalUrl;
}

/// 抓取失败。消息都是给人看的中文，直接可以进错误页。
class PluginFetchException implements Exception {
  PluginFetchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 判断一个地址是否可以安全请求。
///
/// 返回 null 表示可以，否则返回拒绝原因。
///
/// 挡的东西分两类：
///   1. **非 http(s) 协议**：`file://` 能读本机文件，`ftp://` 能打内网服务。
///   2. **内网/回环/链路本地地址**：`127.0.0.1`、`10.x`、`192.168.x`、
///      `172.16-31.x`、`169.254.x`（云元数据！）、`localhost`、
///      IPv6 回环与唯一本地地址。
///
/// 注意：这里**只做字面判断**，不做 DNS 解析。因为解析本身要发请求，
/// 而「解析出来是内网 IP」的域名（DNS rebinding）在客户端场景下
/// 威胁很低——攻击者要能让用户的 App 去请求一个他控制的域名，
/// 那他已经能拿到用户 IP 了，SSRF 不是新增的风险面。
String? urlRejectionReason(String raw) {
  final u = Uri.tryParse(raw);
  if (u == null) return '不是合法 URL';
  if (u.scheme != 'http' && u.scheme != 'https') {
    return '只允许 http/https（实际 $u.scheme）';
  }
  if (u.host.isEmpty) return '缺少主机名';

  final host = u.host.toLowerCase();

  // 测试专用的回环豁免。**默认关闭**，只有测试进程会打开它。
  //
  // 为什么需要这个口子：签名/请求头的正确性只能靠「真的发一次请求、
  // 看服务端收到什么」来验证，而测试里的服务端必然是 127.0.0.1。
  // 不开这个口子的话，签名链路就只能靠读代码「确认」，那不是验证。
  //
  // 它不会削弱线上防护：没有任何运行时路径会把它置为 true，
  // 唯一调用点是 test/ 下的辅助函数。
  if (kAllowLoopbackForTest && (host == '127.0.0.1' || host == 'localhost')) {
    return null;
  }

  if (host == 'localhost' || host == 'localhost.localdomain') {
    return '不允许访问本机';
  }

  // IPv6 字面量在 Uri 里带方括号，host 取出来已经去掉了
  if (host == '::1' || host == '::' || host.startsWith('fe80:') ||
      host.startsWith('fc') || host.startsWith('fd')) {
    return '不允许访问内网 IPv6 地址';
  }

  // IPv4 字面量
  final v4 = _parseIPv4(host);
  if (v4 != null) {
    if (v4[0] == 127) return '不允许访问本机回环地址';
    if (v4[0] == 10) return '不允许访问内网地址';
    if (v4[0] == 192 && v4[1] == 168) return '不允许访问内网地址';
    if (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31) return '不允许访问内网地址';
    // 169.254.0.0/16 是链路本地，云厂商元数据服务（169.254.169.254）
    // 就在这个段里，是最经典的 SSRF 目标
    if (v4[0] == 169 && v4[1] == 254) return '不允许访问链路本地地址';
    if (v4[0] == 0) return '不允许访问 0.0.0.0';
  }

  return null;
}

List<int>? _parseIPv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

/// 拼装最终请求。
///
/// [params] 提供占位符的取值：page / keyword / id / category / vars.x。
/// 占位符替换在**编码之后**做是错的（会把 `%20` 里的 `%2` 当占位符），
/// 所以这里先替换再交给 Dio 编码——Dio 的 queryParameters 会自动编码，
/// 但那样 `{page}` 这类占位符就没法出现在键里。因此统一手拼 query，
/// 用 [Uri.encodeQueryComponent] 显式编码每个值。
PreparedRequest prepareRequest({
  required PluginManifest manifest,
  required PluginRequest req,
  required Map<String, String> params,
}) {
  final base = manifest.baseUrl.trim();
  final baseErr = urlRejectionReason(base);
  if (baseErr != null) {
    throw PluginFetchException('源站地址不可用：$baseErr（$base）');
  }

  final path = _fill(req.path, params);

  // 绝对地址直接用；相对地址拼到 baseUrl 后。
  // 两种都要过安全校验——绝对地址是配置里写的，同样可能是内网。
  final String full;
  if (path.startsWith('http://') || path.startsWith('https://')) {
    full = path;
  } else {
    // baseUrl 可能带路径前缀（`https://cdn.x.com/api/`），
    // 也可能不带（`https://x.com`）。用 Uri 拼比字符串接稳。
    final b = Uri.parse(base.endsWith('/') ? base : '$base/');
    final rel = path.startsWith('/') ? path.substring(1) : path;
    full = b.resolve(rel).toString();
  }

  final u = Uri.tryParse(full);
  if (u == null) {
    throw PluginFetchException('拼出的地址不合法：$full');
  }

  // query：保留 path 自带的 query，再叠加清单声明的
  final qp = <String, String>{...u.queryParameters};
  for (final e in req.query.entries) {
    qp[e.key] = _fill(e.value, params);
  }
  final query = qp.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  final finalUrl = u.replace(query: query.isEmpty ? null : query).toString();

  final reject = urlRejectionReason(finalUrl);
  if (reject != null) {
    throw PluginFetchException('拒绝请求：$reject（$finalUrl）');
  }

  // 头：默认头 + 单请求覆盖，再补一个 UA（不少采集站对空 UA 直接 403）
  final headers = <String, String>{
    'User-Agent': _defaultUa,
    ...manifest.defaultHeaders,
    ...req.headers,
  };
  for (final k in headers.keys.toList()) {
    final lower = k.toLowerCase();
    if (lower == 'host' || lower == 'cookie' || lower == 'authorization') {
      // 清单校验已经拦过，这里再拦一次：prepareRequest 也可能被
      // 别处直接调用（比如测试），不能只依赖 validate()
      headers.remove(k);
    }
  }

  return PreparedRequest(
    url: finalUrl,
    method: req.method,
    headers: headers,
    body: req.isPost ? _fill(req.body, params) : '',
  );
}

/// 与站点抓取保持一致的 UA。用同一个值是因为这些采集站大多会按 UA
/// 做简单的移动端/桌面端分流，换个 UA 可能拿到不同的 HTML 结构。
const String _defaultUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 替换 `{page}` / `{keyword}` / `{vars.x}` 等占位符。
///
/// 只替换已知占位符，未知的原样保留——这样配置里写错了（比如
/// `{pag}`）能立刻在 URL 里看出来，而不是被静默替换成空串。
String _fill(String tpl, Map<String, String> params) {
  var out = tpl;
  for (final e in params.entries) {
    out = out.replaceAll('{${e.key}}', e.value);
  }
  return out;
}

/// 执行请求。
class PluginFetch {
  PluginFetch._();
  static final PluginFetch instance = PluginFetch._();

  Dio? _dio;

  Dio get _client => _dio ??= Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        // 重定向自己跟，这样才能逐个校验目标地址（Dio 自动跟会跳过校验）
        followRedirects: false,
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
      ));

  /// 发请求并返回响应体。
  ///
  /// 重定向手动跟，最多 3 跳，**每一跳都重新做 SSRF 校验**。
  /// 这是必要的：一个公网域名可以 302 到 `http://192.168.1.1/`，
  /// 只校验第一跳等于没校验。
  Future<FetchResult> fetch(PreparedRequest req) async {
    var url = req.url;
    var method = req.method;
    var body = req.body;

    for (var hop = 0; hop <= 3; hop++) {
      final reject = urlRejectionReason(url);
      if (reject != null) {
        throw PluginFetchException('拒绝请求：$reject（$url）');
      }

      final resp = await _client.request<String>(
        url,
        data: method == 'POST' ? body : null,
        options: Options(
          method: method,
          headers: req.headers,
          contentType: method == 'POST'
              ? Headers.formUrlEncodedContentType
              : null,
        ),
      );

      final code = resp.statusCode ?? 0;

      if (code >= 300 && code < 400) {
        final loc = resp.headers.value('location');
        if (loc == null || loc.isEmpty) {
          throw PluginFetchException('HTTP $code 但没有 Location 头');
        }
        // 相对 Location 要按当前地址解析
        url = Uri.parse(url).resolve(loc).toString();
        // 301/302/303 按惯例转成 GET，307/308 保留方法
        if (code == 301 || code == 302 || code == 303) {
          method = 'GET';
          body = '';
        }
        continue;
      }

      if (code < 200 || code >= 300) {
        throw PluginFetchException('HTTP $code');
      }

      final data = resp.data ?? '';
      if (data.length > kPluginMaxBodyBytes) {
        throw PluginFetchException(
            '响应过大（${(data.length / 1024).round()}KB，'
            '上限 ${kPluginMaxBodyBytes ~/ 1024}KB）');
      }
      return FetchResult(body: data, finalUrl: url);
    }
    throw PluginFetchException('重定向次数过多');
  }
}

/// 给错误信息补上「人话」前缀。
///
/// 插件解析失败时抛出的异常对用户毫无意义（`SyntaxError: Unexpected token`），
/// 但完全不显示又没法排查。折中：错误页显示一句人话，原始错误进日志。
String pluginFriendlyError(Object e) {
  if (e is PluginFetchException) return e.message;
  if (e is SocketException) return '网络不可用';
  if (e is TimeoutException) return '请求超时';
  return '这个源暂时不可用';
}