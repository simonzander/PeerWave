import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Signed PreKey rotation status
enum SignedPreKeyStatus {
  /// Not yet checked
  unknown,

  /// Key is fresh (< 7 days)
  fresh,

  /// Key needs rotation (>= 7 days)
  needsRotation,

  /// Currently rotating
  rotating,

  /// Error during rotation
  error,
}

/// Observable state for SignedPreKey store operations
///
/// Tracks:
/// - Current key age
/// - Rotation status (fresh vs needs rotation)
/// - Last rotation time
/// - Key ID
///
/// Usage:
/// ```dart
/// final state = SignedPreKeyState.instance;
/// state.addListener(() {
///   print('Key age: ${state.ageInDays} days');
///   print('Status: ${state.status}');
/// });
/// ```
class SignedPreKeyState extends ChangeNotifier {
  static final SignedPreKeyState instance = SignedPreKeyState._();
  SignedPreKeyState._();

  int? _currentKeyId;
  DateTime? _createdAt;
  DateTime? _lastRotationTime;
  SignedPreKeyStatus _status = SignedPreKeyStatus.unknown;
  bool _isRotating = false;
  String? _errorMessage;

  // Getters
  int? get currentKeyId => _currentKeyId;
  DateTime? get createdAt => _createdAt;
  DateTime? get lastRotationTime => _lastRotationTime;
  SignedPreKeyStatus get status => _status;
  bool get isRotating => _isRotating;
  String? get errorMessage => _errorMessage;

  /// Age of current key in days
  int? get ageInDays {
    if (_createdAt == null) return null;
    return DateTime.now().difference(_createdAt!).inDays;
  }

  /// Check if rotation is needed (>= 7 days)
  bool get needsRotation {
    final age = ageInDays;
    return age != null && age >= 7;
  }

  /// Update current key info
  void updateKey(int keyId, DateTime createdAt) {
    _currentKeyId = keyId;
    _createdAt = createdAt;

    // Auto-update status based on age
    final age = DateTime.now().difference(createdAt).inDays;
    if (age < 7) {
      _status = SignedPreKeyStatus.fresh;
    } else {
      _status = SignedPreKeyStatus.needsRotation;
    }

    notifyListeners();
  }

  /// Mark rotation as in progress
  void markRotating() {
    _isRotating = true;
    _status = SignedPreKeyStatus.rotating;
    notifyListeners();
  }

  /// Mark rotation as complete
  void markRotationComplete(int newKeyId, DateTime createdAt) {
    _isRotating = false;
    _lastRotationTime = DateTime.now();
    updateKey(newKeyId, createdAt);
  }

  /// Mark error during rotation
  void markError(String error) {
    _isRotating = false;
    _status = SignedPreKeyStatus.error;
    _errorMessage = error;
    notifyListeners();
  }

  /// Reset state
  void reset() {
    _currentKeyId = null;
    _createdAt = null;
    _lastRotationTime = null;
    _status = SignedPreKeyStatus.unknown;
    _isRotating = false;
    _errorMessage = null;
    notifyListeners();
  }
}
