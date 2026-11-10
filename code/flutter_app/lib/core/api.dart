/// 4K追剧 API 客户端
///
/// 已验证可用的端点（全部实测 HTTP 200）：
///   /api/proto/v5/drama/search     searchKeys(原文)/typeId1 + page/pagesize  → 列表
///   /api/proto/v5/drama/category   typeId1 + page/pagesize                  → 列表
///   /api/proto/v5/drama/popular    vodIds + page/pagesize                   → 列表
///   /api/proto/v5/drama/recommend  id + page/pagesize                       → 列表
///   /api/proto/v5/drama/getDetail  id                                       → 详情
///   /api/proto/v5/videoUsableUrl   vodPlayFrom + playUrl(URL编码)            → 播放地址
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'models.dart';
import 'protocol.dart';

class ApiException implements Exception {
  final int code;
  final String msg;
  ApiException(this.code, this.msg);
  @override
  String toString() => 'ApiException($code, $msg)';
}

class ZhuijuApi {
  ZhuijuApi._();
  static final ZhuijuApi instance = ZhuijuApi._();

  static const String host = 'http://juziapp.hzhcbkj.cn';

  /// 备用域名：主域被墙时可换
  static String baseUrl = host;

  /// 固定设备指纹（与原 App 抓包一致，避免风控）
  static const String deviceId = '3342CF6E5B34747029419DBA6B159A35';
  static const String androidId = 'f00b0e69983f85a9';
  static const String vApp = '3070';

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    responseType: ResponseType.bytes,
    validateStatus: (_) => true,
  ));

  // ---------------- publicParams 构造 ----------------
  String _buildPublicParams() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final r16 = randomToken(16);

    final map = <String, dynamic>{
      'country': 'CN',
      'vName': '3.0.7.0',
      'cpuId': 'Qualcomm%20Technologies%2C%20Inc%20MSM8998',
      'young': 0,
      'facturer': 'samsung',
      'pkg': 'com.asjdhjhd.mgd.p3',
      'uuid': deviceId,
      'resolution': '720x1280',
      'mac': '00%3Adb%3A1e%3A1b%3Aa8%3Ae8',
      'abid': '4365',
      'model': 'SM-N9700',
      'plat': 'android',
      'udid': deviceId,
      'dpi': '320',
      'net': '1',
      'lang': 'zh',
      'brand': 'samsung',
      'density': '2.0',
      'appName': '%E6%A9%98%E6%B1%81',
      'cpu': 'x86_64',
      'chid': '10000',
      'carrier': '%E7%A7%BB%E5%8A%A8',
      'v': '1',
      'tenantId': '',
      '_vOsCode': '28',
      'vOs': '9',
      'vApp': vApp,
      'device': '0',
      'androidID': androidId,
      // 签名三元组
      'timestamp': ts,
      'random_str': r16,
      'sig': rsaEncryptB64('$ts$r16$vApp'),
    };

    final sigA = aesEcbB64(kSafeSecret, '$ts$r16');
    map['sig2'] = sigA.substring(0, 8);
    map['sig3'] = sigA.substring(8);

    return jsonEncode(map);
  }

  // ---------------- 请求体构造 ----------------
  Uint8List _buildBody(Map<String, String> params) {
    final kv = params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final r8 = randomToken(8);
    final fake20 = randomToken(20);

    final b64 = aesEcbB64(kSafeCode, '$kv$ts');
    final merged = '$r8$b64';
    final enc1 = merged.substring(0, 20);
    final enc2 = merged.substring(20);

    final w = PbWriter()
      ..str(1, enc1)
      ..str(2, enc2)
      ..str(3, fake20)
      ..i64(4, ts)
      ..str(5, r8);
    return w.takeBytes();
  }

  // ---------------- 通用 POST ----------------
  /// 带重试的 POST。
  ///
  /// 这个接口跑在移动网络下，一次瞬时丢包就会让整页变成错误页，
  /// 用户只能手动点重试。这里对「网络类异常」自动重试 2 次（共 3 次尝试），
  /// 业务错误（code != 200）不重试——那是服务端明确拒绝，重试没意义。
  Future<Uint8List> _post(String path, Map<String, String> params) async {
    const maxAttempt = 3;
    Object? lastErr;

    for (var attempt = 0; attempt < maxAttempt; attempt++) {
      if (attempt > 0) {
        // 0.4s → 1.2s，短退避即可；用户还在等页面出来
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt * 3));
      }
      try {
        return await _postOnce(path, params);
      } on ApiException {
        rethrow; // 业务错误，重试无用
      } catch (e) {
        lastErr = e;
        if (!_isRetryable(e)) rethrow;
        debugPrint('[API] $path attempt ${attempt + 1}/$maxAttempt failed: $e');
      }
    }
    throw lastErr!;
  }

  /// 只有连接层问题值得重试；超时/断开/无网络都算
  bool _isRetryable(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
          return true;
        default:
          return false;
      }
    }
    return false;
  }

  Future<Uint8List> _postOnce(String path, Map<String, String> params) async {
    final body = _buildBody(params);
    final resp = await _dio.post<List<int>>(
      '$baseUrl$path',
      data: body,
      options: Options(
        headers: {
          'Content-Type': 'application/x-protobuf',
          'Accept': 'application/x-protobuf',
          'User-Agent': 'okhttp/3.12.1',
          'publicParams': _buildPublicParams(),
        },
      ),
    );

    final raw = resp.data;
    if (raw == null) {
      throw ApiException(resp.statusCode ?? -1, '空响应 HTTP ${resp.statusCode}');
    }
    final bytes = Uint8List.fromList(raw);
    if (bytes.isEmpty) {
      throw ApiException(resp.statusCode ?? -1, 'HTTP ${resp.statusCode} 无内容');
    }

    // 解 ApiResult{code, msg, data}
    final fs = PbReader(bytes).readAll();
    final code = pbInt(fs, 1) ?? -1;
    final msg = pbString(fs, 2) ?? '';
    if (code != 200) {
      throw ApiException(code, msg.isEmpty ? '请求失败($code)' : msg);
    }
    final data = pbBytesAll(fs, 3);
    if (data.isEmpty) return Uint8List(0);
    return data.first;
  }

  // ---------------- 列表类接口 ----------------
  /// 通用分页列表解析：body 里 repeated DramaBean 在 field 1
  Future<List<Drama>> _list(String path, Map<String, String> params) async {
    final body = await _post(path, params);
    if (body.isEmpty) return const [];
    final fs = PbReader(body).readAll();
    final items = <Drama>[];
    for (final seg in pbBytesAll(fs, 1)) {
      try {
        items.add(Drama.fromBytes(seg));
      } catch (_) {
        // 跳过异常条目
      }
    }
    return items;
  }

  /// 搜索（searchKeys 传原始中文，不做 URL 编码——已实测）
  ///
  /// [extra] 用于透传尚未确认的筛选/排序参数。这些参数是对方服务端
  /// 下发的，我们这套接口是否认它们必须实测（见 test/api_probe_test.dart），
  /// 所以先留一个不做校验的入口，避免为每个假设参数都改一次方法签名。
  Future<List<Drama>> search(String keyword,
      {int page = 1, int pageSize = 20, String? typeId1,
      Map<String, String>? extra}) {
    final p = <String, String>{
      'page': '$page',
      'pagesize': '$pageSize',
    };
    if (keyword.isNotEmpty) p['searchKeys'] = keyword;
    if (typeId1 != null && typeId1.isNotEmpty) p['typeId1'] = typeId1;
    if (extra != null) p.addAll(extra);
    return _list('/api/proto/v5/drama/search', p);
  }

  /// 分类列表
  Future<List<Drama>> category(String typeId1,
          {int page = 1, int pageSize = 20}) =>
      _list('/api/proto/v5/drama/category', {
        'typeId1': typeId1,
        'page': '$page',
        'pagesize': '$pageSize',
      });

  /// 热门（需 vodIds，逗号分隔）
  Future<List<Drama>> popular(String vodIds,
          {int page = 1, int pageSize = 20}) =>
      _list('/api/proto/v5/drama/popular', {
        'vodIds': vodIds,
        'page': '$page',
        'pagesize': '$pageSize',
      });

  /// 相关推荐
  Future<List<Drama>> recommend(int id, {int page = 1, int pageSize = 20}) =>
      _list('/api/proto/v5/drama/recommend', {
        'id': '$id',
        'page': '$page',
        'pagesize': '$pageSize',
      });

  // ---------------- 详情 ----------------
  Future<DramaDetail> detail(int id) async {
    final body = await _post('/api/proto/v5/drama/getDetail', {'id': '$id'});
    if (body.isEmpty) throw ApiException(200, '详情为空');
    return DramaDetail.fromBytes(body);
  }

  // ---------------- 播放地址 ----------------
  /// 用 DramaVideo 的 source + path 换取真实播放地址
  Future<PlayInfo> playUrl(String source, String path) async {
    final body = await _post('/api/proto/v5/videoUsableUrl', {
      'vodPlayFrom': source,
      'playUrl': Uri.encodeComponent(path),
    });
    if (body.isEmpty) throw ApiException(200, '播放地址为空');
    return PlayInfo.fromBytes(body);
  }

  /// 直接可用的直链判定：path 本身是 http(s) 的 m3u8/mp4
  static bool isDirectUrl(String path) =>
      path.startsWith('http://') || path.startsWith('https://');
}

