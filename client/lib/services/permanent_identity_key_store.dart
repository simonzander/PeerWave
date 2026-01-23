import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:collection/collection.dart';
import 'device_scoped_storage_service.dart';

/// A persistent identity key store for Signal identities.
/// Uses encrypted device-scoped storage (IndexedDB on web, native platform storage on Windows/macOS/Linux).

class PermanentIdentityKeyStore extends IdentityKeyStore {
  final String _storeName = 'peerwaveSignalIdentityKeys';
  final String _keyPrefix = 'identity_';
  IdentityKeyPair? identityKeyPair;
  int? localRegistrationId;

  // 🔒 SYNC-LOCK: Prevent race conditions during key regeneration
  bool _isRegenerating = false;
  final List<Completer<void>> _pendingOperations = [];

  PermanentIdentityKeyStore();

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

  /// Get identity key for a specific server (multi-server support)
  Future<IdentityKey?> getIdentityForServer(
    SignalProtocolAddress address,
    String serverUrl,
  ) async {
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(
      _storeName,
      _storeName,
      _identityKey(address),
      serverUrl: serverUrl,
    );

    if (value != null) {
      return IdentityKey.fromBytes(base64Decode(value), 0);
    }
    return null;
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    if (identityKeyPair == null) {
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

  /// Get identity key pair for a specific server (multi-server support)
  Future<IdentityKeyPair> getIdentityKeyPairForServer(String serverUrl) async {
    final identityData = await getIdentityKeyPairDataForServer(serverUrl);
    final publicKeyBytes = base64Decode(identityData['publicKey']!);
    final publicKey = Curve.decodePoint(publicKeyBytes, 0);
    final publicIdentityKey = IdentityKey(publicKey);
    final privateKey = Curve.decodePrivatePoint(
      base64Decode(identityData['privateKey']!),
    );
    return IdentityKeyPair(publicIdentityKey, privateKey);
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
        '[IDENTITY] ✓ Loaded encrypted IdentityKeyPair from device-scoped storage',
      );
    }

    // Generate new identity key pair if not found
    if (publicKeyBase64 == null ||
        privateKeyBase64 == null ||
        registrationId == null) {
      debugPrint(
        '[IDENTITY] ⚠️  CRITICAL: IdentityKeyPair missing - generating NEW keys!',
      );
      debugPrint(
        '[IDENTITY] This will invalidate all existing encrypted sessions.',
      );

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
      } finally {
        // 🔓 RELEASE LOCK: Even if error occurs
        releaseLock();
      }
    }

    if (createdNew) {
      // CRITICAL: Clean up all dependent keys before uploading new identity
      debugPrint('[IDENTITY] Cleaning up ALL dependent keys...');
      await _cleanupDependentKeys();

      debugPrint('[IDENTITY] Uploading NEW identity key to server...');

      // Try socket emit first (faster)
      if (SocketService().isConnected) {
        debugPrint('[IDENTITY] Socket connected - using emit');
        SocketService().emit("signalIdentity", {
          'publicKey': publicKeyBase64,
          'registrationId': registrationId,
        });
      } else {
        debugPrint(
          '[IDENTITY] ⚠️ Socket NOT connected - identity update may be lost!',
        );
        debugPrint(
          '[IDENTITY] Server will have STALE identity key until next socket connection!',
        );
        // TODO: Add HTTP fallback endpoint to ensure identity is always updated
      }
    }

