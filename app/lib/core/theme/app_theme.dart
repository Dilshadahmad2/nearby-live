import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

ThemeData buildAppTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.page,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.cyan,
      secondary: AppColors.blue,
      surface: AppColors.panel,
      error: AppColors.red,
    ),
  );
  final text = GoogleFonts.outfitTextTheme(base.textTheme).apply(
    bodyColor: AppColors.ink,
    displayColor: AppColors.ink,
  );
  return base.copyWith(
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.page,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
    ),
    cardTheme: const CardThemeData(color: AppColors.panel),
    dividerColor: AppColors.line,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.cyan : AppColors.muted),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.cyan.withValues(alpha: .35) : AppColors.line),
    ),
  );
}

/// Outfit text style shortcut used by the custom chrome.
TextStyle outfit(double size, {FontWeight weight = FontWeight.w500, Color color = Colors.white, List<Shadow>? shadows, double? height}) =>
    GoogleFonts.outfit(fontSize: size, fontWeight: weight, color: color, shadows: shadows, height: height,
            fontFeatures: const [FontFeature.tabularFigures()])
        // Outfit has no Devanagari; Hindi falls back to Noto (the Android system font).
        .copyWith(fontFamilyFallback: const ['Noto Sans Devanagari']);
