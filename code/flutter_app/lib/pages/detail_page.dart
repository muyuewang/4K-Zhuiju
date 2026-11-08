/// 剧集详情页：多源切换 + 剧集列表
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/models.dart';
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

  /// 已知可稳定下载完整 MP4 的源（实测 support Range，token 不失效）。
  /// 这些源优先作为默认选中项，用户点开就能直接播、直接下。
  static const _stableMp4Sources = {
    'pylg', // 自建蓝光   425MB
    'tocyyds', // 自建4K-4  1.78GB
    'qq', // QQ         722MB
  };

  /// 选默认源：优先「能直连 MP4」的稳定源 → 其次集数最多的源。
  String _pickDefaultSource(Map<String, List<DramaVideo>> m) {
    // 1. 先按稳定 MP4 源找（用 source 字段精确匹配，不靠中文名）
    for (final key in m.keys) {
      final list = m[key] ?? const <DramaVideo>[];
      if (list.isEmpty) continue;
      if (_stableMp4Sources.contains(list.first.source)) return key;
    }
    // 2. 退化：集数最多的源
    return m.keys.reduce((a, b) => m[a]!.length >= m[b]!.length ? a : b);
  }

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