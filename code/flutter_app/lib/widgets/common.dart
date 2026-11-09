/// 通用组件
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
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
                  // 原来写死白色系：浅色主题下标题压在浅底上直接消失。
                  // 改成主题正文色；「悬停变亮」在浅色下表现为变实
                  // （0.92 → 1.0），方向对但不会白到看不见。
                  color: _hover
                      ? context.palette.onSurface
                      : context.palette.onSurface.withValues(alpha: 0.92),
                ),
              ),
              if (drama.displaySub.isNotEmpty)
                Text(
                  drama.displaySub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: context.palette.textDim),
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
        color: context.palette.card,
        child: Center(
          child: Icon(Icons.movie_outlined, color: context.palette.textDim, size: 26),
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
            Icon(Icons.cloud_off_rounded, color: context.palette.textDim, size: 44),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.textDim, fontSize: 13),
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
              Icon(Icons.search_off_rounded, color: context.palette.textDim, size: 44),
              const SizedBox(height: 12),
              Text(text,
                  style: TextStyle(color: context.palette.textDim, fontSize: 13)),
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
  /// 每页条数。必须和 API 的默认 pageSize 一致，
  /// 判断「最后一页」靠的就是「返回条数不足一页」。
  /// 之前这里写死 20，接口一改分页大小就会把中间页误判成末页。
  static const int kPageSize = 20;

  final _items = <Drama>[];

  /// 已出现过的剧集 id。接口翻页偶尔会重复吐同一部剧，
  /// 不去的重复卡片：同一张海报在一屏里出现两次，看着像 bug。
  final _seen = <int>{};

  final _scroll = ScrollController();
  int _page = 1;
  bool _loading = false;
  bool _end = false;
  String? _err;

  /// 请求代次。下拉刷新时 +1，让还在飞的旧请求作废。
  ///
  /// 没有它会出这种错：滚到第 3 页时下拉刷新，刷新把列表清空、页码重置
  /// 为 1，而第 3 页的响应随后回来，把第 3 页的内容填进刚清空的列表里，
  /// 页码又被它 +1 成 2 —— 列表里是第 3 页的数据，下一页却去要第 2 页。
  int _gen = 0;

  /// TabBarView 默认不保活：从「电影」切到「电视剧」再切回来，
  /// 整个 State 会被销毁重建，滚动位置丢失、接口重新请求一遍。
  /// 分类页的数据几乎不变，保活收益远大于内存占用。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
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
    final gen = _gen;
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final list = await widget.loader(_page);
      if (!mounted || gen != _gen) return;
      setState(() {
        if (list.length < kPageSize) _end = true;
        for (final d in list) {
          if (_seen.add(d.id)) _items.add(d);
        }
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        // 之前直接 e.toString()，界面上会显示一长串
        // "DioException [connection error]: ..."，普通用户看不懂。
        _err = friendlyError(e);
      });
    }
  }

  Future<void> refresh() async {
    // 作废旧请求，否则它的响应会把刷新结果覆盖掉
    _gen++;
    setState(() {
      _items.clear();
      _seen.clear();
      _page = 1;
      _end = false;
      _loading = false;
      _err = null;
    });
    await _load();
  }

  /// 加载失败后的重试：只重试这一页，不清已有内容
  void _retry() {
    setState(() => _err = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 要求必须调用，否则保活不生效
    super.build(context);
    if (_items.isEmpty) {
      if (_loading) return const Loading();
      if (_err != null) {
        return ErrorView(message: _err!, onRetry: _retry);
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
              // 这一格是「翻页状态」本身，三种情况必须分开画：
              //   _err  → 显示失败原因 + 重试入口
              //   其它   → 转圈
              // 之前不管成功失败都只画转圈，翻页一失败底部就永远转下去，
              // 用户以为还在加载，其实请求早就结束了。
              if (_err != null) {
                return Center(
                  child: TextButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text(
                      '加载失败，点击重试',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                );
              }
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