import 'package:flutter/foundation.dart';
import '../state/identity_key_state.dart';
import '../state/signed_pre_key_state.dart';
import '../state/sender_key_state.dart';
import '../core/key_manager.dart';
import '../../device_scoped_storage_service.dart';

/// Observes IdentityKeyState and triggers dependent key regeneration
///
/// When identity key changes (replaced/regenerated):
/// 1. Clears all SignedPreKeys (they're signed by old identity)
/// 2. Clears all PreKeys (orphaned by identity change)
/// 3. Clears all SenderKeys (sessions established with old identity)
/// 4. Regenerates new keys
///
/// Usage:
/// ```dart
/// final observer = IdentityKeyObserver(keyManager: keyManager);
/// observer.start(); // Begin observing
/// // ...
/// observer.stop(); // Stop observing (cleanup)
/// ```
class IdentityKeyObserver {
  final SignalKeyManager keyManager;
  String? _lastIdentityFingerprint;
  bool _isObserving = false;

  // State instances from KeyManager
  IdentityKeyState get identityKeyState => keyManager.identityKeyState;
  SignedPreKeyState get signedPreKeyState => keyManager.signedPreKeyState;
  SenderKeyState get senderKeyState => keyManager.senderKeyState;

  IdentityKeyObserver({required this.keyManager});

  /// Start observing identity key changes
  void start() {
    if (_isObserving) {
      debugPrint('[IDENTITY_OBSERVER] Already observing');
      return;
    }

    _lastIdentityFingerprint = identityKeyState.publicKeyFingerprint;
    identityKeyState.addListener(_onIdentityStateChanged);
    _isObserving = true;

    debugPrint(
      '[IDENTITY_OBSERVER] Started observing identity key (fingerprint: $_lastIdentityFingerprint)',
    );
  }

  /// Stop observing identity key changes
  void stop() {
    if (!_isObserving) return;

    identityKeyState.removeListener(_onIdentityStateChanged);
    _isObserving = false;

    debugPrint('[IDENTITY_OBSERVER] Stopped observing identity key');
  }

  /// Handle identity state changes
  Future<void> _onIdentityStateChanged() async {
    final currentFingerprint = identityKeyState.publicKeyFingerprint;

    // Check if identity actually changed (not just status update)
    if (currentFingerprint == null ||
        currentFingerprint == _lastIdentityFingerprint) {
      return; // No identity change
    }

    debugPrint('[IDENTITY_OBSERVER] ⚠️ Identity key changed!');
    debugPrint('[IDENTITY_OBSERVER]   Old: $_lastIdentityFingerprint');
    debugPrint('[IDENTITY_OBSERVER]   New: $currentFingerprint');

    _lastIdentityFingerprint = currentFingerprint;

    // Trigger cascade regeneration
    await _regenerateDependentKeys();
  }

  /// Regenerate all keys that depend on identity key
  Future<void> _regenerateDependentKeys() async {
    try {
      debugPrint(
        '[IDENTITY_OBSERVER] ========================================',
      );
      debugPrint('[IDENTITY_OBSERVER] Starting dependent key regeneration...');

      // 1. Regenerate SignedPreKey (CRITICAL - signed by identity)
      debugPrint('[IDENTITY_OBSERVER] Regenerating SignedPreKey...');
      signedPreKeyState.markRotating();
      await keyManager.rotateSignedPreKey(keyManager.identityKeyPair);
      debugPrint('[IDENTITY_OBSERVER] ✓ SignedPreKey regenerated');

      // 2. Regenerate PreKeys (orphaned by identity change)
      debugPrint('[IDENTITY_OBSERVER] Regenerating PreKeys...');
      await keyManager.checkPreKeys(); // Auto-regenerates if needed
      debugPrint('[IDENTITY_OBSERVER] ✓ PreKeys regenerated');

      // 3. Clear SenderKeys (sessions invalid with old identity)
      debugPrint('[IDENTITY_OBSERVER] Clearing SenderKeys...');
      await _clearAllSenderKeys();
      senderKeyState.updateStatus(0, 0); // Reset to 0 groups
      debugPrint('[IDENTITY_OBSERVER] ✓ SenderKeys cleared');

      debugPrint(
        '[IDENTITY_OBSERVER] ========================================',
      );
      debugPrint(
        '[IDENTITY_OBSERVER] ✅ Dependent keys regenerated successfully',
      );
    } catch (e, stackTrace) {
      debugPrint('[IDENTITY_OBSERVER] ❌ Error regenerating dependent keys: $e');
      debugPrint('[IDENTITY_OBSERVER] Stack trace: $stackTrace');

      // Mark states as error
      signedPreKeyState.markError('Failed to regenerate after identity change');
      senderKeyState.markError('Failed to clear: $e');
    }
  }

  /// Clear all local sender keys (they're invalid after identity change)
  Future<void> _clearAllSenderKeys() async {
    try {
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(
        'peerwaveSenderKeys',
        'peerwaveSenderKeys',
      );

      for (final key in keys) {
        await storage.deleteEncrypted(
          'peerwaveSenderKeys',
          'peerwaveSenderKeys',
          key,
        );
      }

      debugPrint('[IDENTITY_OBSERVER] Cleared ${keys.length} sender keys');
    } catch (e) {
      debugPrint('[IDENTITY_OBSERVER] Error clearing sender keys: $e');
      rethrow;
    }
  }
}
