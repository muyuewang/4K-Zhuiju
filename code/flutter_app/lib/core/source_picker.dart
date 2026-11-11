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
import 'playback_prefs.dart';
import 'source/data_source.dart';

/// 默认策略。
///
/// 刻意与 kanju 一致：现有单测的夹具都是 kanju 形态，且 `byPreference`
/// 是「会重排」的那一种，最容易被误用到别的源上。把它作为显式默认值，
/// 调用方只要漏传 policy 就会退回旧行为，而不是静默改成按接口顺序 ——
/// 这种差异在真机上很难一眼看出来。
const LineOrderPolicy kDefaultLineOrderPolicy =
    LineOrderPolicy.byPreference;

/// 已知可稳定下载完整 MP4 的源（实测 support Range，token 不失效）。
/// 这些源优先作为默认选中项，用户点开就能直接播、直接下。
///
/// 注意：这是**橘汁专有**的 source 标识。kanju 的线路键是
/// `wsym3u8` / `hnm3u8` / `bytedance` 这类，不会命中这里，
/// 它靠下面的 [lineRankOf] 走「官方/直出」另一条判别路径。
const Set<String> kStableMp4Sources = {
  'pylg', // 自建蓝光   425MB
  'tocyyds', // 自建4K-4  1.78GB
  'qq', // QQ         722MB
};

/// 线路等级，数字越小越优先。
///
/// 为什么要这个：橘汁和 kanju 的线路形态完全相反，一套「可播/不可播」
/// 的二分法盖不住后者。
///
///   - 橘汁：一部剧 3~5 条线路，差别在「能不能播」（令牌形态的整条死掉）
///   - kanju：一部剧 14~28 条并行线路，**全部**都能播，差别在「画质与代价」
///
/// kanju 两类线路的优劣（2026-11-11 实测）：
///
///   | 类型     | 画质            | 代价                          |
///   | -------- | --------------- | ----------------------------- |
///   | 官方线   | 1080P / 4K 最高 | 多一次 resolve 请求 + 需会话   |
///   | 普通线   | 清晰度参差、常卡 | 拿来即播                      |
///
/// 历次结论变化，改这里前务必读懂：
///   - 早期：官方线部分集数 401，所以判为「次优」（kRankResolve=2）
///   - 现在：接入游客会话（POST /v1/users/anonymous）后，
///     沙海 8 集抽样官方线 16/16、庆余年 6 集抽样 27/27，**100% 可播**。
///     用户实测反馈「普通源很卡、无法播放」，所以默认翻转成官方优先。
///
/// 但官方线要过一次会话接口，弱网下多一跳反而慢，所以保留手动切回
/// 「普通线优先」的能力（见 [PlaybackPrefs]）。
const int kRankStableMp4 = 0; // 稳定 MP4：可直接播、可直接下（橘汁）
const int kRankDead = 3; // 整条不可播

/// 「首选」档：官方优先时是官方线，普通优先时是直出线。
///
/// 命名刻意不叫「官方线档」：这两种线路的先后由用户偏好决定，
/// 档位本身只表达「首选 / 次选」。用偏好名去命名档位，
/// 一旦默认值翻转，常量名就会集体说谎。
const int kRankPrimary = 1;

/// 「次选」档
const int kRankSecondary = 2;

/// 单条条目的等级。
///
/// [pref] 决定官方线与直出线的先后；其余档位（稳定 MP4 / 不可播）固定。
/// 默认「官方优先」，与 [PlaybackPrefs] 的默认值保持一致——
/// 若两处默认不一致，测试与线上行为会分叉，极难发现。
int lineRankOf(
  DramaVideo v, {
  LinePreference pref = LinePreference.officialFirst,
}) {
  if (!v.pathLooksPlayable) return kRankDead;
  final officialIsPrimary = pref == LinePreference.officialFirst;
  if (v.needsResolve) {
    return officialIsPrimary ? kRankPrimary : kRankSecondary;
  }
  if (kStableMp4Sources.contains(v.source)) return kRankStableMp4;
  // 直出线：与官方线互为镜像
  return officialIsPrimary ? kRankSecondary : kRankPrimary;
}

/// 整条线路的等级：取该线路里最好的一条。
///
/// 一条线路内部等级可能不一致（橘汁某些源既有直链又有站内路径），
/// 只要有一条能一步播，这条线路就不该被当成「需二次解析」下沉。
int lineRankOfAll(
  List<DramaVideo> list, {
  LinePreference pref = LinePreference.officialFirst,
}) {
  var best = kRankDead;
  for (final v in list) {
    final r = lineRankOf(v, pref: pref);
    if (r < best) best = r;
    if (best == kRankStableMp4) break;
  }
  return best;
}

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

