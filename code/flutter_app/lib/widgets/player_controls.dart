/// 播放器控制条：进度、倍速、音量、全屏
///
/// 抽成公共组件的原因：在线播放页（player_page）和本地播放页
/// （local_player_page）需要完全一致的这组控件。之前两份各写一套，
/// 一改就得改两处、还容易不一致。
///
/// 版式参照主流影视播放器（爱奇艺/腾讯视频横屏样式）：
///   进度条 ————————————————————
///   ▶  00:12 / 02:07:47        倍速 🔊 ⛶
///
/// 设计要点：
///   1. 内部只订阅 controller 这一个 ValueNotifier，父页面不需要为
///      播放进度重建——视频播放时每秒 30~60 次回调，整页重建会明显掉帧。
///   2. 倍速是「贴着按钮向上弹出的竖排菜单」，音量是「竖排滑杆」，
///      都浮在画面上方而不是从底部挤出一条横条：横屏全屏时底部空间
///      很宝贵，横向面板会把画面顶上去、甚至溢出。
///   3. 弹出位置靠 GlobalKey 实测按钮坐标算出，不写死偏移量：
///      横屏/竖屏、有无 extraActions 时按钮位置都不同，写死一定会错位。
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import '../core/tokens.dart';

/// 常用倍速档位（面板里按从高到低排，和主流 App 一致）
const List<double> kSpeedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

class PlayerControlBar extends StatefulWidget {
  final VideoPlayerController ctrl;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;

  /// 右侧额外插槽（比如本地播放页的「从头播」）
  final List<Widget> extraActions;

  const PlayerControlBar({
    super.key,
    required this.ctrl,
    this.fullscreen = false,
    this.onToggleFullscreen,
    this.extraActions = const [],
  });

  @override
  State<PlayerControlBar> createState() => _PlayerControlBarState();
}

class _PlayerControlBarState extends State<PlayerControlBar> {
  /// 倍速和音量**不存本地副本**，每次 build 都从 controller 的
  /// [VideoPlayerValue] 现读。原因有两条，都是实测踩出来的：
  ///
  ///   1. 换源后 Widget 在树里的位置和类型都没变，Flutter 会复用同一个
  ///      State，`initState` 根本不会重跑。本地副本于是停在上一个源的
  ///      倍速/音量上，按钮显示和实际播放对不上。
  ///   2. 键盘快捷键（↑↓ 调音量、M 静音）在 player_page 里直接改
  ///      controller，压根不经过这个组件，本地副本同样不会更新。
  ///
  /// controller 本身是 ValueNotifier，setVolume / setPlaybackSpeed 都会
  /// notifyListeners，下面的 ValueListenableBuilder 自动就刷新了。

  /// 当前展开的浮层：null / 'speed' / 'volume'
  String? _panel;

  /// 拖动进度条时先只更新本地值，松手才 seek。
  /// 直接在 onChanged 里 seek 会让拖动过程中疯狂起 seek 请求，
  /// 低端机上表现为手指还没松开画面就在乱跳。
  bool _scrubbing = false;
  double _scrubMs = 0;

  /// 浮层挂在 Overlay 上而不是控制条自己的 Stack 里。
  ///
  /// 这是必须的，不是洁癖：浮层要向上弹出 200 多像素，一定超出控制条
  /// 自身的高度。`Stack` 设 `clipBehavior: Clip.none` 只能让它「画」到
  /// 外面，**命中测试仍被父级尺寸卡死**——RenderBox.hitTest 第一步就是
  /// 判断点在不在自己的 size 里，不在就直接返回 false，子节点的
  /// onTap 永远不会被调用。表现就是面板看得见、点不动。
  /// 竖屏还多一层：控制条在 SingleChildScrollView 里，超出部分直接被裁掉。
  /// 放进 Overlay 后既不被裁剪，也天然在最上层接收点击。
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _speedKey = GlobalKey();
  final GlobalKey _volKey = GlobalKey();

  /// 浮层的屏幕坐标（Overlay 是整屏坐标系）
  double _popLeft = 0;
  double _popTop = 0;

  static const double _speedPanelW = 92;
  static const double _volPanelW = 54;
  static const double _rowH = 32;
  static const double _speedPanelH = 7 * _rowH + 8;
  static const double _volPanelH = 148;

