/// 通用组件
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/models.dart';
import '../theme.dart';

/// 剧集卡片（竖版海报）
///
/// 桌面端加鼠标悬停反馈：指针变手型、卡片微微上浮、标题变亮。
/// 手机上永远碰不到 hover，不会有多余开销（isDesktop 判断在编译期常量外，
/// 但 MouseRegion 在触屏设备上不产生事件）。
class DramaCard extends StatefulWidget {
  final Drama drama;
  final VoidCallback onTap;

  const DramaCard({super.key, required this.drama, required this.onTap});

  @override
  State<DramaCard> createState() => _DramaCardState();
}

class _DramaCardState extends State<DramaCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final drama = widget.drama;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          // 上浮 3px + 轻微提亮，幅度刻意做小：整屏几十张卡同时放大
          // 会显得很吵，静止时也更费 GPU。
          transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 130),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _hover ? kAccent.withValues(alpha: 0.55) : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.5),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _poster(),
                        // 底部渐变 + 备注
                        if (drama.remark.isNotEmpty)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(6, 12, 6, 5),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black87],
                                ),
                              ),
                              child: Text(
                                drama.remark,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                drama.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: _hover ? Colors.white : Colors.white.withValues(alpha: 0.92),
                ),
              ),
              if (drama.displaySub.isNotEmpty)
                Text(
                  drama.displaySub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: kTextDim),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _poster() {
    final url = widget.drama.cover.best;
    if (url.isEmpty) return _placeholder();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      // 按解码尺寸缓存：源站海报多为 1000px 以上的原图，
      // 网格里实际只占 220px 宽，按原图解码纯属浪费内存——
      // 一屏十几张原图足以让低端机频繁 GC 掉帧。
      memCacheWidth: 480,
      placeholder: (_, __) => _placeholder(),
      errorWidget: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        color: kCard,
        child: const Center(
          child: Icon(Icons.movie_outlined, color: kTextDim, size: 26),
        ),
      );
}

/// 加载中
class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
}

/// 错误 + 重试
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorView({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: kTextDim, size: 44),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextDim, fontSize: 13),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空状态
class EmptyView extends StatelessWidget {
  final String text;
  const EmptyView({super.key, required this.text});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_rounded, color: kTextDim, size: 44),
              const SizedBox(height: 12),
              Text(text,
                  style: const TextStyle(color: kTextDim, fontSize: 13)),
            ],
          ),
        ),
      );
}

/// 分页网格
///
/// 列数不再写死：手机 3 列，宽屏自动增加到 6~10 列。
/// 写死 3 列在 1280 宽的桌面窗口里，每张海报会被拉到 400px 宽，
/// 图糊、行数少、大片留白——一眼就是「手机 App 被强行拉宽」。
class PagedGrid extends StatefulWidget {
  final Future<List<Drama>> Function(int page) loader;
  final void Function(Drama) onTap;
  final EdgeInsets padding;
  final double aspect;

  const PagedGrid({
    super.key,
    required this.loader,
    required this.onTap,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 16),
    this.aspect = 0.56,
  });

  @override
  State<PagedGrid> createState() => PagedGridState();
}

class PagedGridState extends State<PagedGrid>
    with AutomaticKeepAliveClientMixin {
  final _items = <Drama>[];
  final _scroll = ScrollController();
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  String? _err;

  /// TabBarView 默认不保活：从「电影」切到「电视剧」再切回来，
  /// 整个 State 会被销毁重建，滚动位置丢失、接口重新请求一遍。
  /// 分类页的数据几乎不变，保活收益远大于内存占用。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >
          _scroll.position.maxScrollExtent - 400) {
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
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final list = await widget.loader(_page);
      if (!mounted) return;
      setState(() {
        if (list.isEmpty || list.length < 20) _end = true;
        _items.addAll(list);
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = e.toString();
      });
    }
  }

  Future<void> refresh() async {
    setState(() {
      _items.clear();
      _page = 1;
      _end = false;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 要求必须调用，否则保活不生效
    super.build(context);
    if (_items.isEmpty) {
      if (_loading) return const Loading();
      if (_err != null) {
        return ErrorView(message: _err!, onRetry: _load);
      }
      return const EmptyView(text: '暂无内容');
    }
    // 宽屏把网格夹在舒适宽度内，超宽屏两侧留白比塞满更耐看
    return ContentClamp(
      child: RefreshIndicator(
        onRefresh: refresh,
        child: GridView.builder(
          controller: _scroll,
          padding: widget.padding,
          gridDelegate: posterGridDelegate(aspect: widget.aspect),
          itemCount: _items.length + (_end ? 0 : 1),
          itemBuilder: (c, i) {
            if (i >= _items.length) {
              return const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final d = _items[i];
            return DramaCard(drama: d, onTap: () => widget.onTap(d));
          },
        ),
      ),
    );
  }
}