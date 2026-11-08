/// 弹幕渲染层：按视频进度从右向左滚动
///
/// 为什么不用三方库：主流弹幕库（flutter_danmaku 等）都自带一套
/// 播放器时间源抽象，接进来要额外包一层 adapter，而且它们的缓存/暂停
/// 逻辑默认按「自己的计时器」走，和 video_player 的 seek、倍速容易错位。
/// 这里直接读 controller.value.position 作为唯一时间源，几十行就能覆盖
/// 「滚动 + 轨道不重叠 + seek 重同步 + 暂停跟随」这几个真正需要的点。
///
/// 三个关键设计：
///   1. 用 Ticker 每帧驱动，但**不** setState 整个页面：只让本层重绘，
///      播放页其余部分不参与，避免弹幕把播放页拖到掉帧。
///   2. seek 检测：视频位置跳变超过 2 秒就清空在场弹幕并从新位置重新入队，
///      否则拖进度条后会在半路冒出一堆「早该出现」的弹幕。
///   3. 轨道分配：优先选「最久没被占用的轨道」，避免同一行两条弹幕重叠；
///      轨道数按可用高度算，横屏能放 6~8 行、竖屏小窗放 3~4 行。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../core/danmaku.dart';
import '../theme.dart';

/// 弹幕开关的全局状态（本地持久化，不需要账号）
///
/// 用 ValueNotifier 而不是把 bool 塞进每个播放页：用户在 A 集关掉弹幕，
/// 切到 B 集、或换源重建页面后应当仍然是关的，否则每换一集都要再关一次。
///
/// 持久化的意义在于「跨启动」：弹幕是强干扰项，关掉的人多半是一直不想看，
/// 每次开 App 都要再关一次会很烦。写入用 fire-and-forget，不阻塞 UI，
/// 读失败一律回落默认值 true（宁可见弹幕，也不要因为磁盘异常静默关掉）。
class DanmakuSettings {
  DanmakuSettings._();
  static final DanmakuSettings instance = DanmakuSettings._();

  static const String _prefsKey = 'danmaku_enabled';

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// 是否已经从磁盘读过（避免重复读，也便于判断何时该写）
  bool _restored = false;

  /// 启动时调用；不 await 也能用，读回来会自动刷新 notifier
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getBool(_prefsKey);
      if (v != null) enabled.value = v;
    } catch (e) {
      debugPrint('[DM] restore prefs failed: $e');
    }
  }

  /// 切换开关并落盘
  void toggle() {
    enabled.value = !enabled.value;
    _persist();
  }

  void _persist() {
    final v = enabled.value;
    // 这里刻意不 await：UI 立刻响应，磁盘写失败也不该让开关卡住
    SharedPreferences.getInstance()
        .then((sp) => sp.setBool(_prefsKey, v))
        .catchError((Object e) {
      debugPrint('[DM] persist prefs failed: $e');
      return false;
    });
  }
}

class DanmakuOverlay extends StatefulWidget {
  final VideoPlayerController ctrl;
  final List<DanmakuItem> items;

  /// 单条弹幕从右侧进入到完全离开左侧所需时间
  final Duration travel;

  /// 字号
  final double fontSize;

