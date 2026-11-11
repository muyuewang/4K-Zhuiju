/// 剧集详情页：多源切换 + 剧集列表
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/favorites.dart';
import '../core/history.dart';
import '../core/layout.dart';
import '../core/models.dart';
import '../core/playback_prefs.dart';
import '../core/source/data_source.dart';
import '../core/source/registry.dart';
import '../core/source_picker.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/tv_focus.dart';
import 'player_page.dart';
import '../core/tokens.dart';

class DetailPage extends StatefulWidget {
  final String dramaId;
  final String? title;

  /// 本剧所属数据源。
  ///
  /// 为什么必须由调用方传：收藏/历史可能横跨两个源，用户切了源之后
  /// 再去点一条旧收藏，若按「当前源」去查必然 404（id 体系完全不同）。
  /// 传空串表示「不知道来源」，此时退回当前源 —— 这也是升级前老数据
  /// 的路径（老收藏没有 sourceId 字段）。
  final String sourceId;

  /// 从「最近观看」进来时带上上次看到的信息，加载完成后自动
  /// 定位到该集并直接起播，不用用户再点一次。
  final int resumeEpisode;
  final String resumeSource;
  final int resumeSec;

  const DetailPage({
    super.key,
    required this.dramaId,
    this.title,
    this.sourceId = '',
    this.resumeEpisode = 0,
    this.resumeSource = '',
    this.resumeSec = 0,
  });

  /// 是否有续播意图
  bool get wantsResume => resumeEpisode > 0;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  DramaDetail? _detail;
  String? _err;
  bool _loading = true;

  /// 本剧所属的数据源。取一次之后固定下来：
  /// 详情页加载过程中用户在别处切了源，这一页也应该继续用打开时那个源，
  /// 否则会拿 A 源的 id 去 B 源查，直接 404。
  late final DataSource _src =
      SourceRegistry.instance.byId(widget.sourceId);

  /// 当前选中的源显示名
  String? _curSource;

  /// 本剧的观看记录（没有就是 null）。
  ///
  /// 主流影视 App 的详情页都靠它做两件事，缺一件用户就得自己找：
  ///   1. 主按钮从「播放」变成「继续观看 第N集 12:34」；
  ///   2. 剧集网格里把正在看的那一集高亮出来。
  /// 没有账号体系，这个记录就是本机的 HistoryStore。
  WatchRecord? _record;

  /// 简介是否已展开（默认 3 行截断，主流 App 都有「展开」）
  bool _introExpanded = false;

  /// 剧集是否倒序显示。40 集以上的剧，最新一集在末尾，
  /// 每次进来都要滚到底，主流 App 都提供「倒序」切换。
  bool _epDesc = false;

  @override
  void initState() {
    super.initState();
    // 先读本地记录：网络详情回来之前就能知道「上次看到哪一集」，
    // 主按钮不必先显示成「播放」再跳成「继续观看」。
    _readRecord();
    _load();
  }

