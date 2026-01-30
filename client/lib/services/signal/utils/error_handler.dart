import 'package:flutter/foundation.dart';
import '../callbacks/error_callbacks.dart';

/// Centralized error handling for Signal Protocol operations
///
/// Handles:
/// - Error logging and categorization
/// - Error severity assessment
/// - Automatic healing triggers
/// - Analytics reporting for critical errors
///
/// Usage:
/// ```dart
/// ErrorHandler.handleReceiveError(error, messageData);
/// ErrorHandler.handleSendError(error, recipientId);
/// ErrorHandler.log(SignalError(...));
/// ```
class ErrorHandler {
  static final ErrorHandler instance = ErrorHandler._();
  ErrorHandler._();

  final List<SignalError> _errorLog = [];
  static const int maxLogSize = 100;

  /// Get recent errors
  List<SignalError> get recentErrors => List.unmodifiable(_errorLog);

  /// Get errors by category
  List<SignalError> getErrorsByCategory(ErrorCategory category) {
    return _errorLog.where((e) => e.category == category).toList();
  }

  /// Get errors by severity
  List<SignalError> getErrorsBySeverity(ErrorSeverity severity) {
    return _errorLog.where((e) => e.severity == severity).toList();
  }

  /// Handle receive errors (message decryption failures)
  static void handleReceiveError(dynamic error, Map<String, dynamic>? data) {
    final errorStr = error.toString().toLowerCase();

    SignalError signalError;

    // Categorize error based on error type
    if (errorStr.contains('invalid message') ||
        errorStr.contains('bad mac') ||
        errorStr.contains('decrypt')) {
      signalError = SignalError(
        category: ErrorCategory.encryption,
        severity: ErrorSeverity.error,
        message: 'Message decryption failed',
        context: {'error': error.toString(), 'data': data},
        timestamp: DateTime.now(),
      );
    } else if (errorStr.contains('session') ||
        errorStr.contains('no session')) {
      signalError = SignalError(
        category: ErrorCategory.healing,
        severity: ErrorSeverity.warning,
        message: 'Session error - healing required',
        context: {'error': error.toString(), 'data': data},
        timestamp: DateTime.now(),
      );
    } else if (errorStr.contains('identity') ||
        errorStr.contains('untrusted')) {
      signalError = SignalError(
        category: ErrorCategory.validation,
        severity: ErrorSeverity.warning,
        message: 'Identity validation error',
        context: {'error': error.toString(), 'data': data},
        timestamp: DateTime.now(),
      );
    } else if (errorStr.contains('network') ||
        errorStr.contains('timeout') ||
        errorStr.contains('connection')) {
      signalError = SignalError(
        category: ErrorCategory.network,
        severity: ErrorSeverity.warning,
        message: 'Network error during receive',
        context: {'error': error.toString(), 'data': data},
        timestamp: DateTime.now(),
      );
    } else {
      signalError = SignalError(
        category: ErrorCategory.encryption,
        severity: ErrorSeverity.error,
        message: 'Unknown receive error',
        context: {'error': error.toString(), 'data': data},
        timestamp: DateTime.now(),
      );
    }

    log(signalError);

    // Trigger healing if needed
    if (signalError.needsHealing && data != null) {
      final senderId = data['sender'] as String?;
      if (senderId != null) {
        debugPrint('[ERROR_HANDLER] Triggering healing for $senderId');
        // TODO: Trigger HealingService when available
        // HealingService.instance.heal(senderId);
      }
    }
  }

  /// Handle send errors (message encryption/send failures)
  static void handleSendError(dynamic error, String recipientId) {
    final errorStr = error.toString().toLowerCase();

    SignalError signalError;

    if (errorStr.contains('session') || errorStr.contains('no session')) {
      signalError = SignalError(
        category: ErrorCategory.healing,
        severity: ErrorSeverity.error,
        message: 'Send failed - no session with $recipientId',
        context: {'error': error.toString(), 'recipientId': recipientId},
        timestamp: DateTime.now(),
      );
    } else if (errorStr.contains('network') || errorStr.contains('timeout')) {
      signalError = SignalError(
        category: ErrorCategory.network,
        severity: ErrorSeverity.warning,
        message: 'Network error sending to $recipientId',
        context: {'error': error.toString(), 'recipientId': recipientId},
        timestamp: DateTime.now(),
      );
    } else if (errorStr.contains('encrypt')) {
      signalError = SignalError(
        category: ErrorCategory.encryption,
        severity: ErrorSeverity.error,
        message: 'Encryption failed for $recipientId',
        context: {'error': error.toString(), 'recipientId': recipientId},
        timestamp: DateTime.now(),
      );
    } else {
      signalError = SignalError(
        category: ErrorCategory.encryption,
        severity: ErrorSeverity.error,
        message: 'Send failed to $recipientId',
        context: {'error': error.toString(), 'recipientId': recipientId},
        timestamp: DateTime.now(),
      );
    }

    log(signalError);

    // Trigger healing if needed
    if (signalError.needsHealing) {
      debugPrint('[ERROR_HANDLER] Triggering healing for $recipientId');
      // TODO: Trigger HealingService when available
      // HealingService.instance.heal(recipientId);
    }
  }

