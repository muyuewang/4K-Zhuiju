/// 设计 token：字号 / 圆角 / 间距
///
/// 为什么需要这一层：
/// 之前全项目散落着 **15 种字号**（9 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 /
/// 13 / 13.5 / 14 / 15 / 16 / 17 / 19 / 24）和 **11 种圆角**（2 / 3 / 6 / 7 /
/// 8 / 8.5 / 9 / 10 / 12 / 14 / 18）。单个页面看都说得过去，整体没有节奏——
/// 12.5 和 13.5 这种半像素值，说明是「看着差一点就加 0.5」调出来的，
/// 不是从一套阶梯里选的。UI/UX 规范把 Random font sizes 明确列为反模式。
///
/// 收敛原则：**只取现有高频值**，不发明新数值。
/// 这样归一是「把杂音并到最近的档」，观感收紧但不换样，老用户不会觉得
/// 换了个 App。
///
/// 命名按**角色**而不是按大小（caption/body/title 而不是 small/medium/large）：
/// 按大小命名时，改一次阶梯就要全局改名；按角色命名，阶梯值可以随时调，
/// 调用处语义不变。
library;

import 'package:flutter/widgets.dart';

/// 字号阶梯（7 级）
///
/// 移动端正文下限取 13：`11` 只留给角标、进度数字这类辅助信息，
/// 原先散落的 `9` / `10` / `10.5` 在手机上已低于舒适阅读下限，一并收到 11。
abstract final class Ts {
  /// 角标、进度百分比、极小辅助说明
  static const double caption = 11;

  /// 次要信息：副标题、时间戳、集数
  static const double bodySm = 12;

  /// 正文默认档
  static const double body = 13;

  /// 稍大的正文、按钮文字、列表主文案
  static const double bodyLg = 14;

  /// 卡片标题、小标题、分组标题
  static const double subtitle = 16;

  /// 页面标题、剧名（详情页手机版）
  static const double title = 19;

  /// 大标题：详情页宽屏剧名
  static const double display = 24;
}

/// 行高倍率
///
/// 不逐处手写 `height:`：中文字形本身占满 em 框，1.0 的行高会让
/// 上下两行贴在一起。正文用 1.45，标题用 1.25（大字号不需要那么松）。
abstract final class Lh {
  static const double display = 1.25;
  static const double title = 1.3;
  static const double body = 1.45;
  static const double tight = 1.15;
}

/// 圆角阶梯（5 级 + 进度条）
///
/// 按**元素体量**分配，不是按心情：越大的面用越大的圆角，
/// 视觉上才有一致的「柔软度」。原先 8 / 9 / 10 三个几乎同义却并存，
/// 8.5 更是手工微调，现在统一到 card=10。
abstract final class R {
  /// 进度条、分隔细线这类内嵌元素。
  ///
  /// 保留 2 不并入 sm：进度条高度只有 3~4dp，用 6 会显示成两头尖的
  /// 胶囊，反而失真。
  static const double bar = 2;

  /// 小标签、输入框内元素、缩略图
  static const double sm = 6;

  /// 卡片、海报、列表项（最常用）
  static const double card = 10;

  /// 面板、设置区、大卡片
  static const double panel = 14;

  /// 胶囊、chip、标签
  static const double pill = 18;

  /// 圆形按钮、头像框
  static const double round = 26;
}

/// 间距阶梯
///
/// **本文件只定义，不强制全局替换。**
/// 间距改动会直接改变布局尺寸，容易在固定高度的容器里撑出 overflow，
/// 需要逐屏目视验证。所以这一组先立标准，后续改到哪个页面就在
/// 那个页面就近迁移，避免一次性大范围动布局。
abstract final class Sp {
  /// 相邻元素最小间隙（图标与文字之间）
  static const double xs = 4;

  /// 紧凑间隙（同一组内的行距）
  static const double sm = 8;

  /// 默认间隙（卡片内边距、区块内间距）
  static const double md = 12;

  /// 区块之间的间距
  static const double lg = 16;

  /// 大区块分隔
  static const double xl = 24;

  /// 页面级留白
  static const double xxl = 32;
}

/// 动效时长
///
/// 统一成三档。之前散落着 130 / 180 / 300 / 350 / 400 / 700 / 900 / 1200 /
/// 1600 / 2200 / 6500 / 8500 共 12 种，其中 130 是「点击反馈」、6500 是
/// 弹幕飞行——量级差 50 倍，混在一个枚举里只会让人不敢改。
abstract final class Motion {
  /// 点击/悬停反馈：手指抬起时已经该结束了
  static const Duration micro = Duration(milliseconds: 130);

  /// 状态切换：展开、淡入、焦点框
  static const Duration short = Duration(milliseconds: 220);

  /// 页面级转场
  static const Duration medium = Duration(milliseconds: 320);
}

/// 按系统「减少动态效果」设置返回时长
///
/// 无障碍设置里关掉动画的人（前庭功能障碍、偏头痛、单纯不喜欢）
/// 打开 App 后照样会看到全部位移和渐变——因为 Flutter 的
/// [AnimatedContainer] 之类只管「时长」，不会自己去问系统设不设防。
/// 检测一次很便宜，收益是这类用户不会因为「点了卡片整个界面在动」
/// 而直接卸载。
///
/// 传 [Duration.zero] 时组件会瞬间跳到终态，布局不塌、状态仍正确，
/// 只是没有过渡过程——这正是「减少动效」想要的结果。
Duration motionOf(BuildContext context, Duration fallback) {
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
    return Duration.zero;
  }
  return fallback;
}