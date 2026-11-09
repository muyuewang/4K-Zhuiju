/// 剧集详情页：多源切换 + 剧集列表
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/layout.dart';
import '../core/models.dart';
import '../core/source_picker.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'player_page.dart';

class DetailPage extends StatefulWidget {
  final int dramaId;
  final String? title;

  const DetailPage({super.key, required this.dramaId, this.title});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  DramaDetail? _detail;
  String? _err;
  bool _loading = true;

  /// 当前选中的源显示名
  String? _curSource;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final d = await ZhuijuApi.instance.detail(widget.dramaId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        final m = d.sourcesByCn;
        if (m.isNotEmpty) {
          _curSource = _pickDefaultSource(m);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = friendlyError(e);
      });
    }
  }

  /// 选默认源：优先稳定 MP4 源 → 可播且分集粒度细 → 可播的单条目 → 集数最多。
  /// 判定细节见 core/source_picker.dart（有单测覆盖）。
  String _pickDefaultSource(Map<String, List<DramaVideo>> m) =>
      pickDefaultSource(m);

  void _play(DramaVideo v) {
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
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        video: v,
        dramaName: d?.name ?? '',
        cover: d?.cover.best ?? '',
        // 观看历史用剧集 id 做唯一键，否则同名剧会互相覆盖
        dramaId: d?.id ?? widget.dramaId,
        alternates: alts,
        // 全屏选集 / 按源名换源 / 自动连播都需要完整的「源 → 集」映射。
        // 只传 alternates（同集候选）是不够的：那样不知道该集后面还有没有
        // 下一集，也无法在播放器里列出别的源的剧集。
        sources: d?.sourcesByCn ?? const {},
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Loading()
          : _err != null
              ? ErrorView(message: _err!, onRetry: _load)
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    final d = _detail!;
    final sources = d.sourcesByCn;
    final sourceNames = sources.keys.toList();
    final cur = _curSource ?? (sourceNames.isNotEmpty ? sourceNames.first : null);
    final eps = cur == null ? <DramaVideo>[] : (sources[cur] ?? []);

    // 宽屏：左封面右信息，剧集列表在右栏下方，一屏能看到更多集数。
    // 手机：保持原来的「大图头部 + 信息 + 剧集」单列纵向流。
    if (isWide(context)) return _wideBody(d, sourceNames, sources, cur, eps);

    return CustomScrollView(
      slivers: [
        // 头部：封面 + 信息
        SliverAppBar(
          expandedHeight: 260,
          pinned: true,
          backgroundColor: kBg,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: _header(d),
          ),
        ),
        SliverToBoxAdapter(child: _info(d)),
        // 源选择
        if (sourceNames.isNotEmpty)
          SliverToBoxAdapter(child: _sourceSelector(sourceNames, sources, cur)),
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
              (c, i) => _episodeChip(eps[i]),
              childCount: eps.length,
            ),
          ),
        ),
      ],
    );
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
                      const Text('详情',
                          style: TextStyle(
                              fontSize: 14, color: kTextDim)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: d.cover.best.isEmpty
                          ? Container(
                              color: kCard,
                              child: const Center(
                                child: Icon(Icons.movie_outlined,
                                    color: kTextDim, size: 40),
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: d.cover.best,
                              fit: BoxFit.cover,
                              memCacheWidth: 520,
                              errorWidget: (_, __, ___) =>
                                  Container(color: kCard),
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
                if (sourceNames.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _sourceSelector(sourceNames, sources, cur),
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
                      (c, i) => _episodeChip(eps[i]),
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
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
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
          _kv('导演', d.director),
        ],
        if (d.actor.isNotEmpty) ...[
          const SizedBox(height: 5),
          _kv('主演', d.actor),
        ],
        if (d.brief.isNotEmpty || d.intro.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            d.intro.isNotEmpty ? d.intro : d.brief,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              height: 1.62,
              color: kTextDim,
            ),
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
            errorWidget: (_, __, ___) => Container(color: kCard),
          ),
        // 顶部/底部渐变
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent, kBg],
              stops: [0, 0.45, 1],
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
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
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
            _kv('导演', d.director),
          ],
          if (d.actor.isNotEmpty) ...[
            const SizedBox(height: 4),
            _kv('主演', d.actor),
          ],
          if (d.brief.isNotEmpty || d.intro.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              d.intro.isNotEmpty ? d.intro : d.brief,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: kTextDim,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tag(String s, {bool highlight = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: highlight ? kAccent.withValues(alpha: 0.16) : kCard,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          s,
          style: TextStyle(
            fontSize: 11,
            color: highlight ? kAccent : kTextDim,
          ),
        ),
      );

  Widget _kv(String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$k  ', style: const TextStyle(fontSize: 12, color: kTextDim)),
          Expanded(
            child: Text(
              v,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('播放源',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('${names.length} 个可用',
                  style: const TextStyle(fontSize: 11, color: kTextDim)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: names.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (c, i) {
                final n = names[i];
                final active = n == cur;
                return GestureDetector(
                  onTap: () => setState(() => _curSource = n),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? kAccent : kCard,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: Text(
                      n,
                      style: TextStyle(
                        fontSize: 12,
                        color: active ? Colors.white : kTextDim,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeChip(DramaVideo v) {
    return GestureDetector(
      onTap: () => _play(v),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              v.epLabel,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (v.isVip)
              const Text('VIP',
                  style: TextStyle(fontSize: 9, color: kAccent)),
          ],
        ),
      ),
    );
  }
}