import 'package:flutter/material.dart';

enum AppThemeChoice { light, dim, dark }

extension AppThemeChoiceX on AppThemeChoice {
  String get storageValue => name;

  String get label => switch (this) {
        AppThemeChoice.light => 'Светлая',
        AppThemeChoice.dim => 'Сумеречная',
        AppThemeChoice.dark => 'Тёмная',
      };

  IconData get icon => switch (this) {
        AppThemeChoice.light => Icons.light_mode_outlined,
        AppThemeChoice.dim => Icons.brightness_6_outlined,
        AppThemeChoice.dark => Icons.dark_mode_outlined,
      };

  static AppThemeChoice parse(Object? value) => switch (value) {
        'dim' => AppThemeChoice.dim,
        'dark' => AppThemeChoice.dark,
        _ => AppThemeChoice.light,
      };
}

@immutable
class ShiftStatusColors extends ThemeExtension<ShiftStatusColors> {
  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color vacation;
  final Color vacationContainer;
  final Color sick;
  final Color sickContainer;
  final Color night;
  final Color nightContainer;
  final Color neutral;
  final Color neutralContainer;

  const ShiftStatusColors({
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.vacation,
    required this.vacationContainer,
    required this.sick,
    required this.sickContainer,
    required this.night,
    required this.nightContainer,
    required this.neutral,
    required this.neutralContainer,
  });

  @override
  ShiftStatusColors copyWith({
    Color? success,
    Color? successContainer,
    Color? warning,
    Color? warningContainer,
    Color? vacation,
    Color? vacationContainer,
    Color? sick,
    Color? sickContainer,
    Color? night,
    Color? nightContainer,
    Color? neutral,
    Color? neutralContainer,
  }) {
    return ShiftStatusColors(
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      vacation: vacation ?? this.vacation,
      vacationContainer: vacationContainer ?? this.vacationContainer,
      sick: sick ?? this.sick,
      sickContainer: sickContainer ?? this.sickContainer,
      night: night ?? this.night,
      nightContainer: nightContainer ?? this.nightContainer,
      neutral: neutral ?? this.neutral,
      neutralContainer: neutralContainer ?? this.neutralContainer,
    );
  }

