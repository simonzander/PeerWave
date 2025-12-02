import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'dart:convert';

/// Utility class for extracting dominant colors from images
class ImageColorExtractor {
  static final Map<String, Color> _colorCache = {};

  /// Extracts the dominant color from a base64 encoded image
  static Future<Color> extractDominantColor(String base64Image) async {
    // Check cache first
    if (_colorCache.containsKey(base64Image)) {
      return _colorCache[base64Image]!;
    }

    try {
      // Remove data URL prefix if present
      String cleanBase64 = base64Image;
      if (base64Image.contains(',')) {
        cleanBase64 = base64Image.split(',')[1];
      }

      // Decode base64 to bytes
      final bytes = base64Decode(cleanBase64);
      
      // Create image from bytes
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // Generate palette
      final palette = await PaletteGenerator.fromImage(
        image,
        maximumColorCount: 10,
      );

      // Get dominant color, fallback to vibrant or muted
      Color dominantColor = palette.dominantColor?.color ??
          palette.vibrantColor?.color ??
          palette.mutedColor?.color ??
          Colors.teal;

      // Cache the color
      _colorCache[base64Image] = dominantColor;

      return dominantColor;
    } catch (e) {
      debugPrint('[ImageColorExtractor] Error extracting color: $e');
      return Colors.teal; // Fallback color
    }
  }

  /// Clears the color cache
  static void clearCache() {
    _colorCache.clear();
  }

  /// Creates a gradient background from a dominant color
  static LinearGradient createGradientFromColor(Color color) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        color.withOpacity(0.6),
        color.withOpacity(0.3),
        color.darken(0.2).withOpacity(0.4),
      ],
    );
  }
}

/// Extension to darken/lighten colors
extension ColorExtension on Color {
  Color darken([double amount = 0.1]) {
    assert(amount >= 0 && amount <= 1);
    final hsl = HSLColor.fromColor(this);
    final darkened = hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0));
    return darkened.toColor();
  }

  Color lighten([double amount = 0.1]) {
    assert(amount >= 0 && amount <= 1);
    final hsl = HSLColor.fromColor(this);
    final lightened = hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0));
    return lightened.toColor();
  }
}
