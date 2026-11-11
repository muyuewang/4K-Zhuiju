/// 榜单流视图：多分区 + 每区一行横向海报
///
/// 为什么单独做一个组件，而不是塞进 PagedGrid：
///
/// PagedGrid 的心智是「一个源、一种排序、无限往下翻」——它只有一条
/// 扁平的列表，靠页码翻页。kanju 的 `feed/home` 是完全不同的形状：
/// 服务端把内容**编排**成若干分区（大家都在看、韩剧在追、高分电影…），
/// 每个分区有标题、副标题和自己的排序逻辑，翻页的粒度是「分区」而不是
/// 「条目」（cursor 是 base64 的 `{"section_offset":N}`）。
///
/// 硬塞进 PagedGrid 的话，只能把 11 个分区拍平成一个大列表，标题行
/// 变成一种特殊卡片——那样每个分区都要占网格的一格，横向排版全乱，
/// 且「继续加载下一个分区」与「加载下一页」两套翻页逻辑会互相打结。
///
/// 所以这里按电视/流媒体首页的通行形态来做：**纵向滚分区、横向滚条目**。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart' show friendlyError;
import '../core/layout.dart';
import '../core/models.dart';
import '../core/source/data_source.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../core/tokens.dart';

class FeedView extends StatefulWidget {
  /// 拉一页分区。[cursor] 为空表示第一页。
  final Future<HomeFeed> Function(String? cursor) loader;

  final void Function(Drama) onTap;

  /// TV 下是否让第一张卡拿初始焦点（首页只在当前 Tab 开）
  final bool autoFocusFirst;

  /// 单次请求硬性期限，理由同 [PagedGrid.requestDeadline]：
  /// 底层超时是「单次」的，外面还套着重试，最坏能拖到几十秒；
  /// 界面层必须自己兜底，否则 `_loading` 永不复位就是永久转圈。
  final Duration requestDeadline;

  const FeedView({
    super.key,
    required this.loader,
    required this.onTap,
    this.autoFocusFirst = false,
    this.requestDeadline = const Duration(seconds: 20),
  });

  @override
  State<FeedView> createState() => FeedViewState();
}

class FeedViewState extends State<FeedView>
    with AutomaticKeepAliveClientMixin {
  final _sections = <FeedSection>[];

  /// 已出现过的分区 id。服务端的 cursor 是「分区偏移量」，
  /// 正常不会重复，但快照刷新后偏移可能错位，去重比看到两个
  /// 一模一样的「大家都在看」要好。
  final _seen = <String>{};

  final _scroll = ScrollController();

  String? _cursor;
  bool _loading = false;
  bool _end = false;
  String? _err;

  /// 请求代次，下拉刷新时 +1 作废旧请求（同 PagedGrid 的理由）
  int _gen = 0;

  /// 上一次加载实际新增了几个分区。
  ///
  /// 用来区分两种「拉完了但列表没变多」：
  ///   > 0：内容确实变长了，若仍装不满一屏就继续拉下一页
  ///   = 0：服务端只回了重复分区，必须停下（否则死循环）
  int _lastAdded = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      // 提前 600 加载：横向列表高度大，等到触底再请求，
      // 用户会在最后一行停留一秒多才看到新内容。
      if (_scroll.position.pixels >
          _scroll.position.maxScrollExtent - 600) {
        _load();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _end) return;
    final gen = _gen;
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      // 同 PagedGrid：界面层硬限期，避免底层重试叠加后无限转圈
      final feed = await widget.loader(_cursor).timeout(
        widget.requestDeadline,
        onTimeout: () {
          throw TimeoutException('数据源无响应');
        },
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        var added = 0;
        for (final s in feed.sections) {
          // 分区 id 可能为空（服务端异常时），那时用标题当键
          final key = s.id.isNotEmpty ? s.id : s.title;
          if (key.isNotEmpty && !_seen.add(key)) continue;
          _sections.add(s);
          added++;
        }
        _lastAdded = added;
        _cursor = feed.nextCursor;
        if (_cursor == null || _cursor!.isEmpty) _end = true;
        _loading = false;
      });
      _fillViewportIfNeeded();
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _err = e is TimeoutException
            ? '数据源 ${widget.requestDeadline.inSeconds} 秒无响应，可能已卡住。请稍后重试或切换数据源'
            : friendlyError(e);
      });
    }
  }

  /// 内容装不满一屏时自动续拉下一页。
  ///
  /// 为什么必须有这个：榜单每页只给 3 个分区，手机行高 208，
  /// 3×208 加内边距和底部状态位约 700px，而主流手机的逻辑高度
  /// 在 800px 左右 —— **首屏装得下、页面根本不能滚动**。
  /// 而翻页只挂在滚动监听上，滚不动就永远不触发，
  /// 用户看到的永远是第一页那 3 个分区 + 一个一直转的圈，
  /// 「美剧续看 / 国产新剧 / 高分电影」这些第二页内容压根出不来。
  ///
  /// 判断放在 post-frame：此时本帧已经布局完成，
  /// maxScrollExtent 才是真实值。在 setState 里读会拿到上一帧的。
  void _fillViewportIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _end || _err != null) return;
      if (_lastAdded <= 0) return; // 只回了重复分区，停了别死循环
      if (!_scroll.hasClients) return;

      // 能滚就交给滚动监听，别抢
      if (_scroll.position.maxScrollExtent > 0) return;
      _load();
    });
  }

  Future<void> refresh() async {
    _gen++;
    setState(() {
      _sections.clear();
      _seen.clear();
      _cursor = null;
      _end = false;
      _loading = false;
      _err = null;
    });
    await _load();
  }

  void _retry() {
    setState(() => _err = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_sections.isEmpty) {
      if (_loading) return const Loading();
      if (_err != null) {
        return ErrorView(message: _err!, onRetry: _retry);
      }
      return EmptyView(
        text: '榜单暂时没有内容',
        hint: '可能是源站刚更新，稍后再看看',
        icon: Icons.leaderboard_outlined,
        action: FilledButton.tonal(
          onPressed: refresh,
          child: const Text('刷新'),
        ),
      );
    }

    final tv = isTv(context);
    final rowH = tv ? 300.0 : 208.0;

    return ContentClamp(
      child: RefreshIndicator(
        onRefresh: refresh,
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(0, tv ? 10 : 6, 0, tv ? 30 : 20),
          // +1 是底部的「加载更多 / 重试 / 到底了」状态位
          itemCount: _sections.length + 1,
          itemBuilder: (c, i) {
            if (i >= _sections.length) return _footer();
            final s = _sections[i];
            return _SectionRow(
              section: s,
              height: rowH,
              onTap: widget.onTap,
              // 只有第一个分区的第一张卡拿初始焦点：多个分区都 autofocus
              // 会互相抢，遥控器一进来就不知道停哪
              autoFocusFirst: widget.autoFocusFirst && i == 0,
            );
          },
        ),
      ),
    );
  }

  Widget _footer() {
    if (_err != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: TextButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('加载失败，点击重试',
                style: TextStyle(fontSize: Ts.bodySm)),
          ),
        ),
      );
    }
    if (_end) {
      // 到底了给一句明确的话，否则用户会一直往下拽等新内容
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: Text(
            '已经到底啦',
            style: TextStyle(fontSize: Ts.bodySm, color: context.palette.textDim),
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 26),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
    );
  }
}

