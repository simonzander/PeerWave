import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_theme_constants.dart';

/// Material 3 Theme Generator für PeerWave
///
/// Erstellt vollständige ThemeData-Objekte mit PeerWave Design System:
/// - Spacing: 6 / 12 / 20 / 26
/// - Radius: 14px Standard
/// - Animationen: 150ms / 250ms / 350ms
/// - Icons: Filled Style
/// - Farben: Tonwert-Trennung statt Linien
class AppTheme {
  // Private constructor - nur statische Methoden
  AppTheme._();

  // ============================================================================
  // Font Configuration
  // ============================================================================

  /// Standard Schriftart für die gesamte App
  ///
  /// Beliebte Optionen:
  /// - 'Inter' (Modern, clean - EMPFOHLEN)
  /// - 'Roboto' (Google Standard)
  /// - 'Poppins' (Friendly, rounded)
  /// - 'Outfit' (Modern, geometric)
  /// - 'Space Grotesk' (Tech, modern)
  /// - 'Manrope' (Clean, readable)
  /// - 'Plus Jakarta Sans' (Modern, elegant)
  /// - 'DM Sans' (Clean, professional)
  ///
  /// Siehe alle Schriftarten: https://fonts.google.com/
  static const String fontFamily = 'Nunito Sans';

  /// Font-Variante für Breite (Width/Stretch)
  /// Für Nunito Sans SemiCondensed verwenden wir die direkte Methode
  /// Andere Varianten: normal, condensed, expanded
  static const bool useSemiCondensed = true;

  /// Monospace Schriftart für Code/technische Inhalte
  static const String monospaceFontFamily = 'Fira Code';

