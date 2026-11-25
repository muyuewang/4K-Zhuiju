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

  /// 来源角标文案（全局搜索结果用）。非空时显示在海报右上角，
  /// 让用户分清这条结果来自哪个源。首页/分类页不传，不显示。
  final String sourceLabel;

  /// 共享元素转场用的 tag（空串 = 不做 Hero）
  ///
  /// 为什么由调用方给，而不是在这里用 `drama.id` 拼：
  /// 同一个源的同一部剧会同时出现在多个网格里（首页「推荐」与
  /// 「电视剧」两个 Tab 就经常重合，而 TabBarView 会把相邻页留在树上保活）。
  /// 同一路由树里两个 Hero 用同一个 tag，push 时会直接断言失败。
  /// 所以 tag 必须带**页面命名空间**，由知道自己是哪一页的调用方提供。
  final String heroTag;

  const DramaCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.autofocus = false,
    this.sourceLabel = '',
    this.heroTag = '',
  });

  @override
  State<DramaCard> createState() => _DramaCardState();
}

class _DramaCardState extends State<DramaCard> {
  bool _hover = false;

  /// 手指按下时的缩放反馈。
  ///
  /// 手机上点一下海报，从按压到页面推入之间通常有 100~300ms 的空白
  /// （接口慢时更久）。这段时间里如果卡片毫无变化，用户会怀疑没点上，
  /// 于是再点一次 —— 结果返回时叠了两层详情页。
  /// 缩到 0.97 是「能感觉到、又不会让整屏海报跟着抖」的临界值。
  bool _press = false;

  @override
  Widget build(BuildContext context) {
    final drama = widget.drama;
    // 只有触摸平台做按压缩放：桌面已有 hover 上浮 + 描边，再叠一个
    // 按下缩放会变成两层反馈，显得手忙脚乱。
    final plat = Theme.of(context).platform;
    final touch = !isTv(context) &&
        (plat == TargetPlatform.android || plat == TargetPlatform.iOS);

    final poster = _posterBox(context);
    // Hero 只在调用方给了 tag 时启用（见 DramaCard.heroTag 的说明）。
    final posterWithHero = widget.heroTag.isEmpty
        ? poster
        : Hero(
            tag: widget.heroTag,
            // Hero 飞行时活在 overlay 里，那里没有 Material 祖先，
            // 里面的 Text（角标、备注）会渲染成带黄下划线的调试样式。
            child: Material(
              type: MaterialType.transparency,
              child: poster,
            ),
          );

    final body = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: touch ? (_) => setState(() => _press = true) : null,
        onTapUp: touch ? (_) => setState(() => _press = false) : null,
        onTapCancel: touch ? () => setState(() => _press = false) : null,
        child: AnimatedScale(
          scale: _press ? 0.97 : 1.0,
          duration: motionOf(context, Motion.micro),
          curve: Curves.easeOut,
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
                Expanded(child: posterWithHero),
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
                    style: TextStyle(
                        fontSize: Ts.caption, color: context.palette.textDim),
                  ),
              ],
            ),
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

  /// 海报区块：圆角描边 + 角标 + 备注
  ///
  /// 抽成独立方法是为了让 [Hero] 能完整包住「描边 + 角标 + 备注」一整套，
  /// 而不是只飞一张裸图。只飞图片的话，角标和备注会在落地瞬间「啪」地
  /// 跳出来，转场反而更廉价。
  Widget _posterBox(BuildContext context) {
    final drama = widget.drama;
    return AnimatedContainer(
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
            // 右上角来源角标（全局搜索结果用）。手机卡片窄，
            // 源名可能很长（如「大师兄 · 暴风」），限宽 + 省略。
            if (widget.sourceLabel.isNotEmpty)
              Positioned(
                right: 0,
                top: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 92),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 3, 7, 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(R.card),
                      ),
                    ),
                    child: Text(
                      widget.sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: Ts.caption,
                        height: 1.1,
                        color: Colors.white,
                      ),
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

