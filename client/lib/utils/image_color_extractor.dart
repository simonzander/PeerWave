import 'dart:ui' as ui;
import 'package:flutter/material.dart';
// import 'package:palette_generator/palette_generator.dart'; // Package discontinued
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

      // Extract dominant color manually by sampling pixels
      Color dominantColor = await _extractDominantColorFromImage(image);

      // Cache the color
      _colorCache[base64Image] = dominantColor;

      return dominantColor;
    } catch (e) {
      debugPrint('[ImageColorExtractor] Error extracting color: $e');
      return Colors.teal; // Fallback color
    }
  }

  /// Manually extract dominant color by sampling image pixels
  static Future<Color> _extractDominantColorFromImage(ui.Image image) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return Colors.teal;

      final pixels = byteData.buffer.asUint8List();
      final Map<int, int> colorCount = {};
      
      // Sample every 10th pixel to improve performance
      for (int i = 0; i < pixels.length; i += 40) { // 40 = 10 pixels * 4 bytes (RGBA)
        if (i + 3 >= pixels.length) break;
        
        final r = pixels[i];
        final g = pixels[i + 1];
        final b = pixels[i + 2];
        final a = pixels[i + 3];
        
        // Skip transparent or very dark/light pixels
        if (a < 128 || (r < 20 && g < 20 && b < 20) || (r > 235 && g > 235 && b > 235)) {
          continue;
        }
        
        // Quantize colors to reduce variations (group similar colors)
        final quantizedColor = ((r ~/ 32) << 16) | ((g ~/ 32) << 8) | (b ~/ 32);
        colorCount[quantizedColor] = (colorCount[quantizedColor] ?? 0) + 1;
      }
      
      if (colorCount.isEmpty) return Colors.teal;
      
      // Find most common color
      int mostCommonColor = colorCount.entries.reduce((a, b) => a.value > b.value ? a : b).key;
      
      // Convert back from quantized to full color
      final r = ((mostCommonColor >> 16) & 0x1F) * 32;
      final g = ((mostCommonColor >> 8) & 0x1F) * 32;
      final b = (mostCommonColor & 0x1F) * 32;
      
      return Color.fromARGB(255, r, g, b);
    } catch (e) {
      debugPrint('[ImageColorExtractor] Error in manual extraction: $e');
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
        color.withValues(alpha: 0.6),
        color.withValues(alpha: 0.3),
        color.darken(0.2).withValues(alpha: 0.4),
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
