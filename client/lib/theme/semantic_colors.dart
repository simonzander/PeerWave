import 'package:flutter/material.dart';

/// Semantic color extensions for ColorScheme
///
/// Provides consistent semantic colors across the app:
/// - success: Green variants for positive actions (accept, complete, online)
/// - warning: Orange variants for caution states (pending, in-progress)
/// - info: Blue variants for informational states
///
/// These colors automatically adapt to light/dark themes while maintaining
/// semantic meaning.
extension SemanticColors on ColorScheme {
  /// Success color - used for positive actions, completion states, online status
  /// Examples: Accept call, file upload complete, user online
  Color get success => brightness == Brightness.light
      ? const Color(0xFF4CAF50) // Material Green 500
      : const Color(0xFF66BB6A); // Material Green 400

  /// Success container - lighter background for success states
  Color get successContainer => brightness == Brightness.light
      ? const Color(0xFFC8E6C9) // Material Green 100
      : const Color(0xFF1B5E20); // Material Green 900

  /// On success - text/icons on success color
  Color get onSuccess =>
      brightness == Brightness.light ? Colors.white : Colors.black;

  /// Warning color - used for caution states, pending actions
  /// Examples: Pending admission, file in progress, warnings
  Color get warning => brightness == Brightness.light
      ? const Color(0xFFFF9800) // Material Orange 500
      : const Color(0xFFFFB74D); // Material Orange 300

  /// Warning container - lighter background for warning states
  Color get warningContainer => brightness == Brightness.light
      ? const Color(0xFFFFE0B2) // Material Orange 100
      : const Color(0xFFE65100); // Material Orange 900

  /// On warning - text/icons on warning color
  Color get onWarning =>
      brightness == Brightness.light ? Colors.white : Colors.black;

  /// Info color - used for informational states
  /// Examples: Information dialogs, help text, badges
  Color get info => brightness == Brightness.light
      ? const Color(0xFF2196F3) // Material Blue 500
      : const Color(0xFF64B5F6); // Material Blue 300

  /// Info container - lighter background for info states
  Color get infoContainer => brightness == Brightness.light
      ? const Color(0xFFBBDEFB) // Material Blue 100
      : const Color(0xFF0D47A1); // Material Blue 900

  /// On info - text/icons on info color
  Color get onInfo =>
      brightness == Brightness.light ? Colors.white : Colors.black;

  /// Overlay scrim - semi-transparent overlay for modals and dialogs
  /// Replaces Colors.black.withValues(alpha: 0.6)
  Color get overlayScrim => scrim.withValues(alpha: 0.6);

  /// Light overlay - semi-transparent white overlay
  /// Replaces Colors.white.withValues(alpha: 0.7)
  Color get lightOverlay => surface.withValues(alpha: 0.9);
}