  const DanmakuOverlay({
    super.key,
    required this.ctrl,
    required this.items,
    this.travel = const Duration(milliseconds: 8500),
    this.fontSize = 15,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// 已经在场上滚动的弹幕
  final List<_Flying> _flying = <_Flying>[];

  /// 下一条待发射的下标（items 已按时间升序）
  int _next = 0;

  /// 上一帧的视频位置（秒），用于识别 seek
  double? _lastPos;

  /// 轨道占用情况：记录每条轨道上最后一条弹幕的发射时刻（毫秒）
  final List<int> _laneLastMs = <int>[];

  /// 画布尺寸，由 LayoutBuilder 更新
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay old) {
    super.didUpdateWidget(old);
    // 换源/换集后弹幕列表整体换掉，必须重置游标，否则会沿用旧下标
    if (!identical(old.items, widget.items)) {
      _reset();
      _lastPos = null;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _reset() {
    _flying.clear();
    _next = 0;
    _laneLastMs.clear();
  }

  int get _laneCount {
    // 每条弹幕占一行高度 + 行距；上下各留一点边距
    final laneH = widget.fontSize * 1.55;
    final usable = _size.height - 12;
    if (usable <= 0) return 1;
    return math.max(1, (usable / laneH).floor());
  }

  void _onTick(Duration _) {
    final v = widget.ctrl.value;
    if (!v.isInitialized || _size == Size.zero) return;

    final pos = v.position.inMilliseconds / 1000.0;

    // ---- seek 检测 ----
    final last = _lastPos;
    if (last != null && (pos - last).abs() > 2.0) {
      _reset();
      // 从新位置之后的第一条重新开始，跳过的弹幕不再补发
      _next = 0;
      while (_next < widget.items.length &&
          widget.items[_next].timeSec < pos - 0.5) {
        _next++;
      }
      _lastPos = pos;
      if (mounted) setState(() {});
      return;
    }
    _lastPos = pos;

    // 暂停时不推进，但已经在场上的弹幕也应当冻住：
    // 这里直接返回，飞行的位置按 realNow 计算会继续走，所以下面
    // 用「暂停时把基准时间往后推」的方式实现冻结。
    final paused = !v.isPlaying;

    var changed = false;

    // ---- 发射到点的弹幕 ----
    // 一次最多发 3 条，防止拖到弹幕高密度区时瞬间涌入几十条刷屏
    var spawn = 0;
    while (!paused &&
        _next < widget.items.length &&
        widget.items[_next].timeSec <= pos &&
        spawn < 3) {
      final it = widget.items[_next++];
      // 已经晚于出现时间 6 秒以上的，说明是被跳过的高峰段，丢弃不补
      if (pos - it.timeSec <= 6) {
        _launch(it);
        changed = true;
      }
      spawn++;
    }

    // ---- 推进/回收 ----
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final travelMs = widget.travel.inMilliseconds;
    final before = _flying.length;

    _flying.removeWhere((f) {
      if (paused) {
        // 暂停：把发射时刻同步往后挪，等效于冻结
        f.spawnMs += 16;
        return false;
      }
      final el = nowMs - f.spawnMs;
      return el > travelMs;
    });

    if (before != _flying.length) changed = true;
    if (paused && _flying.isNotEmpty) changed = true;

    // 有弹幕在场时才重绘，静止画面不做无谓的帧更新
    if ((changed || _flying.isNotEmpty) && mounted) setState(() {});
  }

  void _launch(DanmakuItem it) {
    final lane = _pickLane();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _flying.add(_Flying(
      item: it,
      lane: lane,
      spawnMs: nowMs,
    ));
    while (_laneLastMs.length <= lane) {
      _laneLastMs.add(0);
    }
    _laneLastMs[lane] = nowMs;
  }

  /// 选轨：优先选最久没用过的那条，弹幕少时自然均匀分布
  int _pickLane() {
    final n = _laneCount;
    while (_laneLastMs.length < n) {
      _laneLastMs.add(0);
    }
    var best = 0;
    for (var i = 1; i < n; i++) {
      if (_laneLastMs[i] < _laneLastMs[best]) best = i;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        if (size != _size) {
          // 尺寸变化（旋转/全屏切换）后轨道数变了，已发射的弹幕轨道可能越界，
          // 直接清空重来最稳，比让它们重叠错位好。
          _size = size;
          _laneLastMs.clear();
        }

        final laneH = widget.fontSize * 1.55;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final travelMs = widget.travel.inMilliseconds;

        return IgnorePointer(
          child: ClipRect(
            child: Stack(
              children: [
                for (final f in _flying) _buildOne(f, laneH, nowMs, travelMs),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildOne(_Flying f, double laneH, int nowMs, int travelMs) {
    final el = (nowMs - f.spawnMs).clamp(0, travelMs);
    final t = el / travelMs; // 0 → 刚进入右侧，1 → 完全离开左侧

    // 文本宽度先粗估（按字号 * 字符数），精确测量会让每帧都跑 TextPainter，
    // 弹幕多时是明显的性能负担；估算误差只影响起点偏移，肉眼无感。
    final textW = f.item.text.characters.length * widget.fontSize * 1.02;

    final track = _size.width + textW;
    final x = _size.width - t * track;

    return Positioned(
      left: x,
      top: 6 + f.lane * laneH,
      child: Text(
        f.item.text,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: widget.fontSize,
          color: f.item.color,
          fontWeight: FontWeight.w500,
          // 描边：浅色画面下白字会糊掉，加一层黑边保证可读
          shadows: const [
            Shadow(color: Colors.black87, blurRadius: 2, offset: Offset(0, 0)),
            Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(1, 1)),
          ],
        ),
      ),
    );
  }
}

class _Flying {
  final DanmakuItem item;
  final int lane;
  int spawnMs;

  _Flying({required this.item, required this.lane, required this.spawnMs});
}

/// 控制条上的弹幕开关按钮
class DanmakuToggleButton extends StatelessWidget {
  final double iconSize;

  const DanmakuToggleButton({super.key, this.iconSize = 22});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DanmakuSettings.instance.enabled,
      builder: (ctx, on, _) => IconButton(
        iconSize: iconSize,
        color: on ? Colors.white : Colors.white38,
        tooltip: on ? '关闭弹幕' : '开启弹幕',
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        visualDensity: VisualDensity.compact,
        icon: Icon(on ? Icons.subtitles_rounded : Icons.subtitles_off_rounded),
        onPressed: () {
          DanmakuSettings.instance.toggle();
        },
      ),
    );
  }
}

/// 弹幕为 0 条时的轻提示（只在开关打开、且确实没数据时显示一次）
class DanmakuEmptyHint extends StatelessWidget {
  const DanmakuEmptyHint({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, top: 6),
          child: Text(
            '本集暂无弹幕',
            style: TextStyle(
              fontSize: 11,
              color: kTextDim.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}