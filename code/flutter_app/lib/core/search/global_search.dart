/// 全局搜索：把一次关键词并发打到所有已注册数据源，渐进式汇总结果。
///
/// ## 为什么单独做一层，而不是在搜索页里 `for (src in all) await src.search()`
///
/// 1. **串行会慢到不可用**：19 个源，慢的 4 秒，串行最坏 19×4 = 76 秒。
///    必须并发，且每个源要有独立超时——一个挂掉的源不能拖垮整轮。
/// 2. **渐进式返回**：哪个源先回来就先显示哪个，用户不用盯着转圈等最慢的
///    金山/优子。搜索页只拿「当前累计结果 + 进度」重绘。
/// 3. **单源失败隔离**：索尼搜不了（SearchUnsupported）、某源超时/502，
///    都只是少一份结果，不该让整页报错。错误按源记进 [failed]，供状态栏显示。
/// 4. **跨源去重**：同一部剧常在多个源重复命中，按「名称 + 年份」归一化
///    合并，避免用户翻两屏都是同一部。但**保留 sourceId**——点进去要去
///    命中的那个源取详情；合并时选一个「最优」来源（见 [_pickBetter]）。
///
/// ## 竞态
///
/// 搜索页已有请求序号 `_seq` 防连点；这里不重复做，但每条回调都带
/// [GlobalSearchProgress]，页面层判断 seq 不匹配就丢弃。取消在飞的请求
/// 代价大（要动每个源的 client），本项目选择「结果回来丢弃」而非真取消。
library;

import 'dart:async';

import '../api.dart' show friendlyError;
import '../models.dart';
import '../source/data_source.dart';
import '../source/offline_source.dart';
import '../source/registry.dart';

/// 单个源的搜索超时。采集站正常 1~4s，设 6s 留足余量又不会让失败源拖太久。
const Duration kGlobalSearchPerSourceTimeout = Duration(seconds: 6);

/// 每个源最多取多少条。全局搜索是「快速找片」，不是全网爬虫，
/// 各源 page=1 的 Top N 足够；不翻页（各源分页语义不统一）。
const int kGlobalSearchPerSourceLimit = 20;

/// 一轮搜索的进度快照。
class GlobalSearchProgress {
  final int total; // 参与搜索的源总数
  final int done; // 已返回（含失败）的源数
  final int ok; // 成功返回结果的源数
  final List<String> noResult; // 搜成功但 0 结果的源 ID

  /// 每个有结果的源 → **未跨源去重**的原始列表（保持源自己的顺序）。
  ///
  /// ## 为什么必须单独存一份，不能从 [GlobalSearchResult.results] 过滤
  ///
  /// 「全部」页会把不同源命中的同一部剧合并成一条（按名称+年份去重），
  /// 合并后只保留最优的那条、并且只带**一个** sourceId。所以拿最终结果
  /// 按 sourceId 过滤会得到「看剧 38 条」，而看剧自己明明命中了 42 条——
  /// 左栏显示 42、点进去 38，用户会以为数据错了。
  ///
  /// 原始列表就是给左栏计数和单源视图用的：它是「这个源到底搜到了什么」，
  /// 与去重无关。翻页也从这份数据接续（第 1 页用它，第 2 页起实时请求）。
  ///
  /// 渐进过程中每次回调都会重建，先回来的源先出现在左栏。
  final Map<String, List<Drama>> perSource;

  const GlobalSearchProgress({
    required this.total,
    required this.done,
    required this.ok,
    this.noResult = const [],
    this.perSource = const {},
  });

  bool get finished => done >= total;

  /// 各源命中条数之和（未去重）。用于左栏「全部」项的角标。
  int get totalHits =>
      perSource.values.fold(0, (sum, list) => sum + list.length);
}

/// 一轮全局搜索的最终结果。
class GlobalSearchResult {
  final List<Drama> results;
  final GlobalSearchProgress progress;

  /// 失败的源 → 人话原因（按源隔离，不影响其他源的结果）。
  final Map<String, String> failed;

  /// 所有已注册源都不支持搜索（全被跳过，一次请求都没发）。
  /// 这种情况下「没找到」是错误的提示——压根没搜，用户会以为词打错了。
  /// 页面据此给出「这个源搜不了」的说明。
  final bool allUnsupported;

  const GlobalSearchResult({
    required this.results,
    required this.progress,
    this.failed = const {},
    this.allUnsupported = false,
  });
}

class GlobalSearchService {
  GlobalSearchService._();
  static final GlobalSearchService instance = GlobalSearchService._();

