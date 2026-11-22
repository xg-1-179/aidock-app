import 'package:flutter/material.dart';

/// 一套配色。深色 / 浅色各一份，运行时整体切换。
class AidockPalette {
  const AidockPalette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.line,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.accentDeep,
    required this.accentSoft,
    required this.ok,
    required this.warn,
    required this.danger,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color line;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color accentDeep;
  final Color accentSoft;
  final Color ok;
  final Color warn;
  final Color danger;
}

/// 深色（默认）：近黑夜色画布，蓝色强调。
const AidockPalette kAidockDark = AidockPalette(
  bg: Color(0xFF0B0F14),
  surface: Color(0xFF141A21),
  surfaceAlt: Color(0xFF1B232C),
  line: Color(0xFF232C36),
  text: Color(0xFFE7EDF3),
  textDim: Color(0xFF8A96A3),
  accent: Color(0xFF4DA3FF),
  // 自己的气泡底色：比 accent 深一档，白字才够对比度（4.9:1）。
  accentDeep: Color(0xFF2B6FD0),
  accentSoft: Color(0x1F4DA3FF),
  ok: Color(0xFF35D07F),
  warn: Color(0xFFFFB74D),
  danger: Color(0xFFFF6B6B),
);

/// 浅色：白底、浅灰分层、更深的蓝保证对比度。强调色与状态色都压深一档，
/// 因为浅底上原来的亮蓝/亮绿对比度不够。
const AidockPalette kAidockLight = AidockPalette(
  bg: Color(0xFFF6F7F9),
  surface: Color(0xFFFFFFFF),
  surfaceAlt: Color(0xFFEEF1F5),
  line: Color(0xFFDCE2EA),
  text: Color(0xFF141A21),
  textDim: Color(0xFF5C6773),
  accent: Color(0xFF1F6FE0),
  accentDeep: Color(0xFF1B5FC4),
  accentSoft: Color(0x1A1F6FE0),
  ok: Color(0xFF17864F),
  warn: Color(0xFF9A6200),
  danger: Color(0xFFC42B2B),
);

/// 全局配色表。字段是**可变静态量**，切换主题时整体替换，UI 立即跟着变。
///
/// 原先这里是 `static const`，所有引用点都带 `const`，没法运行时切换；
/// 现在改成 getter 读 `palette`，引用处一律不能再加 `const`（已全量清理）。
class AidockColors {
  static AidockPalette palette = kAidockDark;

  static bool get isLight => identical(palette, kAidockLight);

  static void apply(bool light) {
    palette = light ? kAidockLight : kAidockDark;
  }

  static Color get bg => palette.bg;
  static Color get surface => palette.surface;
  static Color get surfaceAlt => palette.surfaceAlt;
  static Color get line => palette.line;
  static Color get text => palette.text;
  static Color get textDim => palette.textDim;
  static Color get accent => palette.accent;
  static Color get accentDeep => palette.accentDeep;
  static Color get accentSoft => palette.accentSoft;
  static Color get ok => palette.ok;
  static Color get warn => palette.warn;
  static Color get danger => palette.danger;

  /// 强调色底上的前景：深色主题用近黑（亮蓝底），浅色主题用白（深蓝底）。
  static Color get onAccent =>
      isLight ? const Color(0xFFFFFFFF) : const Color(0xFF06121F);
}

ThemeData buildTheme({bool light = false}) {
  final base = light
      ? ThemeData.light(useMaterial3: true)
      : ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AidockColors.bg,
    colorScheme: base.colorScheme.copyWith(
      brightness: light ? Brightness.light : Brightness.dark,
      primary: AidockColors.accent,
      surface: AidockColors.surface,
      error: AidockColors.danger,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AidockColors.bg,
      foregroundColor: AidockColors.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AidockColors.text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AidockColors.surfaceAlt,
      contentTextStyle: TextStyle(color: AidockColors.text),
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
        borderSide: BorderSide(color: AidockColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AidockColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AidockColors.accent, width: 1.4),
      ),
      hintStyle: TextStyle(color: AidockColors.textDim),
    ),
  );
}
