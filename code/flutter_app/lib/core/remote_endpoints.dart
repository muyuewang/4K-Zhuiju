/// 接口域名的远端下发通道。
///
/// ## 为什么需要
///
/// 橘汁的接口域名 `juziapp.hzhcbkj.cn` 是运营方**动态下发**的（历史上
/// 换过多次），而我们把它写死在 `api.dart` 里。后果是：
///
///   2026-11-17 该域名整站 502（CDN 回源失败，源站自己挂了），而官方
///   官网 juzhi999.app 仍在正常更新、已经发了 v3.0.7.1。也就是说对方
///   只是在换服务器/换域名，我们这边却只能等下一次发版才能跟上——
///   用户装的是旧包，旧包里的旧域名，只能吃一整片「连接失败」。
///
/// 这个类只解决一件事：**域名可配**，不必为改一个字符串发一个版本。
///
/// ## 它不做什么
///
///   - 不接管接口协议。网络仍走 [ZhuijuApi]，这里只改它的 [ZhuijuApi.baseUrl]。
///   - 不保证成功。拉不到就用缓存，缓存没有就用内置默认，**永不阻塞启动**。
///   - 不做「任意配置下发」。协议加解密、字段映射这些都不适合远程改，
///     一旦改错会让整个源解析失败且无法回滚；只有域名这类单值参数是安全的。
///
/// ## 三层兜底
///
///   1. 远端配置（多镜像轮询，任一个成功即用）
///   2. 本地缓存（上一次成功拉到的值，离线也能用）
///   3. 内置默认（[ZhuijuApi.defaultHost]，编译进包里的那一个）
///
/// 任何一层失败都静默降级到下一层，不弹提示、不写错误态——
/// 「配置没拉到」不是用户需要知道的事。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

class RemoteEndpoints {
  RemoteEndpoints._();
  static final RemoteEndpoints instance = RemoteEndpoints._();

  /// 缓存键。带版本号：将来配置结构变了，改版本号即丢弃旧缓存，
  /// 不用写迁移逻辑。
  static const String _prefKey = 'app.endpoints.v1';

  /// 配置文件地址，按顺序尝试，第一个成功即用。
  ///
  /// 第一个走 ghproxy 镜像：实测国内直连 200、约 1s，而
  /// raw.githubusercontent.com 直连不通（HTTP 000）。
  /// 第二个是原始地址，留给网络环境本来就通的情况（含海外用户）——
  /// 镜像挂了不至于全线失守。
  ///
  /// 两个都失败就吃缓存，所以这里不需要再兜更多镜像：多挂几个也不会
  /// 提高成功率，只会拖慢启动时那一次后台请求。
  static const List<String> _mirrors = <String>[
    'https://ghproxy.net/https://raw.githubusercontent.com/'
        'muyuewang/4K-Zhuiju/main/config/endpoints.json',
    'https://raw.githubusercontent.com/'
        'muyuewang/4K-Zhuiju/main/config/endpoints.json',
  ];

  /// 单次请求超时。这是启动后台任务，慢一点无所谓，但不能一直挂着——
  /// 8 秒是「够慢的网络也能拿到一个 1KB 的 json」与「别让请求堆着」的折中。
  static const Duration _timeout = Duration(seconds: 8);

  /// 橘汁接口 base。null 表示「没有远端值」，此时 [ZhuijuApi.baseUrl]
  /// 保持内置默认。
  String? _zhuijuBase;
  String? get zhuijuBase => _zhuijuBase;

  /// 本次运行是否从远端成功刷新过（仅用于设置页展示，不参与逻辑）
  bool _refreshedFromRemote = false;
  bool get refreshedFromRemote => _refreshedFromRemote;

  bool _restored = false;