/// 海报网格骨架屏
///
/// ## 为什么不用一个转圈
///
/// 影视 App 的首屏等待通常 1~3 秒（橘汁一次列表要 1.2s 左右）。这段时间
/// 里如果屏幕上只有一个直径 32 的圆圈，用户得到的信息是「它在转」，
/// 但不知道「转完会出现什么、会不会是一堆海报」。等到内容出现时，
/// 整屏从空白跳到密排海报，视觉冲击很大，主观上会觉得「更久了」。
///
/// 骨架屏把「版式」提前画出来：位置、尺寸、列数都跟真实网格一致，
/// 数据一到就地填充，没有版式跳跃。这也是主流 App（Netflix / 爱奇艺 /
/// 豆瓣）在列表页的通用做法。
///
/// ## 为什么是整块呼吸而不是逐张 shimmer
///
/// 逐张 shimmer 需要每张卡一个 [ShaderMask] + 一个动画控制器，
/// 一屏十几张就是十几个图层在跑渐变。低端机在首屏这个关键时刻
/// （同时在建图、解 JSON、发起网络）掉帧最明显。整块透明度呼吸
/// 只需要一个控制器 + 一次 Opacity 合成，视觉上同样有「在等」的暗示。
class PosterGridSkeleton extends StatefulWidget {
  /// 占位卡片数量
  ///
  /// 18 是按桌面 6 列 × 3 行取的：手机 3 列只能放下 12 张，
  /// 多出来的部分被 GridView 懒加载，不会真的 build。
  final int count;

  final EdgeInsets padding;

  const PosterGridSkeleton({
    super.key,
    this.count = 18,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 16),
  });

  @override
  State<PosterGridSkeleton> createState() => _PosterGridSkeletonState();
}

class _PosterGridSkeletonState extends State<PosterGridSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      // 1.1 秒一个来回：再快会像故障闪烁，再慢会像卡住了。
      duration: const Duration(milliseconds: 1100),
    );
    // 系统开了「减少动态效果」就不呼吸，静态骨架同样能表达"正在加载"。
    if (!(WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
        .disableAnimations)) {
      _c.repeat(reverse: true);
    } else {
      _c.value = 0.5;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = context.palette.card;
    final tv = isTv(context);
    return ContentClamp(
      child: AnimatedBuilder(
        animation: _c,
        // child 只建一次：骨架格子的所有颜色都是常量，
        // 每帧重建 18 个 BoxDecoration 纯属浪费。
        builder: (c, child) => Opacity(
          opacity: 0.45 + 0.35 * _c.value,
          child: child,
        ),
        child: GridView.builder(
          // 骨架不可滚：此时还没有可翻的页，允许拖动只会让用户以为能刷新
          physics: const NeverScrollableScrollPhysics(),
          padding: widget.padding,
          gridDelegate: posterGridDelegate(tv: tv),
          itemCount: widget.count,
          itemBuilder: (c, i) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(R.card),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 标题行：宽度按 index 交替 70%/50%，固定宽度会排成
              // 一列完全等长的灰条，看起来像表格而不是文章。
              FractionallySizedBox(
                widthFactor: i.isEven ? 0.72 : 0.52,
                child: Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(R.bar),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态 / 错误态的大图标：淡色圆底 + 同色图标
///
/// 原来是一个 44px 的灰图标裸放在页面上。灰色圆角图标在深色底上
/// 对比度只有 3.5:1 左右，扫一眼像「一块脏东西」而不是「这里有个状态」。
/// 加一层 12% 透明度的同色圆底之后，图标有了明确的边界，
/// 空屏也从一个「洞」变成一个「卡片」——这是视觉重心的差别。
class _StateIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _StateIcon({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.12),
        ),
        child: Icon(icon, color: color, size: 36),
      );
}

/// 错误 + 重试
///
/// ## 为什么除了「重试」还要能放别的出路
///
/// 重试只对「瞬时故障」有效。当整个源站挂了（2026-11-17 橘汁主域名
/// 整站 502，CDN 回源失败），用户点一百次重试都是同一个错误——
/// 而橘汁又是默认源，开 App 第一屏就撞这里。原来的错误页只给一个
/// 「重试」，等于把「那你换个源吧」这条唯一有用的出路藏起来，
/// 让用户自己想起去「我的 → 数据源」翻。
///
/// 所以留出 [action]：调用方按自己的上下文决定给什么。
/// 列表页给「换源」（源挂了就换源，这是真正能解决问题的一步），
/// 播放页给「换个线路」，本地播放页则可能什么都不给。
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  /// 主按钮之外的额外出路（如「换源」）。与 [onRetry] 并排展示。
  final Widget? action;

  /// 补充说明：解释这次失败**可能的原因**，以及下一步该做什么。
  ///
  /// 与 [message] 分开是因为两者的读者不同：[message] 是「哪里错了」，
  /// 用户扫一眼就知道；[hint] 是「那怎么办」，只在需要多一句时才给。
  final String? hint;

  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.action,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final hasButtons = onRetry != null || action != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StateIcon(icon: Icons.cloud_off_rounded, color: SemColor.danger),
            const SizedBox(height: 14),            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.textDim, fontSize: Ts.body),
            ),
            if (hint != null) ...[
              const SizedBox(height: Sp.xs),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.palette.textDim.withValues(alpha: 0.8),
                  fontSize: Ts.bodySm,
                  height: 1.4,
                ),
              ),
            ],
            if (hasButtons) ...[
              const SizedBox(height: 16),
              // 两个按钮并排。窄屏（TV 竖屏/小手机）放不下就换行，
              // 不硬挤成一行半截字。
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Sp.sm,
                runSpacing: Sp.sm,
                children: [
                  if (onRetry != null)
                    FilledButton.tonal(
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                  if (action != null) action!,
                ],
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
              _StateIcon(icon: icon, color: kAccent),
              const SizedBox(height: Sp.lg),
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

/// 生成「海报 → 详情页」的 Hero tag
///
/// 命名空间（scope）不能省：同一部剧经常同时出现在多个网格里
/// （首页「推荐」和「电视剧」重合是常态，而 TabBarView 会把相邻页
/// 留在树上保活），同一个路由里两个 Hero 用同一个 tag 会直接断言失败。
/// scope 由知道自己是哪一页的调用方给，详情页从同一个 scope 算出
/// 同一个 tag，两边才对得上。
String posterHeroTag(String scope, String dramaId) =>
    scope.isEmpty ? '' : '$scope#$dramaId';

/// 首次出现时的淡入 + 8px 上浮
///
/// 数据从骨架屏填进来的那一刻，如果整屏 18 张海报「啪」地同时出现，
/// 观感是闪屏而不是加载完成。让每张卡各自淡入，视觉上像"依次落位"，
/// 而且成本很低（Opacity + Transform 各一次）。
///
/// 只对**第一次**出现的条目生效（由调用方判断），滚出屏幕再滚回来
/// 不会重放——那种反复淡入会让人以为列表在自动刷新。
class AppearFade extends StatelessWidget {
  final Widget child;
  const AppearFade({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Motion.short,
      curve: Curves.easeOut,
      builder: (c, t, ch) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: ch),
      ),
      child: child,
    );
  }
}

