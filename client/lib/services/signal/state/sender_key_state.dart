import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Sender key rotation status
enum SenderKeyStatus {
  /// Not yet checked
  unknown,

  /// Keys are fresh
  healthy,

  /// One or more keys need rotation
  needsRotation,

  /// Currently rotating keys
  rotating,

  /// Error during rotation
  error,
}

/// Observable state for SenderKey store operations
///
/// Tracks:
/// - Number of groups with sender keys
/// - Keys needing rotation (7+ days or 1000+ messages)
/// - Last check/rotation times
///
/// Usage:
/// ```dart
/// // Access via KeyManager (server-scoped)
/// final state = keyManager.senderKeyState;
/// state.addListener(() {
///   print('Groups: ${state.groupCount}');
///   print('Needs rotation: ${state.keysNeedingRotation}');
/// });
/// ```
class SenderKeyState extends ChangeNotifier {
  SenderKeyState();

  int _groupCount = 0;
  int _keysNeedingRotation = 0;
  DateTime? _lastCheckTime;
  DateTime? _lastRotationTime;
  SenderKeyStatus _status = SenderKeyStatus.unknown;
  bool _isRotating = false;
  String? _errorMessage;

  // Getters
  int get groupCount => _groupCount;
  int get keysNeedingRotation => _keysNeedingRotation;
  DateTime? get lastCheckTime => _lastCheckTime;
  DateTime? get lastRotationTime => _lastRotationTime;
  SenderKeyStatus get status => _status;
  bool get isRotating => _isRotating;
  String? get errorMessage => _errorMessage;

  /// Check if any keys need rotation
  bool get needsRotation => _keysNeedingRotation > 0;

  /// Update group count and rotation needs
  void updateStatus(int groupCount, int keysNeedingRotation) {
    _groupCount = groupCount;
    _keysNeedingRotation = keysNeedingRotation;
    _lastCheckTime = DateTime.now();

    // Auto-update status
    if (keysNeedingRotation > 0) {
      _status = SenderKeyStatus.needsRotation;
    } else if (groupCount > 0) {
      _status = SenderKeyStatus.healthy;
    }

    notifyListeners();
  }

  /// Mark rotation as in progress
  void markRotating() {
    _isRotating = true;
    _status = SenderKeyStatus.rotating;
    notifyListeners();
  }

  /// Mark rotation as complete
  void markRotationComplete(int groupsRotated) {
    _isRotating = false;
    _lastRotationTime = DateTime.now();
    _keysNeedingRotation = (_keysNeedingRotation - groupsRotated).clamp(
      0,
      _groupCount,
    );
    _status = _keysNeedingRotation > 0
        ? SenderKeyStatus.needsRotation
        : SenderKeyStatus.healthy;
    notifyListeners();
  }

  /// Mark error during rotation
  void markError(String error) {
    _isRotating = false;
    _status = SenderKeyStatus.error;
    _errorMessage = error;
    notifyListeners();
  }

  /// Reset state
  void reset() {
    _groupCount = 0;
    _keysNeedingRotation = 0;
    _lastCheckTime = null;
    _lastRotationTime = null;
    _status = SenderKeyStatus.unknown;
    _isRotating = false;
    _errorMessage = null;
    notifyListeners();
  }
}