/// 把 Dio 的异常转成人话
///
/// 界面上的错误提示必须是「用户能据此行动」的一句话。
/// 原来兜底直接返回 `e.toString()`，用户会看到
/// `ClientException with SocketException: Failed host lookup: ...`
/// 这种东西——既看不懂，也不知道下一步该干嘛（重试？换源？检查网络？）。
String friendlyError(Object e) {
  if (e is ApiException) return e.msg;
  if (e is SocketException) return '网络不可达，请检查网络或切换线路';
  if (e is TimeoutException) return '请求超时，请重试或切换线路';
  if (e is DioException) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时，请检查网络';
      case DioExceptionType.sendTimeout:
        return '发送超时，请重试';
      case DioExceptionType.receiveTimeout:
        return '接收超时，请重试';
      case DioExceptionType.connectionError:
        return '连接失败，服务器可能不可达';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code == 403) return '源站拒绝访问（403）';
        if (code == 404) return '接口不存在（404）';
        if (code >= 500) return '服务器出错（$code），请稍后重试';
        return '请求失败（$code）';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badCertificate:
        return '证书校验失败，请检查网络环境';
      case DioExceptionType.transformTimeout:
        return '数据处理超时，请重试';
      case DioExceptionType.unknown:
        return '网络异常，请重试';
    }
  }
  // 兜底：具体异常写日志（开发时能看到完整堆栈），界面上只给人话。
  // 把 toString() 直接甩给用户等于没提示，还暴露内部实现细节。
  debugPrint('[API] 未归类异常: $e');
  return '出错了，请重试';
}