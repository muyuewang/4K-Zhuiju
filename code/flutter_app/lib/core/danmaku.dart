/// 弹幕：接口拉取 + 数据模型
///
/// 接口（逆向 APK 得到，已实测 HTTP 200 并有真实数据）：
///   POST /api/danmu/getMovieDanmuList.do
///     movieId    = 剧集 id（DramaDetail.id）
///     movieKey   = 集数序号（字符串，从 "1" 开始）
///     danmuStart = 起始秒
///     danmuEnd   = 结束秒
///   返回 JSON：
///     { code, msg, data: [ { danmuContent, danmuTime, danmuAttrs, ... } ] }
///
/// 关键细节（都是踩过的坑）：
///   1. movieKey 不是剧名，是**集数**。原 App 里 `config.movieKey =
///      dramaVideosBean.getTitle()` 容易让人误解，但实测传剧名返回 0 条，
///      传 "1"/"2" 才命中——服务端按 movieId+集数 定位一集的弹幕池。
///   2. danmuTime 单位是**秒**，不是毫秒。样本里一集 41 分钟的弹幕
///      最大值为 2515，与秒完全吻合；按毫秒当会全部挤在第 0 秒。
///   3. 颜色在 danmuAttrs 这个 **JSON 字符串** 里（形如
///      {"1":"6","c":"#ffbbaa"}），要再解一层，取 c 字段。
///   4. 该接口是明文 JSON，不走 protobuf + AES 那套，
///      直接用普通 POST + query 即可，不需要签名头。
///
/// 只读定位：本项目不设账号，因此**不做**发送弹幕、点赞、举报，
/// 只拉取展示 + 一个总开关。别为了凑功能去调 addMovieDanmu.do。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// 一条弹幕
class DanmakuItem {
  /// 文本内容
  final String text;

  /// 出现时间（秒）
  final int timeSec;

  /// 颜色（服务端给的 #rrggbb，缺失时为白色）
  final Color color;

  const DanmakuItem({
    required this.text,
    required this.timeSec,
    this.color = Colors.white,
  });

  @override
  String toString() => 'DanmakuItem($timeSec, $text)';
}

class DanmakuApi {
  DanmakuApi._();
  static final DanmakuApi instance = DanmakuApi._();

  /// 与 ZhuijuApi 共用同一个域名常量，换域名时不用改两处
  static const String _path = '/api/danmu/getMovieDanmuList.do';

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    // 接口返回 JSON，但要自己处理「非 JSON / 空串」的容错，
    // 所以统一按纯文本收，再手动 decode。
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
  ));

  /// 集 → 弹幕列表的内存缓存。
  ///
  /// 同一集反复进出播放页很常见（换源、返回再进），每次都请求一遍
  /// 既慢又浪费流量；一集弹幕量很小（几十条），常驻内存没有压力。
  final Map<String, List<DanmakuItem>> _cache = <String, List<DanmakuItem>>{};

  /// 拉取某集弹幕。
  ///
  /// 失败一律返回空列表而不是抛异常：弹幕是锦上添花的功能，
  /// 拉不到不能连累正常播放，也不能在播放页弹错误提示。
  Future<List<DanmakuItem>> fetch({
    required int dramaId,
    required int episode,
    String host = 'http://juziapp.hzhcbkj.cn',
  }) async {
    if (dramaId <= 0 || episode <= 0) return const [];

    final key = '$host|$dramaId|$episode';
    final cached = _cache[key];
    if (cached != null) {
      debugPrint('[DM] cache hit $dramaId/$episode (${cached.length})');
      return cached;
    }

    try {
      final resp = await _dio.post<String>(
        '$host$_path',
        // 一次拉全量：danmuEnd 给足够大的值，避免按 10 分钟分段请求。
        // 实测一集 41 分钟的弹幕总量也就几十条，全量拉取完全可接受。
        queryParameters: {
          'movieId': '$dramaId',
          'movieKey': '$episode',
          'danmuStart': '0',
          'danmuEnd': '999999',
        },
        options: Options(headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        }),
      );

      final raw = resp.data ?? '';
      if (resp.statusCode != 200 || raw.isEmpty) {
        debugPrint('[DM] http ${resp.statusCode} drama=$dramaId ep=$episode');
        return const [];
      }

      final list = _parse(raw);
      _cache[key] = list;
      debugPrint('[DM] loaded $dramaId/$episode -> ${list.length} 条');
      return list;
    } catch (e) {
      debugPrint('[DM] fetch failed drama=$dramaId ep=$episode: $e');
      return const [];
    }
  }

  /// 解析返回体：容忍外层多套一层、字段缺失、单条损坏
  List<DanmakuItem> _parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      debugPrint('[DM] json decode failed: $e');
      return const [];
    }
    if (decoded is! Map) return const [];

    final data = decoded['data'];
    if (data is! List) return const [];

    final out = <DanmakuItem>[];
    for (final e in data) {
      if (e is! Map) continue;
      final text = (e['danmuContent'] as String?)?.trim() ?? '';
      if (text.isEmpty) continue;
      final t = (e['danmuTime'] as num?)?.toInt() ?? -1;
      // 负数时间说明数据有问题，直接跳过；0 秒是合法的（片头就有弹幕）
      if (t < 0) continue;
      out.add(DanmakuItem(
        text: text,
        timeSec: t,
        color: _parseColor(e['danmuAttrs'] as String?),
      ));
    }

    // 按时间排序：渲染层依赖有序，才能做「超出生命周期就跳过」的提前退出
    out.sort((a, b) => a.timeSec.compareTo(b.timeSec));
    return out;
  }

  /// 从 danmuAttrs 里取颜色。
  ///
  /// 形如 {"1":"6","c":"#ffbbaa"}；其它键（1/l 等）是字号/位置等样式，
  /// 这里只用颜色，其余忽略。
  Color _parseColor(String? attrs) {
    if (attrs == null || attrs.isEmpty) return Colors.white;
    try {
      final m = jsonDecode(attrs);
      if (m is Map) {
        final c = m['c'];
        if (c is String && c.length >= 7 && c.startsWith('#')) {
          final v = int.tryParse(c.substring(1, 7), radix: 16);
          if (v != null) return Color(0xFF000000 | v);
        }
      }
    } catch (_) {
      // attrs 不是合法 JSON 就当没有，用默认白色
    }
    return Colors.white;
  }
}