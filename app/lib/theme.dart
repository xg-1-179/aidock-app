import 'package:flutter/material.dart';

class AidockColors {
  static const bg = Color(0xFF0B0F14);
  static const surface = Color(0xFF141A21);
  static const surfaceAlt = Color(0xFF1B232C);
  static const line = Color(0xFF232C36);
  static const text = Color(0xFFE7EDF3);
  static const textDim = Color(0xFF8A96A3);
  static const accent = Color(0xFF4DA3FF);
  static const accentSoft = Color(0x1F4DA3FF);
  static const ok = Color(0xFF35D07F);
  static const warn = Color(0xFFFFB74D);
  static const danger = Color(0xFFFF6B6B);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AidockColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AidockColors.accent,
      surface: AidockColors.surface,
      error: AidockColors.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AidockColors.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AidockColors.text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AidockColors.text,
      displayColor: AidockColors.text,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AidockColors.surfaceAlt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AidockColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AidockColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AidockColors.accent, width: 1.4),
      ),
      hintStyle: const TextStyle(color: AidockColors.textDim),
    ),
  );
}
