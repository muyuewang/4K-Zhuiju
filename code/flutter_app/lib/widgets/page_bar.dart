/// 通用分页条：上一页 / 第 N / M 页 / 下一页 + 总数。
///
/// ## 为什么不用 `PagedGrid` 那套无限滚动
///
/// 首页分类、收藏页是「一直往下滑」，用 `PagedGrid` 合适——用户不知道
/// 总共有多少页，滚到哪算哪。但搜索结果不是：它是一个**有界集合**
/// （看剧命中 42 条 = 3 页），用户会想「我刚看的那部在第 2 页，回去翻」。
/// 无限滚动做不到「回到第 2 页」，只能从头滚。
///
/// ## 为什么不做页码输入框
///
/// 搜索结果通常 2~5 页，写个输入框成本高（键盘、校验、TV 无输入法）
/// 收益低。页数特别多的场景（几百页）在搜索里不存在：全局搜索每源
/// 只取前 20 条，单源翻页也就几页。
library;

import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../theme.dart';
import 'tv_focus.dart';

class PageBar extends StatelessWidget {
  const PageBar({
    super.key,
    required this.page,
    required this.hasPrev,
    required this.hasNext,
    required this.onPrev,
    required this.onNext,
    this.pageCount,
    this.total,
    this.tv = false,
    this.note = '',
  });

  /// 当前页，从 1 开始
  final int page;

  final bool hasPrev;
  final bool hasNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  /// 总页数。**未知时传 null**——各源都不返回总数，
  /// 只能靠「本页条数是否满页」推断还有没有下一页。
  /// 这种情况下界面显示「第 N 页」，不编造一个分母。
  final int? pageCount;

  /// 总条数，未知时传 null
  final int? total;

  /// TV 模式：控件更大，遥控器好瞄
  final bool tv;

  /// 右侧补充说明，如「该源不支持翻页，已显示全部结果」
  final String note;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pageText =
        pageCount != null ? '第 $page / $pageCount 页' : '第 $page 页';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tv ? 16 : 10,
        vertical: tv ? 10 : 7,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: Row(
        children: [
          _btn(context, '上一页', hasPrev, onPrev),
          SizedBox(width: tv ? 14 : 9),
          Text(
            pageText,
            style: TextStyle(
              fontSize: tv ? Ts.bodyLg : Ts.bodySm,
              color: p.onSurface,
              // 页码是当前定位的关键信息，tabler 数字宽度一致才不会
              // 在 9→10 这种进位时让整行左右抖动
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          SizedBox(width: tv ? 14 : 9),
          _btn(context, '下一页', hasNext, onNext),
          const Spacer(),
          if (note.isNotEmpty)
            Flexible(
              child: Text(
                note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: Ts.caption, color: p.textDim),
              ),
            )
          else if (total != null)
            Text(
              '共 $total 条',
              style: TextStyle(fontSize: Ts.caption, color: p.textDim),
            ),
        ],
      ),
    );
  }

  Widget _btn(BuildContext context, String text, bool enabled, VoidCallback tap) {
    final p = context.palette;
    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? tap : null,
      child: Container(
        height: tv ? 36 : 26,
        padding: EdgeInsets.symmetric(horizontal: tv ? 14 : 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? p.card : Colors.transparent,
          borderRadius: BorderRadius.circular(R.sm),
          border: Border.all(
            color: enabled ? Colors.transparent : p.divider,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: tv ? Ts.body : Ts.bodySm,
            // 禁用态用 textDim 的淡版：不能整块隐藏，否则左右两侧
            // 控件位置会随着可用性变化而跳动
            color: enabled ? p.onSurface : p.textDim.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
    return TvFocus(
      radius: R.sm,
      enabled: enabled,
      onActivate: tap,
      child: body,
    );
  }
}