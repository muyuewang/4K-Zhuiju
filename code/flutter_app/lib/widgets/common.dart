/// 通用组件
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/layout.dart';
import '../core/models.dart';
import '../theme.dart';
import 'tv_focus.dart';
import '../core/tokens.dart';

/// 剧集卡片（竖版海报）
///
/// 桌面端加鼠标悬停反馈：指针变手型、卡片微微上浮、标题变亮。
/// 手机上永远碰不到 hover，不会有多余开销（isDesktop 判断在编译期常量外，
/// 但 MouseRegion 在触屏设备上不产生事件）。
///
/// TV 模式下外面套一层 [TvFocus]：GestureDetector 只认触摸事件，
/// 不挂焦点节点的话遥控器方向键根本停不到卡片上（详见 tv_focus.dart）。
class DramaCard extends StatefulWidget {
  final Drama drama;
  final VoidCallback onTap;

  /// TV 模式下是否为页面初始焦点
  final bool autofocus;

  const DramaCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<DramaCard> createState() => _DramaCardState();
}

class _DramaCardState extends State<DramaCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final drama = widget.drama;
    final body = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          // 尊重系统「减少动态效果」：开了这个设置的用户不该看到整屏海报
          // 跟着手指上下浮动。
          duration: motionOf(context, Motion.micro),
          curve: Curves.easeOut,
          // 上浮 3px + 轻微提亮，幅度刻意做小：整屏几十张卡同时放大
          // 会显得很吵，静止时也更费 GPU。
          transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: motionOf(context, Motion.micro),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(R.card),
                    border: Border.all(
                      color: _hover ? kAccent.withValues(alpha: 0.55) : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(R.card),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _poster(),
                        // 左上角年份角标（TV 版参考图里的「2022」那种）
                        //
                        // 只在 TV 加：手机上卡片宽度只有 100 出头，
                        // 再压一个角标会把海报主体挤得很脏；电视上卡片
                        // 236 宽，角标占比小，且 3 米外年份是筛选剧集
                        // 最常用的线索之一。
                        if (isTv(context) && drama.year > 0)
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(7, 3, 8, 4),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Colors.black87, Colors.transparent],
                                ),
                              ),
                              child: Text(
                                '${drama.year}',
                                style: const TextStyle(
                                  fontSize: Ts.bodySm,
                                  height: 1.1,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
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
                                  fontSize: Ts.caption,
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
                  fontSize: Ts.body,
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
                  style: TextStyle(fontSize: Ts.caption, color: context.palette.textDim),
                ),
            ],
          ),
        ),
      ),
    );

    // 【读屏语义】
    //
    // 原来这里什么都没有：TalkBack / VoiceOver 走到海报上只能念出画面里
    // 的 Text，也就是「兰香如故」四个字——用户不知道这是能点的，
    // 也不知道它更新到第几集。GestureDetector 虽然会自动补一个 tap 动作，
    // 但「能点」和「点了会怎样」是两回事。
    //
    // excludeSemantics 是必要的：加上 label 后再让子 Text 各自发声，
    // 读屏会念「兰香如故，按钮，兰香如故，更新至20集」——同一件事说两遍。
    // 合并成一句反而信息更全。
    final labeled = Semantics(
      button: true,
      excludeSemantics: true,
      label: drama.remark.isEmpty
          ? drama.name
          : '${drama.name}，${drama.remark}',
      child: body,
    );

    // 非 TV 模式直接返回原组件，不引入任何额外节点
    if (!isTv(context)) return labeled;
    return TvFocus(
      autofocus: widget.autofocus,
      radius: R.card,
      onActivate: widget.onTap,
      child: labeled,
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
      memCacheWidth: isTv(context) ? 640 : 480,
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
              style: TextStyle(color: context.palette.textDim, fontSize: Ts.body),
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
///
/// 空屏不是「没数据」的通知，而是一次**引导机会**。
/// 原来只有图标 + 一行灰字，用户看完只知道「没有」，然后自己找出路——
/// 绝大多数情况只能按返回键退回上一页。规范里这条写得很直接：
/// Do: Show helpful message and action / Don't: Blank empty screens。
///
/// 所以这里强制留出 [action] 位置：调用方要么给一个出路（试试别的、
/// 清掉筛选、去别处看看），要么明确说明为什么可以不给出路。
class EmptyView extends StatelessWidget {
  final String text;

  /// 补充说明：解释为什么是空的，比重复「没有」有用
  final String? hint;

  /// 出路。没有它，空屏就只是一堵墙。
  final Widget? action;

  final IconData icon;

  const EmptyView({
    super.key,
    required this.text,
    this.hint,
    this.action,
    this.icon = Icons.search_off_rounded,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: context.palette.textDim, size: 44),
              const SizedBox(height: Sp.md),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.palette.onSurface,
                  fontSize: Ts.body,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: Sp.xs),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.palette.textDim, fontSize: Ts.bodySm),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: Sp.lg),
                action!,
              ],
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

  /// TV 下是否让第一张卡自动获得焦点
  ///
  /// 不能每个网格都给自己开：首页是 TabBarView，它会同时把相邻页
  /// 留在树上（为了滑动动画）。若每个网格都 autofocus，两个页面
  /// 会争夺同一个焦点，光标可能落到用户看不见的相邻 Tab 里，
  /// 表现就是"方向键乱跳"或"按了没反应"。由外层按当前 Tab 决定。
  final bool autoFocusFirst;

  /// 单次请求的硬性期限，超过就当失败。
  ///
  /// **这是防「一个请求卡住 → 整个 App 永久转圈」的最后一道闸。**
  ///
  /// 底层各源自己也有 connectTimeout / receiveTimeout，但那是**单次**
  /// 的，且外面还套着 3 次重试：橘汁 `_post` 是 3 次 × (12s 连接 +
  /// 25s 接收) + 退避，最坏能拖到 80 秒。这段时间里 `_loading` 一直是
  /// true，用户看到的就是一个永不结束的圈；更糟的是只要有一条路径
  /// 忘了把 `_loading` 复位（例如重试链在某个分支里吞掉了异常），
  /// 这个圈就再也不会停，切到别的源也救不回来，只能杀进程。
  ///
  /// 所以这里不依赖底层的超时是否配得对：**界面层自己兜底**，
  /// 到点必然退出加载态并给出可重试的错误。
  final Duration requestDeadline;

  const PagedGrid({
    super.key,
    required this.loader,
    required this.onTap,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 16),
    this.aspect = 0.56,
    this.autoFocusFirst = false,
    this.requestDeadline = const Duration(seconds: 20),
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
  final _seen = <String>{};

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
      // 界面层硬限期：底层超时/重试再怎么叠，这里到点必须收敛。
      // 超时后抛弃这次结果（gen 已变），避免迟到响应把错误态覆盖成空白。
      final list = await widget.loader(_page).timeout(
        widget.requestDeadline,
        onTimeout: () {
          throw TimeoutException('数据源无响应');
        },
      );
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
        _err = e is TimeoutException
            ? '数据源 ${widget.requestDeadline.inSeconds} 秒无响应，可能已卡住。请稍后重试或切换数据源'
            : friendlyError(e);
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
      // 分类空屏给「刷新」：源站偶尔会短时空返回，用户干等不如自己催一下。
      // 顺带说明这不是出错——「暂无内容」容易被读成「加载失败」。
      return EmptyView(
        text: '这个分类暂时没有内容',
        hint: '可能是源站刚更新，稍后再看看',
        icon: Icons.movie_filter_outlined,
        action: FilledButton.tonal(
          onPressed: refresh,
          child: const Text('刷新'),
        ),
      );
    }
    // 宽屏把网格夹在舒适宽度内，超宽屏两侧留白比塞满更耐看
    final tv = isTv(context);
    return ContentClamp(
      child: RefreshIndicator(
        onRefresh: refresh,
        child: GridView.builder(
          controller: _scroll,
          padding: widget.padding,
          // TV 下换更大的目标宽度与间距（见 layout.dart 的说明）
          gridDelegate:
              posterGridDelegate(aspect: widget.aspect, tv: tv),
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
                      style: TextStyle(fontSize: Ts.bodySm),
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
            return DramaCard(
              drama: d,
              onTap: () => widget.onTap(d),
              // 只有外层明确指定时才给第一张卡初始焦点。
              // 见 PagedGrid.autoFocusFirst 的说明：多个网格同时
              // autofocus 会互相抢焦点。
              autofocus: tv && widget.autoFocusFirst && i == 0,
            );
          },
        ),
      ),
    );
  }
}