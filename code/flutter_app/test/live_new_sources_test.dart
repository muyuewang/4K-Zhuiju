/// 两个新源（优子 / 金山）的**联网**端到端探针。
///
/// 与 `maccms_xml_parse_test.dart` 的分工：
///   - 那个文件测**解析函数**，纯离线，用录下来的报文；
///   - 这个文件测**真实链路**，走 [DataSource] 契约的四个方法。
///
/// 为什么两者都要有：解析函数对了不代表链路能跑通。比如
/// `listNeedsBatchDetail` 打开后要发两次请求，如果第二次失败时
/// 把整个列表吞掉，解析测试全绿、用户却看到空白页。
///
/// 断网时打印「跳过」并正常结束，不让套件变红。
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/maccms_api_source.dart';
import 'package:zhuiju/core/source/site_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把所有 HTTP 打成 400，这里恢复真实 HttpClient
  HttpOverrides.global = null;

  Future<void> probe(DataSource src) async {
    print('\n${'=' * 68}');
    final cfg = (src as MacCmsApiSource).cfg;
    print('${cfg.displayName}（${cfg.id}）format=${cfg.format}');
    print('=' * 68);

    // ① 推荐列表（走 listNeedsBatchDetail 的两次请求）
    List<Drama> feed;
    final sw = Stopwatch()..start();
    try {
      feed = await src.category('', page: 1);
    } catch (e) {
      print('  ① 推荐列表 失败: $e');
      return;
    }
    sw.stop();
    print('  ① 推荐列表  ${sw.elapsedMilliseconds}ms  ${feed.length} 条');
    print('     ${feed.take(4).map((d) => '${d.id}:${d.name}').join(' | ')}');
    final withCover = feed.where((d) => d.cover.path.isNotEmpty).length;
    print('     封面 $withCover/${feed.length}');
    final years = feed.map((d) => d.year).where((y) => y > 0).toList()..sort();
    print('     年份 ${years.isEmpty ? '—' : '${years.first}~${years.last}'}'
        '（若全是 2022~2023 说明列表落到了 videolist 的老片排序）');
    if (feed.isEmpty) {
      print('  ✗ 推荐为空，后续跳过');
      return;
    }

    // ② 分类列表
    final cat = src.categories.firstWhere(
      (e) => e.id.isNotEmpty,
      orElse: () => const SourceCategory('', ''),
    );
    if (cat.id.isNotEmpty) {
      try {
        final sw2 = Stopwatch()..start();
        final list = await src.category(cat.id, page: 1);
        sw2.stop();
        print('  ② 分类「${cat.name}」 ${sw2.elapsedMilliseconds}ms  ${list.length} 条'
            '  封面 ${list.where((d) => d.cover.path.isNotEmpty).length}/${list.length}');
      } catch (e) {
        print('  ② 分类「${cat.name}」 失败: $e');
      }
    }

    // ③ 搜索
    try {
      final sw3 = Stopwatch()..start();
      final hits = await src.search('凡人', page: 1);
      sw3.stop();
      print('  ③ 搜索「凡人」 ${sw3.elapsedMilliseconds}ms  ${hits.length} 条');
      print('     ${hits.take(3).map((d) => d.name).join(' / ')}');
    } catch (e) {
      print('  ③ 搜索 失败: $e');
    }

    // ④ 详情（含分集）
    final target = feed.first;
    DramaDetail detail;
    try {
      final sw4 = Stopwatch()..start();
      detail = await src.detail(target.id);
      sw4.stop();
      final lineNames = <String, int>{};
      for (final v in detail.videos) {
        lineNames[v.sourceCn.isNotEmpty ? v.sourceCn : v.source] =
            (lineNames[v.sourceCn.isNotEmpty ? v.sourceCn : v.source] ?? 0) + 1;
      }
      print('  ④ 详情《${detail.name}》 ${sw4.elapsedMilliseconds}ms  '
          '${detail.videos.length} 集  ${lineNames.entries.map((e) => '${e.key}×${e.value}').join(', ')}');
      if (detail.videos.isEmpty) {
        print('  ✗ 详情没有分集');
        return;
      }
    } catch (e) {
      print('  ④ 详情 失败: $e');
      return;
    }

    // ⑤ 播放地址：取每条线路的第 1 集，实探 m3u8
    final firstPerLine = <String, DramaVideo>{};
    for (final v in detail.videos) {
      firstPerLine.putIfAbsent(v.sourceCn.isEmpty ? v.source : v.sourceCn,
          () => v);
    }
    for (final entry in firstPerLine.entries) {
      try {
        final resolved = await src.resolveUrl(entry.value);
        final head = await _headM3u8(resolved);
        print('  ⑤ ${entry.key.padRight(10)} ${head.padRight(28)} ${_short(resolved)}');
      } catch (e) {
        print('  ⑤ ${entry.key.padRight(10)} 解析失败: $e');
      }
    }
  }

  test('优子资源 端到端', () async {
    await probe(kYzzySource);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('金山资源 端到端', () async {
    await probe(kJszySource);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('起点资源 端到端', () async {
    await probe(kQdys2Source);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String _short(String u) => u.length > 62 ? '${u.substring(0, 62)}…' : u;

/// 拉 m3u8 的前若干字节，判断是不是合法播放清单。
///
/// 判定标准刻意不用「HTTP 200 就算好」：这些站的 CDN 对失效地址会
/// 返回 200 + 一个 HTML 错误页（本次探测里踩到过多次），
/// 只有 `#EXTM3U` 才能证明播放器真的能读。
///
/// 只读前 4 KB 就主动断开：媒体清单动辄几十上百 KB，探针不需要全文，
/// 而且 `index.m3u8` 后面常跟着分片列表，读全量纯属浪费。
Future<String> _headM3u8(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent =
        'Mozilla/5.0 (Linux; Android 13) Chrome/120.0 Mobile Safari/537.36';
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 15));

    final buf = <int>[];
    await for (final chunk in resp) {
      buf.addAll(chunk);
      if (buf.length >= 4096) break;
    }
    // 用 utf8 + allowMalformed：清单是 UTF-8，但个别 CDN 会在注释里塞
    // 非 UTF-8 的频道名。用 SystemEncoding 在 Windows 上是 GBK，必炸。
    final text = String.fromCharCodes(buf);
    return _classify(resp.statusCode, text);
  } catch (e) {
    return 'ERR ${e.runtimeType}';
  } finally {
    client.close(force: true);
  }
}

String _classify(int code, String body) {
  if (code != 200) return 'HTTP $code';
  if (body.contains('#EXTM3U')) return '✓ #EXTM3U';
  if (body.trimLeft().startsWith('<')) return '✗ 返回 HTML 不是清单';
  return '✗ 非 m3u8 内容';
}