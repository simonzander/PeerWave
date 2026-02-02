import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Identity key status
enum IdentityKeyStatus {
  /// Not yet initialized
  unknown,

  /// Identity key exists and is valid
  ready,

  /// Currently generating
  generating,

  /// Error during generation
  error,
}

/// Observable state for Identity Key operations
///
/// Tracks:
/// - Identity key existence
/// - Registration ID
/// - Public key fingerprint
/// - Generation status
///
/// Usage:
/// ```dart
/// // Access through KeyManager (server-scoped)
/// final state = keyManager.identityKeyState;
/// state.addListener(() {
///   print('Has identity: ${state.hasIdentityKey}');
///   print('Status: ${state.status}');
/// });
/// ```
class IdentityKeyState extends ChangeNotifier {
  // No longer a singleton - instantiated per KeyManager
  IdentityKeyState();

  bool _hasIdentityKey = false;
  int? _registrationId;
  String? _publicKeyFingerprint;
  DateTime? _createdAt;
  IdentityKeyStatus _status = IdentityKeyStatus.unknown;
  bool _isGenerating = false;
  String? _errorMessage;

  // Getters
  bool get hasIdentityKey => _hasIdentityKey;
  int? get registrationId => _registrationId;
  String? get publicKeyFingerprint => _publicKeyFingerprint;
  DateTime? get createdAt => _createdAt;
  IdentityKeyStatus get status => _status;
  bool get isGenerating => _isGenerating;
  String? get errorMessage => _errorMessage;

  /// Check if identity is ready for use
  bool get isReady => _status == IdentityKeyStatus.ready && _hasIdentityKey;

  /// Update identity key info
  void updateIdentity({
    required bool hasKey,
    int? registrationId,
    String? publicKeyFingerprint,
    DateTime? createdAt,
  }) {
    _hasIdentityKey = hasKey;
    _registrationId = registrationId;
    _publicKeyFingerprint = publicKeyFingerprint;
    _createdAt = createdAt;
    _status = hasKey ? IdentityKeyStatus.ready : IdentityKeyStatus.unknown;
    notifyListeners();
  }

  /// Mark generation as in progress
  void markGenerating() {
    _isGenerating = true;
    _status = IdentityKeyStatus.generating;
    notifyListeners();
  }

  /// Mark generation as complete
  void markGenerationComplete({
    required int registrationId,
    required String publicKeyFingerprint,
  }) {
    _isGenerating = false;
    _hasIdentityKey = true;
    _registrationId = registrationId;
    _publicKeyFingerprint = publicKeyFingerprint;
    _createdAt = DateTime.now();
    _status = IdentityKeyStatus.ready;
    notifyListeners();
  }

  /// Mark error during generation
  void markError(String error) {
    _isGenerating = false;
    _status = IdentityKeyStatus.error;
    _errorMessage = error;
    notifyListeners();
  }

  /// Reset state
  void reset() {
    _hasIdentityKey = false;
    _registrationId = null;
    _publicKeyFingerprint = null;
    _createdAt = null;
    _status = IdentityKeyStatus.unknown;
    _isGenerating = false;
    _errorMessage = null;
    notifyListeners();
  }
}
