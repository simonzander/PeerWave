import 'package:flutter/material.dart';

/// Vordefinierte Color Schemes für Material 3 Theme
/// 
/// Jedes Schema unterstützt sowohl Light als auch Dark Mode.
/// Schemas können über ihre ID referenziert werden.
class AppColorSchemes {
  /// PeerWave - Standard Theme mit Türkis-Highlight
  /// Primary: RGB(14, 132, 129) = #0E8481
  static ColorScheme peerwave(Brightness brightness) {
    const highlightColor = Color(0xFF0E8481); // RGB(14, 132, 129) - Türkis/Cyan
    
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: highlightColor,              // #0E8481 - Türkis
        onPrimary: Colors.white,              // Weißer Text auf Türkis
        primaryContainer: Color(0xFF0A5F5D), // Dunkleres Türkis für Container
        onPrimaryContainer: Color(0xFFE0FFF9), // Heller Text auf Primary Container
        
        secondary: Color(0xFF0E8481),         // Gleiche Farbe für Konsistenz
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFF0A5F5D),
        onSecondaryContainer: Color(0xFFE0FFFA),
        
        tertiary: Color(0xFF0E8481),          // Gleiche Farbe für Konsistenz
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFF0A5F5D),
        onTertiaryContainer: Color(0xFFD0F5EE),
        
        error: Color(0xFFFF5555),             // Rot für Fehler
        onError: Colors.white,
        errorContainer: Color(0xFFCC0000),
        onErrorContainer: Color(0xFFFFDADA),
        
        // Layout-spezifische Surfaces
        surface: Color(0xFF181C21),           // Main View Background
        onSurface: Color.fromRGBO(255, 255, 255, 0.85), // Items 85% Weiß
        surfaceVariant: Color(0xFF5A6269),
        surfaceContainerHighest: Color(0xFF14181D), // Context Panel Background
        onSurfaceVariant: Color.fromRGBO(255, 255, 255, 0.6), // Überschriften 60% Grau
        
        outline: Color(0xFF6B6B6B),
        outlineVariant: Color(0xFF3D3D3D),
        
        shadow: Colors.black,
        scrim: Colors.black,
        inverseSurface: Color(0xFFE0E0E0),
        onInverseSurface: Color(0xFF0E1218),
        inversePrimary: highlightColor,
      );
    } else {
      // Light variant (optional, falls User Light Mode für PeerWave wählt)
      return const ColorScheme.light(
        primary: highlightColor,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFB3F5E9),
        onPrimaryContainer: Color(0xFF003D34),
        
        secondary: Color(0xFF00C8A0),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFB3F5E9),
        onSecondaryContainer: Color(0xFF003D34),
        
        tertiary: Color(0xFF00987D),
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFFB3F5E9),
        onTertiaryContainer: Color(0xFF003D34),
        
        error: Color(0xFFCC0000),
        onError: Colors.white,
        errorContainer: Color(0xFFFFDADA),
        onErrorContainer: Color(0xFF5C0000),
        
        surface: Color(0xFFFAFAFA),
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
        inverseSurface: Color(0xFF2A2A2A),
        onInverseSurface: Color(0xFFF0F0F0),
        inversePrimary: highlightColor,
      );
    }
  }

  /// Monochrome Dark - Graustufen mit weißen Akzenten
  static ColorScheme monochromeDark(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: Colors.white,
        onPrimary: Colors.black,
        primaryContainer: Color(0xFF424242),
        onPrimaryContainer: Color(0xFFFFFFFF),
        
        secondary: Color(0xFFE0E0E0),
        onSecondary: Colors.black,
        secondaryContainer: Color(0xFF616161),
        onSecondaryContainer: Color(0xFFF5F5F5),
        
        tertiary: Color(0xFFBDBDBD),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFF757575),
        onTertiaryContainer: Color(0xFFEEEEEE),
        
        error: Color(0xFFFFFFFF),             // Weiß für Fehler (kontrastreich)
        onError: Colors.black,
        errorContainer: Color(0xFFE0E0E0),
        onErrorContainer: Colors.black,
        
        surface: Color(0xFF1A1A1A),           // Sehr Dunkelgrau
        onSurface: Colors.white,
        surfaceVariant: Color(0xFF585858),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        onSurfaceVariant: Color(0xFFE0E0E0),
        
        outline: Color(0xFF757575),
        outlineVariant: Color(0xFF424242),
        
        shadow: Colors.black,
        scrim: Colors.black,
        inverseSurface: Color(0xFFF5F5F5),
        onInverseSurface: Color(0xFF1A1A1A),
        inversePrimary: Color(0xFF424242),
      );
    } else {
      return monochromeLight(Brightness.light);
    }
  }

  /// Monochrome Light - Graustufen mit schwarzen Akzenten
  static ColorScheme monochromeLight(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const ColorScheme.light(
        primary: Colors.black,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFE0E0E0),
        onPrimaryContainer: Colors.black,
        
        secondary: Color(0xFF424242),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFBDBDBD),
        onSecondaryContainer: Colors.black,
        
        tertiary: Color(0xFF616161),
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFF9E9E9E),
        onTertiaryContainer: Colors.black,
        
        error: Color(0xFF000000),             // Schwarz für Fehler (kontrastreich)
        onError: Colors.white,
        errorContainer: Color(0xFF424242),
        onErrorContainer: Colors.white,
        
        surface: Color(0xFFFFFBFE),           // Weiß
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
        inverseSurface: Color(0xFF2A2A2A),
        onInverseSurface: Color(0xFFFFFBFE),
        inversePrimary: Color(0xFFBDBDBD),
      );
    } else {
      return monochromeDark(Brightness.dark);
    }
  }

  /// Oceanic Green - Grün/Türkis Theme
  static ColorScheme oceanicGreen(Brightness brightness) {
    const primaryGreen = Color(0xFF00BFA5);
    
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: primaryGreen,
        onPrimary: Colors.black,
        primaryContainer: Color(0xFF00897B),
        onPrimaryContainer: Color(0xFFB2DFDB),
        
        secondary: Color(0xFF26A69A),
        onSecondary: Colors.black,
        secondaryContainer: Color(0xFF00796B),
        onSecondaryContainer: Color(0xFFB2DFDB),
        
        tertiary: Color(0xFF4DB6AC),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFF00695C),
        onTertiaryContainer: Color(0xFFB2DFDB),
        
        error: Color(0xFFFF6B6B),
        onError: Colors.black,
        errorContainer: Color(0xFFCC0000),
        onErrorContainer: Color(0xFFFFDADA),
        
        surface: Color(0xFF1E1E1E),
        onSurface: Colors.white,
        surfaceVariant: Color(0xFF5A6269),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        onSurfaceVariant: Color(0xFFE0E0E0),
        
        outline: Color(0xFF6B6B6B),
        outlineVariant: Color(0xFF3D3D3D),
        
        shadow: Colors.black,
        scrim: Colors.black,
      );
    } else {
      return const ColorScheme.light(
        primary: primaryGreen,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFB2DFDB),
        onPrimaryContainer: Color(0xFF004D40),
        
        secondary: Color(0xFF26A69A),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFB2DFDB),
        onSecondaryContainer: Color(0xFF004D40),
        
        tertiary: Color(0xFF4DB6AC),
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFFB2DFDB),
        onTertiaryContainer: Color(0xFF004D40),
        
        error: Color(0xFFCC0000),
        onError: Colors.white,
        errorContainer: Color(0xFFFFDADA),
        onErrorContainer: Color(0xFF5C0000),
        
        surface: Color(0xFFFAFAFA),
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
      );
    }
  }

  /// Sunset Orange - Warme Orange-Töne
  static ColorScheme sunsetOrange(Brightness brightness) {
    const primaryOrange = Color(0xFFFF6F00);
    
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: primaryOrange,
        onPrimary: Colors.black,
        primaryContainer: Color(0xFFE65100),
        onPrimaryContainer: Color(0xFFFFE0B2),
        
        secondary: Color(0xFFFF9800),
        onSecondary: Colors.black,
        secondaryContainer: Color(0xFFF57C00),
        onSecondaryContainer: Color(0xFFFFE0B2),
        
        tertiary: Color(0xFFFFB74D),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFFF57C00),
        onTertiaryContainer: Color(0xFFFFE0B2),
        
        error: Color(0xFFFF5555),
        onError: Colors.black,
        errorContainer: Color(0xFFCC0000),
        onErrorContainer: Color(0xFFFFDADA),
        
        surface: Color(0xFF1E1E1E),
        onSurface: Colors.white,
        surfaceVariant: Color(0xFF5A6269),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        onSurfaceVariant: Color(0xFFE0E0E0),
        
        outline: Color(0xFF6B6B6B),
        outlineVariant: Color(0xFF3D3D3D),
        
        shadow: Colors.black,
        scrim: Colors.black,
      );
    } else {
      return const ColorScheme.light(
        primary: primaryOrange,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFFFE0B2),
        onPrimaryContainer: Color(0xFFE65100),
        
        secondary: Color(0xFFFF9800),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFFFE0B2),
        onSecondaryContainer: Color(0xFFE65100),
        
        tertiary: Color(0xFFFFB74D),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFFFFE0B2),
        onTertiaryContainer: Color(0xFFE65100),
        
        error: Color(0xFFCC0000),
        onError: Colors.white,
        errorContainer: Color(0xFFFFDADA),
        onErrorContainer: Color(0xFF5C0000),
        
        surface: Color(0xFFFAFAFA),
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
      );
    }
  }

  /// Lavender Purple - Sanfte Lila-Töne
  static ColorScheme lavenderPurple(Brightness brightness) {
    const primaryPurple = Color(0xFFAB47BC);
    
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: primaryPurple,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFF8E24AA),
        onPrimaryContainer: Color(0xFFE1BEE7),
        
        secondary: Color(0xFFBA68C8),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFF9C27B0),
        onSecondaryContainer: Color(0xFFE1BEE7),
        
        tertiary: Color(0xFFCE93D8),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFF9C27B0),
        onTertiaryContainer: Color(0xFFE1BEE7),
        
        error: Color(0xFFFF5555),
        onError: Colors.black,
        errorContainer: Color(0xFFCC0000),
        onErrorContainer: Color(0xFFFFDADA),
        
        surface: Color(0xFF1E1E1E),
        onSurface: Colors.white,
        surfaceVariant: Color(0xFF5A6269),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        onSurfaceVariant: Color(0xFFE0E0E0),
        
        outline: Color(0xFF6B6B6B),
        outlineVariant: Color(0xFF3D3D3D),
        
        shadow: Colors.black,
        scrim: Colors.black,
      );
    } else {
      return const ColorScheme.light(
        primary: primaryPurple,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFE1BEE7),
        onPrimaryContainer: Color(0xFF6A1B9A),
        
        secondary: Color(0xFFBA68C8),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFE1BEE7),
        onSecondaryContainer: Color(0xFF6A1B9A),
        
        tertiary: Color(0xFFCE93D8),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFFE1BEE7),
        onTertiaryContainer: Color(0xFF6A1B9A),
        
        error: Color(0xFFCC0000),
        onError: Colors.white,
        errorContainer: Color(0xFFFFDADA),
        onErrorContainer: Color(0xFF5C0000),
        
        surface: Color(0xFFFAFAFA),
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
      );
    }
  }

  /// Forest Green - Natürliche Grüntöne
  static ColorScheme forestGreen(Brightness brightness) {
    const primaryGreen = Color(0xFF2E7D32);
    
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: Color(0xFF66BB6A),
        onPrimary: Colors.black,
        primaryContainer: primaryGreen,
        onPrimaryContainer: Color(0xFFC8E6C9),
        
        secondary: Color(0xFF81C784),
        onSecondary: Colors.black,
        secondaryContainer: Color(0xFF388E3C),
        onSecondaryContainer: Color(0xFFC8E6C9),
        
        tertiary: Color(0xFFA5D6A7),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFF43A047),
        onTertiaryContainer: Color(0xFFC8E6C9),
        
        error: Color(0xFFFF5555),
        onError: Colors.black,
        errorContainer: Color(0xFFCC0000),
        onErrorContainer: Color(0xFFFFDADA),
        
        surface: Color(0xFF1E1E1E),
        onSurface: Colors.white,
        surfaceVariant: Color(0xFF5A6269),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        onSurfaceVariant: Color(0xFFE0E0E0),
        
        outline: Color(0xFF6B6B6B),
        outlineVariant: Color(0xFF3D3D3D),
        
        shadow: Colors.black,
        scrim: Colors.black,
      );
    } else {
      return const ColorScheme.light(
        primary: primaryGreen,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFC8E6C9),
        onPrimaryContainer: Color(0xFF1B5E20),
        
        secondary: Color(0xFF43A047),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFC8E6C9),
        onSecondaryContainer: Color(0xFF1B5E20),
        
        tertiary: Color(0xFF66BB6A),
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFFC8E6C9),
        onTertiaryContainer: Color(0xFF1B5E20),
        
        error: Color(0xFFCC0000),
        onError: Colors.white,
        errorContainer: Color(0xFFFFDADA),
        onErrorContainer: Color(0xFF5C0000),
        
        surface: Color(0xFFFAFAFA),
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
      );
    }
  }

  /// Cherry Red - Lebhafte Rot-Töne
  static ColorScheme cherryRed(Brightness brightness) {
    const primaryRed = Color(0xFFE53935);
    
    if (brightness == Brightness.dark) {
      return const ColorScheme.dark(
        primary: Color(0xFFEF5350),
        onPrimary: Colors.white,
        primaryContainer: primaryRed,
        onPrimaryContainer: Color(0xFFFFCDD2),
        
        secondary: Color(0xFFFF6F60),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFD32F2F),
        onSecondaryContainer: Color(0xFFFFCDD2),
        
        tertiary: Color(0xFFFF8A80),
        onTertiary: Colors.black,
        tertiaryContainer: Color(0xFFC62828),
        onTertiaryContainer: Color(0xFFFFCDD2),
        
        error: Color(0xFFFFAB91),
        onError: Colors.black,
        errorContainer: Color(0xFFFF5722),
        onErrorContainer: Color(0xFFFFE0B2),
        
        surface: Color(0xFF1E1E1E),
        onSurface: Colors.white,
        surfaceVariant: Color(0xFF5A6269),
        surfaceContainerHighest: Color(0xFF2A2A2A),
        onSurfaceVariant: Color(0xFFE0E0E0),
        
        outline: Color(0xFF6B6B6B),
        outlineVariant: Color(0xFF3D3D3D),
        
        shadow: Colors.black,
        scrim: Colors.black,
      );
    } else {
      return const ColorScheme.light(
        primary: primaryRed,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFFFCDD2),
        onPrimaryContainer: Color(0xFFB71C1C),
        
        secondary: Color(0xFFEF5350),
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFFFFCDD2),
        onSecondaryContainer: Color(0xFFB71C1C),
        
        tertiary: Color(0xFFFF6F60),
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFFFFCDD2),
        onTertiaryContainer: Color(0xFFB71C1C),
        
        error: Color(0xFFFF5722),
        onError: Colors.white,
        errorContainer: Color(0xFFFFE0B2),
        onErrorContainer: Color(0xFFBF360C),
        
        surface: Color(0xFFFAFAFA),
        onSurface: Colors.black,
        surfaceVariant: Color(0xFFE8E8E8),
        surfaceContainerHighest: Color(0xFFEEEEEE),
        onSurfaceVariant: Color(0xFF424242),
        
        outline: Color(0xFF9E9E9E),
        outlineVariant: Color(0xFFD6D6D6),
        
        shadow: Colors.black26,
        scrim: Colors.black54,
      );
    }
  }
}

