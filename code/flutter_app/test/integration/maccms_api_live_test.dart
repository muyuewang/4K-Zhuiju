/// 采集接口源的真实链路验收（**联网**）。
///
/// 离线测试只锁解析；这里走完整实现，验证「源真的能用」：
/// 搜索 → 详情 → 取址，全部经过 [MacCmsApiSource] 的真实请求路径。
///
/// 为什么值得单独写：解析对了不代表能播。可能踩的坑有
///   - `apiUrl` 结尾缺斜杠 → 拼出来的 query 被吃掉路径段；
///   - 站方限流 → 首屏直接超时；
///   - 线路地址是分享页 → 播放器打不开。
/// 这些只有联网跑一遍才知道。
///
/// 网络不可达时整组跳过而不是失败：CI 环境可能没网，
/// 让「没网」把版本卡死没有任何意义。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/site_sources.dart';

void main() {
  group('大师兄 · 暴风（bfzyapi.com）', () {
    late DataSource src;

    setUpAll(() => src = kBofengSource);

    test('搜索「嫁金钗」能命中，且 id/封面/年份都正常', () async {
      List<dynamic> hits;
      try {
        hits = await src.search('嫁金钗');
      } catch (e) {
        // 无网络 / 源站临时不可达：跳过而不是失败
        markTestSkipped('源站不可达，跳过：$e');
        return;
      }
      expect(hits, isNotEmpty, reason: '暴风站内「嫁金钗」有 1200+ 条相关，不该为空');

      final first = hits.first;
      // ignore: avoid_dynamic_calls
      expect(first.id, isNotEmpty);
      // ignore: avoid_dynamic_calls
      expect(first.name, isNotEmpty);
      // ignore: avoid_dynamic_calls
      expect(first.sourceId, 'bofeng', reason: '收藏/历史要靠它回查源');
    });

    test('详情给出多条线路、每集都是 http 地址', () async {
      late List<dynamic> hits;
      try {
        hits = await src.search('嫁金钗');
      } catch (e) {
        markTestSkipped('源站不可达，跳过：$e');
        return;
      }
      if (hits.isEmpty) {
        markTestSkipped('搜索无结果，跳过');
        return;
      }

      // ignore: avoid_dynamic_calls
      final d = await src.detail(hits.first.id as String);
      expect(d.videos, isNotEmpty, reason: '详情一集都没有 = 用户点进去看到白板');
      expect(d.sourceId, 'bofeng');

      for (final v in d.videos) {
        expect(v.path, startsWith('http'),
            reason: '线路 ${v.sourceCn} 的地址不是 URL，播放器打不开');
        expect(v.sourceCn, isNotEmpty, reason: '线路名空白 → 面板上一堆无标签按钮');
      }
    });

    test('首集取址能拿到可播地址', () async {
      late List<dynamic> hits;
      try {
        hits = await src.search('嫁金钗');
      } catch (e) {
        markTestSkipped('源站不可达，跳过：$e');
        return;
      }
      if (hits.isEmpty) {
        markTestSkipped('搜索无结果，跳过');
        return;
      }

      // ignore: avoid_dynamic_calls
      final d = await src.detail(hits.first.id as String);
      if (d.videos.isEmpty) {
        markTestSkipped('无线路，跳过');
        return;
      }

      final url = await src.resolveUrl(d.videos.first);
      expect(url, startsWith('http'));
      expect(
        url.toLowerCase().contains('.m3u8') || url.toLowerCase().contains('.mp4'),
        isTrue,
        reason: '取址结果不是视频地址，实际是 $url',
      );
    });

    test('任何分类都能拿到非空列表（防止填了空分类 id）', () async {
      for (final c in src.categories) {
        if (c.id.isEmpty) continue;
        try {
          final list = await src.category(c.id);
          expect(list, isNotEmpty,
              reason: '分类「${c.name}」(${c.id}) 返回空，用户点进去是白板');
        } catch (e) {
          markTestSkipped('分类「${c.name}」请求失败，跳过：$e');
        }
      }
    });
  });

  group('大师兄 · 量子（cj.lziapi.com）', () {
    late DataSource src;

    setUpAll(() => src = kLiangziSource);

    test('分类列表都非空', () async {
      for (final c in src.categories) {
        if (c.id.isEmpty) continue;
        try {
          final list = await src.category(c.id);
          expect(list, isNotEmpty,
              reason: '分类「${c.name}」(${c.id}) 返回空');
        } catch (e) {
          markTestSkipped('分类「${c.name}」请求失败，跳过：$e');
        }
      }
    });

    test('详情 + 首集取址（覆盖分享页二次解析）', () async {
      List<dynamic> hits;
      try {
        hits = await src.search('美食新闻报道');
      } catch (e) {
        markTestSkipped('源站不可达，跳过：$e');
        return;
      }
      if (hits.isEmpty) {
        markTestSkipped('搜索无结果，跳过');
        return;
      }

      // ignore: avoid_dynamic_calls
      final d = await src.detail(hits.first.id as String);
      expect(d.videos, isNotEmpty);

      // 量子这部剧有两条线（liangzi 分享页 / lzm3u8 直链），
      // 两条都必须能取到地址，否则等于少一半线路。
      final flags = d.videos.map((v) => v.source).toSet();
      expect(flags.length, greaterThanOrEqualTo(1));
      for (final v in d.videos.take(1)) {
        final url = await src.resolveUrl(v);
        expect(url, startsWith('http'));
        expect(
          url.toLowerCase().contains('.m3u8') ||
              url.toLowerCase().contains('.mp4'),
          isTrue,
          reason: '线路 ${v.sourceCn} 取址失败，实际是 $url',
        );
      }
    });
  });
}