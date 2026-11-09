/// 主题体系
///
/// 为什么不用 `const Color kBg = ...` 那套：
/// 那三个颜色（背景/卡片/次要文字）原本是编译期常量，散布在 12 个文件、
/// 130 多处。常量没法在运行时换值，浅色模式一开就会全片失效。
/// 所以改成 [AppPalette] 主题扩展，随 ThemeData 一起切换。
///
/// 但**视频播放区不跟随主题**：不管深浅，画面四周必须是黑的。
/// 浅色下把播放器底衬成白色，画面会发灰、字幕也糊。
/// 这部分用 [kVideoBg] / [kOnVideoDim] 这组固定色，不受主题影响。
library;

import 'package:flutter/material.dart';

/// 品牌主色。深浅共用同一个橙色——它是识别度最高的元素，
/// 换色会让 App 看起来像另一个产品。
const Color kAccent = Color(0xFFFF6B3D);

/// 压在 [kAccent] 橙色底上的前景色（图标/文字）
///
/// 必须固定深色，**不能**用 palette.bg：橙色本身是亮色，
/// 浅色主题下若用 #F4F5F7 这种浅灰画上去，对比度只剩 1.3:1，
/// 图标直接糊成一片。底部导航选中态、角标数字都用它。
const Color kOnAccent = Color(0xFF0E0F13);

/// 视频区固定色（永远深色，**不随主题变**）
///
/// 播放页、进度条、弹幕层只准用这三个常量，不要用 [AppPalette]。
/// 浅色主题下把播放器底衬成白色，画面会发灰、白色字幕直接看不见。
/// 主流播放器（YouTube / VLC / 各家影视 App）都是播放区恒定深色。
const Color kVideoBg = Color(0xFF000000);
const Color kVideoCard = Color(0xFF181A21);
const Color kOnVideoDim = Color(0xFF9AA0AE);

/// 语义化色板
///
/// 字段刻意只留「一个界面真正需要区分的几种颜色」，
/// 不做成完整的设计系统：颜色越多，两套主题越容易调不一致。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  /// 页面底色
  final Color bg;

  /// 卡片 / 面板 / 输入框底色
  final Color card;

  /// 次要文字、未选中图标
  final Color textDim;

  /// 分隔线
  final Color divider;

  /// 正文主色
  final Color onSurface;

  /// 桌面端鼠标悬停时的提亮叠加色
  final Color hover;

  const AppPalette({
    required this.bg,
    required this.card,
    required this.textDim,
    required this.divider,
    required this.onSurface,
    required this.hover,
  });

  /// 深色（原有配色，一个值都没改，老用户视觉零变化）
  static const AppPalette dark = AppPalette(
    bg: Color(0xFF0E0F13),
    card: Color(0xFF181A21),
    textDim: Color(0xFF9AA0AE),
    divider: Color(0xFF23262F),
    onSurface: Color(0xFFFFFFFF),
    hover: Color(0x0DFFFFFF),
  );

  /// 浅色
  ///
  /// 底色不用纯白（#FFF）：整屏纯白在夜里看久了刺眼，
  /// 用略带灰的 #F4F5F7 打底、卡片才用纯白，靠底色差把卡片「托」出来。
  ///
  /// textDim 从 #6B7280 加深到 #5F6672：
  /// 原值压在 #F4F5F7 上只有 4.43:1，没达到 WCAG 正文下限 4.5 —
  /// 是这次加主题测试时量出来的。现在 bg 上 5.30:1、card 上 5.79:1，
  /// 小字号（11~12px 的副标题、时间戳）也能读清。
  static const AppPalette light = AppPalette(
    bg: Color(0xFFF4F5F7),
    card: Color(0xFFFFFFFF),
    textDim: Color(0xFF5F6672),
    divider: Color(0xFFE3E5EA),
    onSurface: Color(0xFF14161A),
    hover: Color(0x0F000000),
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? dark;

  @override
  AppPalette copyWith({
    Color? bg,
    Color? card,
    Color? textDim,
    Color? divider,
    Color? onSurface,
    Color? hover,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      card: card ?? this.card,
      textDim: textDim ?? this.textDim,
      divider: divider ?? this.divider,
      onSurface: onSurface ?? this.onSurface,
      hover: hover ?? this.hover,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      onSurface: Color.lerp(onSurface, other.onSurface, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
    );
  }
}

/// 取色板的快捷写法：`context.palette.card`
///
/// 用扩展而不是全局函数，是为了让调用处一眼能看出「这个颜色跟主题走」。
extension AppPaletteX on BuildContext {
  AppPalette get palette => AppPalette.of(this);
}

/// 构建指定明暗的完整主题
ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
  final dark = brightness == Brightness.dark;
  final base = dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    colorScheme: base.colorScheme.copyWith(
      brightness: brightness,
      primary: kAccent,
      secondary: kAccent,
      surface: p.card,
      onSurface: p.onSurface,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: p.onSurface,
        fontSize: 19,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: p.onSurface),
    ),
    cardColor: p.card,
    dividerColor: p.divider,
    textTheme: base.textTheme.apply(
      bodyColor: p.onSurface,
      displayColor: p.onSurface,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.card,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      hintStyle: TextStyle(color: p.textDim),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? p.card : const Color(0xFF2B2F37),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: kAccent,
      unselectedLabelColor: p.textDim,
      indicatorColor: kAccent,
      dividerColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(backgroundColor: p.card),
    listTileTheme: ListTileThemeData(iconColor: p.textDim),
    // 放最后：copyWith 里 extensions 会整体替换，
    // 前面若有别的扩展也要一起列进来。
    extensions: <ThemeExtension<dynamic>>[p],
  );
}