/// 源名排序。
///
/// [policy] 决定两种完全不同的排序语义（见 [LineOrderPolicy]）：
///   - [LineOrderPolicy.sourceOrder]：接口顺序即官方推荐顺序，原样保留，
///     只把「整条不可播」的线路稳定地挪到末尾。橘汁实测 12 条线里
///     自建蓝光/自建4K 排最前、QQ 垫底，重排只会把差的顶上来。
///   - [LineOrderPolicy.byPreference]：按 [pref] 把官方线/直出线分档，
///     同档再按原始下标，避免 Dart 的 sort 不稳定造成面板抖动。
List<String> sortedSourceNames(
  Map<String, List<DramaVideo>> m, {
  LinePreference pref = LinePreference.officialFirst,
  LineOrderPolicy policy = kDefaultLineOrderPolicy,
}) {
  final names = m.keys.toList();

  if (policy == LineOrderPolicy.sourceOrder) {
    // 稳定分区，不做 sort：可播的保持接口相对顺序，不可播的整段沉底。
    // 用 lineRankOfAll 而不是只看首条 —— 一条线路里可能混着死条目，
    // 但只要有任意一条能换址，这条线路就不该被判死。
    final alive = <String>[];
    final dead = <String>[];
    for (final k in names) {
      (lineRankOfAll(m[k] ?? const [], pref: pref) == kRankDead
              ? dead
              : alive)
          .add(k);
    }
    return [...alive, ...dead];
  }

  final order = <String, int>{
    for (var i = 0; i < names.length; i++) names[i]: i,
  };
  final rank = <String, int>{
    for (final k in names) k: lineRankOfAll(m[k] ?? const [], pref: pref),
  };
  names.sort((a, b) {
    final c = (rank[a] ?? kRankDead).compareTo(rank[b] ?? kRankDead);
    if (c != 0) return c;
    return (order[a] ?? 0).compareTo(order[b] ?? 0);
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
/// 现在的优先级（默认官方优先）：
///   1. 稳定 MP4 源（可下载、token 不过期）——橘汁专有
///   2. 官方线（1080P/4K，已接游客会话，实测 100% 可播）
///   3. 直出线路（拿来就是 m3u8，一步进播放器，但常卡）
///   4. 全部不可播才退回集数最多（至少让用户有东西点）
///
/// [pref] 为 [LinePreference.directFirst] 时把 2、3 两档对调。
/// [policy] 为 [LineOrderPolicy.sourceOrder] 时不分档，直接取接口顺序里
/// 第一条可播线路（橘汁就是自建蓝光），只把整条不可播的沉底。
///
/// 同等级内比「分集粒度更细」（条目多 → 能对上更多集），
/// 再比接口原始顺序：kanju 一部剧 14~28 条线路条目数**完全相等**，
/// 只按条目数比较时排序恒等，Dart 的 sort 又不稳定，
/// 默认项就会在不同次打开之间跳动。
String pickDefaultSource(
  Map<String, List<DramaVideo>> m, {
  LinePreference pref = LinePreference.officialFirst,
  LineOrderPolicy policy = kDefaultLineOrderPolicy,
}) {
  final entries = m.entries.where((e) => e.value.isNotEmpty).toList();
  if (entries.isEmpty) return m.isEmpty ? '' : m.keys.first;

  if (policy == LineOrderPolicy.sourceOrder) {
    // 接口已经排好序，别再自作聪明按「是不是直出 MP4」重排。
    // 只保留一条硬规则：整条不可播的（独家短剧那种数字令牌）不能当默认。
    for (final k in sortedSourceNames(m, pref: pref, policy: policy)) {
      if (lineRankOfAll(m[k] ?? const [], pref: pref) != kRankDead) return k;
    }
    return m.keys.first; // 全军覆没时也给用户一个能点的
  }

  // 原始顺序表：同等级同条目数时用它兜底，避免 sort 不稳定带来的抖动
  final order = <String, int>{
    for (var i = 0; i < entries.length; i++) entries[i].key: i,
  };

  var best = entries.first;
  for (final e in entries.skip(1)) {
    final rb = lineRankOfAll(best.value, pref: pref);
    final re = lineRankOfAll(e.value, pref: pref);
    if (re != rb) {
      if (re < rb) best = e;
      continue;
    }
    if (e.value.length != best.value.length) {
      if (e.value.length > best.value.length) best = e;
      continue;
    }
    if ((order[e.key] ?? 0) < (order[best.key] ?? 0)) best = e;
  }
  return best.key;
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
///
/// 输出顺序按线路等级排（受 [pref] 影响：官方优先时官方线在前）。
/// kanju 一部剧有 14~28 条线路，「自动换源」只会取第一个候选，
/// 若顺序按接口原始序，很可能连续几条都落在同一类线路上，
/// 用户点一次换源、失败、再点、再失败，而旁边 20 多条线一次都没试到。
List<DramaVideo> switchCandidates(
  Map<String, List<DramaVideo>> sources,
  DramaVideo cur, {
  Set<String> tried = const {},
  LinePreference pref = LinePreference.officialFirst,
  LineOrderPolicy policy = kDefaultLineOrderPolicy,
}) {
  final curSrc = sourceKeyOf(cur);
  final out = <DramaVideo>[];
  final seen = <String>{};

  // 按该源声明的策略排序后再遍历，保证输出天然「好的在前」
  final ordered = sortedSourceNames(sources, pref: pref, policy: policy);

  for (final name in ordered) {
    final list = sources[name] ?? const <DramaVideo>[];
    if (name == curSrc) continue;
    if (tried.contains(name)) continue;
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