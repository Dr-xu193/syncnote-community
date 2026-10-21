import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------------
// Custom color extension
// ---------------------------------------------------------------------------
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.subtleBackground,
    required this.cardColor,
    required this.cardShadowColor,
    required this.surfaceVariant,
    required this.dividerColor,
    required this.tagBackground,
    required this.tagForeground,
    required this.urgentColor,
    required this.highColor,
    required this.normalColor,
    required this.lowColor,
    required this.successColor,
    required this.warningColor,
    required this.navBackground,
    required this.shimmerBase,
    required this.shimmerHighlight,
  });

  final Color subtleBackground;
  final Color cardColor;
  final Color cardShadowColor;
  final Color surfaceVariant;
  final Color dividerColor;
  final Color tagBackground;
  final Color tagForeground;
  final Color urgentColor;
  final Color highColor;
  final Color normalColor;
  final Color lowColor;
  final Color successColor;
  final Color warningColor;
  final Color navBackground;
  final Color shimmerBase;
  final Color shimmerHighlight;

  static const AppColors light = AppColors(
    subtleBackground: Color(0xFFF4F3FF),
    cardColor: Color(0xFFFFFFFF),
    cardShadowColor: Color(0x1A6C63FF),
    surfaceVariant: Color(0xFFEEEDFB),
    dividerColor: Color(0xFFE8E7F8),
    tagBackground: Color(0xFFEAE9FF),
    tagForeground: Color(0xFF4A42CC),
    urgentColor: Color(0xFFE53935),
    highColor: Color(0xFFFF7043),
    normalColor: Color(0xFF6C63FF),
    lowColor: Color(0xFF78909C),
    successColor: Color(0xFF43A047),
    warningColor: Color(0xFFFB8C00),
    navBackground: Color(0xFFFFFFFF),
    shimmerBase: Color(0xFFE0DFFF),
    shimmerHighlight: Color(0xFFF5F4FF),
  );

  static const AppColors dark = AppColors(
    subtleBackground: Color(0xFF12101E),
    cardColor: Color(0xFF1E1A2E),
    cardShadowColor: Color(0x406C63FF),
    surfaceVariant: Color(0xFF252038),
    dividerColor: Color(0xFF2E2845),
    tagBackground: Color(0xFF2A2550),
    tagForeground: Color(0xFFB0ACFF),
    urgentColor: Color(0xFFEF5350),
    highColor: Color(0xFFFF8A65),
    normalColor: Color(0xFF9C99FF),
    lowColor: Color(0xFF90A4AE),
    successColor: Color(0xFF66BB6A),
    warningColor: Color(0xFFFFA726),
    navBackground: Color(0xFF1A1628),
    shimmerBase: Color(0xFF2A2545),
    shimmerHighlight: Color(0xFF3D3660),
  );

  @override
  AppColors copyWith({
    Color? subtleBackground,
    Color? cardColor,
    Color? cardShadowColor,
    Color? surfaceVariant,
    Color? dividerColor,
    Color? tagBackground,
    Color? tagForeground,
    Color? urgentColor,
    Color? highColor,
    Color? normalColor,
    Color? lowColor,
    Color? successColor,
    Color? warningColor,
    Color? navBackground,
    Color? shimmerBase,
    Color? shimmerHighlight,
  }) {
    return AppColors(
      subtleBackground: subtleBackground ?? this.subtleBackground,
      cardColor: cardColor ?? this.cardColor,
      cardShadowColor: cardShadowColor ?? this.cardShadowColor,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      dividerColor: dividerColor ?? this.dividerColor,
      tagBackground: tagBackground ?? this.tagBackground,
      tagForeground: tagForeground ?? this.tagForeground,
      urgentColor: urgentColor ?? this.urgentColor,
      highColor: highColor ?? this.highColor,
      normalColor: normalColor ?? this.normalColor,
      lowColor: lowColor ?? this.lowColor,
      successColor: successColor ?? this.successColor,
      warningColor: warningColor ?? this.warningColor,
      navBackground: navBackground ?? this.navBackground,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      subtleBackground: Color.lerp(subtleBackground, other.subtleBackground, t)!,
      cardColor: Color.lerp(cardColor, other.cardColor, t)!,
      cardShadowColor: Color.lerp(cardShadowColor, other.cardShadowColor, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t)!,
      tagBackground: Color.lerp(tagBackground, other.tagBackground, t)!,
      tagForeground: Color.lerp(tagForeground, other.tagForeground, t)!,
      urgentColor: Color.lerp(urgentColor, other.urgentColor, t)!,
      highColor: Color.lerp(highColor, other.highColor, t)!,
      normalColor: Color.lerp(normalColor, other.normalColor, t)!,
      lowColor: Color.lerp(lowColor, other.lowColor, t)!,
      successColor: Color.lerp(successColor, other.successColor, t)!,
      warningColor: Color.lerp(warningColor, other.warningColor, t)!,
      navBackground: Color.lerp(navBackground, other.navBackground, t)!,
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t)!,
      shimmerHighlight: Color.lerp(shimmerHighlight, other.shimmerHighlight, t)!,
    );
  }
}

