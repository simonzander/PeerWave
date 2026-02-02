import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:collection/collection.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../../device_scoped_storage_service.dart';
import '../../api_service.dart';
import '../state/identity_key_state.dart';

/// Manages Signal Protocol Identity Keys with persistent encrypted storage
///
/// Core Operations:
/// - getIdentityKeyPair() - Get/ensure identity keypair exists (auto-generates, caches, uploads)
/// - regenerateIdentityKey() - Force new identity key generation (DANGEROUS!)
/// - getPublicKey() - Get public key as base64 string
/// - getLocalRegistrationId() - Get registration ID
/// - isTrustedIdentity() - Verify remote peer's identity (AUTOMATIC via libsignal)
/// - saveIdentity() - Save remote peer's identity (AUTOMATIC via libsignal)
/// - getIdentity() - Get stored remote peer's identity
/// - removeIdentity() - Remove remote peer's identity
/// - uploadIdentityKey() - Sync to server via API
///
/// 💡 Key Insight: Just call getIdentityKeyPair() everywhere - it handles everything!
///
/// Trust Management Flow:
/// 1. When receiving PreKeyBundle → libsignal calls saveIdentity() AUTOMATICALLY
/// 2. Before decrypting message → libsignal calls isTrustedIdentity() AUTOMATICALLY
/// 3. You DON'T need to manually call saveIdentity() unless handling identity changes
/// 4. Use removeIdentity() when user blocks/removes contact
///
/// 🌐 Multi-Server Support:
/// This store is server-scoped via KeyManager.
/// - apiService: Used for HTTP uploads (server-scoped, knows baseUrl)
/// - socketService: Used for real-time events (server-scoped, knows serverUrl)
///
/// Storage isolation is automatic:
/// - DeviceIdentityService provides unique deviceId per server
/// - DeviceScopedStorageService creates isolated databases automatically
/// - No serverUrl needed in store code!
///
/// Uses encrypted device-scoped storage (IndexedDB on web, native storage on desktop)
mixin PermanentIdentityKeyStore implements IdentityKeyStore {
  // Abstract getters - provided by KeyManager
  ApiService get apiService;
  SocketService get socketService;
  bool get hasIdentityKeyPair; // Check if identity key is initialized
  IdentityKeyState get identityKeyState; // State instance for this server

  final String _storeName = 'peerwaveSignalIdentityKeys';
  final String _keyPrefix = 'identity_';
  IdentityKeyPair? identityKeyPair;
  int? localRegistrationId;

  // 🔒 SYNC-LOCK: Prevent race conditions during key regeneration
  bool _isRegenerating = false;
  final List<Completer<void>> _pendingOperations = [];

  String _identityKey(SignalProtocolAddress address) =>
      '$_keyPrefix${address.getName()}_${address.getDeviceId()}';

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(
      _storeName,
      _storeName,
      _identityKey(address),
    );

    if (value != null) {
      return IdentityKey.fromBytes(base64Decode(value), 0);
    }
    return null;
  }

  // ============================================================================
  // Local Identity Operations (PUBLIC API)
  // ============================================================================

  /// Get local identity key pair (auto-creates if needed)
  ///
  /// ✨ This is THE method you need - one call does everything:
  /// 1. Checks if identity key exists in cache
  /// 2. If not cached, loads from persistent storage
  /// 3. If not in storage, auto-generates new identity key
  /// 4. Uploads new key to server automatically
  /// 5. Returns the identity key pair
  ///
  /// Use this everywhere you need the identity key pair!
  /// No need to check existence separately.
  ///
  /// Thread-safe: Includes sync-lock to prevent concurrent generation.
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    if (!hasIdentityKeyPair) {
      final identityData = await getIdentityKeyPairData();
      final publicKeyBytes = base64Decode(identityData['publicKey']!);
      final publicKey = Curve.decodePoint(publicKeyBytes, 0);
      final publicIdentityKey = IdentityKey(publicKey);
      final privateKey = Curve.decodePrivatePoint(
        base64Decode(identityData['privateKey']!),
      );
      identityKeyPair = IdentityKeyPair(publicIdentityKey, privateKey);
      localRegistrationId = int.parse(identityData['registrationId']!);
    }
    return identityKeyPair!;
  }

  /// Force regenerate identity key (DANGEROUS!)
  ///
  /// ⚠️ WARNING: This regenerates the identity key, invalidating ALL existing sessions!
  ///
  /// Use ONLY for:
  /// - Manual key regeneration (advanced users who know the consequences)
  /// - Security compromise recovery
  /// - Testing/debugging
  ///
  /// For normal operations, just use getIdentityKeyPair() - it handles first-time setup automatically.
  Future<IdentityKeyPair> regenerateIdentityKey() async {
    try {
      debugPrint('[IDENTITY_KEY_STORE] ⚠️ REGENERATING identity key...');
      debugPrint('[IDENTITY_KEY_STORE] This will invalidate ALL sessions!');

      // Clear cached keypair to force regeneration
      identityKeyPair = null;
      localRegistrationId = null;

      // Clear from storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(
        'peerwaveSignal',
        'identityKeyPair',
        'identityKeyPair',
      );

      // Regenerate (getIdentityKeyPairData will detect missing and create new)
      final keyPair = await getIdentityKeyPair();

      debugPrint(
        '[IDENTITY_KEY_STORE] ✓ New identity key generated and uploaded',
      );
      return keyPair;
    } catch (e) {
      debugPrint('[IDENTITY_KEY_STORE] Error regenerating identity key: $e');
      rethrow;
    }
  }

  /// Get local public key as base64 string
  ///
  /// Used for:
  /// - Server upload
  /// - QR code generation
  /// - Key fingerprint display
  Future<String> getPublicKey() async {
    try {
      final identityData = await getIdentityKeyPairData();
      return identityData['publicKey']!;
    } catch (e) {
      debugPrint('[IDENTITY_KEY_STORE] Error getting public key: $e');
      rethrow;
    }
  }

  /// Remove local identity key
  ///
  /// WARNING: Extremely dangerous! This will:
  /// - Invalidate ALL existing sessions
  /// - Make you unable to decrypt existing messages
  /// - Require full re-registration with server
  ///
  /// Only use for:
  /// - Account deletion
  /// - Complete app reset
  Future<void> removeIdentityKey() async {
    try {
      debugPrint('[IDENTITY_KEY_STORE] ⚠️ REMOVING identity key...');
      identityKeyPair = null;
      localRegistrationId = null;

      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(
        'peerwaveSignal',
        'identityKeyPair',
        'identityKeyPair',
      );

      debugPrint('[IDENTITY_KEY_STORE] ✓ Identity key removed');
    } catch (e) {
      debugPrint('[IDENTITY_KEY_STORE] Error removing identity key: $e');
      rethrow;
    }
  }

  /// Clear cached identity key pair (force reload from storage on next access)
  ///
  /// Useful for:
  /// - Testing
  /// - Memory management
  /// - Forcing fresh load after external storage changes
  ///
  /// Note: Does NOT delete from storage, only clears memory cache
  void clearCache() {
    identityKeyPair = null;
    localRegistrationId = null;
    debugPrint('[IDENTITY_KEY_STORE] ✓ Cache cleared');
  }

  /// Check if identity key exists without loading it into memory
  ///
  /// Useful for:
  /// - Checking registration status
  /// - UI state management
  /// - Avoiding unnecessary loads
  Future<bool> hasIdentityKey() async {
    final storage = DeviceScopedStorageService.instance;
    final encryptedData = await storage.getDecrypted(
      'peerwaveSignal',
      'identityKeyPair',
      'identityKeyPair',
    );
    return encryptedData != null && encryptedData is Map;
  }

  /// Upload local identity key to server
  ///
  /// Required for:
  /// - Initial registration
  /// - After key regeneration
  /// - Server key distribution to other clients
  Future<void> uploadIdentityKey() async {
    try {
      debugPrint('[IDENTITY_KEY_STORE] Uploading identity key to server...');

      final publicKey = await getPublicKey();
      final registrationId = await getLocalRegistrationId();

      final response = await ApiService.instance.post(
        '/signal/identity',
        data: {
          'publicKey': publicKey,
          'registrationId': registrationId.toString(),
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to upload identity: ${response.statusCode}');
      }

      debugPrint('[IDENTITY_KEY_STORE] ✓ Identity key uploaded');
    } catch (e) {
      debugPrint('[IDENTITY_KEY_STORE] Error uploading identity key: $e');
      rethrow;
    }
  }

  @override
  Future<int> getLocalRegistrationId() async {
    if (localRegistrationId == null) {
      final identityData = await getIdentityKeyPairData();
      localRegistrationId = int.parse(identityData['registrationId']!);
    }
    return localRegistrationId!;
  }

  /// Loads or creates the identity key pair and registrationId from persistent storage.
  Future<Map<String, String?>> getIdentityKeyPairData() async {
    String? publicKeyBase64;
    String? privateKeyBase64;
    String? registrationId;

    bool createdNew = false;

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final encryptedData = await storage.getDecrypted(
      'peerwaveSignal',
      'identityKeyPair',
      'identityKeyPair',
    );

    if (encryptedData != null && encryptedData is Map) {
      publicKeyBase64 = encryptedData['publicKey'] as String?;
      privateKeyBase64 = encryptedData['privateKey'] as String?;
      var regIdObj = encryptedData['registrationId'];
      registrationId = regIdObj?.toString();
      debugPrint(
        '[IDENTITY_KEY_STORE] ✓ Loaded encrypted IdentityKeyPair from device-scoped storage',
      );

      // Update state: identity key loaded
      if (publicKeyBase64 != null &&
          privateKeyBase64 != null &&
          registrationId != null) {
        identityKeyState.updateIdentity(
          hasKey: true,
          registrationId: int.tryParse(registrationId) ?? 0,
          publicKeyFingerprint: publicKeyBase64.substring(
            0,
            16,
          ), // Simple fingerprint
        );
      }
    }

    // Generate new identity key pair if not found
    if (publicKeyBase64 == null ||
        privateKeyBase64 == null ||
        registrationId == null) {
      debugPrint(
        '[IDENTITY_KEY_STORE] ⚠️  CRITICAL: IdentityKeyPair missing - generating NEW keys!',
      );
      debugPrint(
        '[IDENTITY_KEY_STORE] This will invalidate all existing encrypted sessions.',
      );

      // Mark state as generating
      identityKeyState.markGenerating();

      // 🔒 ACQUIRE LOCK: Prevent concurrent regeneration
      await acquireLock();
      try {
        final generated = await _generateIdentityKeyPair();
        publicKeyBase64 = generated['publicKey'];
        privateKeyBase64 = generated['privateKey'];
        registrationId = generated['registrationId'];

        // 🔒 Store encrypted identity key pair
        await storage.storeEncrypted(
          'peerwaveSignal',
          'identityKeyPair',
          'identityKeyPair',
          {
            'publicKey': publicKeyBase64,
            'privateKey': privateKeyBase64,
            'registrationId': registrationId,
          },
        );
        createdNew = true;

        // Mark generation complete
        identityKeyState.markGenerationComplete(
          registrationId: int.tryParse(registrationId!) ?? 0,
          publicKeyFingerprint: publicKeyBase64!.substring(0, 16),
        );
      } catch (e) {
        // Mark error
        identityKeyState.markError('Failed to generate identity key: $e');
        rethrow;
      } finally {
        // 🔓 RELEASE LOCK: Even if error occurs
        releaseLock();
      }
    }

    if (createdNew) {
      // CRITICAL: Clean up all dependent keys before uploading new identity
      debugPrint('[IDENTITY_KEY_STORE] Cleaning up ALL dependent keys...');
      await _cleanupDependentKeys();

      debugPrint(
        '[IDENTITY_KEY_STORE] Uploading NEW identity key to server...',
      );
      await uploadIdentityKey();
    }

    return {
      'publicKey': publicKeyBase64,
      'privateKey': privateKeyBase64,
      'registrationId': registrationId,
    };
  }

  Future<Map<String, String>> _generateIdentityKeyPair() async {
    final identityKeyPair = generateIdentityKeyPair();
    final publicKeyBase64 = base64Encode(
      identityKeyPair.getPublicKey().serialize(),
    );
    final privateKeyBase64 = base64Encode(
      identityKeyPair.getPrivateKey().serialize(),
    );
    final registrationId = generateRegistrationId(false);
    return {
      'publicKey': publicKeyBase64,
      'privateKey': privateKeyBase64,
      'registrationId': registrationId.toString(),
    };
  }

  /// CRITICAL: Clean up all dependent keys when IdentityKeyPair is regenerated
  ///
  /// When a new IdentityKeyPair is generated (e.g., after storage clear),
  /// ALL dependent keys become invalid because:
  /// - PreKeys are part of PreKeyBundles that include the old Identity Public Key
  /// - SignedPreKeys are signed with the old Identity Key Pair
  /// - Sessions are based on old PreKeyBundles
  /// - SenderKeys distributions use Sessions
  ///
  /// This method deletes all local and server-side keys to ensure consistency.
  Future<void> _cleanupDependentKeys() async {
    try {
      debugPrint('[IDENTITY_KEY_STORE] Starting cleanup of dependent keys...');

      // 1. Delete all local PreKeys
      debugPrint('[IDENTITY_KEY_STORE] Deleting local PreKeys...');
      try {
        final storage = DeviceScopedStorageService.instance;
        final keys = await storage.getAllKeys(
          'peerwaveSignalPreKeys',
          'peerwaveSignalPreKeys',
        );
        for (final key in keys) {
          await storage.deleteEncrypted(
            'peerwaveSignalPreKeys',
            'peerwaveSignalPreKeys',
            key,
          );
        }
        debugPrint(
          '[IDENTITY_KEY_STORE] ✓ Local PreKeys deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_KEY_STORE] Warning: Could not clear PreKeys from device-scoped storage: $e',
        );
      }

      // 2. Delete all local SignedPreKeys
      debugPrint('[IDENTITY_KEY_STORE] Deleting local SignedPreKeys...');
      try {
        final storage = DeviceScopedStorageService.instance;
        final keys = await storage.getAllKeys(
          'peerwaveSignalSignedPreKeys',
          'peerwaveSignalSignedPreKeys',
        );
        for (final key in keys) {
          await storage.deleteEncrypted(
            'peerwaveSignalSignedPreKeys',
            'peerwaveSignalSignedPreKeys',
            key,
          );
        }
        debugPrint(
          '[IDENTITY_KEY_STORE] ✓ Local SignedPreKeys deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_KEY_STORE] Warning: Could not clear SignedPreKeys from device-scoped storage: $e',
        );
      }

      // 3. Delete all local Sessions
      debugPrint('[IDENTITY_KEY_STORE] Deleting local Sessions...');
      try {
        final storage = DeviceScopedStorageService.instance;
        final keys = await storage.getAllKeys(
          'peerwaveSignalSessions',
          'peerwaveSignalSessions',
        );
        for (final key in keys) {
          await storage.deleteEncrypted(
            'peerwaveSignalSessions',
            'peerwaveSignalSessions',
            key,
          );
        }
        debugPrint(
          '[IDENTITY_KEY_STORE] ✓ Local Sessions deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_KEY_STORE] Warning: Could not clear Sessions from device-scoped storage: $e',
        );
      }

      // 4. Delete all local SenderKeys
      debugPrint('[IDENTITY_KEY_STORE] Deleting local SenderKeys...');
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
        debugPrint(
          '[IDENTITY_KEY_STORE] ✓ Local SenderKeys deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_KEY_STORE] Warning: Could not clear SenderKeys from device-scoped storage: $e',
        );
      }

      // 5. Request server-side deletion of all keys
      debugPrint('[IDENTITY_KEY_STORE] Requesting server-side key deletion...');
      try {
        // Use REST API to delete all keys
        final response = await apiService.delete('/api/signal/keys');
        if (response.statusCode == 200) {
          debugPrint('[IDENTITY_KEY_STORE] ✓ Server keys deleted via REST API');
        } else {
          debugPrint(
            '[IDENTITY_KEY_STORE] ⚠️ Failed to delete server keys: ${response.statusCode}',
          );
        }
      } catch (e) {
        debugPrint(
          '[IDENTITY_KEY_STORE] Warning: Could not request server deletion: $e',
        );
      }

      debugPrint('[IDENTITY_KEY_STORE] ✅ Cleanup completed successfully');
      debugPrint(
        '[IDENTITY_KEY_STORE] ⚠️  NOTE: All encrypted sessions are now invalid',
      );
      debugPrint(
        '[IDENTITY_KEY_STORE] ⚠️  NOTE: Users will need to re-establish sessions',
      );
    } catch (e, stackTrace) {
      debugPrint('[IDENTITY_KEY_STORE] ❌ ERROR during cleanup: $e');
      debugPrint('[IDENTITY_KEY_STORE] Stack trace: $stackTrace');
      // Continue anyway - better to have partial cleanup than to block identity generation
    }
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction? direction,
  ) async {
    final trusted = await getIdentity(address);
    if (identityKey == null) {
      debugPrint(
        '[IDENTITY_KEY_STORE] isTrustedIdentity: identityKey is null for ${address.getName()}:${address.getDeviceId()}',
      );
      return false;
    }

    if (trusted == null) {
      debugPrint(
        '[IDENTITY_KEY_STORE] isTrustedIdentity: No stored identity for ${address.getName()}:${address.getDeviceId()} - TRUSTING new key (first contact)',
      );
      return true; // First contact - trust the key
    }

    final trustedBytes = trusted.serialize();
    final providedBytes = identityKey.serialize();
    final matches = const ListEquality().equals(trustedBytes, providedBytes);

    if (!matches) {
      debugPrint('[IDENTITY_KEY_STORE] ⚠️ UNTRUSTED IDENTITY DETECTED!');
      debugPrint(
        '[IDENTITY_KEY_STORE] Address: ${address.getName()}:${address.getDeviceId()}',
      );
      debugPrint(
        '[IDENTITY_KEY_STORE] Stored identity:  ${base64Encode(trustedBytes)}',
      );
      debugPrint(
        '[IDENTITY_KEY_STORE] Provided identity: ${base64Encode(providedBytes)}',
      );
      debugPrint(
        '[IDENTITY_KEY_STORE] This indicates the peer regenerated their keys!',
      );
    }

    return matches;
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) {
      return false;
    }
    final existing = await getIdentity(address);
    if (existing == null ||
        !const ListEquality().equals(
          existing.serialize(),
          identityKey.serialize(),
        )) {
      final encoded = base64Encode(identityKey.serialize());

      if (existing != null) {
        debugPrint(
          '[IDENTITY_KEY_STORE] ⚠️ IDENTITY KEY CHANGED for ${address.getName()}:${address.getDeviceId()}',
        );
        debugPrint(
          '[IDENTITY_KEY_STORE] Old key: ${base64Encode(existing.serialize())}',
        );
        debugPrint('[IDENTITY_KEY_STORE] New key: $encoded');
        debugPrint(
          '[IDENTITY_KEY_STORE] This will invalidate existing sessions!',
        );
      } else {
        debugPrint(
          '[IDENTITY_KEY_STORE] ✓ Storing NEW identity for ${address.getName()}:${address.getDeviceId()}',
        );
        debugPrint('[IDENTITY_KEY_STORE] Identity key: $encoded');
      }

      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      await storage.storeEncrypted(
        _storeName,
        _storeName,
        _identityKey(address),
        encoded,
      );
      return true;
    } else {
      return false;
    }
  }

  /// Remove identity key for a specific remote peer
  ///
  /// Use cases:
  /// - User blocks/removes contact
  /// - Manual identity reset
  /// - Privacy: clear stored keys
  Future<void> removeIdentity(SignalProtocolAddress address) async {
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(
      _storeName,
      _storeName,
      _identityKey(address),
    );
    debugPrint(
      '[IDENTITY_KEY_STORE] ✓ Removed identity for ${address.getName()}:${address.getDeviceId()}',
    );
  }

  /// 🔒 SYNC-LOCK: Acquire lock before regenerating keys
  /// Returns a Future that completes when lock is acquired
  /// Throws TimeoutException if lock cannot be acquired within 30 seconds
  Future<void> acquireLock() async {
    if (_isRegenerating) {
      debugPrint(
        '[IDENTITY_KEY_STORE] 🔒 Regeneration in progress - queuing operation...',
      );
      final completer = Completer<void>();
      _pendingOperations.add(completer);

      // Add timeout to prevent infinite waiting
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[IDENTITY_KEY_STORE] ❌ Lock acquisition timeout!');
          _pendingOperations.remove(completer);
          throw TimeoutException(
            'Failed to acquire identity key lock after 30 seconds',
          );
        },
      );

      debugPrint(
        '[IDENTITY_KEY_STORE] ✓ Lock acquired - proceeding with operation',
      );
    }
    _isRegenerating = true;
  }

  /// 🔒 SYNC-LOCK: Release lock after regeneration completes
  /// Processes all queued operations
  void releaseLock() {
    _isRegenerating = false;
    debugPrint(
      '[IDENTITY_KEY_STORE] 🔓 Lock released - processing ${_pendingOperations.length} queued operations',
    );

    // Complete all pending operations
    for (final completer in _pendingOperations) {
      completer.complete();
    }
    _pendingOperations.clear();
  }

  /// Check if regeneration is in progress
  bool get isRegenerating => _isRegenerating;

  /// Check if identity key pair is loaded in memory cache
  bool get isCached => identityKeyPair != null && localRegistrationId != null;
}