  /// Handle key management errors
  static void handleKeyError(dynamic error, String operation) {
    final signalError = SignalError(
      category: ErrorCategory.validation,
      severity: ErrorSeverity.critical,
      message: 'Key management error during $operation',
      context: {'error': error.toString(), 'operation': operation},
      timestamp: DateTime.now(),
    );

    log(signalError);

    // Critical errors should trigger re-initialization
    if (signalError.severity == ErrorSeverity.critical) {
      debugPrint(
        '[ERROR_HANDLER] CRITICAL: Key error - may need re-initialization',
      );
      // TODO: Notify user or trigger re-initialization
    }
  }

  /// Handle session management errors
  static void handleSessionError(dynamic error, String userId, int deviceId) {
    final signalError = SignalError(
      category: ErrorCategory.healing,
      severity: ErrorSeverity.warning,
      message: 'Session error with $userId:$deviceId',
      context: {
        'error': error.toString(),
        'userId': userId,
        'deviceId': deviceId,
      },
      timestamp: DateTime.now(),
    );

    log(signalError);
  }

  /// Log error to internal log and notify callbacks
  static void log(SignalError error) {
    instance._errorLog.add(error);

    // Keep log size limited
    if (instance._errorLog.length > maxLogSize) {
      instance._errorLog.removeAt(0);
    }

    // Log to console with appropriate level
    final prefix = _getSeverityPrefix(error.severity);
    debugPrint(
      '$prefix [${error.category.name.toUpperCase()}] ${error.message}',
    );

    if (error.context != null) {
      debugPrint('$prefix context: ${error.context}');
    }

    // Notify error callbacks
    // ErrorCallbacks will handle notifying registered listeners
    // This is passive - services can register to listen for errors

    // Log to analytics if critical
    if (error.severity == ErrorSeverity.critical) {
      _logToAnalytics(error);
    }
  }

  /// Get severity prefix for logging
  static String _getSeverityPrefix(ErrorSeverity severity) {
    switch (severity) {
      case ErrorSeverity.warning:
        return '⚠️';
      case ErrorSeverity.error:
        return '❌';
      case ErrorSeverity.critical:
        return '🔴 CRITICAL';
    }
  }

  /// Log critical errors to analytics
  static void _logToAnalytics(SignalError error) {
    // TODO: Integrate with analytics service
    debugPrint('[ANALYTICS] Critical error: ${error.message}');
    debugPrint('[ANALYTICS] Category: ${error.category.name}');
    debugPrint('[ANALYTICS] context: ${error.context}');
  }

  /// Clear error log
  static void clearLog() {
    instance._errorLog.clear();
    debugPrint('[ERROR_HANDLER] Error log cleared');
  }

  /// Get error statistics
  static Map<String, dynamic> getStatistics() {
    final stats = <String, dynamic>{
      'total': instance._errorLog.length,
      'byCategory': <String, int>{},
      'bySeverity': <String, int>{},
    };

    for (final error in instance._errorLog) {
      // Count by category
      final category = error.category.name;
      stats['byCategory'][category] = (stats['byCategory'][category] ?? 0) + 1;

      // Count by severity
      final severity = error.severity.name;
      stats['bySeverity'][severity] = (stats['bySeverity'][severity] ?? 0) + 1;
    }

    return stats;
  }

  /// Check if healing is needed based on recent errors
  static bool needsHealing(String userId) {
    final recentErrors = instance._errorLog.where((e) {
      final isRecent = DateTime.now().difference(e.timestamp).inMinutes < 5;
      final isForUser =
          e.context?['userId'] == userId ||
          e.context?['recipientId'] == userId ||
          e.context?['senderId'] == userId;
      return isRecent && isForUser && e.needsHealing;
    });

    return recentErrors.isNotEmpty;
  }

  /// Get errors for specific user
  static List<SignalError> getErrorsForUser(String userId) {
    return instance._errorLog.where((e) {
      return e.context?['userId'] == userId ||
          e.context?['recipientId'] == userId ||
          e.context?['senderId'] == userId;
    }).toList();
  }
}
