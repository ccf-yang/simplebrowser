import 'package:flutter/material.dart';

/// Paper / ink palette with a single signal accent.
///
/// The signal green is reserved for live state, counts and the current
/// capture; it is never used for body text.
abstract final class AppColors {
  static const Color paper = Color(0xFFF2F2EC);
  static const Color surface = Color(0xFFFBFBF7);
  static const Color card = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF0E0F0E);
  static const Color ink2 = Color(0xFF3B3E39);
  static const Color muted = Color(0xFF71756C);
  static const Color faint = Color(0xFF9A9E94);
  static const Color line = Color(0xFFE3E4DB);
  static const Color line2 = Color(0xFFD6D8CD);
  static const Color wash = Color(0xFFEDEEE6);
  static const Color signal = Color(0xFFD2F65A);
  static const Color signalInk = Color(0xFF1B2408);
  static const Color signalWash = Color(0xFFF2F9DC);
  static const Color signalLine = Color(0xFFDFECB6);
  static const Color danger = Color(0xFFD94A4A);
  static const Color warn = Color(0xFFC9912C);
  static const Color dark = Color(0xFF15161A);
  static const Color dark2 = Color(0xFF1D1F24);
  static const Color darkText = Color(0xFFC9CEC1);
  static const Color darkMuted = Color(0xFF9BA093);
  static const Color onInk = Color(0xFFF5F6F0);

  static const Color mono = ink;
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.signal,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.ink,
    onPrimary: AppColors.onInk,
    secondary: AppColors.signal,
    onSecondary: AppColors.signalInk,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    error: AppColors.danger,
    onError: Colors.white,
    outline: AppColors.line2,
    outlineVariant: AppColors.line,
    surfaceTint: Colors.transparent,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.paper,
    splashFactory: InkRipple.splashFactory,
    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: const TextStyle(
        color: AppColors.onInk,
        fontSize: 12.5,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.ink,
      selectionColor: AppColors.signal.withAlpha(120),
      selectionHandleColor: AppColors.ink,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.onInk,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.muted,
        textStyle: const TextStyle(fontSize: 12),
      ),
    ),
  );
}
