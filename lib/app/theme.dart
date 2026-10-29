import 'package:flutter/material.dart';

/// Paleta de NJB Rec.
class NjbColors {
  NjbColors._();

  static const bg = Color(0xFF0E0C18);
  static const bgElevated = Color(0xFF17142A);
  static const surface = Color(0xFF1F1B36);
  static const surfaceHigh = Color(0xFF2A2548);
  static const border = Color(0xFF342E58);
  static const violet = Color(0xFF7C5CFF);
  static const cyan = Color(0xFF35D0FF);
  static const red = Color(0xFFFF4D6D);
  static const amber = Color(0xFFFFBE3C);
  static const green = Color(0xFF3DDC97);
  static const text = Color(0xFFF2F0FF);
  static const textMuted = Color(0xFF9B95BF);

  static const brandGradient = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

ThemeData buildNjbTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final scheme = ColorScheme.fromSeed(
    seedColor: NjbColors.violet,
    brightness: Brightness.dark,
    primary: NjbColors.violet,
    secondary: NjbColors.cyan,
    error: NjbColors.red,
    surface: NjbColors.bgElevated,
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: NjbColors.bg,
    canvasColor: NjbColors.bg,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.apply(
      bodyColor: NjbColors.text,
      displayColor: NjbColors.text,
      fontFamily: 'Segoe UI',
    ),
    cardTheme: const CardThemeData(
      color: NjbColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: NjbColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(color: NjbColors.border, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NjbColors.bgElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NjbColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NjbColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NjbColors.violet, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: const TextStyle(color: NjbColors.textMuted),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(NjbColors.surfaceHigh),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: NjbColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : NjbColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? NjbColors.violet : NjbColors.surfaceHigh,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: NjbColors.violet,
      inactiveTrackColor: NjbColors.surfaceHigh,
      thumbColor: Colors.white,
      overlayColor: Color(0x337C5CFF),
      trackHeight: 4,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: NjbColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NjbColors.border),
      ),
      textStyle: const TextStyle(color: NjbColors.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: NjbColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: NjbColors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: NjbColors.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: NjbColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NjbColors.violet,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: NjbColors.text,
        side: const BorderSide(color: NjbColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: NjbColors.cyan,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: NjbColors.text),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: NjbColors.bgElevated,
        selectedBackgroundColor: NjbColors.violet,
        selectedForegroundColor: Colors.white,
        foregroundColor: NjbColors.textMuted,
        side: const BorderSide(color: NjbColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: NjbColors.cyan,
      linearTrackColor: NjbColors.surfaceHigh,
    ),
  );
}
