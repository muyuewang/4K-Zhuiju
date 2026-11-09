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

  // 浮层定位用的锚点
  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey _speedKey = GlobalKey();
  final GlobalKey _volKey = GlobalKey();
  double _popLeft = 0;
  double _popBottom = 0;

  static const double _speedPanelW = 92;
  static const double _volPanelW = 54;

  /// 换源换了 controller：收起浮层、清掉拖动残留。
  /// 不这么做的话，新 controller 会继承上一个源的「拖动中」状态，
  /// 进度条一直停在旧位置不动，直到用户再拖一次才恢复。
  @override
  void didUpdateWidget(PlayerControlBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.ctrl, widget.ctrl)) {
      _panel = null;
      _scrubbing = false;
      _scrubMs = 0;
    }
  }

  Future<void> _setSpeed(double v) async {
    await widget.ctrl.setPlaybackSpeed(v);
    // 不用 setState 记值：controller 自己 notify，下面的
    // ValueListenableBuilder 会重建；这里只需收起面板。
    if (!mounted) return;
    setState(() => _panel = null);
  }

  Future<void> _setVolume(double v) => widget.ctrl.setVolume(v);

  void _togglePanel(String p, GlobalKey anchor) {
    final open = _panel != p;
    setState(() => _panel = open ? p : null);
    if (open) _measure(anchor);
  }

  /// 把浮层贴到按钮正上方（右边缘对齐按钮右边缘，再夹在容器内）
  void _measure(GlobalKey anchor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sb = _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final bb = anchor.currentContext?.findRenderObject() as RenderBox?;
      if (sb == null || bb == null || !sb.hasSize || !bb.hasSize) return;
      final sbOrigin = sb.localToGlobal(Offset.zero);
      final bbOrigin = bb.localToGlobal(Offset.zero);
      final w = _panel == 'volume' ? _volPanelW : _speedPanelW;
      var left = bbOrigin.dx + bb.size.width - sbOrigin.dx - w;
      left = left.clamp(4.0, (sb.size.width - w - 4).clamp(4.0, double.infinity));
      final bottom = sbOrigin.dy + sb.size.height - bbOrigin.dy + 6;
      if (!mounted) return;
      setState(() {
        _popLeft = left;
        _popBottom = bottom;
      });
    });
  }

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

        return Stack(
          key: _stackKey,
          clipBehavior: Clip.none,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _progress(c, total, max, value),
                SizedBox(
                  height: 42,
                  child: _bar(v, c, shown),
                ),
              ],
            ),
            if (_panel != null)
              Positioned(
                left: _popLeft,
                bottom: _popBottom,
                child: _panel == 'speed'
                    ? _speedPanel(_speedOf(v))
                    : _volPanel(_volOf(v)),
              ),
          ],
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
      ),
      child: Slider(
        value: value,
        max: max,
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

  // ---------------- 底部一行 ----------------

  Widget _bar(VideoPlayerValue v, VideoPlayerController c, Duration shown) {
    return Row(
      children: [
        const SizedBox(width: 2),
        _iconBtn(
          icon: v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 30,
          onTap: () => v.isPlaying ? c.pause() : c.play(),
        ),
        const SizedBox(width: 6),
        Text(
          '${_dur(shown)} / ${_dur(v.duration)}',
          style: const TextStyle(
            fontSize: 13,
            color: Colors.white,
            fontWeight: FontWeight.w500,
            height: 1.1,
          ),
        ),
        const Spacer(),
        _speedBtn(_speedOf(v)),
        _volumeBtn(_volOf(v)),
        ...widget.extraActions,
        if (widget.onToggleFullscreen != null)
          _iconBtn(
            icon: widget.fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            size: 24,
            tooltip: widget.fullscreen ? '退出全屏' : '全屏',
            onTap: widget.onToggleFullscreen!,
          ),
        const SizedBox(width: 2),
      ],
    );
  }

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
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
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
    return Container(
      width: _speedPanelW,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 从高到低，和主流播放器一致
          for (final s in kSpeedOptions.reversed)
            InkWell(
              onTap: () => _setSpeed(s),
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Text(
                    '${_fmtSpeed(s)}X',
                    style: TextStyle(
                      fontSize: 13,
                      color: (s - speed).abs() < 0.01 ? kAccent : Colors.white,
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
    );
  }

  Widget _volPanel(double volume) {
    return Container(
      width: _volPanelW,
      height: 148,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            '${(volume * 100).round()}',
            style: const TextStyle(fontSize: 11, color: Colors.white70),
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
                child: Slider(value: volume, onChanged: _setVolume),
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
                style: const TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
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