  @override
  ShiftStatusColors lerp(ShiftStatusColors? other, double t) {
    if (other == null) return this;
    return ShiftStatusColors(
      success: Color.lerp(success, other.success, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      vacation: Color.lerp(vacation, other.vacation, t)!,
      vacationContainer:
          Color.lerp(vacationContainer, other.vacationContainer, t)!,
      sick: Color.lerp(sick, other.sick, t)!,
      sickContainer: Color.lerp(sickContainer, other.sickContainer, t)!,
      night: Color.lerp(night, other.night, t)!,
      nightContainer: Color.lerp(nightContainer, other.nightContainer, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      neutralContainer:
          Color.lerp(neutralContainer, other.neutralContainer, t)!,
    );
  }
}

extension ShiftThemeContext on BuildContext {
  ShiftStatusColors get shiftColors =>
      Theme.of(this).extension<ShiftStatusColors>()!;
}

class AppTheme {
  static const _primary = Color(0xFF0866E5);

  static ThemeData forChoice(AppThemeChoice choice) => switch (choice) {
        AppThemeChoice.light => light(),
        AppThemeChoice.dim => dim(),
        AppThemeChoice.dark => dark(),
      };

  static ThemeData light() => _build(
        brightness: Brightness.light,
        background: const Color(0xFFF6F8FC),
        surface: const Color(0xFFFFFFFF),
        surfaceHigh: const Color(0xFFF0F4FA),
        outline: const Color(0xFFD9E0EA),
        text: const Color(0xFF101828),
        muted: const Color(0xFF667085),
      );

  static ThemeData dim() => _build(
        brightness: Brightness.dark,
        background: const Color(0xFF1A202B),
        surface: const Color(0xFF242C39),
        surfaceHigh: const Color(0xFF303A49),
        outline: const Color(0xFF445064),
        text: const Color(0xFFF1F4F8),
        muted: const Color(0xFFB7C0CE),
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        background: const Color(0xFF080B11),
        surface: const Color(0xFF111722),
        surfaceHigh: const Color(0xFF1A2230),
        outline: const Color(0xFF2A3545),
        text: const Color(0xFFF7F9FC),
        muted: const Color(0xFF9BA8BA),
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color surfaceHigh,
    required Color outline,
    required Color text,
    required Color muted,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? const Color(0xFF65A3FF) : _primary,
      onPrimary: isDark ? const Color(0xFF001B3F) : Colors.white,
      primaryContainer:
          isDark ? const Color(0xFF123A72) : const Color(0xFFDDEBFF),
      onPrimaryContainer:
          isDark ? const Color(0xFFD9E8FF) : const Color(0xFF003B7D),
      secondary: const Color(0xFF14B8BE),
      onSecondary: const Color(0xFF002022),
      secondaryContainer:
          isDark ? const Color(0xFF0A4A4E) : const Color(0xFFD3F5F4),
      onSecondaryContainer:
          isDark ? const Color(0xFFB6F0EF) : const Color(0xFF004F52),
      tertiary: const Color(0xFF8B5CF6),
      onTertiary: Colors.white,
      tertiaryContainer:
          isDark ? const Color(0xFF39256E) : const Color(0xFFECE4FF),
      onTertiaryContainer:
          isDark ? const Color(0xFFE9DDFF) : const Color(0xFF3D1D82),
      error: isDark ? const Color(0xFFFF8A86) : const Color(0xFFD92D20),
      onError: isDark ? const Color(0xFF500006) : Colors.white,
      errorContainer:
          isDark ? const Color(0xFF6D1B1D) : const Color(0xFFFFE3E1),
      onErrorContainer:
          isDark ? const Color(0xFFFFDAD7) : const Color(0xFF7A1511),
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: surfaceHigh,
      onSurfaceVariant: muted,
      outline: outline,
      outlineVariant: outline.withValues(alpha: 0.72),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: text,
      onInverseSurface: background,
      inversePrimary: _primary,
    );

    final baseText = Typography.material2021().black.apply(
          bodyColor: text,
          displayColor: text,
          fontFamily: 'Segoe UI',
        );
    final textTheme = baseText.copyWith(
      headlineLarge: baseText.headlineLarge?.copyWith(
        fontSize: 34,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
      ),
      headlineMedium: baseText.headlineMedium?.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleLarge: baseText.titleLarge?.copyWith(
        fontSize: 21,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 14.5),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );

    final radius = BorderRadius.circular(14);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      textTheme: textTheme,
      dividerColor: outline.withValues(alpha: 0.75),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: outline.withValues(alpha: 0.85)),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: textTheme.titleLarge,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
        height: 68,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHigh,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: textTheme.labelMedium,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      extensions: [
        ShiftStatusColors(
          success: const Color(0xFF12A150),
          successContainer:
              isDark ? const Color(0xFF143F29) : const Color(0xFFE0F7E8),
          warning: const Color(0xFFF79009),
          warningContainer:
              isDark ? const Color(0xFF52320E) : const Color(0xFFFFF0D5),
          vacation: const Color(0xFF10B5BA),
          vacationContainer:
              isDark ? const Color(0xFF0A4145) : const Color(0xFFD8F6F5),
          sick: const Color(0xFF8B5CF6),
          sickContainer:
              isDark ? const Color(0xFF372465) : const Color(0xFFEDE5FF),
          night: const Color(0xFF5E6AD2),
          nightContainer:
              isDark ? const Color(0xFF2C336A) : const Color(0xFFE4E7FF),
          neutral: muted,
          neutralContainer: surfaceHigh,
        ),
      ],
    );
  }
}
