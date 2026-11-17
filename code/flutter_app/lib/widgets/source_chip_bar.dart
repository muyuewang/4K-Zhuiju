/// 播放源（线路）胶囊栏
///
/// 为什么单独抽出来：线路栏曾经是「固定高度的横向 ListView」，在手机上
/// 靠手指滑动没问题，但桌面端**根本滑不动**——滚轮的 delta 是纵向的
/// （`dy`），横向 `ScrollView` 直接忽略它，又没有画 `Scrollbar`，于是
/// 用户只看得到前十几条，后面的线路既点不到、也看不出还有。
///
/// 2026-11-17 用户实机截图：看剧 26 条线路，面板只露到第 14 条，右边缘
/// 直接切断。这类"内容被裁掉且无法到达"的问题不该靠用户报 bug 才发现，
/// 所以换成 `Wrap`：多少条都摊开，一屏内自动换行，不依赖任何手势。
///
/// 顺序**原样使用** [names] 的顺序：插件侧已经按站点 `line_options[]`
/// 的原版顺序下发，这里再排一次就是「我们自己排序」，用户能看出来。
library;

import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../theme.dart';
import 'tv_focus.dart';

class SourceChipBar extends StatelessWidget {
  const SourceChipBar({
    super.key,
    required this.names,
    required this.current,
    required this.onSelect,
    this.tv = false,
  });

  /// 线路名，顺序即展示顺序（不要排序）
  final List<String> names;

  /// 当前选中的线路名
  final String? current;

  final ValueChanged<String> onSelect;

  /// TV 模式：胶囊更大，遥控器更容易瞄准
  final bool tv;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: tv ? 12 : 8,
      runSpacing: tv ? 10 : 8,
      children: [
        for (final n in names) _chip(context, n, n == current),
      ],
    );
  }

  Widget _chip(BuildContext context, String name, bool active) {
    final body = GestureDetector(
      onTap: active ? null : () => onSelect(name),
      child: Container(
        // 用 minHeight 而不是固定 height：Wrap 按子件真实尺寸排版，
        // 写死高度会让换行后的每行基线参差。
        constraints: BoxConstraints(minHeight: tv ? 46 : 32),
        padding: EdgeInsets.symmetric(
            horizontal: tv ? 20 : 13, vertical: tv ? 10 : 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? kAccent : context.palette.card,
          borderRadius: BorderRadius.circular(tv ? 23 : 16),
        ),
        child: Text(
          name,
          style: TextStyle(
            fontSize: tv ? Ts.subtitle : Ts.bodySm,
            color: active ? Colors.white : context.palette.textDim,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
    if (!tv) return body;
    return TvFocus(
      radius: 23,
      onActivate: () => onSelect(name),
      child: body,
    );
  }
}
