/// 探针：验证「这条 video 是不是直播」的代码级判据。
///
/// 背景
/// ----
/// 橘汁的「直播」分类（typeId1=25）和普通剧集走同一个 detail 接口，
/// 返回的 videos 结构完全一样，UI 分不出来。要靠 `source` / `path`
/// 的形态来打标，而这个判据**必须两个方向都验**：
///
///   - 命中率：直播分类的 video 有多少能认出来（漏判 → 用户还是看到选集）
///   - 误判率：点播分类的 video 有多少被误认成直播（误判 → 正常剧集
///     失去选集、不能记进度、播完不能自动下一集）
///
/// 误判的后果比漏判严重得多，所以这里把电视剧（21）/ 电影（20）当对照组
/// 一起测，只有「直播全中 且 点播零误判」这个判据才能用。
///
/// 这是联网探针，结果靠 print 给人看，不做断言。
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';
import 'package:zhuiju/core/models.dart';

/// 待验证的判据：source 是 cctv 且 path 以 zb- 开头。
///
/// 选这两个特征而不是只看 path 前缀，是因为 `zb-` 太短，别的源将来
/// 万一有 `zb-` 开头的点播文件名就会撞上；加上 source 限定更稳。
bool looksLive(DramaVideo v) =>
    v.source == 'cctv' && v.path.trimLeft().startsWith('zb-');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  /// 抽样统计某个分类的 video 形态
  Future<void> survey(String api2, String label, int take) async {
    final api = ZhuijuApi.instance;
    List<Drama> list;
    try {
      list = await api.category(api2, pageSize: 20);
    } catch (e) {
      print('[$label] 分类请求失败: $e');
      return;
    }
    if (list.isEmpty) {
      print('[$label] 分类为空');
      return;
    }

    var totalVideos = 0;
    var marked = 0;
    final sources = <String, int>{};
    final pathPrefixes = <String, int>{};
    var checked = 0;

    for (final d in list.take(take)) {
      DramaDetail det;
      try {
        det = await api.detail(d.id);
      } catch (_) {
        continue;
      }
      checked++;
      for (final v in det.videos) {
        totalVideos++;
        if (looksLive(v)) marked++;
        sources[v.source] = (sources[v.source] ?? 0) + 1;
        final p = v.path.trimLeft();
        final pre = p.length >= 3 ? p.substring(0, 3) : p;
        pathPrefixes[pre] = (pathPrefixes[pre] ?? 0) + 1;
      }
    }

    print('[$label] 抽查 $checked 部 / $totalVideos 条 video');
    print('   判据命中 $marked 条'
        '（${totalVideos == 0 ? 0 : (marked * 100 / totalVideos).toStringAsFixed(0)}%）');
    print('   source 分布: ${_top(sources)}');
    print('   path 前3字符分布: ${_top(pathPrefixes)}');
  }

  test('直播判据：命中率与误判率', () async {
    print('=== 对照组：直播 typeId=25 ===');
    await survey('25', '直播25', 6);
    print('');
    print('=== 对照组：电视剧 typeId=21 ===');
    await survey('21', '电视剧21', 4);
    print('');
    print('=== 对照组：电影 typeId=20 ===');
    await survey('20', '电影20', 4);
    print('');
    print('=== 对照组：短剧 typeId=24 ===');
    await survey('24', '短剧24', 4);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String _top(Map<String, int> m) {
  final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return e.take(6).map((x) => '"${x.key}":${x.value}').join(' ');
}