/// 一个分区：标题行 + 横向海报行
class _SectionRow extends StatelessWidget {
  final FeedSection section;
  final double height;
  final void Function(Drama) onTap;
  final bool autoFocusFirst;

  const _SectionRow({
    required this.section,
    required this.height,
    required this.onTap,
    this.autoFocusFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    final tv = isTv(context);
    final cardW = tv ? 190.0 : 118.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(tv ? 24 : 14, tv ? 18 : 12,
              tv ? 24 : 14, tv ? 10 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: tv ? Ts.title : Ts.subtitle,
                    fontWeight: FontWeight.w700,
                    color: context.palette.onSurface,
                  ),
                ),
              ),
              if (section.subtitle.isNotEmpty) ...[
                const SizedBox(width: 10),
                // 副标题在电视上信息量低（隔 3 米看不清），只在手机上留
                if (!tv)
                  Flexible(
                    child: Text(
                      section.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Ts.bodySm,
                        color: context.palette.textDim,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: tv ? 24 : 14),
            itemCount: section.cards.length,
            separatorBuilder: (_, __) => SizedBox(width: tv ? 16 : 10),
            itemBuilder: (c, i) {
              final d = section.cards[i];
              return SizedBox(
                width: cardW,
                child: DramaCard(
                  drama: d,
                  onTap: () => onTap(d),
                  // autofocus 只在 TV 下生效（DramaCard 内部判断）
                  autofocus: autoFocusFirst && i == 0,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 供首页判断某个源要不要走榜单视图
///
/// 单独抽出来是为了让首页只依赖一个布尔判断，不必到处写
/// `source is SectionedFeed`——将来榜单能力若下放到所有源，
/// 只改这里一处。
bool sourceHasFeed(DataSource s) => s is SectionedFeed;

/// 榜单的加载函数：把 [SectionedFeed] 包成 FeedView 要的签名
///
/// 用早退而不是三元表达式：`s is SectionedFeed ? s : null` 的静态类型
/// 会被推成 `DataSource?`，编译器不会把「已判定的交叉类型」带出来，
/// 于是 `homeFeed` 在 DataSource 上找不到。早退能让类型收窄真正生效。
Future<HomeFeed> Function(String?) feedLoaderOf(DataSource s) {
  if (s is! SectionedFeed) {
    return (_) async => const HomeFeed(sections: []);
  }
  final feed = s as SectionedFeed;
  return (cursor) => feed.homeFeed(cursor: cursor);
}