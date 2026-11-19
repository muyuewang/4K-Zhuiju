/// 搜索结果页的左侧源导航。
///
/// ## 为什么要有这一栏
///
/// 全局搜索把 19 个源的结果混在一起，用户看到 300 多条却没法回答
/// 「哪部是看剧的、量子有没有」。更要紧的是**分页**：全部页里翻页要
/// 让 19 个源同时翻到第 2 页，慢且各源分页语义不统一；锁定到单个源后，
/// 翻页只打一个接口，几百毫秒就回来。
///
/// ## 只列「有结果」的源
///
/// 超时、无响应的源点进去必然是空屏，列出来只是给用户制造一次失望。
/// 它们的信息折成底部一行小字（见 [SearchSourceRail.footNote]），
/// 用户知道「有几个源没回来」但不需要去点。
///
/// ## 排序
///
/// 「全部」恒置顶，其余按命中条数降序。每次搜索的源表现都不同，
/// 按内容量排能让「货最多」的源浮到第一屏；按注册顺序排的话，
/// 用户得先滚过一堆 3 条的源才能看见 80 条的那个。
library;

import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../theme.dart';
import 'tv_focus.dart';

/// 左栏里的一项。
class SourceRailItem {
  /// 源 id；空串代表「全部」这个伪源。
  final String id;

  /// 展示名（「全部」项传「全部」）
  final String label;

  /// 命中条数
  final int count;

  const SourceRailItem({
    required this.id,
    required this.label,
    required this.count,
  });

  /// 是否为「全部」项
  bool get isAll => id.isEmpty;
}

class SearchSourceRail extends StatelessWidget {
  const SearchSourceRail({
    super.key,
    required this.items,
    required this.selectedId,
    required this.onSelect,
    this.tv = false,
    this.footNote = '',
    this.autofocus = false,
  });

  /// 已排好序的源列表（「全部」在第一位）。
  ///
  /// 排序由调用方决定而不是这里排：页面还要用它渲染头部计数，
  /// 两处各排一次容易出现「左栏第 3 项」和「右侧第 3 个源」不一致。
  final List<SourceRailItem> items;

  /// 当前选中的源 id（空串 = 全部）
  final String selectedId;

  final ValueChanged<String> onSelect;

  final bool tv;

  /// 底部补充说明，如「3 个源无响应」。空串不渲染。
  final String footNote;

  /// TV 下是否让「全部」获得初始焦点
  final bool autofocus;

  /// 左侧信息栏宽度。
  ///
  /// 134 是实测的平衡点：手机竖屏（≥360dp）扣掉它还剩 226dp，
  /// 按 [kPosterTargetExtent] 能放 2 列海报；再宽就只剩 1 列，
  /// 搜索结果退化成大图流，一屏看不到几部片。
  /// TV 屏宽裕，加到 176 让「大师兄 · 量子」这种长名不被截断。
  static double widthFor(bool tv) => tv ? 176 : 134;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: widthFor(tv),
      decoration: BoxDecoration(
        // 用 divider 画右边线而不是 Container(border:)，避免 border 把
        // 内部可用宽度吃掉 1px 导致每行文字列宽和右侧网格对不齐
        border: Border(right: BorderSide(color: p.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.symmetric(vertical: tv ? 8 : 6),
              // 项数固定，给 itemExtent 让滚动条长度算得准，
              // 也省掉每项的高度测量
              itemExtent: tv ? 46 : 36,
              itemCount: items.length,
              itemBuilder: (c, i) => _row(context, items[i], i),
            ),
          ),
          if (footNote.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(tv ? 12 : 9, 4, 8, tv ? 10 : 8),
              child: Text(
                footNote,
                style: TextStyle(
                  fontSize: Ts.caption,
                  color: p.textDim,
                  height: Lh.body,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, SourceRailItem it, int i) {
    final active = it.id == selectedId;
    final p = context.palette;

    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: active ? null : () => onSelect(it.id),
      child: Container(
        // 选中态的左边条用 foregroundDecoration 而不是 Stack：
        // Stack 会让每行多一层绘制，且 GestureDetector 的命中区
        // 只在 child 上，竖条会变成点不到的死区。
        foregroundDecoration: active
            ? const BoxDecoration(
                border: Border(
                  left: BorderSide(color: kAccent, width: 2),
                ),
              )
            : null,
        decoration: BoxDecoration(
          color: active ? p.card : Colors.transparent,
          borderRadius: BorderRadius.circular(R.sm),
        ),
        margin: EdgeInsets.symmetric(
          horizontal: tv ? 6 : 5,
          vertical: 1,
        ),
        padding: EdgeInsets.only(
          // 选中的左边条占了 2px，内容要跟着右移，否则切换选中项时
          // 文字会左右跳一下
          left: (tv ? 10 : 8) + (active ? 2 : 0),
          right: tv ? 9 : 7,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                it.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: tv ? Ts.bodyLg : Ts.bodySm,
                  // 选中项加粗 + 主文字色；未选中用略暗的正文色，
                  // 保证「一眼看出选的是哪个」又不至于让整列花掉
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? p.onSurface : p.textDim,
                ),
              ),
            ),
            SizedBox(width: tv ? 8 : 5),
            // 条数在「全部」项上用强调色：它是用户最常用的入口，
            // 也是「一共搜到多少」的唯一数字来源
            Text(
              it.count > 0 ? '${it.count}' : '0',
              style: TextStyle(
                fontSize: Ts.caption,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active || it.isAll ? kAccent : p.textDim,
              ),
            ),
          ],
        ),
      ),
    );

    // TV 下包一层焦点框；手机端 TvFocus 本身会短路成 child，零开销
    return TvFocus(
      radius: R.sm,
      autofocus: autofocus && i == 0,
      onActivate: () {
        if (!active) onSelect(it.id);
      },
      child: body,
    );
  }
}