  /// 读本地缓存并**立即生效**。
  ///
  /// 必须在任何接口请求之前完成，否则第一屏会先打内置默认域名、
  /// 再被缓存覆盖，等于白发一次注定失败的请求。
  /// 只读一个字符串，比任何网络动作都便宜，放在 `_restoreInBackground` 最前。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;
      final base = map['zhuijuBase'];
      if (base is String && isValidBase(base)) {
        _apply(base);
      }
    } catch (e) {
      // 缓存损坏（手改、升级残留、编码问题）不必修，直接丢弃用默认。
      debugPrint('[CFG] restore failed: $e');
    }
  }

  /// 从远端拉一次配置。
  ///
  /// 调用方**不应该** await 它——这是启动后的后台动作，慢一点没人在等，
  /// 阻塞启动只换来「白屏多几秒」。
  Future<void> refresh() async {
    final dio = Dio(BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      // 配置文件可能是任意 4xx/5xx，交给下面按状态码判断，
      // 不让 Dio 抛异常，省一层 try
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
      headers: {
        // GitHub 系对无 UA 的请求会直接拒（403），必须带
        'User-Agent': '4KZhuiju/remote-config',
        'Accept': 'application/json',
      },
    ));

    for (final url in _mirrors) {
      try {
        // 按小时加时间戳：CDN 默认会缓存一段时间，配置改完想立刻生效
        // 只能靠 query 打破缓存。按天粒度可能出现「改了要等一天」。
        final stamp = DateTime.now().millisecondsSinceEpoch ~/ 3600000;
        final resp = await dio.get<String>('$url?t=$stamp');
        if (resp.statusCode != 200) {
          debugPrint('[CFG] $url -> HTTP ${resp.statusCode}');
          continue;
        }
        final body = resp.data;
        if (body == null || body.isEmpty) continue;

        final map = jsonDecode(body);
        if (map is! Map) continue;
        final base = map['zhuijuBase'];
        if (base is! String || !isValidBase(base)) {
          // 配置写坏了不能直接信：宁可用旧值，也不要因为一条坏配置
          // 把本来能用的源改死
          debugPrint('[CFG] invalid zhuijuBase: $base');
          continue;
        }

        _refreshedFromRemote = true;
        if (base == _zhuijuBase) {
          // 和当前一致就不必落盘，省一次写
          return;
        }
        _apply(base);
        await _persist();
        debugPrint('[CFG] zhuijuBase updated -> $base');
        return;
      } catch (e) {
        debugPrint('[CFG] $url failed: $e');
      }
    }
    // 全部镜像失败：保持现有值（缓存或默认），不写错误态
  }

  /// 生效并同步到 [ZhuijuApi.baseUrl]
  void _apply(String base) {
    _zhuijuBase = base;
    ZhuijuApi.baseUrl = base;
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _prefKey,
        jsonEncode({'zhuijuBase': _zhuijuBase}),
      );
    } catch (e) {
      debugPrint('[CFG] persist failed: $e');
    }
  }

  /// 只接受 http/https 的绝对地址，其余一律拒绝。
  ///
  /// 为什么必须校验：这个值会被拼进每一个接口 URL，等于把「请求发去哪」
  /// 交给了一份远端文件。虽然文件在我们自己的仓库里，但仓库也能被误改，
  /// 而一个写错的 scheme（比如误写成 `ftp:`）会让整个源彻底不可用且
  /// 现象难查。这里挑剔一点，坏值就当作没配。
  ///
  /// 不允许带用户名密码（`http://u:p@host`）：没有任何正当用途，
  /// 却是配置被劫持时最直接的凭证泄漏形态。
  ///
  /// 公开而非私有：这条规则是「远端配置能不能生效」的唯一闸门，
  /// 值得单测逐条钉住（见 `test/remote_endpoints_test.dart`），
  /// 而不是等某天配置写错了才发现它只挡了一半情况。
  static bool isValidBase(String s) {
    if (s.isEmpty || s.length > 200) return false;
    final u = Uri.tryParse(s);
    if (u == null) return false;
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    if (u.host.isEmpty) return false;
    if (u.userInfo.isNotEmpty) return false;
    // 只允许「协议 + 域名 + 可选端口」这种根地址，带路径的不要——
    // 接口路径是代码拼的，base 里再带一层路径会拼出双斜杠或错层
    if (u.path.isNotEmpty && u.path != '/') return false;
    return true;
  }
}