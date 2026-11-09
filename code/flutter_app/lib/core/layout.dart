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
///
/// **TV 是另一套逻辑，不能复用上面的断点。**
/// 电视盒子常把 1080p 面板上报成 960x540（dpr=2），按宽度只会落进
/// medium，于是拿到手机字号和底部导航 —— 投到 3 米外看不清，
/// 遥控器也够不着底栏。TV 模式要独立判定，并把「目标卡片尺寸」
/// 整体放大：观看距离是沙发的距离，不是手的距离。
library;

import 'package:flutter/material.dart';

import 'tv.dart';

enum FormFactor { compact, medium, expanded }

/// 单张海报卡片的目标宽度（含间距）
const double kPosterTargetExtent = 132;

/// TV 模式下单张海报的目标宽度
///
/// 手机 132 是按「手持 30cm」定的。电视通常 2.5~4 米，按视角换算
/// 要放到 2 倍左右才有一致的清晰度；同时 TV 一屏宁可少放几列，
/// 也别让用户为了看全一行按十几次方向键。
const double kTvPosterTargetExtent = 236;

FormFactor formFactorOf(BuildContext context) =>
    formFactorOfWidth(MediaQuery.sizeOf(context).width);

FormFactor formFactorOfWidth(double w) {
  if (w < 720) return FormFactor.compact;
  if (w < 1024) return FormFactor.medium;
  return FormFactor.expanded;
}

/// 是否宽屏（桌面/平板横屏）
bool isWide(BuildContext context) =>
    formFactorOf(context) == FormFactor.expanded;

/// 是否 TV 模式（遥控器操作）
bool isTv(BuildContext context) => tvModeOn;

/// 是否常显侧边导航
///
/// TV 恒为 true：底部横条在电视上既难够着（遥控器要按到底），
/// 又浪费本来就矮的纵向空间（960x540 里 58dp 的底栏占掉一成）。
/// 左侧竖排导航用「上下」就能走完，是遥控器最省力的形态。
bool useSideNav(BuildContext context) =>
    isTv(context) || formFactorOf(context) != FormFactor.compact;

/// 自适应海报网格
///
/// 用 MaxCrossAxisExtent 而不是 FixedCrossAxisCount：后者在宽屏下会把
/// 卡片严重拉伸，前者保证每张卡片不超过 [maxExtent]，列数自动增减。
SliverGridDelegate posterGridDelegate({
  double maxExtent = kPosterTargetExtent,
  double spacing = 9,
  double mainSpacing = 14,
  double aspect = 0.56,
  bool? tv,
}) {
  // TV 下换更大的目标尺寸与间距：卡片大、留白多，焦点框才不会挤在一起
  final useTv = tv ?? false;
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: useTv ? kTvPosterTargetExtent : maxExtent,
    crossAxisSpacing: useTv ? 18 : spacing,
    mainAxisSpacing: useTv ? 24 : mainSpacing,
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