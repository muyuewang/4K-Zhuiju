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
        // 固定高度：Wrap 同一行里各胶囊高度一致，换行后每行基线才齐。
        // （原来用 minHeight + alignment，见下方 _widthNote 的坑）
        height: tv ? 46 : 30,
        padding: EdgeInsets.symmetric(horizontal: tv ? 20 : 13),
        decoration: BoxDecoration(
          color: active ? kAccent : context.palette.card,
          borderRadius: BorderRadius.circular(tv ? 23 : 15),
        ),
        // **关键**：这里必须是 `Center(widthFactor: 1)`，不能给 Container 加
        // `alignment`。
        //
        // `Container(alignment: x)` 内部会包一个 `Align`。`Align` 在宽度
        // 有界（Wrap 给子件的 maxWidth 是整行）且没设 widthFactor 时，会
        // 撑满整行宽度。结果就是每个胶囊都是一整行长条，一行只能放一个，
        // 14 条线路铺成 14 行、上下留白几十像素——2026-11-18 用户截图
        // 报的"线路太占地方"就是这个。
        //
        // widthFactor: 1 = 宽度收缩到文字宽度（高度由外层 height 定死）。
        child: Center(
          widthFactor: 1,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: tv ? Ts.subtitle : Ts.bodySm,
              color: active ? Colors.white : context.palette.textDim,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
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
