import 'package:flutter/foundation.dart';

/// Observable state for Signal key generation and synchronization
///
/// Provides real-time progress updates during:
/// - Initial key generation (identity, signed prekey, prekeys)
/// - Background key synchronization with server
/// - Key validation and healing operations
///
/// Usage:
/// ```dart
/// final keyState = KeyState.instance;
/// keyState.addListener(() {
///   print('Progress: ${keyState.percentage}%');
///   print('Status: ${keyState.statusText}');
/// });
/// ```
class KeyState extends ChangeNotifier {
  static final KeyState instance = KeyState._();
  KeyState._();

  // Progress tracking
  int _current = 0;
  int _total = 0;
  String _statusText = 'Not started';
  KeyStatus _status = KeyStatus.uninitialized;
  String? _errorMessage;

  // Key availability
  bool _hasIdentityKey = false;
  bool _hasSignedPreKey = false;
  int _preKeyCount = 0;

  // Getters
  int get current => _current;
  int get total => _total;
  String get statusText => _statusText;
  KeyStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get hasIdentityKey => _hasIdentityKey;
  bool get hasSignedPreKey => _hasSignedPreKey;
  int get preKeyCount => _preKeyCount;

  double get percentage {
    if (_total == 0) return 0.0;
    return (_current / _total * 100).clamp(0.0, 100.0);
  }

  bool get isComplete => _status == KeyStatus.ready;
  bool get isGenerating => _status == KeyStatus.generating;
  bool get isSyncing => _status == KeyStatus.syncing;
  bool get hasError => _status == KeyStatus.error;

  /// Update generation progress
  void updateProgress(String statusText, int current, int total) {
    _statusText = statusText;
    _current = current;
    _total = total;
    if (_status != KeyStatus.generating && _status != KeyStatus.syncing) {
      _status = KeyStatus.generating;
    }
    notifyListeners();
  }

  /// Mark key generation as complete
  void markComplete() {
    _status = KeyStatus.ready;
    _statusText = 'Keys ready';
    _current = _total;
    _errorMessage = null;
    notifyListeners();
  }

  /// Mark as syncing with server
  void markSyncing(String statusText) {
    _status = KeyStatus.syncing;
    _statusText = statusText;
    notifyListeners();
  }

  /// Mark as validating keys
  void markValidating(String statusText) {
    _status = KeyStatus.validating;
    _statusText = statusText;
    notifyListeners();
  }

  /// Mark as healing (key recovery)
  void markHealing(String statusText) {
    _status = KeyStatus.healing;
    _statusText = statusText;
    notifyListeners();
  }

  /// Mark error state
  void markError(String errorMessage) {
    _status = KeyStatus.error;
    _errorMessage = errorMessage;
    _statusText = 'Error: $errorMessage';
    notifyListeners();
  }

  /// Reset to initial state
  void reset() {
    _current = 0;
    _total = 0;
    _statusText = 'Not started';
    _status = KeyStatus.uninitialized;
    _errorMessage = null;
    _hasIdentityKey = false;
    _hasSignedPreKey = false;
    _preKeyCount = 0;
    notifyListeners();
  }

  /// Update key availability status
  void updateKeyAvailability({
    required bool hasIdentityKey,
    required bool hasSignedPreKey,
    required int preKeyCount,
  }) {
    _hasIdentityKey = hasIdentityKey;
    _hasSignedPreKey = hasSignedPreKey;
    _preKeyCount = preKeyCount;
    notifyListeners();
  }

  /// Check key availability from stores (async)
  /// This should be called by KeyManager after initialization
  Future<void> checkKeyAvailability() async {
    // This will be implemented by KeyManager
    // For now, just mark as checking
    markValidating('Checking key availability...');
  }
}

/// Status of Signal key operations
enum KeyStatus {
  /// Keys not yet initialized
  uninitialized,

  /// Currently generating keys
  generating,

  /// Syncing keys with server
  syncing,

  /// Validating keys with server
  validating,

  /// Healing corrupted keys
  healing,

  /// Keys ready for use
  ready,

  /// Error occurred
  error,
}
