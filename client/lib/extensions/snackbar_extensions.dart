import 'package:flutter/material.dart';

/// Extension methods for showing themed SnackBars with Material 3 design.
///
/// Provides convenient methods to display success, error, info, and warning
/// messages with consistent styling across the app.
///
/// Example usage:
/// ```dart
/// context.showSuccessSnackBar('Changes saved successfully');
/// context.showErrorSnackBar('Failed to connect to server');
/// context.showInfoSnackBar('New message received');
/// context.showWarningSnackBar('Low storage space');
/// ```
extension SnackBarExtensions on BuildContext {
  /// Shows a success SnackBar with primary container background color.
  ///
  /// Use this for positive feedback like successful operations,
  /// data saved, or completed actions.
  void showSuccessSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(this).colorScheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 4),
        action: action,
      ),
    );
  }

  /// Shows an error SnackBar with error container background color.
  ///
  /// Use this for error messages, failed operations, or validation errors.
  void showErrorSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(this).colorScheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 4),
        action: action,
      ),
    );
  }

  /// Shows an info SnackBar with tertiary container background color.
  ///
  /// Use this for informational messages, tips, or neutral notifications.
  void showInfoSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(this).colorScheme.tertiaryContainer,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 4),
        action: action,
      ),
    );
  }

  /// Shows a warning SnackBar with secondary container background color.
  ///
  /// Use this for warnings, cautionary messages, or attention-needed situations.
  void showWarningSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(this).colorScheme.secondaryContainer,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 4),
        action: action,
      ),
    );
  }

  /// Shows a custom SnackBar with specified background color.
  ///
  /// Use this when you need a specific color that doesn't fit
  /// the standard success/error/info/warning categories.
  void showCustomSnackBar(
    String message, {
    Color? backgroundColor,
    Duration? duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor ?? Theme.of(this).colorScheme.surface,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 4),
        action: action,
      ),
    );
  }
}
