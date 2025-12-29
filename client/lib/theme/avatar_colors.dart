import 'package:flutter/material.dart';

/// Avatar color palette for consistent user avatar colors across the app
/// These colors are theme-compatible pastel shades that work well in both light and dark modes
class AvatarColors {
  AvatarColors._(); // Private constructor to prevent instantiation

  /// Palette of 8 distinct colors for user avatars
  /// Colors are generated consistently based on user name hash
  static const List<Color> palette = [
    Color(0xFF7C4DFF), // Deep Purple (softer)
    Color(0xFF5C6BC0), // Indigo (softer)
    Color(0xFF42A5F5), // Blue (softer)
    Color(0xFF26A69A), // Teal (softer)
    Color(0xFF66BB6A), // Green (softer)
    Color(0xFFFF7043), // Deep Orange (softer)
    Color(0xFFEC407A), // Pink (softer)
    Color(0xFFAB47BC), // Purple (softer)
  ];

  /// Default fallback color for profiles (teal)
  static const Color defaultProfile = Color(0xFF26A69A);

  /// Generate a consistent color for a user based on their name
  static Color colorForName(String name) {
    final hash = name.hashCode;
    return palette[hash.abs() % palette.length];
  }
}
