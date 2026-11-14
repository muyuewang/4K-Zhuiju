/// 探针：橘汁源「直播」分类（typeId1=25）到底能不能看。
///
/// 为什么走 Dart 而不是 Python：这个接口的请求体是 AES 加密 + protobuf，
/// 头部还要带 RSA 签名的 publicParams。在 Python 里复现一遍等于制造
/// 第二份实现，测出来的结论反而不代表 App 的真实行为。
/// 这里直接调 App 的 ZhuijuApi，测的就是用户点开时走的同一条代码路径。
///
/// 判定标准（不能只看 HTTP 200）：
///   detail 里 videos 有没有 path → 有没有可播的播放地址
///   换出来的 URL 响应体是不是 #EXTM3U / ftyp / FLV
///
/// 这不是断言型测试，是联网探针，结果靠 print 给人看。
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把所有请求打成 400，联网探针要真实网络
  HttpOverrides.global = null;

  test('typeId=25 直播分类实测', () async {
    final api = ZhuijuApi.instance;

    List<dynamic> list;
    try {
      list = await api.category('25', pageSize: 20);
    } catch (e) {
      print('分类 25 请求失败: $e');
      return;
    }
    print('=== category(25) 返回 ${list.length} 条 ===');
    if (list.isEmpty) {
      print('结论: 分类 25 无内容');
      return;
    }
    for (final d in list.take(6)) {
      print('  id=${d.id} name="${d.name}" type=${d.type} clazz=${d.clazz}');
    }

    int withVideos = 0;
    int withDirect = 0;
    int playable = 0;
    final samples = <String>[];

    for (final d in list.take(6)) {
      try {
        final det = await api.detail('${d.id}');
        final vs = det.videos;
        if (vs.isEmpty) {
          print('  [${d.id}] "${d.name}" → detail 无 videos');
          continue;
        }
        withVideos++;
        final v = vs.first;
        final isDirect = ZhuijuApi.isDirectUrl(v.path);
        if (isDirect) withDirect++;
        print('  [${d.id}] "${d.name}" videos=${vs.length} '
            '首条 source="${v.source}" path="${_cut(v.path)}" direct=$isDirect');

        // 换播放地址
        try {
          final info = await api.playUrl(v.source, v.path);
          final u = info.playUrl;
          print('      → playUrl: ${_cut(u)}');
          if (u.isNotEmpty) {
            final ok = await _sniff(u);
            print('      → 探活: $ok');
            if (ok.startsWith('OK')) playable++;
          }
        } catch (e) {
          print('      → playUrl 失败: $e');
        }
      } catch (e) {
        print('  [${d.id}] detail 失败: $e');
      }
      if (samples.length < 8) samples.add('${d.id}:${d.name}');
    }

    print('');
    print('=== 统计（抽查 6 条） ===');
    print('  有 videos : $withVideos');
    print('  直链 path : $withDirect');
    print('  能播      : $playable');
    print('  样本      : ${samples.join(" | ")}');
  }, timeout: const Timeout(Duration(minutes: 4)));
}

String _cut(String s) => s.length <= 80 ? s : '${s.substring(0, 77)}...';

/// 看响应体前 64 字节判断是不是媒体流
Future<String> _sniff(String url) async {
  if (!url.toLowerCase().startsWith('http')) return 'NO(非http)';
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..badCertificateCallback = (c, h, p) => true;
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'okhttp/3.12.1');
    final resp = await req.close();
    if (resp.statusCode != 200) return 'NO(HTTP${resp.statusCode})';
    final buf = <int>[];
    await for (final chunk in resp) {
      buf.addAll(chunk);
      if (buf.length >= 64) break;
    }
    final head = String.fromCharCodes(buf.take(64));
    if (head.trimLeft().startsWith('#EXTM3U')) return 'OK M3U8';
    if (head.contains('ftyp')) return 'OK MP4';
    if (head.startsWith('FLV')) return 'OK FLV';
    return 'NO(内容=${head.replaceAll(RegExp(r"\s"), " ").substring(0, head.length > 40 ? 40 : head.length)})';
  } catch (e) {
    return 'NO(${e.runtimeType})';
  } finally {
    client.close(force: true);
  }
}