  /// Helper: Gibt den korrekten TextStyle mit der richtigen Font-Variante zurück
  /// Fällt auf System-Fonts zurück wenn Google Fonts nicht verfügbar sind
  static TextStyle _getFontStyle({
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
    double? letterSpacing,
  }) {
    try {
      if (useSemiCondensed) {
        // Verwende die spezifische SemiCondensed Variante
        return GoogleFonts.nunitoSans(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          letterSpacing: letterSpacing,
          // SemiCondensed hat eine eigene font-feature
        );
      } else {
        return GoogleFonts.getFont(
          fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          letterSpacing: letterSpacing,
        );
      }
    } catch (e) {
      // Fallback to system font when offline or Google Fonts unavailable
      return TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
        fontFamily: 'sans-serif', // System default
      );
    }
  }

  /// Erstellt ein Light Theme mit optionalem ColorScheme
  static ThemeData light({ColorScheme? colorScheme}) {
    final scheme = colorScheme ?? _defaultLightColorScheme();

    // Debug info (nur einmal beim ersten Aufruf)
    debugPrintFontInfo();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,

      // Typography
      textTheme: _textTheme(scheme),

      // Component Themes
      appBarTheme: _appBarTheme(scheme, Brightness.light),
      navigationBarTheme: _navigationBarTheme(scheme),
      navigationRailTheme: _navigationRailTheme(scheme),
      navigationDrawerTheme: _navigationDrawerTheme(scheme),
      cardTheme: _cardTheme(scheme),
      elevatedButtonTheme: _elevatedButtonTheme(scheme),
      filledButtonTheme: _filledButtonTheme(scheme),
      outlinedButtonTheme: _outlinedButtonTheme(scheme),
      textButtonTheme: _textButtonTheme(scheme),
      floatingActionButtonTheme: _fabTheme(scheme),
      inputDecorationTheme: _inputDecorationTheme(scheme),
      snackBarTheme: _snackBarTheme(scheme),
      dialogTheme: _dialogTheme(scheme),
      bottomSheetTheme: _bottomSheetTheme(scheme),
      chipTheme: _chipTheme(scheme),
      dividerTheme: _dividerTheme(scheme),
      iconTheme: _iconTheme(scheme),
      listTileTheme: _listTileTheme(scheme),

      // Scaffold (Main View Background)
      scaffoldBackgroundColor: AppThemeConstants.mainViewBackground,

      // Splash & Highlight
      splashFactory: InkRipple.splashFactory,
      highlightColor: scheme.primary.withValues(alpha: 0.12),
      splashColor: scheme.primary.withValues(alpha: 0.12),
    );
  }

  /// Erstellt ein Dark Theme mit optionalem ColorScheme
  static ThemeData dark({ColorScheme? colorScheme}) {
    final scheme = colorScheme ?? _defaultDarkColorScheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,

      // Typography
      textTheme: _textTheme(scheme),

      // Component Themes
      appBarTheme: _appBarTheme(scheme, Brightness.dark),
      navigationBarTheme: _navigationBarTheme(scheme),
      navigationRailTheme: _navigationRailTheme(scheme),
      navigationDrawerTheme: _navigationDrawerTheme(scheme),
      cardTheme: _cardTheme(scheme),
      elevatedButtonTheme: _elevatedButtonTheme(scheme),
      filledButtonTheme: _filledButtonTheme(scheme),
      outlinedButtonTheme: _outlinedButtonTheme(scheme),
      textButtonTheme: _textButtonTheme(scheme),
      floatingActionButtonTheme: _fabTheme(scheme),
      inputDecorationTheme: _inputDecorationTheme(scheme),
      snackBarTheme: _snackBarTheme(scheme),
      dialogTheme: _dialogTheme(scheme),
      bottomSheetTheme: _bottomSheetTheme(scheme),
      chipTheme: _chipTheme(scheme),
      dividerTheme: _dividerTheme(scheme),
      iconTheme: _iconTheme(scheme),
      listTileTheme: _listTileTheme(scheme),

      // Scaffold (Main View Background)
      scaffoldBackgroundColor: AppThemeConstants.mainViewBackground,

      // Splash & Highlight
      splashFactory: InkRipple.splashFactory,
      highlightColor: scheme.primary.withValues(alpha: 0.12),
      splashColor: scheme.primary.withValues(alpha: 0.12),
    );
  }

  // ============================================================================
  // Default Color Schemes
  // ============================================================================

  static ColorScheme _defaultLightColorScheme() {
    return const ColorScheme.light(
      primary: Color(0xFF00D1B2),
      onPrimary: Colors.white,
      surface: Color(0xFFFAFAFA),
      onSurface: Colors.black,
    );
  }

  static ColorScheme _defaultDarkColorScheme() {
    return const ColorScheme.dark(
      primary: Color(0xFF00D1B2),
      onPrimary: Colors.black,
      surface: Color(0xFF1E1E1E),
      onSurface: Colors.white,
    );
  }

  // ============================================================================
  // Typography
  // ============================================================================

  static TextTheme _textTheme(ColorScheme scheme) {
    // Debug: Print font info
    debugPrint('🎨 AppTheme: Loading font family: $fontFamily');

    // Basis TextTheme mit Google Font (mit Fehlerbehandlung)
    TextTheme baseTextTheme;
    try {
      baseTextTheme = GoogleFonts.getTextTheme(fontFamily);
      debugPrint(
        '🎨 AppTheme: Base TextTheme created with family: ${baseTextTheme.bodyMedium?.fontFamily}',
      );
    } catch (e) {
      debugPrint(
        '🎨 AppTheme: Google Fonts unavailable (offline?), using system fonts',
      );
      baseTextTheme = const TextTheme();
    }

    final textTheme = baseTextTheme.copyWith(
      // Display (Largest)
      displayLarge: _getFontStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.25,
        color: scheme.onSurface,
      ),
      displayMedium: _getFontStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      displaySmall: _getFontStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),

      // Headline
      headlineLarge: _getFontStyle(
        fontSize: 32,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      headlineMedium: _getFontStyle(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      headlineSmall: _getFontStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),

      // Title
      titleLarge: _getFontStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      titleMedium: _getFontStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.15,
        color: scheme.onSurface,
      ),
      titleSmall: _getFontStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),

      // Body
      bodyLarge: _getFontStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
        color: scheme.onSurface,
      ),
      bodyMedium: _getFontStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        color: scheme.onSurface,
      ),
      bodySmall: _getFontStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
        color: scheme.onSurface,
      ),

      // Label
      labelLarge: _getFontStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),
      labelMedium: _getFontStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: scheme.onSurface,
      ),
      labelSmall: _getFontStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: scheme.onSurface,
      ),
    );

    // Debug: Print loaded font families
    debugPrint('🎨 AppTheme TextTheme created:');
    debugPrint('   displayLarge: ${baseTextTheme.displayLarge?.fontFamily}');
    debugPrint('   bodyMedium: ${baseTextTheme.bodyMedium?.fontFamily}');
    debugPrint('   labelLarge: ${baseTextTheme.labelLarge?.fontFamily}');

    return textTheme;
  }

  /// TextTheme für Monospace (Code, technische Inhalte)
  static TextTheme monoTextTheme(ColorScheme scheme) {
    try {
      return GoogleFonts.getTextTheme(
        monospaceFontFamily,
        TextTheme(
          bodyMedium: TextStyle(color: scheme.onSurface),
          bodySmall: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    } catch (e) {
      // Fallback to system monospace font
      return TextTheme(
        bodyMedium: TextStyle(color: scheme.onSurface, fontFamily: 'monospace'),
        bodySmall: TextStyle(
          color: scheme.onSurfaceVariant,
          fontFamily: 'monospace',
        ),
      );
    }
  }

  /// Debug-Funktion: Gibt alle verfügbaren Google Fonts aus
  static void debugPrintFontInfo() {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('🎨 AppTheme Font Configuration Debug Info');
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('Configured font family: $fontFamily');
    debugPrint('Configured mono font family: $monospaceFontFamily');
    debugPrint('Use SemiCondensed: $useSemiCondensed');
    debugPrint('');

    // Test different font weights
    debugPrint('Testing font weights:');
    for (var weight in [
      FontWeight.w100,
      FontWeight.w200,
      FontWeight.w300,
      FontWeight.w400,
      FontWeight.w500,
    ]) {
      final testStyle = GoogleFonts.nunitoSans(fontWeight: weight);
      debugPrint(
        '  FontWeight.${weight.toString().split('.').last}: ${testStyle.fontFamily} (actual weight: ${testStyle.fontWeight})',
      );
    }
    debugPrint('');

    // Test font loading
    final testStyle = GoogleFonts.getFont(fontFamily);
    debugPrint('Test style created:');
    debugPrint('  fontFamily: ${testStyle.fontFamily}');
    debugPrint('  fontFamilyFallback: ${testStyle.fontFamilyFallback}');
    debugPrint('');

    // Alternative font loading methods
    final nunitoSans = GoogleFonts.nunitoSans();
    debugPrint('GoogleFonts.nunitoSans():');
    debugPrint('  fontFamily: ${nunitoSans.fontFamily}');
    debugPrint('  fontFamilyFallback: ${nunitoSans.fontFamilyFallback}');
    debugPrint('  fontWeight: ${nunitoSans.fontWeight}');

    // Test thin weight
    final nunitoSansThin = GoogleFonts.nunitoSans(fontWeight: FontWeight.w100);
    debugPrint('GoogleFonts.nunitoSans(w100):');
    debugPrint('  fontFamily: ${nunitoSansThin.fontFamily}');
    debugPrint('  fontWeight: ${nunitoSansThin.fontWeight}');
    debugPrint('═══════════════════════════════════════════════════════════');
  }

  // ============================================================================
  // Component Themes
  // ============================================================================

  static AppBarTheme _appBarTheme(ColorScheme scheme, Brightness brightness) {
    return AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 3,
      shadowColor: scheme.shadow,
      surfaceTintColor: scheme.surfaceTint,
      centerTitle: false,
      titleSpacing: 16,
      titleTextStyle: _getFontStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
    );
  }

  static NavigationBarThemeData _navigationBarTheme(ColorScheme scheme) {
    return NavigationBarThemeData(
      backgroundColor: scheme.surface,
      elevation: 3,
      height: 80,
      indicatorColor: scheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _getFontStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          );
        }
        return _getFontStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: scheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: scheme.onSecondaryContainer, size: 24);
        }
        return IconThemeData(color: scheme.onSurfaceVariant, size: 24);
      }),
    );
  }

  static NavigationRailThemeData _navigationRailTheme(ColorScheme scheme) {
    return NavigationRailThemeData(
      backgroundColor: scheme.surface,
      elevation: 0,
      indicatorColor: scheme.secondaryContainer,
      selectedIconTheme: IconThemeData(
        color: scheme.onSecondaryContainer,
        size: 24,
      ),
      unselectedIconTheme: IconThemeData(
        color: scheme.onSurfaceVariant,
        size: 24,
      ),
      selectedLabelTextStyle: _getFontStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: _getFontStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  static NavigationDrawerThemeData _navigationDrawerTheme(ColorScheme scheme) {
    return NavigationDrawerThemeData(
      backgroundColor: scheme.surface,
      elevation: 1,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _getFontStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: scheme.onSecondaryContainer,
          );
        }
        return _getFontStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: scheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: scheme.onSecondaryContainer, size: 24);
        }
        return IconThemeData(color: scheme.onSurfaceVariant, size: 24);
      }),
    );
  }

  static CardThemeData _cardTheme(ColorScheme scheme) {
    return CardThemeData(
      color: scheme.surfaceContainerHighest,
      elevation: 1,
      shadowColor: scheme.shadow,
      surfaceTintColor: scheme.surfaceTint,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(8),
    );
  }

  static ElevatedButtonThemeData _elevatedButtonTheme(ColorScheme scheme) {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.primary,
        elevation: AppThemeConstants.elevationHover,
        shadowColor: scheme.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: AppThemeConstants.borderRadiusStandard,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: AppThemeConstants.spacingMd,
          vertical: AppThemeConstants.spacingSm,
        ),
        minimumSize: const Size(64, 40),
      ),
    );
  }

  static FilledButtonThemeData _filledButtonTheme(ColorScheme scheme) {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: AppThemeConstants.elevationNone,
        shape: RoundedRectangleBorder(
          borderRadius: AppThemeConstants.borderRadiusStandard,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: AppThemeConstants.spacingMd,
          vertical: AppThemeConstants.spacingSm,
        ),
        minimumSize: const Size(64, 40),
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(ColorScheme scheme) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(
          color: scheme.outline,
          width: AppThemeConstants.borderWidthStandard,
        ),
        elevation: AppThemeConstants.elevationNone,
        shape: RoundedRectangleBorder(
          borderRadius: AppThemeConstants.borderRadiusStandard,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: AppThemeConstants.spacingMd,
          vertical: AppThemeConstants.spacingSm,
        ),
        minimumSize: const Size(64, 40),
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(ColorScheme scheme) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        elevation: AppThemeConstants.elevationNone,
        shape: RoundedRectangleBorder(
          borderRadius: AppThemeConstants.borderRadiusStandard,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: AppThemeConstants.spacingSm,
          vertical: AppThemeConstants.spacingSm,
        ),
        minimumSize: const Size(64, 40),
      ),
    );
  }

  static FloatingActionButtonThemeData _fabTheme(ColorScheme scheme) {
    return FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      elevation: 3,
      highlightElevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }

  static InputDecorationTheme _inputDecorationTheme(ColorScheme scheme) {
    return InputDecorationTheme(
      filled: true,
      fillColor: AppThemeConstants.inputBackground,
      border: OutlineInputBorder(
        borderRadius: AppThemeConstants.borderRadiusStandard,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppThemeConstants.borderRadiusStandard,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppThemeConstants.borderRadiusStandard,
        borderSide: BorderSide(
          color: scheme.primary,
          width: AppThemeConstants.borderWidthStandard,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppThemeConstants.borderRadiusStandard,
        borderSide: BorderSide(
          color: scheme.error,
          width: AppThemeConstants.borderWidthStandard,
        ),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppThemeConstants.borderRadiusStandard,
        borderSide: BorderSide(
          color: scheme.error,
          width: AppThemeConstants.borderWidthThick,
        ),
      ),
      contentPadding: AppThemeConstants.paddingSm,
      hintStyle: const TextStyle(color: AppThemeConstants.textSecondary),
      labelStyle: const TextStyle(color: AppThemeConstants.textSecondary),
      floatingLabelStyle: TextStyle(color: scheme.primary),
    );
  }

  static SnackBarThemeData _snackBarTheme(ColorScheme scheme) {
    return SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      actionTextColor: scheme.inversePrimary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 3,
    );
  }

  static DialogThemeData _dialogTheme(ColorScheme scheme) {
    return DialogThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      surfaceTintColor: scheme.surfaceTint,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: _getFontStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      contentTextStyle: _getFontStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  static BottomSheetThemeData _bottomSheetTheme(ColorScheme scheme) {
    return BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      surfaceTintColor: scheme.surfaceTint,
      elevation: 1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      modalBackgroundColor: scheme.surfaceContainerHighest,
      modalElevation: 1,
    );
  }

  static ChipThemeData _chipTheme(ColorScheme scheme) {
    return ChipThemeData(
      backgroundColor: AppThemeConstants.inputBackground,
      deleteIconColor: AppThemeConstants.textSecondary,
      disabledColor: scheme.onSurface.withValues(alpha: 0.12),
      selectedColor: scheme.secondaryContainer,
      secondarySelectedColor: scheme.secondaryContainer,
      labelPadding: EdgeInsets.symmetric(
        horizontal: AppThemeConstants.spacingXs,
      ),
      padding: EdgeInsets.all(AppThemeConstants.spacingXs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          AppThemeConstants.radiusSmall,
        ), // 8px
      ),
      labelStyle: const TextStyle(
        fontSize: AppThemeConstants.fontSizeCaption,
        color: AppThemeConstants.textPrimary,
      ),
      secondaryLabelStyle: _getFontStyle(
        fontSize: AppThemeConstants.fontSizeCaption,
        fontWeight: AppThemeConstants.fontWeightCaption,
        color: scheme.onSecondaryContainer,
      ),
      brightness: scheme.brightness,
    );
  }

  static DividerThemeData _dividerTheme(ColorScheme scheme) {
    return DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.1), // Sehr subtil
      thickness: 1,
      space: 1,
      indent: 0,
      endIndent: 0,
    );
  }

  static IconThemeData _iconTheme(ColorScheme scheme) {
    return IconThemeData(color: scheme.onSurface, size: 24);
  }

  static ListTileThemeData _listTileTheme(ColorScheme scheme) {
    return ListTileThemeData(
      tileColor: Colors.transparent,
      selectedTileColor: AppThemeConstants.activeChannelBackground,
      selectedColor: scheme.primary,
      iconColor: AppThemeConstants.textPrimary,
      textColor: AppThemeConstants.textPrimary,
      contentPadding: AppThemeConstants.paddingHorizontalSm,
      minLeadingWidth: 40,
      dense: true,
      shape: RoundedRectangleBorder(
        borderRadius: AppThemeConstants.borderRadiusStandard,
        side: BorderSide.none,
      ),
    );
  }
}