/// 分页网格
///
/// 列数不再写死：手机 3 列，宽屏自动增加到 6~10 列。
/// 写死 3 列在 1280 宽的桌面窗口里，每张海报会被拉到 400px 宽，
/// 图糊、行数少、大片留白——一眼就是「手机 App 被强行拉宽」。
class PagedGrid extends StatefulWidget {
  final Future<List<Drama>> Function(int page) loader;

  /// 点击回调。第二个参数是本卡的 Hero tag（[posterHeroTag] 生成），
  /// 调用方原样传给 DetailPage 即可；不做 Hero 时忽略。
  final void Function(Drama drama, String heroTag) onTap;

  /// Hero 命名空间。空串 = 不启用海报转场。
  final String heroScope;
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

  /// 错误页上的额外出路（如「换源」）。
  ///
  /// 做成注入而不是在这里直接依赖 `SourceRegistry`：common.dart 是纯 UI
  /// 组件库，一旦它反向依赖某个业务单例，就没法在别的场景复用（比如
  /// 详情页里的剧集列表并不想给「换源」）。调用方知道自己在什么上下文，
  /// 由它决定给什么按钮。
  final Widget? errorAction;

  /// 错误页的补充说明（如「源站可能已下线」）
  final String? errorHint;

  const PagedGrid({
    super.key,
    required this.loader,
    required this.onTap,
    this.heroScope = '',
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 16),
    this.aspect = 0.56,
    this.autoFocusFirst = false,
    this.requestDeadline = const Duration(seconds: 20),
    this.errorAction,
    this.errorHint,
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

  /// 已经播过入场动画的条目。滚出屏幕再滚回来不重放淡入。
  final _appeared = <String>{};

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
      _appeared.clear();
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
      // 骨架屏顶替转圈：版式先画出来，数据到了就地填充，不跳版。
      if (_loading) return PosterGridSkeleton(padding: widget.padding);
      if (_err != null) {
        return ErrorView(
          message: _err!,
          onRetry: _retry,
          hint: widget.errorHint,
          action: widget.errorAction,
        );
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
            final tag = posterHeroTag(widget.heroScope, d.id);
            final card = DramaCard(
              drama: d,
              heroTag: tag,
              onTap: () => widget.onTap(d, tag),
              // 只有外层明确指定时才给第一张卡初始焦点。
              // 见 PagedGrid.autoFocusFirst 的说明：多个网格同时
              // autofocus 会互相抢焦点。
              autofocus: tv && widget.autoFocusFirst && i == 0,
            );
            // 只在首次出现时播入场动画；滚回来不重放
            if (!_appeared.add(d.id)) return card;
            return AppearFade(key: ValueKey('appear-${d.id}'), child: card);
          },
        ),
      ),
    );
  }
}