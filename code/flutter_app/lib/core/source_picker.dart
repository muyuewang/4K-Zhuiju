/// 播放源（线路）选择与换源决策。
///
/// 为什么单独抽一个文件：
///
/// 这套判定原来是散在 detail_page / player_page 里的私有方法，只能在
/// 真机上点着试才知道对不对。短剧的线路形态又特别刁钻（一条线路装
/// 90 集、另一条只装 11 集、还有一条根本返回令牌），靠手工点验证
/// 成本高且容易漏。抽成纯函数后可以用真实接口数据写单测，
/// 把「默认选谁」「换源给谁」固定下来，改坏了测试会直接报。
library;

import 'models.dart';

/// 已知可稳定下载完整 MP4 的源（实测 support Range，token 不失效）。
/// 这些源优先作为默认选中项，用户点开就能直接播、直接下。
const Set<String> kStableMp4Sources = {
  'pylg', // 自建蓝光   425MB
  'tocyyds', // 自建4K-4  1.78GB
  'qq', // QQ         722MB
};

/// 源（线路）的唯一键：优先中文名，退化到 source 标识
String sourceKeyOf(DramaVideo v) =>
    v.sourceCn.isNotEmpty ? v.sourceCn : v.source;

/// 一条线路整体是否可能播放。
///
/// 只看「有没有至少一条条目的 path 像地址」。独家短剧（hgdj）这种
/// 整条线路全是 `7512797350914444313&1` 令牌形态的源，在这里被判死。
bool isSourcePlayable(List<DramaVideo> list) {
  if (list.isEmpty) return false;
  for (final v in list) {
    if (v.pathLooksPlayable) return true;
  }
  return false;
}

/// 源名排序：可播的在前，不可播的沉到最后。
///
/// 「独家短剧」集数最多但整条线路不可用。若按接口原始顺序展示，
/// 它永远排第一且默认选中，用户点进去必失败，观感就是
/// 「所有线路都不能用」。排序不改数据，只把能用的先摆出来。
List<String> sortedSourceNames(Map<String, List<DramaVideo>> m) {
  final names = m.keys.toList();
  names.sort((a, b) {
    final pa = isSourcePlayable(m[a] ?? const []);
    final pb = isSourcePlayable(m[b] ?? const []);
    if (pa == pb) return 0;
    return pa ? -1 : 1;
  });
  return names;
}

/// 选默认源。
///
/// 旧实现只做两档：撞中稳定 MP4 源 → 否则「集数最多的源」。
/// 第二档在短剧上必踩坑：短剧的「独家短剧」源集数最多（实测 90 集），
/// 但它的 path 是原版播放器专用令牌，不是地址也不是站内路径，
/// 我们根本播不了。结果就是用户进详情页、点任意一集、必失败。
///
/// 现在的优先级：
///   1. 稳定 MP4 源（可下载、token 不过期）
///   2. 可播源里**分集粒度最细**的（条目多 → 能对上更多集）
///   3. 可播源里的全集单条目源（一条 m3u8 装完，集数对不上）
///   4. 全部不可播才退回集数最多（至少让用户有东西点）
String pickDefaultSource(Map<String, List<DramaVideo>> m) {
  // 1. 稳定 MP4 源（用 source 字段精确匹配，不靠中文名）
  for (final key in m.keys) {
    final list = m[key] ?? const <DramaVideo>[];
    if (list.isEmpty) continue;
    if (kStableMp4Sources.contains(list.first.source)) return key;
  }

  final entries = m.entries.where((e) => e.value.isNotEmpty).toList();

  // 2. 可播 + 分集粒度细
  final playableMulti = entries
      .where((e) => isSourcePlayable(e.value) && e.value.length > 1)
      .toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  if (playableMulti.isNotEmpty) return playableMulti.first.key;

  // 3. 可播但只有全集单条目
  final playableSingle =
      entries.where((e) => isSourcePlayable(e.value)).toList();
  if (playableSingle.isNotEmpty) return playableSingle.first.key;

  // 4. 全不可播
  return m.keys.reduce((a, b) => m[a]!.length >= m[b]!.length ? a : b);
}

/// 判断某条剧集条目是不是「整部剧打包成一个文件」。
///
/// 实测 B蓝光的 title 是「全集」、episode 为 1 且该源仅 1 条。
/// 放宽判定是为了不漏掉命名不规范的源。
bool isWholeSeriesEntry(DramaVideo v) {
  if (v.episode <= 1) return true;
  final t = v.title.trim();
  return t.contains('全集') || t.contains('完整版');
}

/// 换源候选：每个可用线路挑一条最合适的条目。
///
/// 短剧有个特殊形态必须兼容：有的源把整部剧打包成**一条**条目
/// （B蓝光的 `全集/index.m3u8`，2421 个分片覆盖全部 90 集）。
/// 这种源永远不可能有「同集条目」，若按集精确匹配就永远选不到，
/// 于是短剧只要主源失效，换源永远提示「没有更多可用源了」——
/// 明明 B蓝光/BL 两条线路服务端都健康，用户却一集都放不出来。
///
/// 优先级：同集数 > 同集标签 > 该源的全集单条目 > 该源首条。
/// 整条线路都不可播的（令牌形态）直接跳过，绝不推给用户。
List<DramaVideo> switchCandidates(
  Map<String, List<DramaVideo>> sources,
  DramaVideo cur, {
  Set<String> tried = const {},
}) {
  final curSrc = sourceKeyOf(cur);
  final out = <DramaVideo>[];
  final seen = <String>{};

  for (final entry in sources.entries) {
    final name = entry.key;
    if (name == curSrc) continue;
    if (tried.contains(name)) continue;
    final list = entry.value;
    if (list.isEmpty) continue;

    // 整条线路没有一条条目的 path 像地址：直接跳过。
    final pool =
        list.where((v) => v.pathLooksPlayable).toList(growable: false);
    if (pool.isEmpty) continue;

    DramaVideo? pick;
    // 1. 同集数
    for (final v in pool) {
      if (v.episode == cur.episode) {
        pick = v;
        break;
      }
    }
    // 2. 同集数标签兜底（少数源集数编号不一致）
    if (pick == null) {
      for (final v in pool) {
        if (v.epLabel == cur.epLabel) {
          pick = v;
          break;
        }
      }
    }
    // 3. 全集单条目（一条装完整部剧）——短剧最需要这一档
    if (pick == null && pool.length == 1 && isWholeSeriesEntry(pool.first)) {
      pick = pool.first;
    }
    // 4. 实在对不上集：仍允许切过去，不要一句「没有更多可用源了」把人挡死
    pick ??= pool.first;

    if (seen.add(name)) out.add(pick);
  }
  return out;
}