  /// 单行控制条的高度。
  ///
  /// 原先是「进度条 + 42dp 按钮行」，连内外边距约 100dp；压成一行后
  /// 只有 40dp，压在画面上不再挡内容。下限不能低于 36：IconButton 的
  /// 点击热区再小就点不准（Material 建议 48 是理想值，这里是「看得见
  /// 画面」与「点得中」之间的折中，靠 padding 撑到实际热区）。
  static const double _barH = 40;

  /// 换源换了 controller：收起浮层、清掉拖动残留。
  /// 不这么做的话，新 controller 会继承上一个源的「拖动中」状态，
  /// 进度条一直停在旧位置不动，直到用户再拖一次才恢复。
  @override
  void didUpdateWidget(PlayerControlBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.ctrl, widget.ctrl)) {
      final wasShowing = _portal.isShowing;
      _panel = null;
      _scrubbing = false;
      _scrubMs = 0;
      // 换源时浮层必须一起收起：Overlay 条目不随 _panel 置空自动消失，
      // 否则会挂在屏幕上、还挡住底下的按钮。
      // hide() 会触发 markNeedsBuild，不能在当前这个 build 阶段直接调，
      // 挪到帧末执行。
      if (wasShowing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _panel == null && _portal.isShowing) {
            _portal.hide();
          }
        });
      }
    }
  }

  Future<void> _setSpeed(double v) async {
    await widget.ctrl.setPlaybackSpeed(v);
    // 不用 setState 记值：controller 自己 notify，下面的
    // ValueListenableBuilder 会重建；这里只需收起面板。
    if (!mounted) return;
    _closePanel();
  }

  Future<void> _setVolume(double v) => widget.ctrl.setVolume(v);

  void _closePanel() {
    setState(() => _panel = null);
    // 没 attach 过就 hide() 会断言 '_zOrderIndex != null' 崩掉
    if (_portal.isShowing) _portal.hide();
  }

  void _togglePanel(String p, GlobalKey anchor) {
    if (_panel == p) {
      _closePanel();
      return;
    }
    setState(() => _panel = p);
    // 先算坐标再显示：Overlay 首帧就得落在正确位置，
    // 否则会出现「先闪一下再跳过去」。
    _measure(anchor, p);
    _portal.show();
  }

  /// 把浮层贴到按钮正上方，右边缘对齐按钮右边缘，再夹在屏幕内
  void _measure(GlobalKey anchor, String panel) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bb = anchor.currentContext?.findRenderObject() as RenderBox?;
      if (bb == null || !bb.hasSize) return;
      final size = MediaQuery.sizeOf(context);
      final bbTopLeft = bb.localToGlobal(Offset.zero);
      final w = panel == 'volume' ? _volPanelW : _speedPanelW;
      final h = panel == 'volume' ? _volPanelH : _speedPanelH;

      var left = bbTopLeft.dx + bb.size.width - w;
      left = left.clamp(4.0, (size.width - w - 4).clamp(4.0, double.infinity));

      // 优先向上弹；上方塞不下就翻到下方，再不行就顶到屏幕顶端。
      // 横屏全屏时控制条贴着屏幕底部，向上弹一定够；
      // 竖屏非全屏时控制条偏上，向上不够就自动翻到下方。
      var top = bbTopLeft.dy - h - 6;
      if (top < 8) {
        final below = bbTopLeft.dy + bb.size.height + 6;
        top = below + h <= size.height - 8 ? below : 8;
      }

      if (!mounted) return;
      setState(() {
        _popLeft = left;
        _popTop = top;
      });
    });
  }

  // 这里不要手动 _portal.hide()：OverlayPortal 卸载时会自己移除浮层条目。
  // 而且浮层从没 show 过时 controller 尚未 attach，hide() 会直接断言
  // '_zOrderIndex != null' 崩掉——连没点过倍速按钮的用例都过不了。

  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (ctx, v, _) {
        final total = v.duration.inMilliseconds;
        final max = total == 0 ? 1.0 : total.toDouble();
        final posMs = v.position.inMilliseconds.clamp(0, total == 0 ? 1 : total);
        final value = (_scrubbing ? _scrubMs : posMs.toDouble()).clamp(0.0, max);
        final shown = _scrubbing
            ? Duration(milliseconds: _scrubMs.round())
            : v.position;

        return OverlayPortal(
          controller: _portal,
          // 点击浮层以外的任何地方都收起，避免面板一直挂在屏幕上
          overlayChildBuilder: (ctx) {
            // _panel 已置空但 hide() 还在路上的那一帧，
            // 不要渲染任何面板内容，否则会闪一下音量面板。
            if (_panel == null) return const SizedBox.shrink();
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closePanel,
                  ),
                ),
                Positioned(
                  left: _popLeft,
                  top: _popTop,
                  child: _panel == 'speed'
                      ? _speedPanel(_speedOf(v))
                      : _volPanel(_volOf(v)),
                ),
              ],
            );
          },
          // 【单行】播放/暂停 · 进度 · 时间 · 倍速 · 音量 · 全屏
          //
          // 原先是「进度条一行 + 按钮一行」，整体约 100dp。压在画面底部时
          // 等于把视频挖掉一条，用户反馈「太占地方、挡住画面」。
          // B 站是全部排在一行里，高度只有 40dp 左右，观感差别很大。
          //
          // 窄屏（手机竖屏 ~360dp）放不下这么多按钮：算下来固定部分要 240dp，
          // 进度条只剩 100dp，拖动会很难受。所以按可用宽度分级——
          // 窄屏只留「播放/暂停 · 进度 · 时间 · 全屏」，倍速和音量收进全屏，
          // B 站竖屏也是这个取舍（它的倍速只在全屏里给）。
          child: SizedBox(
            height: _barH,
            child: LayoutBuilder(
              builder: (ctx, cons) {
                final roomy = cons.maxWidth >= 400;
                return Row(
                  children: [
                    _iconBtn(
                      icon: v.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 26,
                      onTap: () => v.isPlaying ? c.pause() : c.play(),
                    ),
                    Expanded(child: _progress(c, total, max, value)),
                    // 时间放在进度条右侧（B 站的位置）：左边留给滑块起点，
                    // 手指从最左按下拖动的行程不被文字挤短。
                    Padding(
                      padding: const EdgeInsets.only(left: 6, right: 2),
                      child: Text(
                        '${_dur(shown)} / ${_dur(v.duration)}',
                        style: const TextStyle(
                          fontSize: Ts.caption,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          height: 1.1,
                        ),
                      ),
                    ),
                    if (roomy) ...[
                      _speedBtn(_speedOf(v)),
                      _volumeBtn(_volOf(v)),
                      ...widget.extraActions,
                    ],
                    if (widget.onToggleFullscreen != null)
                      _iconBtn(
                        icon: widget.fullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        size: 24,
                        tooltip: widget.fullscreen ? '退出全屏' : '全屏',
                        onTap: widget.onToggleFullscreen!,
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  // ---------------- 进度条 ----------------

  Widget _progress(
    VideoPlayerController c,
    int total,
    double max,
    double value,
  ) {
    final enabled = total > 0;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2.5,
        activeTrackColor: kAccent,
        inactiveTrackColor: Colors.white24,
        thumbColor: Colors.white,
        overlayColor: kAccent.withValues(alpha: 0.22),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: _scrubbing ? 7 : 5,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        // 把滑块压到行高中间那一小条：默认 Slider 会按 overlay 半径
        // 自动留出上下各 14dp 的空白，塞进 40dp 的单行里会顶掉轨迹、
        // 甚至撑破布局。这里只留 2dp 呼吸位，热区由外层 Expanded 保证。
        trackShape: const RectangularSliderTrackShape(),
      ),
      child: Slider(
        value: value,
        max: max,
        padding: const EdgeInsets.symmetric(vertical: 2),
        // onChangeStart 里必须同时把 _scrubbing 置位。
        // 只记 _scrubMs 的话，按下那一帧 _scrubbing 还是 false，
        // value 又回落到 v.position（旧位置），滑块会先弹回旧位置
        // 再跳到手指处，肉眼就是「点一下闪一下」。
        onChangeStart: enabled
            ? (x) => setState(() {
                  _scrubbing = true;
                  _scrubMs = x;
                })
            : null,
        onChanged: enabled
            ? (x) => setState(() => _scrubMs = x)
            : null,
        onChangeEnd: enabled
            ? (x) async {
                // 先把目标位置钉住，等 seekTo 回来再放开。
                // 顺序反了的话，松手瞬间进度条会先跳回视频的旧 position，
                // 等 seek 生效再跳过去，中间那一下很像卡了。
                setState(() => _scrubMs = x);
                await c.seekTo(Duration(milliseconds: x.round()));
                if (!mounted) return;
                setState(() => _scrubbing = false);
              }
            : null,
      ),
    );
  }

  // ---------------- 单个按钮 ----------------

  Widget _iconBtn({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    double size = 22,
  }) =>
      IconButton(
        iconSize: size,
        color: Colors.white,
        tooltip: tooltip,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        visualDensity: VisualDensity.compact,
        icon: Icon(icon),
        onPressed: onTap,
      );

  /// 从当前值里取倍速。插件在 setPlaybackSpeed 时会 copyWith 并 notify，
  /// 所以这里永远是真实生效的那个值，不会和播放内核脱节。
  double _speedOf(VideoPlayerValue v) {
    final s = v.playbackSpeed;
    return s <= 0 ? 1.0 : s;
  }

  double _volOf(VideoPlayerValue v) => v.volume.clamp(0.0, 1.0);

  Widget _speedBtn(double speed) => TextButton(
        key: _speedKey,
        onPressed: () => _togglePanel('speed', _speedKey),
        style: TextButton.styleFrom(
          minimumSize: const Size(40, 32),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          foregroundColor: (speed - 1.0).abs() < 0.01 ? Colors.white : kAccent,
        ),
        child: Text(
          (speed - 1.0).abs() < 0.01 ? '倍速' : '${_fmtSpeed(speed)}X',
          style: const TextStyle(fontSize: Ts.body, fontWeight: FontWeight.w500),
        ),
      );

  Widget _volumeBtn(double volume) => IconButton(
        key: _volKey,
        iconSize: 22,
        color: Colors.white,
        tooltip: '音量',
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        visualDensity: VisualDensity.compact,
        icon: Icon(
          volume == 0
              ? Icons.volume_off_rounded
              : (volume < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded),
        ),
        onPressed: () => _togglePanel('volume', _volKey),
      );

  // ---------------- 浮层 ----------------

  Widget _speedPanel(double speed) {
    // 浮层画在 Overlay 里，已经不在 Scaffold 之下，没有 Material 祖先。
    // InkWell / Slider 都要求祖先里有 Material，缺了会直接断言报错，
    // 所以这里自己包一层（transparent 不影响下面的黑底装饰）。
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: _speedPanelW,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(color: Colors.white24, width: 0.8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(R.card),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 从高到低，和主流播放器一致
              for (final s in kSpeedOptions.reversed)
                InkWell(
                  onTap: () => _setSpeed(s),
                  child: SizedBox(
                    height: _rowH,
                    child: Center(
                      child: Text(
                        '${_fmtSpeed(s)}X',
                        style: TextStyle(
                          fontSize: Ts.body,
                          color:
                              (s - speed).abs() < 0.01 ? kAccent : Colors.white,
                          fontWeight: (s - speed).abs() < 0.01
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _volPanel(double volume) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: _volPanelW,
        height: _volPanelH,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(color: Colors.white24, width: 0.8),
        ),
        child: Column(
          children: [
            Text(
              '${(volume * 100).round()}',
              style: const TextStyle(fontSize: Ts.caption, color: Colors.white70),
            ),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    activeTrackColor: kAccent,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    overlayColor: kAccent.withValues(alpha: 0.22),
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: volume,
                    onChanged: _setVolume,
                  ),
                ),
              ),
            ),
            Icon(
              volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 18,
              color: Colors.white70,
            ),
          ],
        ),
      ),
    );
  }

  /// 面板里的显示：1 → 1X，0.75 → 0.75X（不要 1.0X 这种别扭写法）
  String _fmtSpeed(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }

  String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// 全屏时用的「加载中/失败」占位，保证两种播放页表现一致
class PlayerPlaceholder extends StatelessWidget {
  final bool loading;
  final String? message;
  final String? hint;
  final VoidCallback? onRetry;
  final String retryLabel;

  const PlayerPlaceholder({
    super.key,
    this.loading = false,
    this.message,
    this.hint,
    this.onRetry,
    this.retryLabel = '重试',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      width: double.infinity,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else
              const Icon(Icons.videocam_off_rounded,
                  color: Colors.white38, size: 40),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(
                message ?? (loading ? '正在加载…' : '播放器未就绪'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: Ts.body),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: Ts.caption),
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}