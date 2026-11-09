/// TV / 遥控器焦点基础设施
///
/// 手机和电视的根本差别不在屏幕大小，而在**输入设备**：
/// 手指能直接点在任意位置，遥控器只能「上下左右 + 确定 + 返回」。
/// Flutter 里 `GestureDetector` 响应的是触摸事件，它**不参与焦点系统**——
/// 也就是说，一个只用 GestureDetector 包起来的卡片，在电视上
/// 方向键根本停不上去，确认键也按不动。这是 TV 适配最容易漏的一层。
///
/// 所以能按的东西必须包一层 [TvFocus]：
///   1. 挂 `Focus` 节点，让方向键能停上来；
///   2. 把「确定」键翻译成点击（遥控器的确定键在 Flutter 里是
///      `select`，不是 `enter`，两个都要认）；
///   3. 有焦点时画一圈描边。遥控器没有指针，**看不出当前选中谁**
///      就等于没法操作，焦点高亮不是装饰而是必要信息。
///
/// 还处理了一件容易忽略的事：焦点移动后自动滚动到可见区域。
/// 电视一屏能看的内容比手机少，光标往下走到第二行以外时若不自
/// 滚动，用户会以为「下面没有内容了」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 遥控器「确定」键。不同设备上报的 key 不一样，能见到的都列上：
///   - select      : Android KEYCODE_DPAD_CENTER（电视盒子最常见）
///   - enter       : 外接键盘 / 部分盒子的 OK 键
///   - numpadEnter : 数字键盘回车
///   - gameButtonA : 游戏手柄 A 键
///   - space       : 部分遥控器映射
///
/// 不能写成 `const` 集合：LogicalKeyboardKey 重写了 == 与 hashCode，
/// 常量集合要求元素是基本相等语义，编译器会直接报错。
final Set<LogicalKeyboardKey> kActivateKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
  LogicalKeyboardKey.space,
};

/// 焦点描边宽度
const double kTvFocusBorder = 2.6;

/// 给不参与焦点系统的组件（GestureDetector / InkWell 自绘卡片）
/// 套上遥控器焦点能力：能停焦点、确认键触发、聚焦画描边。
class TvFocus extends StatefulWidget {
  final Widget child;
  final VoidCallback onActivate;

  /// 是否作为页面初始焦点（TV 首页第一张卡用）
  final bool autofocus;

  /// 关掉时直接返回 child，零开销
  final bool enabled;

  /// 描边圆角，跟随卡片形状
  final double radius;

  const TvFocus({
    super.key,
    required this.child,
    required this.onActivate,
    this.autofocus = false,
    this.enabled = true,
    this.radius = 10,
  });

  @override
  State<TvFocus> createState() => _TvFocusState();
}

class _TvFocusState extends State<TvFocus> {
  bool _focused = false;

  void _onFocusChange(bool v) {
    if (_focused != v && mounted) setState(() => _focused = v);
    if (!v) return;
    // 焦点可能落在屏幕外（列表第二屏之后），滚进来。
    // 必须等这一帧布局完成再算，否则拿到的还是旧位置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = context;
      if (!ctx.mounted) return;
      try {
        // 没有可滚动祖先时 ensureVisible 会抛，这里吞掉即可：
        // 不在可滚动容器里就不需要滚动。
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: (node, event) {
        // 只认按下，不认抬起/长按重复，避免一次按键触发两回
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (kActivateKeys.contains(event.logicalKey)) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        // 描边画在前景，不进布局：给 Container 加 border 会让内容
        // 缩进 2px，聚焦/失焦瞬间整块内容抖一下。
        foregroundDecoration: _focused
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                border: Border.all(color: kAccent, width: kTvFocusBorder),
                boxShadow: [
                  BoxShadow(
                    color: kAccent.withValues(alpha: 0.45),
                    blurRadius: 14,
                    spreadRadius: 0.5,
                  ),
                ],
              )
            : null,
        child: widget.child,
      ),
    );
  }
}

/// 只给「本身已具备焦点与点击能力」的组件加描边
///
/// Material 的 IconButton / TextButton / ListTile 已经能从焦点系统
/// 拿到确定键并转成点击，再在外面套 [TvFocus] 会导致一次按键触发
/// 两次（自己一次 + 内层一次）。这里只做聚焦态观察，不消费按键：
/// `Focus(canRequestFocus: false)` 自己不抢焦点，但子孙拿到焦点时
/// `hasFocus` 会变 true，正好用来画描边。
class TvFocusRing extends StatefulWidget {
  final Widget child;
  final double radius;

  const TvFocusRing({super.key, required this.child, this.radius = 8});

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (v) {
        if (_focused != v && mounted) setState(() => _focused = v);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        foregroundDecoration: _focused
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                border: Border.all(color: kAccent, width: kTvFocusBorder),
              )
            : null,
        child: widget.child,
      ),
    );
  }
}