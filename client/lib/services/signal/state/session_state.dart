import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Session health status
enum SessionStatus {
  /// Not yet checked
  unknown,

  /// Sessions are healthy
  healthy,

  /// Some sessions need healing
  needsHealing,

  /// Currently healing sessions
  healing,

  /// Error during healing
  error,
}

/// Observable state for Session operations
///
/// Tracks:
/// - Active session count
/// - Sessions needing healing/validation
/// - Last validation time
///
/// Usage:
/// ```dart
/// final state = SessionState.instance;
/// state.addListener(() {
///   print('Active sessions: ${state.activeSessionCount}');
///   print('Needs healing: ${state.sessionsNeedingHealing}');
/// });
/// ```
class SessionState extends ChangeNotifier {
  static final SessionState instance = SessionState._();
  SessionState._();

  int _activeSessionCount = 0;
  int _sessionsNeedingHealing = 0;
  DateTime? _lastValidationTime;
  DateTime? _lastHealingTime;
  SessionStatus _status = SessionStatus.unknown;
  bool _isHealing = false;
  String? _errorMessage;

  // Getters
  int get activeSessionCount => _activeSessionCount;
  int get sessionsNeedingHealing => _sessionsNeedingHealing;
  DateTime? get lastValidationTime => _lastValidationTime;
  DateTime? get lastHealingTime => _lastHealingTime;
  SessionStatus get status => _status;
  bool get isHealing => _isHealing;
  String? get errorMessage => _errorMessage;

  /// Check if any sessions need healing
  bool get needsHealing => _sessionsNeedingHealing > 0;

  /// Update session status
  void updateStatus(int activeCount, int needingHealing) {
    _activeSessionCount = activeCount;
    _sessionsNeedingHealing = needingHealing;
    _lastValidationTime = DateTime.now();

    // Auto-update status
    if (needingHealing > 0) {
      _status = SessionStatus.needsHealing;
    } else if (activeCount > 0) {
      _status = SessionStatus.healthy;
    }

    notifyListeners();
  }

  /// Mark healing as in progress
  void markHealing() {
    _isHealing = true;
    _status = SessionStatus.healing;
    notifyListeners();
  }

  /// Mark healing as complete
  void markHealingComplete(int sessionsHealed) {
    _isHealing = false;
    _lastHealingTime = DateTime.now();
    _sessionsNeedingHealing = (_sessionsNeedingHealing - sessionsHealed).clamp(
      0,
      _activeSessionCount,
    );
    _status = _sessionsNeedingHealing > 0
        ? SessionStatus.needsHealing
        : SessionStatus.healthy;
    notifyListeners();
  }

  /// Mark error during healing
  void markError(String error) {
    _isHealing = false;
    _status = SessionStatus.error;
    _errorMessage = error;
    notifyListeners();
  }

  /// Reset state
  void reset() {
    _activeSessionCount = 0;
    _sessionsNeedingHealing = 0;
    _lastValidationTime = null;
    _lastHealingTime = null;
    _status = SessionStatus.unknown;
    _isHealing = false;
    _errorMessage = null;
    notifyListeners();
  }
}
