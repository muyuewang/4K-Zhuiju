/// 选集区常显的「上一集 / 下一集」。
///
/// 需求（2026-11-11）：两个按钮**永远都显示**，第一集时上一集置灰、
/// 最后一集时下一集置灰，而不是把不可用的那个藏起来。
/// 位置固定，用户不用每次重新找「下一集在哪」。
///
/// 单独抽成无状态组件是为了能直接写 widget 测试：播放页依赖真实的
/// VideoPlayerController 和网络取址，整页 pump 起来既慢又脆。
library;

import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../theme.dart';

class EpisodeNavBar extends StatelessWidget {
  /// null 表示该方向没有相邻集（按钮置灰、不可点）
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const EpisodeNavBar({super.key, this.onPrev, this.onNext});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _chip(
          context,
          key: const ValueKey('episodePrev'),
          label: '上一集',
          icon: Icons.chevron_left_rounded,
          onTap: onPrev,
        ),
        const SizedBox(width: 6),
        _chip(
          context,
          key: const ValueKey('episodeNext'),
          label: '下一集',
          icon: Icons.chevron_right_rounded,
          onTap: onNext,
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context, {
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final p = context.palette;
    final enabled = onTap != null;
    final c = enabled ? kAccent : p.textDim.withValues(alpha: 0.5);
    return Material(
      key: key,
      color: enabled ? kAccent.withValues(alpha: 0.12) : p.bg,
      borderRadius: BorderRadius.circular(R.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: c),
              Text(label, style: TextStyle(fontSize: Ts.caption, color: c)),
            ],
          ),
        ),
      ),
    );
  }
}