// ---------------------------------------------------------------------------
// AppTheme
// ---------------------------------------------------------------------------
class AppTheme {
  AppTheme._();

  static const Color _primarySeed = Color(0xFF6C63FF);
  static const Color _primaryDark = Color(0xFF9C99FF);

  static const double _radiusSm = 8.0;
  static const double _radiusMd = 12.0;
  static const double _radiusLg = 16.0;
  static const double _radiusXl = 24.0;

  static TextTheme _buildTextTheme(TextTheme base) {
    return GoogleFonts.interTextTheme(base).copyWith(
      displayLarge: GoogleFonts.inter(
        fontSize: 57,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
      ),
      displayMedium: GoogleFonts.inter(
        fontSize: 45,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      displaySmall: GoogleFonts.inter(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      headlineLarge: GoogleFonts.inter(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      headlineSmall: GoogleFonts.inter(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleLarge: GoogleFonts.inter(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
      ),
      titleSmall: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      bodyLarge: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
      ),
      labelLarge: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Light Theme
  // -------------------------------------------------------------------------
  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _primarySeed,
      brightness: Brightness.light,
      primary: _primarySeed,
      secondary: const Color(0xFF7C4DFF),
      tertiary: const Color(0xFF03DAC6),
      surface: const Color(0xFFFAF9FF),
      surfaceContainerHighest: const Color(0xFFE8E7F8),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      extensions: const <ThemeExtension<dynamic>>[AppColors.light],
      textTheme: _buildTextTheme(ThemeData.light().textTheme),
      scaffoldBackgroundColor: const Color(0xFFF4F3FF),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFFFAF9FF),
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        shadowColor: const Color(0x1A6C63FF),
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: colorScheme.onSurface,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
        ),
        shadowColor: const Color(0x1A6C63FF),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primarySeed,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radiusMd),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _primarySeed,
          side: const BorderSide(color: _primarySeed, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radiusMd),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _primarySeed,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radiusSm),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF0EFFF),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: const BorderSide(color: Color(0xFFDDDCF5), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: const BorderSide(color: _primarySeed, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.5),
        ),
        hintStyle: GoogleFonts.inter(
          color: const Color(0xFF9E9EC8),
          fontSize: 14,
        ),
        labelStyle: GoogleFonts.inter(
          color: const Color(0xFF6B6B9B),
          fontSize: 14,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFFEAE9FF),
        labelStyle: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: const Color(0xFF4A42CC),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        side: BorderSide.none,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _primarySeed,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusLg),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: _primarySeed,
        unselectedItemColor: Color(0xFF9E9EC8),
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: const Color(0xFFFAF9FF),
        selectedIconTheme: const IconThemeData(color: _primarySeed),
        unselectedIconTheme: const IconThemeData(color: Color(0xFF9E9EC8)),
        selectedLabelTextStyle: GoogleFonts.inter(
          color: _primarySeed,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: GoogleFonts.inter(
          color: const Color(0xFF9E9EC8),
          fontSize: 12,
        ),
        indicatorColor: const Color(0xFFEAE9FF),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE8E7F8),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2D2B45),
        contentTextStyle: GoogleFonts.inter(
          color: Colors.white,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        elevation: 8,
        shadowColor: const Color(0x336C63FF),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusXl),
        ),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF1A1A2E),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(_radiusXl),
          ),
        ),
        elevation: 8,
        shadowColor: Color(0x336C63FF),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return _primarySeed;
          return const Color(0xFFBBBBDD);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFFDDDCFF);
          }
          return const Color(0xFFE0E0F0);
        }),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return _primarySeed;
          return Colors.transparent;
        }),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: const BorderSide(color: Color(0xFFBBBBDD), width: 1.5),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: _primarySeed,
        linearTrackColor: Color(0xFFE0DFFF),
        circularTrackColor: Color(0xFFE0DFFF),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF2D2B45),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: GoogleFonts.inter(
          color: Colors.white,
          fontSize: 12,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Dark Theme
  // -------------------------------------------------------------------------
  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _primarySeed,
      brightness: Brightness.dark,
      primary: _primaryDark,
      secondary: const Color(0xFFB39DDB),
      tertiary: const Color(0xFF03DAC6),
      surface: const Color(0xFF12101E),
      surfaceContainerHighest: const Color(0xFF252038),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      extensions: const <ThemeExtension<dynamic>>[AppColors.dark],
      textTheme: _buildTextTheme(ThemeData.dark().textTheme),
      scaffoldBackgroundColor: const Color(0xFF0E0C1A),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF12101E),
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        shadowColor: const Color(0x406C63FF),
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: -0.3,
        ),
        iconTheme: const IconThemeData(color: Color(0xFFB0B0D8)),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1E1A2E),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
        ),
        shadowColor: const Color(0x406C63FF),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryDark,
          foregroundColor: const Color(0xFF12101E),
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radiusMd),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _primaryDark,
          side: const BorderSide(color: _primaryDark, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radiusMd),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _primaryDark,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_radiusSm),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1E1A2E),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: const BorderSide(color: Color(0xFF2E2845), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: const BorderSide(color: _primaryDark, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusMd),
          borderSide: const BorderSide(color: Color(0xFFEF5350), width: 1.5),
        ),
        hintStyle: GoogleFonts.inter(
          color: const Color(0xFF6B6B9B),
          fontSize: 14,
        ),
        labelStyle: GoogleFonts.inter(
          color: const Color(0xFF9090B8),
          fontSize: 14,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF2A2550),
        labelStyle: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: const Color(0xFFB0ACFF),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        side: BorderSide.none,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _primaryDark,
        foregroundColor: const Color(0xFF12101E),
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusLg),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1A1628),
        selectedItemColor: _primaryDark,
        unselectedItemColor: Color(0xFF6B6B9B),
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: const Color(0xFF12101E),
        selectedIconTheme: const IconThemeData(color: _primaryDark),
        unselectedIconTheme: const IconThemeData(color: Color(0xFF6B6B9B)),
        selectedLabelTextStyle: GoogleFonts.inter(
          color: _primaryDark,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: GoogleFonts.inter(
          color: const Color(0xFF6B6B9B),
          fontSize: 12,
        ),
        indicatorColor: const Color(0xFF2A2550),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2E2845),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2D2B45),
        contentTextStyle: GoogleFonts.inter(
          color: Colors.white,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF1E1A2E),
        elevation: 8,
        shadowColor: const Color(0x666C63FF),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusXl),
        ),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF1E1A2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(_radiusXl),
          ),
        ),
        elevation: 8,
        shadowColor: Color(0x666C63FF),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return _primaryDark;
          return const Color(0xFF4A4A6A);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFF3D3660);
          }
          return const Color(0xFF2E2845);
        }),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return _primaryDark;
          return Colors.transparent;
        }),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: const BorderSide(color: Color(0xFF4A4A6A), width: 1.5),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: _primaryDark,
        linearTrackColor: Color(0xFF2A2545),
        circularTrackColor: Color(0xFF2A2545),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF3D3660),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: GoogleFonts.inter(
          color: Colors.white,
          fontSize: 12,
        ),
      ),
    );
  }
}
