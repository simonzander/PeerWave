import 'package:flutter/foundation.dart';

/// Error severity levels for Signal Protocol operations
enum ErrorSeverity {
  /// Warning - operation completed with issues
  warning,

  /// Error - operation failed but recoverable
  error,

  /// Critical - requires immediate attention/action
  critical,
}

/// Error categories for targeted error handling
enum ErrorCategory {
  /// Encryption/decryption errors
  encryption,

  /// Network/connection errors
  network,

  /// Data validation errors
  validation,

  /// Session healing/recovery errors
  healing,

  /// Key management errors
  keyManagement,

  /// Session management errors
  session,

  /// Unknown/uncategorized errors
  unknown,
}

/// Structured error information for Signal Protocol operations
class SignalError {
  final ErrorCategory category;
  final ErrorSeverity severity;
  final String message;
  final dynamic originalError;
  final StackTrace? stackTrace;
  final Map<String, dynamic>? context;
  final DateTime timestamp;

  SignalError({
    required this.category,
    required this.severity,
    required this.message,
    this.originalError,
    this.stackTrace,
    this.context,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Whether this error requires healing/recovery
  bool get needsHealing =>
      category == ErrorCategory.healing ||
      category == ErrorCategory.session ||
      (category == ErrorCategory.encryption &&
          severity == ErrorSeverity.critical);

  /// Whether this error is recoverable
  bool get isRecoverable => severity != ErrorSeverity.critical;

  /// Get user-friendly error message
  String get userMessage {
    switch (category) {
      case ErrorCategory.encryption:
        return 'Unable to encrypt/decrypt message';
      case ErrorCategory.network:
        return 'Connection error, please try again';
      case ErrorCategory.validation:
        return 'Invalid data received';
      case ErrorCategory.healing:
        return 'Recovering encryption keys...';
      case ErrorCategory.keyManagement:
        return 'Key management error';
      case ErrorCategory.session:
        return 'Session error, retrying...';
      case ErrorCategory.unknown:
        return 'An error occurred';
    }
  }

  @override
  String toString() {
    return 'SignalError(category: $category, severity: $severity, message: $message)';
  }
}

/// Error handling callbacks for Signal Protocol operations
///
/// Provides centralized error handling with category-based routing.
/// Allows registration of specific error handlers for different error types.
class ErrorCallbacks {
  /// Global error callbacks (all errors)
  final List<Function(SignalError)> _globalCallbacks = [];

  /// Category-specific error callbacks
  final Map<ErrorCategory, List<Function(SignalError)>> _categoryCallbacks = {};

  /// Register global error callback (receives all errors)
  void onError(Function(SignalError) callback, {ErrorCategory? category}) {
    if (category != null) {
      _categoryCallbacks.putIfAbsent(category, () => []).add(callback);
      debugPrint(
        '[ERROR_CALLBACKS] Registered callback for category: $category',
      );
    } else {
      _globalCallbacks.add(callback);
      debugPrint(
        '[ERROR_CALLBACKS] Registered global callback (${_globalCallbacks.length} total)',
      );
    }
  }

  /// Register encryption error callback
  void onEncryptionError(Function(SignalError) callback) {
    onError(callback, category: ErrorCategory.encryption);
  }

  /// Register network error callback
  void onNetworkError(Function(SignalError) callback) {
    onError(callback, category: ErrorCategory.network);
  }

  /// Register healing error callback
  void onHealingError(Function(SignalError) callback) {
    onError(callback, category: ErrorCategory.healing);
  }

  /// Notify error occurred
  void notifyError(SignalError error) {
    debugPrint('[ERROR_CALLBACKS] Error: ${error.message} (${error.category})');

    // Notify global callbacks
    for (final callback in _globalCallbacks) {
      try {
        callback(error);
      } catch (e, stack) {
        debugPrint('[ERROR_CALLBACKS] Error in global callback: $e');
        debugPrint('[ERROR_CALLBACKS] Stack: $stack');
      }
    }

    // Notify category-specific callbacks
    final categoryCallbacks = _categoryCallbacks[error.category];
    if (categoryCallbacks != null) {
      debugPrint(
        '[ERROR_CALLBACKS] Notifying ${categoryCallbacks.length} category callbacks',
      );
      for (final callback in categoryCallbacks) {
        try {
          callback(error);
        } catch (e, stack) {
          debugPrint(
            '[ERROR_CALLBACKS] Error in category callback for ${error.category}: $e',
          );
          debugPrint('[ERROR_CALLBACKS] Stack: $stack');
        }
      }
    }
  }

  /// Clear all callbacks
  void clear() {
    _globalCallbacks.clear();
    _categoryCallbacks.clear();
    debugPrint('[ERROR_CALLBACKS] ✓ All callbacks cleared');
  }

  /// Get count of registered callbacks
  int get count =>
      _globalCallbacks.length +
      _categoryCallbacks.values.fold(0, (sum, list) => sum + list.length);

  /// Get statistics by category
  Map<String, int> getStats() {
    final stats = <String, int>{'global': _globalCallbacks.length};
    for (final entry in _categoryCallbacks.entries) {
      stats[entry.key.toString()] = entry.value.length;
    }
    return stats;
  }
}
