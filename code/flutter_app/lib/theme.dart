import 'package:flutter/material.dart';

/// 深色影视风格主题
const Color kBg = Color(0xFF0E0F13);
const Color kCard = Color(0xFF181A21);
const Color kAccent = Color(0xFFFF6B3D);
const Color kTextDim = Color(0xFF9AA0AE);

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: kBg,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      secondary: kAccent,
      surface: kCard,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 19,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardColor: kCard,
    textTheme: base.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kCard,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(color: kTextDim),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kCard,
      contentTextStyle: TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: kAccent,
      unselectedLabelColor: kTextDim,
      indicatorColor: kAccent,
    ),
  );
}