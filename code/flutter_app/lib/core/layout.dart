/// 响应式断点
///
/// 桌面端不是「把手机界面拉宽」：1280 宽下三列海报每张会被拉到 400px，
/// 图糊、留白巨大；导航栏横在底部更像模拟器而不是桌面软件。
/// 所以宽屏必须换一套排布：
///
///   compact  (< 720)   手机竖屏   —— 底部导航 + 3 列
///   medium   (720~1024) 平板/小窗  —— 底部导航 + 自适应列
///   expanded (>= 1024)  桌面       —— 左侧导航栏 + 右侧内容 + 自适应列
///
/// 列数不写死，由 [posterGridDelegate] 按「单张卡片的目标宽度」反推，
/// 这样 1000 宽和 2560 宽都能保持卡片视觉尺寸一致。
library;

import 'package:flutter/material.dart';

enum FormFactor { compact, medium, expanded }

/// 单张海报卡片的目标宽度（含间距）
const double kPosterTargetExtent = 132;

FormFactor formFactorOf(BuildContext context) =>
    formFactorOfWidth(MediaQuery.sizeOf(context).width);

FormFactor formFactorOfWidth(double w) {
  if (w < 720) return FormFactor.compact;
  if (w < 1024) return FormFactor.medium;
  return FormFactor.expanded;
}

bool isWide(BuildContext context) =>
    formFactorOf(context) == FormFactor.expanded;

/// 桌面/平板是否常显侧边导航
bool useSideNav(BuildContext context) =>
    formFactorOf(context) != FormFactor.compact;

/// 自适应海报网格
///
/// 用 MaxCrossAxisExtent 而不是 FixedCrossAxisCount：后者在宽屏下会把
/// 卡片严重拉伸，前者保证每张卡片不超过 [maxExtent]，列数自动增减。
SliverGridDelegate posterGridDelegate({
  double maxExtent = kPosterTargetExtent,
  double spacing = 9,
  double mainSpacing = 14,
  double aspect = 0.56,
}) {
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: maxExtent,
    crossAxisSpacing: spacing,
    mainAxisSpacing: mainSpacing,
    childAspectRatio: aspect,
  );
}

/// 内容区最大宽度
///
/// 超宽屏（2560/3440）下一行摆十几张海报反而难扫读，把内容夹在一个
/// 舒适宽度内居中，两侧留白比塞满更耐看。null 表示不限制。
double? contentMaxWidth(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w <= 1600) return null;
  return 1560;
}

/// 把内容居中并限制最大宽度
class ContentClamp extends StatelessWidget {
  final Widget child;
  const ContentClamp({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final maxW = contentMaxWidth(context);
    if (maxW == null) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: child,
      ),
    );
  }
}