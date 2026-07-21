import 'package:flutter/material.dart';

/// Light-blue palette matching logo_square.png
class AppColors {
  static const skyDeep = Color(0xFF1A6BB5);
  static const sky = Color(0xFF3B9BEA);
  static const skySoft = Color(0xFF7EC8F5);
  static const skyPale = Color(0xFFB8E0FB);
  static const skyMist = Color(0xFFE8F6FF);
  static const ink = Color(0xFF0B2A45);
  static const inkSoft = Color(0xFF3A5F7A);
  static const card = Color(0xF2FFFFFF);
  static const accent = Color(0xFF2F8FDB);
  static const success = Color(0xFF1FA97A);
  static const danger = Color(0xFFE23D4A);
  static const warn = Color(0xFFE8A838);
}

ThemeData buildAppTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.sky,
    brightness: Brightness.light,
    primary: AppColors.accent,
    surface: AppColors.skyMist,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: AppColors.skyMist,
    fontFamily: null,
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        color: AppColors.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleMedium: TextStyle(
        color: AppColors.ink,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(color: AppColors.inkSoft, height: 1.35),
      bodySmall: TextStyle(color: AppColors.inkSoft),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        side: BorderSide(color: AppColors.sky.withValues(alpha: 0.35)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.85),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      hintStyle: TextStyle(color: AppColors.inkSoft.withValues(alpha: 0.55)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