  /// 对 [keyword] 发起全局搜索。
  ///
  /// [onPartial] 每有一个源返回就回调一次（包含当前累计、去重后的结果和进度）。
  /// 页面据此渐进刷新；回调在 UI isolate 上同步触发，页面里 setState 即可。
  /// 返回的 Future 在所有源结束后才 complete，拿最终汇总。
  Future<GlobalSearchResult> search(
    String keyword, {
    required void Function(List<Drama> results, GlobalSearchProgress progress)
        onPartial,
    Duration perSourceTimeout = kGlobalSearchPerSourceTimeout,
    int perSourceLimit = kGlobalSearchPerSourceLimit,
  }) async {
    final q = keyword.trim();
    // 排掉占位源、站方不支持搜索的源；后者发请求也只会拿回「暂不支持搜索」。
    final sources = SourceRegistry.all.where((s) {
      if (s is OfflineSource) return false;
      if (s is SearchUnsupported &&
          (s as SearchUnsupported).searchUnsupportedHint.isNotEmpty) {
        return false;
      }
      return true;
    }).toList();

    // 所有已注册源都不支持搜索：一次请求都不会发。要让页面说清楚是
    // 「源搜不了」而不是「没找到」，否则用户会反复换关键词白费劲。
    if (sources.isEmpty) {
      const empty = GlobalSearchProgress(total: 0, done: 0, ok: 0);
      onPartial(const <Drama>[], empty);
      return const GlobalSearchResult(
        results: <Drama>[],
        progress: empty,
        allUnsupported: true,
      );
    }

    final accumulated = <Drama>[];
    final index = <String, int>{}; // 归一化 key → accumulated 下标
    final failed = <String, String>{};
    final noResult = <String>[];

    // 每个源命中、且**未跨源去重**的原始列表，供左栏计数与单源视图使用。
    // 与 [accumulated] 并行维护：accumulated 是给人看的合并结果，
    // 这里是「每个源到底搜到了什么」，两者条数不同是正常的（见字段注释）。
    final perSource = <String, List<Drama>>{};
    var done = 0;
    var ok = 0;

    // 每个源独立 Future：超时/异常都吞掉记进 failed，绝不 rethrow，
    // 否则 Future.wait 会因为一个源失败而让整轮搜索报错。
    final tasks = sources.map((src) async {
      try {
        final list = await src.search(q).timeout(perSourceTimeout);
        final limited = list.length > perSourceLimit
            ? list.sublist(0, perSourceLimit)
            : list;
        if (limited.isEmpty) {
          noResult.add(src.id);
        } else {
          ok++;
          perSource[src.id] = List<Drama>.unmodifiable(limited);
          for (final d in limited) {
            _merge(accumulated, index, d);
          }
        }
      } catch (e) {
        failed[src.id] = friendlyError(e);
      } finally {
        done++;
        onPartial(
          List<Drama>.unmodifiable(accumulated),
          GlobalSearchProgress(
            total: sources.length,
            done: done,
            ok: ok,
            noResult: List<String>.unmodifiable(noResult),
            perSource: Map<String, List<Drama>>.unmodifiable(perSource),
          ),
        );
      }
    });

    await Future.wait(tasks);

    // 最终结果按相关度排一次：渐进过程中结果 arrived 顺序＝源返回顺序，
    // 那是网络快慢不是相关度；收尾统一重排，页面再 setState 一次。
    final sorted = _sortByRelevance(accumulated, q);
    final progress = GlobalSearchProgress(
      total: sources.length,
      done: done,
      ok: ok,
      noResult: List<String>.unmodifiable(noResult),
      perSource: Map<String, List<Drama>>.unmodifiable(perSource),
    );
    onPartial(List<Drama>.unmodifiable(sorted), progress);
    return GlobalSearchResult(
      results: sorted,
      progress: progress,
      failed: Map<String, String>.unmodifiable(failed),
    );
  }

  /// 把一条结果并入累计列表。同「名称+年份」视为同一部剧：
  /// 保留信息更全的那条（有封面/有简介/评分高），但它仍指向一个真实源。
  void _merge(List<Drama> out, Map<String, int> index, Drama d) {
    final key = _normKey(d);
    if (key.isEmpty) {
      // 没有可去重的字段（理论上 search 已过滤空 id/空 name），直接收下
      out.add(d);
      return;
    }
    final at = index[key];
    if (at == null) {
      index[key] = out.length;
      out.add(d);
      return;
    }
    if (_pickBetter(d, out[at])) out[at] = d;
  }

  /// 归一化去重键：名称去空格/标点/大小写 + 年份（年份 0 用空串）。
  ///
  /// 不同源对同一部剧的写法差异主要是空格、全半角括号、繁简体不做处理
  /// （繁简转换要引词典，收益低）。年份能把「新版/老版」区分开，避免
  /// 同名翻拍被误并。
  String _normKey(Drama d) {
    final name = d.name
        .replaceAll(RegExp(r'[\s（）()【】\[\]·:：\-—_]'), '')
        .toLowerCase();
    if (name.isEmpty) return '';
    return '$name|${d.year > 0 ? d.year : ''}';
  }

  /// [a] 是否比 [b] 更值得展示。评分优先，其次封面、简介长度。
  bool _pickBetter(Drama a, Drama b) {
    if (a.stars != b.stars) return a.stars > b.stars;
    final aPic = a.cover.path.isNotEmpty;
    final bPic = b.cover.path.isNotEmpty;
    if (aPic != bPic) return aPic;
    return a.brief.length > b.brief.length;
  }

  /// 相关度排序：标题等于 > 前缀 > 包含 > 其它；同类按评分降序。
  List<Drama> _sortByRelevance(List<Drama> list, String q) {
    final key = q.toLowerCase();
    final scored = list
        .map((d) => _Score(d, _relevance(d.name.toLowerCase(), key)))
        .toList();
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return b.drama.stars.compareTo(a.drama.stars);
    });
    return scored.map((e) => e.drama).toList();
  }

  int _relevance(String name, String key) {
    if (key.isEmpty) return 0;
    if (name == key) return 100;
    if (name.startsWith(key)) return 80;
    if (name.contains(key)) return 60;
    // 逐字包含（「庆余年 第二季」搜「庆余」已由 contains 覆盖），
    // 这里处理关键词被空格切开的情况：「庆 余 年」
    final compact = name.replaceAll(RegExp(r'\s'), '');
    final kc = key.replaceAll(RegExp(r'\s'), '');
    if (compact.contains(kc)) return 50;
    return 0;
  }
}

class _Score {
  final Drama drama;
  final int score;
  const _Score(this.drama, this.score);
}
