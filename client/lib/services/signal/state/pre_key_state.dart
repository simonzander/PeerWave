import 'package:flutter/foundation.dart';

/// PreKey health status
enum PreKeyStatus {
  /// Not yet checked
  unknown,

  /// Count is healthy (20-110)
  healthy,

  /// Count is low (< 20), regeneration needed
  low,

  /// Count is too high (> 110), cleanup needed
  excess,

  /// Currently generating PreKeys
  generating,

  /// Error during generation
  error,
}

/// Observable state for PreKey store operations
///
/// Tracks:
/// - PreKey count (should be 20-110)
/// - Generation/regeneration in progress
/// - Last sync/check time
/// - Server sync status
///
/// Usage:
/// ```dart
/// final state = PreKeyState.instance;
/// state.addListener(() {
///   print('PreKeys: ${state.count}/110');
///   print('Status: ${state.status}');
/// });
/// ```
class PreKeyState extends ChangeNotifier {
  static final PreKeyState instance = PreKeyState._();
  PreKeyState._();

  int _count = 0;
  PreKeyStatus _status = PreKeyStatus.unknown;
  DateTime? _lastCheckTime;
  DateTime? _lastGenerationTime;
  bool _isGenerating = false;
  String? _errorMessage;

  // Getters
  int get count => _count;
  PreKeyStatus get status => _status;
  DateTime? get lastCheckTime => _lastCheckTime;
  DateTime? get lastGenerationTime => _lastGenerationTime;
  bool get isGenerating => _isGenerating;
  String? get errorMessage => _errorMessage;

  /// Check if PreKey count is healthy (>= 20)
  bool get isHealthy => _count >= 20;

  /// Check if regeneration is needed (< 20)
  bool get needsRegeneration => _count < 20;

  /// Update PreKey count
  void updateCount(int count) {
    _count = count;
    _lastCheckTime = DateTime.now();

    // Auto-update status based on count
    if (count >= 20 && count <= 110) {
      _status = PreKeyStatus.healthy;
    } else if (count < 20) {
      _status = PreKeyStatus.low;
    } else {
      _status = PreKeyStatus.excess;
    }

    notifyListeners();
  }

  /// Mark generation as in progress
  void markGenerating() {
    _isGenerating = true;
    _status = PreKeyStatus.generating;
    notifyListeners();
  }

  /// Mark generation as complete
  void markGenerationComplete(int newCount) {
    _isGenerating = false;
    _lastGenerationTime = DateTime.now();
    updateCount(newCount);
  }

  /// Mark error during generation
  void markError(String error) {
    _isGenerating = false;
    _status = PreKeyStatus.error;
    _errorMessage = error;
    notifyListeners();
  }

  /// Reset state
  void reset() {
    _count = 0;
    _status = PreKeyStatus.unknown;
    _lastCheckTime = null;
    _lastGenerationTime = null;
    _isGenerating = false;
    _errorMessage = null;
    notifyListeners();
  }
}
