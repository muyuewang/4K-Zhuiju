/// 数据源快速切换面板。
///
/// ## 为什么要做（用户 2026-11-13 明确要求）
///
/// 原先换源只能「进我的 → 设置 → 数据源」，路径深且低频入口藏在设置里。
/// 但实际使用中换源是**高频**动作：某部剧在当前源搜不到、或者某条线路
/// 挂了，用户就想立刻换个源再试一次。让他为此走三层菜单，等于逼他放弃。
///
/// 所以这里在首页顶部放一个常驻入口，点开就是分组好的源列表。
///
/// ## 与原注释的矛盾（已修正）
///
/// `profile_page._pickSource` 里原本写着「为什么不放在首页顶部做成切换
/// 按钮」的三条理由（低频 / 会丢滚动位置 / 会误触）。本轮用户实测后
/// 明确要求加，说明前两条的产品判断被真实使用场景推翻了 —— 换源确实是
/// 高频动作。误触问题改用「二次确认」以外的方式解决：面板里当前源
/// 用强调色实心标记，且**点空白处关闭**，不设默认焦点在换源项上。
///
/// 因此收口成这一份共享实现，设置页与首页顶部都复用它，避免两处
/// 各写一套导致分组逻辑分叉。
library;

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/source/data_source.dart';
import '../core/source/registry.dart';
import '../core/tokens.dart';
import '../theme.dart';
import 'tv_focus.dart';

/// 弹出数据源快速切换面板。返回被选中的源（取消则 null）。
///
/// 这里只负责「选」，不负责「切」：调用方拿到结果后自己 `select`，
/// 这样首页可以在切换后立刻刷新自己的列表，设置页也能做别的事。
Future<DataSource?> showSourceSwitcher(BuildContext context) {
  return showModalBottomSheet<DataSource>(
    context: context,
    backgroundColor: context.palette.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(R.panel)),
    ),
    builder: (sheetCtx) => const _SourceSwitcherSheet(),
  );
}

class _SourceSwitcherSheet extends StatelessWidget {
  const _SourceSwitcherSheet();

  @override
  Widget build(BuildContext context) {
    final cur = SourceRegistry.instance.now;
    final all = SourceRegistry.all;

    // 按分组归拢，组内保持注册表顺序（那已是按实测速度排好的）
    final grouped = <String, List<DataSource>>{};
    for (final s in all) {
      grouped.putIfAbsent(SourceRegistry.groupOf(s), () => []).add(s);
    }

    // 小屏 + 15 个源一定超一屏，必须可滚。上限给 0.78 屏高，
    // 让用户还能看到上方首页内容，有「这是个浮层」的空间感。
    final maxH = MediaQuery.of(context).size.height * 0.78;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, cur),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 10),
                children: [
                  for (final group in SourceRegistry.groupOrder)
                    if (grouped[group] != null) ...[
                      _groupLabel(context, group),
                      for (final s in grouped[group]!)
                        _sourceTile(context, s, identical(s, cur)),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, DataSource cur) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '切换数据源',
                  style: TextStyle(
                    fontSize: Ts.subtitle,
                    fontWeight: FontWeight.w600,
                    color: context.palette.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '当前：${cur.displayName}',
                  style: const TextStyle(fontSize: Ts.bodySm, color: kAccent),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '关闭',
            color: context.palette.textDim,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _groupLabel(BuildContext context, String name) {
    // 「需系统代理」这组要额外解释一句：用户看到 4 个源排在最后，
    // 不知道是因为「差」，会以为是排序坏了。一句话说清原因。
    final hint = name == '需系统代理' ? '源站国内直连不通，需先开代理' : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: Ts.bodySm,
              fontWeight: FontWeight.w600,
              color: context.palette.textDim,
              letterSpacing: 0.3,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                style: TextStyle(
                  fontSize: Ts.caption,
                  color: context.palette.textDim.withValues(alpha: 0.75),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sourceTile(BuildContext context, DataSource s, bool active) {
    final proxy = SourceRegistry.needsProxy(s);
    final tile = InkWell(
      onTap: () => Navigator.of(context).pop(s),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(
          children: [
            Icon(
              active ? Icons.check_circle_rounded : Icons.dns_outlined,
              size: 19,
              color: active ? kAccent : context.palette.textDim,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          s.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Ts.bodyLg,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
                            color: active
                                ? kAccent
                                : context.palette.onSurface,
                          ),
                        ),
                      ),
                      if (proxy) ...[
                        const SizedBox(width: 6),
                        _tag(context, '需代理'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: Ts.caption,
                      height: 1.35,
                      color: context.palette.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // TV 上没有触摸，必须能用遥控器选中并按 OK
    if (isTv(context)) {
      return TvFocus(
        radius: R.sm,
        onActivate: () => Navigator.of(context).pop(s),
        child: tile,
      );
    }
    return tile;
  }

  /// 小标签（「需代理」）
  Widget _tag(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: context.palette.textDim.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(R.bar),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: context.palette.textDim),
      ),
    );
  }
}