    return {
      'publicKey': publicKeyBase64,
      'privateKey': privateKeyBase64,
      'registrationId': registrationId,
    };
  }

  /// Loads identity key pair data for a specific server (multi-server support)
  Future<Map<String, String?>> getIdentityKeyPairDataForServer(
    String serverUrl,
  ) async {
    final storage = DeviceScopedStorageService.instance;
    final encryptedData = await storage.getDecrypted(
      'peerwaveSignal',
      'identityKeyPair',
      'identityKeyPair',
      serverUrl: serverUrl,
    );

    if (encryptedData != null && encryptedData is Map) {
      final publicKeyBase64 = encryptedData['publicKey'] as String?;
      final privateKeyBase64 = encryptedData['privateKey'] as String?;
      var regIdObj = encryptedData['registrationId'];
      final registrationId = regIdObj?.toString();

      if (publicKeyBase64 != null &&
          privateKeyBase64 != null &&
          registrationId != null) {
        return {
          'publicKey': publicKeyBase64,
          'privateKey': privateKeyBase64,
          'registrationId': registrationId,
        };
      }
    }

    throw Exception('No identity key pair found for server: $serverUrl');
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
      debugPrint('[IDENTITY_CLEANUP] Starting cleanup of dependent keys...');

      // 1. Delete all local PreKeys
      debugPrint('[IDENTITY_CLEANUP] Deleting local PreKeys...');
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
          '[IDENTITY_CLEANUP] ✓ Local PreKeys deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_CLEANUP] Warning: Could not clear PreKeys from device-scoped storage: $e',
        );
      }

      // 2. Delete all local SignedPreKeys
      debugPrint('[IDENTITY_CLEANUP] Deleting local SignedPreKeys...');
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
          '[IDENTITY_CLEANUP] ✓ Local SignedPreKeys deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_CLEANUP] Warning: Could not clear SignedPreKeys from device-scoped storage: $e',
        );
      }

      // 3. Delete all local Sessions
      debugPrint('[IDENTITY_CLEANUP] Deleting local Sessions...');
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
          '[IDENTITY_CLEANUP] ✓ Local Sessions deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_CLEANUP] Warning: Could not clear Sessions from device-scoped storage: $e',
        );
      }

      // 4. Delete all local SenderKeys
      debugPrint('[IDENTITY_CLEANUP] Deleting local SenderKeys...');
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
          '[IDENTITY_CLEANUP] ✓ Local SenderKeys deleted from device-scoped storage',
        );
      } catch (e) {
        debugPrint(
          '[IDENTITY_CLEANUP] Warning: Could not clear SenderKeys from device-scoped storage: $e',
        );
      }

      // 5. Request server-side deletion of all keys
      debugPrint('[IDENTITY_CLEANUP] Requesting server-side key deletion...');
      try {
        SocketService().emit("deleteAllSignalKeys", {
          'reason': 'IdentityKeyPair regenerated',
          'timestamp': DateTime.now().toIso8601String(),
        });
        debugPrint('[IDENTITY_CLEANUP] ✓ Server deletion requested');
      } catch (e) {
        debugPrint(
          '[IDENTITY_CLEANUP] Warning: Could not request server deletion: $e',
        );
      }

      debugPrint('[IDENTITY_CLEANUP] ✅ Cleanup completed successfully');
      debugPrint(
        '[IDENTITY_CLEANUP] ⚠️  NOTE: All encrypted sessions are now invalid',
      );
      debugPrint(
        '[IDENTITY_CLEANUP] ⚠️  NOTE: Users will need to re-establish sessions',
      );
    } catch (e, stackTrace) {
      debugPrint('[IDENTITY_CLEANUP] ❌ ERROR during cleanup: $e');
      debugPrint('[IDENTITY_CLEANUP] Stack trace: $stackTrace');
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
        '[IDENTITY] isTrustedIdentity: identityKey is null for ${address.getName()}:${address.getDeviceId()}',
      );
      return false;
    }

    if (trusted == null) {
      debugPrint(
        '[IDENTITY] isTrustedIdentity: No stored identity for ${address.getName()}:${address.getDeviceId()} - TRUSTING new key (first contact)',
      );
      return true; // First contact - trust the key
    }

    final trustedBytes = trusted.serialize();
    final providedBytes = identityKey.serialize();
    final matches = const ListEquality().equals(trustedBytes, providedBytes);

    if (!matches) {
      debugPrint('[IDENTITY] ⚠️ UNTRUSTED IDENTITY DETECTED!');
      debugPrint(
        '[IDENTITY] Address: ${address.getName()}:${address.getDeviceId()}',
      );
      debugPrint('[IDENTITY] Stored identity:  ${base64Encode(trustedBytes)}');
      debugPrint(
        '[IDENTITY] Provided identity: ${base64Encode(providedBytes)}',
      );
      debugPrint('[IDENTITY] This indicates the peer regenerated their keys!');
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
          '[IDENTITY] ⚠️ IDENTITY KEY CHANGED for ${address.getName()}:${address.getDeviceId()}',
        );
        debugPrint('[IDENTITY] Old key: ${base64Encode(existing.serialize())}');
        debugPrint('[IDENTITY] New key: $encoded');
        debugPrint('[IDENTITY] This will invalidate existing sessions!');
      } else {
        debugPrint(
          '[IDENTITY] ✓ Storing NEW identity for ${address.getName()}:${address.getDeviceId()}',
        );
        debugPrint('[IDENTITY] Identity key: $encoded');
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

  /// 🔒 SYNC-LOCK: Acquire lock before regenerating keys
  /// Returns a Future that completes when lock is acquired
  Future<void> acquireLock() async {
    if (_isRegenerating) {
      debugPrint(
        '[IDENTITY_LOCK] 🔒 Regeneration in progress - queuing operation...',
      );
      final completer = Completer<void>();
      _pendingOperations.add(completer);
      await completer.future;
      debugPrint('[IDENTITY_LOCK] ✓ Lock acquired - proceeding with operation');
    }
    _isRegenerating = true;
  }

  /// 🔒 SYNC-LOCK: Release lock after regeneration completes
  /// Processes all queued operations
  void releaseLock() {
    _isRegenerating = false;
    debugPrint(
      '[IDENTITY_LOCK] 🔓 Lock released - processing ${_pendingOperations.length} queued operations',
    );

    // Complete all pending operations
    for (final completer in _pendingOperations) {
      completer.complete();
    }
    _pendingOperations.clear();
  }

  /// Check if regeneration is in progress
  bool get isRegenerating => _isRegenerating;
}