/// Color Scheme Option - Wrapper für UI-Darstellung
class ColorSchemeOption {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color previewColor;
  final ColorScheme Function(Brightness) schemeBuilder;

  const ColorSchemeOption({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.previewColor,
    required this.schemeBuilder,
  });

  ColorScheme light() => schemeBuilder(Brightness.light);
  ColorScheme dark() => schemeBuilder(Brightness.dark);
}

/// Alle verfügbaren Color Schemes
class ColorSchemeOptions {
  static final List<ColorSchemeOption> all = [
    ColorSchemeOption(
      id: 'peerwave',
      name: 'PeerWave',
      description: 'Dark theme with turquoise highlight',
      icon: Icons.waves,
      previewColor: const Color(0xFF0E8481),
      schemeBuilder: AppColorSchemes.peerwave,
    ),
    ColorSchemeOption(
      id: 'monochrome_dark',
      name: 'Monochrome',
      description: 'Grayscale with white accents',
      icon: Icons.brightness_2,
      previewColor: Colors.white,
      schemeBuilder: AppColorSchemes.monochromeDark,
    ),
    /*ColorSchemeOption(
      id: 'monochrome_light',
      name: 'Monochrome Light',
      description: 'Grayscale with black accents',
      icon: Icons.brightness_5,
      previewColor: Colors.black,
      schemeBuilder: AppColorSchemes.monochromeLight,
    ),
    ColorSchemeOption(
      id: 'oceanic_green',
      name: 'Oceanic Green',
      description: 'Green and turquoise tones',
      icon: Icons.water,
      previewColor: const Color(0xFF00BFA5),
      schemeBuilder: AppColorSchemes.oceanicGreen,
    ),
    */
    ColorSchemeOption(
      id: 'sunset_orange',
      name: 'Sunset Orange',
      description: 'Warm orange and red tones',
      icon: Icons.wb_sunny,
      previewColor: const Color(0xFFFF6F00),
      schemeBuilder: AppColorSchemes.sunsetOrange,
    ),
    ColorSchemeOption(
      id: 'lavender_purple',
      name: 'Lavender Purple',
      description: 'Purple and pink tones',
      icon: Icons.local_florist,
      previewColor: const Color(0xFFAB47BC),
      schemeBuilder: AppColorSchemes.lavenderPurple,
    ),
    ColorSchemeOption(
      id: 'forest_green',
      name: 'Forest Green',
      description: 'Deep green nature tones',
      icon: Icons.park,
      previewColor: const Color(0xFF2E7D32),
      schemeBuilder: AppColorSchemes.forestGreen,
    ),
    ColorSchemeOption(
      id: 'cherry_red',
      name: 'Cherry Red',
      description: 'Red and pink tones',
      icon: Icons.favorite,
      previewColor: const Color(0xFFE53935),
      schemeBuilder: AppColorSchemes.cherryRed,
    ),
  ];

  /// Findet ein Schema nach ID
  static ColorSchemeOption? byId(String id) {
    try {
      return all.firstWhere((scheme) => scheme.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Standard Schema (PeerWave Dark)
  static ColorSchemeOption get defaultScheme => all.first;
}

