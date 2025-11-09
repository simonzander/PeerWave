import 'socket_service.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:collection/collection.dart';
import 'device_scoped_storage_service.dart';

/// A persistent identity key store for Signal identities.
/// Uses device-scoped encrypted storage on web and FlutterSecureStorage on native.

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
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_storeName, _storeName, _identityKey(address));
      
      if (value != null) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      }
      return null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _identityKey(address));
      if (value != null) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      } else {
        return null;
      }
    }
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    if (identityKeyPair == null) {
      final identityData = await getIdentityKeyPairData();
      final publicKeyBytes = base64Decode(identityData['publicKey']!);
      final publicKey = Curve.decodePoint(publicKeyBytes, 0);
      final publicIdentityKey = IdentityKey(publicKey);
      final privateKey = Curve.decodePrivatePoint(base64Decode(identityData['privateKey']!));
      identityKeyPair = IdentityKeyPair(publicIdentityKey, privateKey);
      localRegistrationId = int.parse(identityData['registrationId']!);
    }
    return identityKeyPair!;
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
  if (kIsWeb) {
      // 🔒 Use encrypted storage for identity key pair
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
        debugPrint('[IDENTITY] ✓ Loaded encrypted IdentityKeyPair from device-scoped storage');
      }

      // Generate new identity key pair if not found
      if (publicKeyBase64 == null || privateKeyBase64 == null || registrationId == null) {
        debugPrint('[IDENTITY] ⚠️  CRITICAL: IdentityKeyPair missing - generating NEW keys!');
        debugPrint('[IDENTITY] This will invalidate all existing encrypted sessions.');
        
        // 🔒 ACQUIRE LOCK: Prevent concurrent regeneration
        await acquireLock();
        try {
          final generated = await _generateIdentityKeyPair();
          publicKeyBase64 = generated['publicKey'];
          privateKeyBase64 = generated['privateKey'];
          registrationId = generated['registrationId'];
          
          // 🔒 Store encrypted identity key pair
          await storage.putEncrypted(
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
        
        SocketService().emit("signalIdentity", {
          'publicKey': publicKeyBase64,
          'registrationId': registrationId,
        });
      }
      return {
        'publicKey': publicKeyBase64,
        'privateKey': privateKeyBase64,
        'registrationId': registrationId,
      };
  } else {
      final storage = FlutterSecureStorage();
      var publicKeyBase64 = await storage.read(key: "publicKey");
      var privateKeyBase64 = await storage.read(key: "privateKey");
      var regIdObj = await storage.read(key: "registrationId");
      var registrationId = regIdObj?.toString();

      if (publicKeyBase64 == null || privateKeyBase64 == null || registrationId == null) {
        debugPrint('[IDENTITY] ⚠️  CRITICAL: IdentityKeyPair missing - generating NEW keys!');
        debugPrint('[IDENTITY] This will invalidate all existing encrypted sessions.');
        
        // 🔒 ACQUIRE LOCK: Prevent concurrent regeneration
        await acquireLock();
        try {
          final generated = await _generateIdentityKeyPair();
          publicKeyBase64 = generated['publicKey'];
          privateKeyBase64 = generated['privateKey'];
          registrationId = generated['registrationId'];
          await storage.write(key: "publicKey", value: publicKeyBase64);
          await storage.write(key: "privateKey", value: privateKeyBase64);
          await storage.write(key: "registrationId", value: registrationId);
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
        
        SocketService().emit("signalIdentity", {
          'publicKey': publicKeyBase64,
          'registrationId': registrationId,
        });
      }
      return {
        'publicKey': publicKeyBase64,
        'privateKey': privateKeyBase64,
        'registrationId': registrationId,
      };
    }
  }

  Future<Map<String, String>> _generateIdentityKeyPair() async {
    final identityKeyPair = generateIdentityKeyPair();
    final publicKeyBase64 = base64Encode(identityKeyPair.getPublicKey().serialize());
    final privateKeyBase64 = base64Encode(identityKeyPair.getPrivateKey().serialize());
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
      if (kIsWeb) {
        try {
          final storage = DeviceScopedStorageService.instance;
          final keys = await storage.getAllKeys('peerwaveSignalPreKeys', 'peerwaveSignalPreKeys');
          for (final key in keys) {
            await storage.deleteEncrypted('peerwaveSignalPreKeys', 'peerwaveSignalPreKeys', key);
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local PreKeys deleted from device-scoped storage');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear PreKeys from device-scoped storage: $e');
        }
      } else {
        try {
          final storage = FlutterSecureStorage();
          final allKeys = await storage.readAll();
          for (final key in allKeys.keys) {
            if (key.startsWith('prekey_')) {
              await storage.delete(key: key);
            }
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local PreKeys deleted (SecureStorage)');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear PreKeys from SecureStorage: $e');
        }
      }
      
      // 2. Delete all local SignedPreKeys
      debugPrint('[IDENTITY_CLEANUP] Deleting local SignedPreKeys...');
      if (kIsWeb) {
        try {
          final storage = DeviceScopedStorageService.instance;
          final keys = await storage.getAllKeys('peerwaveSignalSignedPreKeys', 'peerwaveSignalSignedPreKeys');
          for (final key in keys) {
            await storage.deleteEncrypted('peerwaveSignalSignedPreKeys', 'peerwaveSignalSignedPreKeys', key);
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local SignedPreKeys deleted from device-scoped storage');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear SignedPreKeys from device-scoped storage: $e');
        }
      } else {
        try {
          final storage = FlutterSecureStorage();
          final allKeys = await storage.readAll();
          for (final key in allKeys.keys) {
            if (key.startsWith('signedprekey_')) {
              await storage.delete(key: key);
            }
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local SignedPreKeys deleted (SecureStorage)');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear SignedPreKeys from SecureStorage: $e');
        }
      }
      
      // 3. Delete all local Sessions
      debugPrint('[IDENTITY_CLEANUP] Deleting local Sessions...');
      if (kIsWeb) {
        try {
          final storage = DeviceScopedStorageService.instance;
          final keys = await storage.getAllKeys('peerwaveSignalSessions', 'peerwaveSignalSessions');
          for (final key in keys) {
            await storage.deleteEncrypted('peerwaveSignalSessions', 'peerwaveSignalSessions', key);
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local Sessions deleted from device-scoped storage');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear Sessions from device-scoped storage: $e');
        }
      } else {
        try {
          final storage = FlutterSecureStorage();
          final allKeys = await storage.readAll();
          for (final key in allKeys.keys) {
            if (key.startsWith('session_')) {
              await storage.delete(key: key);
            }
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local Sessions deleted (SecureStorage)');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear Sessions from SecureStorage: $e');
        }
      }
      
      // 4. Delete all local SenderKeys
      debugPrint('[IDENTITY_CLEANUP] Deleting local SenderKeys...');
      if (kIsWeb) {
        try {
          final storage = DeviceScopedStorageService.instance;
          final keys = await storage.getAllKeys('peerwaveSenderKeys', 'peerwaveSenderKeys');
          for (final key in keys) {
            await storage.deleteEncrypted('peerwaveSenderKeys', 'peerwaveSenderKeys', key);
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local SenderKeys deleted from device-scoped storage');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear SenderKeys from device-scoped storage: $e');
        }
      } else {
        try {
          final storage = FlutterSecureStorage();
          final allKeys = await storage.readAll();
          for (final key in allKeys.keys) {
            if (key.startsWith('senderkey_')) {
              await storage.delete(key: key);
            }
          }
          debugPrint('[IDENTITY_CLEANUP] ✓ Local SenderKeys deleted (SecureStorage)');
        } catch (e) {
          debugPrint('[IDENTITY_CLEANUP] Warning: Could not clear SenderKeys from SecureStorage: $e');
        }
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
        debugPrint('[IDENTITY_CLEANUP] Warning: Could not request server deletion: $e');
      }
      
      debugPrint('[IDENTITY_CLEANUP] ✅ Cleanup completed successfully');
      debugPrint('[IDENTITY_CLEANUP] ⚠️  NOTE: All encrypted sessions are now invalid');
      debugPrint('[IDENTITY_CLEANUP] ⚠️  NOTE: Users will need to re-establish sessions');
      
    } catch (e, stackTrace) {
      debugPrint('[IDENTITY_CLEANUP] ❌ ERROR during cleanup: $e');
      debugPrint('[IDENTITY_CLEANUP] Stack trace: $stackTrace');
      // Continue anyway - better to have partial cleanup than to block identity generation
    }
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address,
      IdentityKey? identityKey, Direction? direction) async {
    final trusted = await getIdentity(address);
    if (identityKey == null) {
      return false;
    }
    return trusted == null ||
        const ListEquality().equals(trusted.serialize(), identityKey.serialize());
  }

  @override
  Future<bool> saveIdentity(
      SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) {
      return false;
    }
    final existing = await getIdentity(address);
    if (existing == null || !const ListEquality().equals(existing.serialize(), identityKey.serialize())) {
      final encoded = base64Encode(identityKey.serialize());
      if (kIsWeb) {
        // Use encrypted device-scoped storage
        final storage = DeviceScopedStorageService.instance;
        await storage.putEncrypted(_storeName, _storeName, _identityKey(address), encoded);
      } else {
        final storage = FlutterSecureStorage();
        await storage.write(key: _identityKey(address), value: encoded);
      }
      return true;
    } else {
      return false;
    }
  }

  /// 🔒 SYNC-LOCK: Acquire lock before regenerating keys
  /// Returns a Future that completes when lock is acquired
  Future<void> acquireLock() async {
    if (_isRegenerating) {
      debugPrint('[IDENTITY_LOCK] 🔒 Regeneration in progress - queuing operation...');
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
    debugPrint('[IDENTITY_LOCK] 🔓 Lock released - processing ${_pendingOperations.length} queued operations');
    
    // Complete all pending operations
    for (final completer in _pendingOperations) {
      completer.complete();
    }
    _pendingOperations.clear();
  }

  /// Check if regeneration is in progress
  bool get isRegenerating => _isRegenerating;
}