  /// 从本机历史里取本剧的记录（没有则为 null）
  void _readRecord() {
    final id = widget.dramaId;
    for (final r in HistoryStore.instance.records.value) {
      if (r.dramaId == id) {
        if (mounted) setState(() => _record = r);
        return;
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final d = await _src.detail(widget.dramaId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        final m = d.sourcesByCn;
        if (m.isNotEmpty) {
          // 续播时优先停在用户上次看的那条源上。
          // 否则详情页高亮的是「默认源」、播放器播的是另一条源，
          // 选集面板里的集数对不上，用户会以为集数丢了。
          final rs = widget.resumeSource;
          _curSource = (rs.isNotEmpty && m.containsKey(rs))
              ? rs
              : _pickDefaultSource(m);
        }
      });
      // 从「最近观看」进来的：自动定位到那一集并起播
      if (widget.wantsResume) {
        _autoResume(d);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = friendlyError(e);
      });
    }
  }

  /// 自动续播：在已选源里找到记录的那一集，直接进播放页并跳到上次位置。
  ///
  /// 找不到就什么都不做，安静退回普通详情页 —— 源站删集、改名都会让
  /// 记录对不上，这时候强行起播只会播错集，比不播更糟。
  void _autoResume(DramaDetail d) {
    final m = d.sourcesByCn;
    if (m.isEmpty) return;

    List<DramaVideo>? list = m[_curSource];
    list ??= m[_pickDefaultSource(m)];
    if (list == null || list.isEmpty) return;

    DramaVideo? target;
    // 先按集数精确匹配
    for (final e in list) {
      if (e.episode == widget.resumeEpisode) {
        target = e;
        break;
      }
    }
    // 集数对不上（有些源 episode 一直是 0）就退回按标识匹配
    if (target == null && widget.resumeSource.isNotEmpty) {
      for (final v in m.values) {
        for (final e in v) {
          if (e.episode == widget.resumeEpisode && e.path.isNotEmpty) {
            target = e;
            break;
          }
        }
        if (target != null) break;
      }
    }
    if (target == null) {
      debugPrint('[DETAIL] resume miss: ep=${widget.resumeEpisode}');
      return;
    }

    _play(target, startAtSec: widget.resumeSec);
  }

  /// 从剧集列表里挑默认源。
  ///
  /// 用本剧所属数据源声明的策略（橘汁按接口顺序、kanju 按用户偏好），
  /// 不能读 SourceRegistry.now —— 从历史记录跨源打开时那是另一个源。
  /// 判定细节见 core/source_picker.dart（有单测覆盖）。
  String _pickDefaultSource(Map<String, List<DramaVideo>> m) =>
      pickDefaultSource(
        m,
        pref: PlaybackPrefs.instance.linePref.value,
        policy: _src.lineOrderPolicy,
      );

  /// 记录对应的那一集（在当前源里找；找不到返回 null）
  DramaVideo? _resumeTarget(List<DramaVideo> eps) {
    final r = _record;
    if (r == null || eps.isEmpty) return null;
    for (final e in eps) {
      if (e.episode == r.episode) return e;
    }
    // 有些源 episode 恒为 0，退回按集名匹配
    if (r.epLabel.isNotEmpty) {
      for (final e in eps) {
        if (e.epLabel == r.epLabel) return e;
      }
    }
    return null;
  }

  /// 正在看的那一集的集数 key（用于网格高亮），没有记录时返回 -1
  int get _watchingEpisode => _record?.episode ?? 0;

  /// 主按钮该播哪一集、从第几秒开始
  void _playPrimary(List<DramaVideo> eps) {
    if (eps.isEmpty) return;
    final t = _resumeTarget(eps);
    if (t != null) {
      _play(t, startAtSec: _record?.positionSec ?? 0);
      return;
    }
    _play(eps.first);
  }

  void _play(DramaVideo v, {int startAtSec = 0}) async {
    // 收集所有源里同一集的其他候选（用于播放失败时换源）
    final alts = <DramaVideo>[];
    final d = _detail;
    if (d != null) {
      for (final list in d.sourcesByCn.values) {
        for (final e in list) {
          if (e.epLabel == v.epLabel && e.path != v.path) alts.add(e);
        }
      }
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        video: v,
        dramaName: d?.name ?? '',
        cover: d?.cover.best ?? '',
        // 观看历史用剧集 id 做唯一键，否则同名剧会互相覆盖
        dramaId: d?.id ?? widget.dramaId,
        sourceId: d?.sourceId ?? widget.sourceId,
        alternates: alts,
        // 全屏选集 / 按源名换源 / 自动连播都需要完整的「源 → 集」映射。
        // 只传 alternates（同集候选）是不够的：那样不知道该集后面还有没有
        // 下一集，也无法在播放器里列出别的源的剧集。
        sources: d?.sourcesByCn ?? const {},
        startAtSec: startAtSec,
      ),
    ));
    // 从播放页回来必须重读一次记录，否则「继续观看」按钮和剧集高亮
    // 还停在上次进详情页时的进度，用户刚看完第 3 集回来却看到第 1 集
    // 被高亮，会以为进度没保存。
    if (!mounted) return;
    setState(() => _record = null);
    _readRecord();
  }

  @override
  Widget build(BuildContext context) {
    // 加载中 / 失败这两种状态原来直接返回一个裸的 Loading / ErrorView，
    // 没有 AppBar 也就没有返回按钮：用户在弱网下点进来、看到「连接失败」
    // 之后，除了按系统返回键没有任何出路，看起来就像卡死在白屏里。
    // 这里始终保留一条返回栏。
    if (_loading || _err != null) {
      return Scaffold(
        backgroundColor: context.palette.bg,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            widget.title ?? '详情',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: Ts.subtitle),
          ),
        ),
        body: _loading
            ? const Loading()
            : ErrorView(message: _err!, onRetry: _load),
      );
    }
    return Scaffold(body: _buildBody());
  }

  Widget _buildBody() {
    final d = _detail!;
    final sources = d.sourcesByCn;
    // 按「本剧所属数据源」声明的策略排序：
    //   - 橘汁：接口顺序就是官方推荐（自建线在前、QQ 垫底），原样保留；
    //   - kanju：按用户偏好把官方线/直出线分档。
    // 与 pickDefaultSource 用同一个 policy，面板高亮和默认选中才对得上。
    final sourceNames = sortedSourceNames(
      sources,
      pref: PlaybackPrefs.instance.linePref.value,
      policy: _src.lineOrderPolicy,
    );
    final cur = _curSource ?? (sourceNames.isNotEmpty ? sourceNames.first : null);
    final eps = cur == null ? <DramaVideo>[] : (sources[cur] ?? []);

    // 宽屏：左封面右信息，剧集列表在右栏下方，一屏能看到更多集数。
    // 手机：保持原来的「大图头部 + 信息 + 剧集」单列纵向流。
    // TV 一律走宽屏：电视的分辨率常被上报成 960x540，落进 compact 也不奇怪；
    // 而且单列布局封面要占满屏，遥控器得往下按很久才见得到剧集，
    // 每换一集都要重走一遍，完全不可用。
    if (isTv(context) || isWide(context)) {
      return _wideBody(d, sourceNames, sources, cur, eps);
    }

    return CustomScrollView(
      slivers: [
        // 头部：封面 + 信息
        SliverAppBar(
          expandedHeight: 260,
          pinned: true,
          backgroundColor: context.palette.bg,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            if (sourceNames.isNotEmpty || eps.isNotEmpty)
              _favButton(d),
            const SizedBox(width: 4),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: _header(d),
          ),
        ),
        SliverToBoxAdapter(child: _info(d)),
        // 主操作区：继续观看 / 播放。主流影视 App 在简介下面必有一条
        // 醒目的主按钮，用户不必去剧集网格里找「我该点哪一集」。
        if (eps.isNotEmpty)
          SliverToBoxAdapter(child: _primaryActions(eps)),
        // 源选择
        if (sourceNames.isNotEmpty)
          SliverToBoxAdapter(child: _sourceSelector(sourceNames, sources, cur)),
        // 剧集区标题（带集数与正序/倒序切换）
        SliverToBoxAdapter(child: _episodeHeader(eps)),
        // 剧集网格
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 2.1,
            ),
            delegate: SliverChildBuilderDelegate(
              (c, i) => _episodeChip(_ordered(eps)[i]),
              childCount: eps.length,
            ),
          ),
        ),
      ],
    );
  }

  /// 按当前排序返回剧集列表（倒序时第 1 集在最后）
  List<DramaVideo> _ordered(List<DramaVideo> eps) =>
      _epDesc ? eps.reversed.toList() : eps;

  /// 收藏按钮（详情页右上角）
  ///
  /// 用 ValueListenableBuilder 订阅收藏列表：在别处取消了收藏再回到
  /// 这一页，图标要是同步的，否则会出现「显示已收藏但点一下变成已收藏」
  /// 这种点不动第二次的状态错乱。
  Widget _favButton(DramaDetail d) {
    return ValueListenableBuilder<List<FavoriteItem>>(
      valueListenable: FavoriteStore.instance.items,
      builder: (c, list, _) {
        final on = list.any((e) => e.dramaId == d.id);
        final btn = IconButton(
          tooltip: on ? '取消收藏' : '收藏',
          icon: Icon(
            on ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            color: on ? kAccent : null,
          ),
          onPressed: () {
            final now = FavoriteStore.instance.toggle(
              dramaId: d.id,
              name: d.name.isEmpty ? (widget.title ?? '') : d.name,
              cover: d.cover.best,
              year: d.year,
              area: d.area,
              remark: d.remark,
              // 记住条目来自哪个源：换源后再点这条收藏，仍能正确打开
              sourceId: d.sourceId.isNotEmpty
                  ? d.sourceId
                  : SourceRegistry.instance.now.id,
            );
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(now ? '已加入我的收藏' : '已取消收藏',
                  style: const TextStyle(fontSize: Ts.body)),
              duration: const Duration(seconds: 2),
            ));
          },
        );
        // TV 下补焦点描边，否则遥控器移到右上角看不出选中了谁
        return isTv(context) ? TvFocusRing(radius: 22, child: btn) : btn;
      },
    );
  }

  /// 剧集区标题 + 倒序开关
  ///
  /// 长剧（40 集以上）最新一集在最末尾，每次进来都要滚很久。
  /// 主流 App 都提供「倒序」，这里补上；集数少时不必显示，省得干扰。
  Widget _episodeHeader(List<DramaVideo> eps) {
    final tv = isTv(context);
    final showSort = eps.length > 12;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 0),
      child: Row(
        children: [
          Text(
            eps.length > 1 ? '选集' : '播放',
            style: TextStyle(
              fontSize: tv ? Ts.subtitle : Ts.bodyLg,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '共 ${eps.length} ${eps.length > 1 ? '集' : '条线路'}',
            style: TextStyle(
              fontSize: tv ? Ts.body : Ts.bodySm,
              color: context.palette.textDim,
            ),
          ),
          const Spacer(),
          if (showSort)
            TvFocusRing(
              radius: 16,
              child: TextButton.icon(
                onPressed: () => setState(() => _epDesc = !_epDesc),
                style: TextButton.styleFrom(
                  minimumSize: Size(0, tv ? 40 : 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: context.palette.textDim,
                ),
                icon: Icon(
                  _epDesc
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  size: tv ? 18 : 15,
                ),
                label: Text(
                  _epDesc ? '倒序' : '正序',
                  style: TextStyle(fontSize: tv ? Ts.bodyLg : Ts.bodySm),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 主操作区：一个大播放按钮 + 上次看到哪一集的提示
  Widget _primaryActions(List<DramaVideo> eps) {
    final tv = isTv(context);
    final t = _resumeTarget(eps);
    final r = _record;
    // 只有「确实看过一部分」才叫继续观看；刚点开就退出（<10 秒）
    // 不算，否则用户会一直看到「继续观看 00:03」这种没意义的文案。
    final resumable = t != null && r != null && r.positionSec >= 10;

    final label = resumable
        ? '继续观看 · ${t.epLabel} ${_mmss(r.positionSec)}'
        : (eps.length > 1 ? '播放第 1 集' : '立即播放');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: tv ? 52 : 44,
              child: TvFocusRing(
                radius: 10,
                child: FilledButton.icon(
                  onPressed: () => _playPrimary(eps),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(R.card),
                    ),
                  ),
                  icon: Icon(Icons.play_arrow_rounded, size: tv ? 28 : 22),
                  label: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: tv ? Ts.subtitle : Ts.bodyLg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 秒 → mm:ss / h:mm:ss
  String _mmss(int sec) {
    if (sec <= 0) return '00:00';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 宽屏双栏
  ///
  /// 左栏固定 260 宽的封面（海报是 2:3，260x390 刚好一屏可见），
  /// 右栏放可滚动的内容：标题信息 → 播放源 → 剧集网格。
  /// 剧集网格用自适应列数，窗口越宽一行摆越多集，避免宽屏下四列
  /// 把每个集数按钮拉成一条长条。
  Widget _wideBody(
    DramaDetail d,
    List<String> sourceNames,
    Map<String, List<DramaVideo>> sources,
    String? cur,
    List<DramaVideo> eps,
  ) {
    return ContentClamp(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左栏：返回 + 封面
          SizedBox(
            width: 292,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 6, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '返回',
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            size: 18),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 2),
                      Text('详情',
                          style: TextStyle(
                              fontSize: Ts.bodyLg, color: context.palette.textDim)),
                      const Spacer(),
                      // 宽屏没有 AppBar，收藏按钮挂在标题行右端
                      _favButton(d),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(R.panel),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: d.cover.best.isEmpty
                          ? Container(
                              color: context.palette.card,
                              child: Center(
                                child: Icon(Icons.movie_outlined,
                                    color: context.palette.textDim, size: 40),
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: d.cover.best,
                              fit: BoxFit.cover,
                              memCacheWidth: 520,
                              errorWidget: (_, __, ___) =>
                                  Container(color: context.palette.card),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 右栏：信息 + 源 + 剧集
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 46, 20, 0),
                    child: _infoWide(d),
                  ),
                ),
                // 主操作区：继续观看 / 播放
                if (eps.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _primaryActions(eps),
                    ),
                  ),
                if (sourceNames.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _sourceSelector(sourceNames, sources, cur),
                    ),
                  ),
                // 剧集标题 + 正序/倒序
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _episodeHeader(eps),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 20, 24),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 82,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.9,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (c, i) => _episodeChip(_ordered(eps)[i]),
                      childCount: eps.length,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 宽屏信息区：比手机版字号略大、摘要不限 3 行
  Widget _infoWide(DramaDetail d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          d.name.isEmpty ? (widget.title ?? '') : d.name,
          style: const TextStyle(fontSize: Ts.display, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (d.year > 0) _tag('${d.year}'),
            if (d.area.isNotEmpty) _tag(d.area),
            if (d.remark.isNotEmpty) _tag(d.remark, highlight: true),
            if (d.hits > 0) _tag('${_fmtHits(d.hits)}热度'),
            _tag('${d.sourcesByCn.length} 个播放源'),
          ],
        ),
        if (d.director.isNotEmpty) ...[
          const SizedBox(height: 12),
          _kv(context, '导演', d.director),
        ],
        if (d.actor.isNotEmpty) ...[
          const SizedBox(height: 5),
          _kv(context, '主演', d.actor),
        ],
        if (d.brief.isNotEmpty || d.intro.isNotEmpty) ...[
          const SizedBox(height: 12),
          _introText(
            d.intro.isNotEmpty ? d.intro : d.brief,
            fontSize: Ts.body,
            lines: 4,
          ),
        ],
      ],
    );
  }

  Widget _header(DramaDetail d) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (d.cover.best.isNotEmpty)
          CachedNetworkImage(
            imageUrl: d.cover.best,
            fit: BoxFit.cover,
            // 头部只有 260 高，按原图解码会白白吃掉十几 MB
            memCacheWidth: 720,
            errorWidget: (_, __, ___) => Container(color: context.palette.card),
          ),
        // 顶部/底部渐变
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent, context.palette.bg],
              stops: const [0, 0.45, 1],
            ),
          ),
        ),
      ],
    );
  }

  Widget _info(DramaDetail d) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            d.name.isEmpty ? (widget.title ?? '') : d.name,
            style: const TextStyle(fontSize: Ts.title, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (d.year > 0) _tag('${d.year}'),
              if (d.area.isNotEmpty) _tag(d.area),
              if (d.remark.isNotEmpty) _tag(d.remark, highlight: true),
              if (d.hits > 0) _tag('${_fmtHits(d.hits)}热度'),
            ],
          ),
          if (d.director.isNotEmpty) ...[
            const SizedBox(height: 8),
            _kv(context, '导演', d.director),
          ],
          if (d.actor.isNotEmpty) ...[
            const SizedBox(height: 4),
            _kv(context, '主演', d.actor),
          ],
          if (d.brief.isNotEmpty || d.intro.isNotEmpty) ...[
            const SizedBox(height: 8),
            _introText(
              d.intro.isNotEmpty ? d.intro : d.brief,
              fontSize: Ts.body,
              lines: 3,
            ),
          ],
        ],
      ),
    );
  }

  /// 简介：默认截断 + 「展开」
  ///
  /// 原来固定 maxLines: 3 + ellipsis，长简介（很多剧的介绍是整段剧情梗概）
  /// 永远只能看到前三行，用户没有任何办法读完——主流 App 都有展开按钮。
  Widget _introText(String text, {required double fontSize, required int lines}) {
    final style = TextStyle(
      fontSize: fontSize,
      height: 1.55,
      color: context.palette.textDim,
    );
    return LayoutBuilder(
      builder: (ctx, cons) {
        // 先量一下这段文字在给定宽度下到底要几行。
        // 只有真的超出行数上限才显示「展开」，否则短简介底下挂一个
        // 点了没反应的「展开」会显得很怪。
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: lines,
          textDirection: Directionality.of(ctx),
        )..layout(maxWidth: cons.maxWidth);
        final overflows = tp.didExceedMaxLines;
        // 资源要及时释放，这个 LayoutBuilder 每次重建都会量一次
        tp.dispose();

        final body = Text(
          text,
          maxLines: _introExpanded ? null : lines,
          overflow: _introExpanded ? null : TextOverflow.ellipsis,
          style: style,
        );
        if (!overflows && !_introExpanded) return body;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            body,
            GestureDetector(
              onTap: () => setState(() => _introExpanded = !_introExpanded),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _introExpanded ? '收起' : '展开',
                      style: const TextStyle(fontSize: Ts.bodySm, color: kAccent),
                    ),
                    Icon(
                      _introExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: kAccent,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _tag(String s, {bool highlight = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: highlight ? kAccent.withValues(alpha: 0.16) : context.palette.card,
          borderRadius: BorderRadius.circular(R.sm),
        ),
        child: Text(
          s,
          style: TextStyle(
            fontSize: Ts.caption,
            color: highlight ? kAccent : context.palette.textDim,
          ),
        ),
      );

  Widget _kv(BuildContext context, String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$k  ', style: TextStyle(fontSize: Ts.bodySm, color: context.palette.textDim)),
          Expanded(
            child: Text(
              v,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              // 原来写死 Colors.white70：浅色主题下压在浅底上等于白字白底，
              // 导演/主演这两行会直接消失。改用主题正文色。
              style: TextStyle(fontSize: Ts.bodySm, color: context.palette.onSurface),
            ),
          ),
        ],
      );

  String _fmtHits(int h) {
    if (h >= 100000000) return '${(h / 100000000).toStringAsFixed(1)}亿';
    if (h >= 10000) return '${(h / 10000).toStringAsFixed(1)}万';
    return '$h';
  }

  Widget _sourceSelector(
      List<String> names, Map<String, List<DramaVideo>> map, String? cur) {
    final tv = isTv(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('播放源',
                  style: TextStyle(
                      fontSize: tv ? Ts.subtitle : Ts.bodyLg,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('${names.length} 个可用',
                  style: TextStyle(
                      fontSize: tv ? Ts.body : Ts.caption,
                      color: context.palette.textDim)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            // TV 下把可选源做成更高的胶囊，遥控器左右移动时更好瞄准
            height: tv ? 46 : 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: names.length,
              separatorBuilder: (_, __) => SizedBox(width: tv ? 12 : 8),
              itemBuilder: (c, i) {
                final n = names[i];
                final active = n == cur;
                final chip = GestureDetector(
                  onTap: () => setState(() => _curSource = n),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: tv ? 20 : 13),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? kAccent : context.palette.card,
                      borderRadius: BorderRadius.circular(tv ? 23 : 17),
                    ),
                    child: Text(
                      n,
                      style: TextStyle(
                        fontSize: tv ? Ts.subtitle : Ts.bodySm,
                        color: active ? Colors.white : context.palette.textDim,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
                if (!tv) return chip;
                return TvFocus(
                  radius: tv ? 23 : 17,
                  onActivate: () => setState(() => _curSource = n),
                  child: chip,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeChip(DramaVideo v) {
    final tv = isTv(context);
    // 正在观看的那一集：主色描边 + 淡橙底 + 播放小角标。
    // 之前所有集长得一模一样，用户从详情页回来根本认不出自己看到哪了，
    // 只能靠回想（40 集的剧这基本不可能）。
    final watching = v.episode > 0 && v.episode == _watchingEpisode;
    final body = GestureDetector(
      onTap: () => _play(v),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: watching
              ? kAccent.withValues(alpha: 0.16)
              : context.palette.card,
          borderRadius: BorderRadius.circular(R.card),
          border: watching
              ? Border.all(color: kAccent.withValues(alpha: 0.75), width: 1.2)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              v.epLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // TV 下放大集数文字：3 米外 12pt 基本读不出来
              style: TextStyle(
                fontSize: tv ? Ts.subtitle : Ts.bodySm,
                fontWeight: watching ? FontWeight.w700 : FontWeight.w500,
                color: watching ? kAccent : context.palette.onSurface,
              ),
            ),
            if (watching)
              Text(
                '看到 ${_mmss(_record?.positionSec ?? 0)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: tv ? Ts.caption : Ts.caption, color: kAccent),
              )
            else if (v.isVip)
              Text('VIP',
                  style: TextStyle(fontSize: tv ? Ts.caption : Ts.caption, color: kAccent)),
          ],
        ),
      ),
    );

    if (!tv) return body;
    return TvFocus(
      radius: 8,
      onActivate: () => _play(v),
      child: body,
    );
  }
}