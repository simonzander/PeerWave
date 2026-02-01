import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'device_scoped_storage_service.dart';
import 'api_service.dart';
import '../core/metrics/key_management_metrics.dart';

/// Wrapper for a signed pre-key and its metadata.
class StoredSignedPreKey {
  final SignedPreKeyRecord record;
  final DateTime? createdAt;
  StoredSignedPreKey({required this.record, this.createdAt});
}

/// A persistent signed pre-key store for Signal signed pre-keys.
/// Uses encrypted device-scoped storage (IndexedDB on web, native platform storage on Windows/macOS/Linux).
class PermanentSignedPreKeyStore extends SignedPreKeyStore {
  /// Loads a signed prekey and its metadata (createdAt).
  Future<StoredSignedPreKey?> loadStoredSignedPreKey(int signedPreKeyId) async {
    if (await containsSignedPreKey(signedPreKeyId)) {
      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(
        _storeName,
        _storeName,
        _signedPreKey(signedPreKeyId),
      );
      final metaValue = await storage.getDecrypted(
        _storeName,
        _storeName,
        _signedPreKeyMeta(signedPreKeyId),
      );

      SignedPreKeyRecord? record;
      if (value is String) {
        record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
      } else if (value is Uint8List) {
        record = SignedPreKeyRecord.fromSerialized(value);
      } else {
        throw Exception('Invalid signed prekey data');
      }
      DateTime? createdAt;
      if (metaValue is String) {
        var meta = jsonDecode(metaValue);
        if (meta is Map && meta['createdAt'] != null) {
          createdAt = DateTime.parse(meta['createdAt']);
        }
      }
      return StoredSignedPreKey(record: record, createdAt: createdAt);
    } else {
      return null;
    }
  }

  /// Loads all signed prekeys and their metadata.
  Future<List<StoredSignedPreKey>> loadAllStoredSignedPreKeys() async {
    final results = <StoredSignedPreKey>[];
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    var keys = await storage.getAllKeys(_storeName, _storeName);

    for (var key in keys) {
      if (key.startsWith(_keyPrefix) && !key.endsWith('_meta')) {
        var value = await storage.getDecrypted(_storeName, _storeName, key);
        if (value != null) {
          SignedPreKeyRecord? record;
          if (value is String) {
            record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
          } else if (value is Uint8List) {
            record = SignedPreKeyRecord.fromSerialized(value);
          }
          if (record != null) {
            var metaKey = '${key}_meta';
            var metaValue = await storage.getDecrypted(
              _storeName,
              _storeName,
              metaKey,
            );
            DateTime? createdAt;
            if (metaValue is String) {
              var meta = jsonDecode(metaValue);
              if (meta is Map && meta['createdAt'] != null) {
                createdAt = DateTime.parse(meta['createdAt']);
              }
            }
            results.add(
              StoredSignedPreKey(record: record, createdAt: createdAt),
            );
          }
        }
      }
    }
    return results;
  }

  final IdentityKeyPair identityKeyPair;

  final String _storeName = 'peerwaveSignalSignedPreKeys';
  final String _keyPrefix = 'signedprekey_';

  PermanentSignedPreKeyStore(this.identityKeyPair) {
    // Listen for incoming signed prekeys from server
    SocketService.instance.registerListener("getSignedPreKeysResponse", (
      data,
    ) async {
      // Server does not store private keys; nothing to reconstruct here.
      if (data.isEmpty) {
        debugPrint("No signed pre keys found, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
    }, registrationName: 'SignedPreKeyStore');
    // check if we have any signed prekeys, if not create one
    loadAllStoredSignedPreKeys().then((keys) async {
      if (keys.isEmpty) {
        debugPrint("No signed pre keys found locally, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
        return;
      }

      // Sort by createdAt (newest first)
      keys.sort((a, b) {
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      final newest = keys.first;
      debugPrint(
        '[SIGNED_PREKEY_SETUP] Found ${keys.length} local signed prekeys, newest ID: ${newest.record.id}',
      );

      // Check if the NEWEST signed prekey is older than 7 days
      final createdAt = newest.createdAt;
      if (createdAt != null &&
          DateTime.now().difference(createdAt).inDays > 7) {
        debugPrint(
          '[SIGNED_PREKEY_SETUP] Newest key is ${DateTime.now().difference(createdAt).inDays} days old - rotating',
        );
        var newPreSignedKey = generateSignedPreKey(
          identityKeyPair,
          keys.length,
        );
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
        // Re-fetch keys after rotation
        keys = await loadAllStoredSignedPreKeys();
        keys.sort((a, b) {
          if (a.createdAt == null) return 1;
          if (b.createdAt == null) return -1;
          return b.createdAt!.compareTo(a.createdAt!);
        });
      }

      // Ensure the newest key is uploaded to server (re-upload to be safe)
      debugPrint(
        '[SIGNED_PREKEY_SETUP] Ensuring newest signed prekey (ID ${keys.first.record.id}) is on server',
      );
      await storeSignedPreKey(keys.first.record.id, keys.first.record);

      // Local cleanup: Keep at least 2 keys, delete only those older than 30 days
      // This provides grace period for devices with cached PreKey bundles
      final cutoffDate = DateTime.now().subtract(const Duration(days: 30));
      int localDeleted = 0;

      for (int i = 0; i < keys.length; i++) {
        final key = keys[i];
        // Keep at least 2 keys (newest + 1 backup)
        if (i < 2) continue;

        // Delete only if older than 30 days
        if (key.createdAt != null && key.createdAt!.isBefore(cutoffDate)) {
          debugPrint(
            '[SIGNED_PREKEY_SETUP] Deleting local key ${key.record.id} (${DateTime.now().difference(key.createdAt!).inDays} days old)',
          );
          await _deleteLocalOnly(key.record.id);
          localDeleted++;
        }
      }

      if (localDeleted > 0) {
        debugPrint(
          '[SIGNED_PREKEY_SETUP] ✓ Deleted $localDeleted old local keys',
        );
      }

      // Server cleanup: Remove old signedPreKeys from server IMMEDIATELY
      // This ensures PreKey bundles always use the newest signedPreKey
      // Local keeps grace period (30 days) to decrypt delayed messages
      int serverDeleted = 0;

      for (final key in keys) {
        // Keep newest key always
        if (key.record.id == keys.first.record.id) continue;

        // Delete ALL old keys from server immediately
        debugPrint(
          '[SIGNED_PREKEY_SETUP] Removing old server key: ${key.record.id}',
        );
        SocketService.instance.emit("removeSignedPreKey", <String, dynamic>{
          'id': key.record.id,
        });
        serverDeleted++;
      }

      if (serverDeleted > 0) {
        debugPrint(
          '[SIGNED_PREKEY_SETUP] ✓ Removed $serverDeleted old keys from server',
        );
      }

      debugPrint(
        '[SIGNED_PREKEY_SETUP] ✅ Setup complete: ${keys.length} local keys, 1 server key (newest)',
      );
    });
  }

  String _signedPreKey(int signedPreKeyId) => '$_keyPrefix$signedPreKeyId';
  String _signedPreKeyMeta(int signedPreKeyId) =>
      '$_keyPrefix${signedPreKeyId}_meta';

  Future<void> loadRemoteSignedPreKeys() async {
    SocketService.instance.emit("getSignedPreKeys", null);
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final stored = await loadStoredSignedPreKey(signedPreKeyId);
    if (stored != null) {
      return stored.record;
    } else {
      // SignedPreKey not found - this can happen if:
      // 1. Sender used old PreKey bundle (we deleted the signedPreKey)
      // 2. This is first message - sender just fetched bundle with this ID
      // 3. Device was unregistered/re-registered with same ID
      // 4. Local storage (IndexedDB/native) was cleared but server still has the key
      debugPrint(
        '[SIGNED_PREKEY] ❌ SignedPreKey $signedPreKeyId not found locally',
      );

      // Debug: Show what keys we DO have
      final allKeys = await loadAllStoredSignedPreKeys();
      debugPrint(
        '[SIGNED_PREKEY] Available local keys: ${allKeys.map((k) => k.record.id).toList()}',
      );

      debugPrint(
        '[SIGNED_PREKEY] This usually means sender used cached/stale PreKey bundle',
      );
      throw Exception('No such signedprekeyrecord! $signedPreKeyId');
    }
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    // For compatibility, return only the records (without metadata)
    final stored = await loadAllStoredSignedPreKeys();
    return stored.map((e) => e.record).toList();
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    debugPrint("Storing signed pre key: $signedPreKeyId");
    // Split SignedPreKeyRecord into publicKey and signature for storage
    final publicKey = base64Encode(record.getKeyPair().publicKey.serialize());
    final signature = base64Encode(record.signature);

    // Upload to server with acknowledgment
    try {
      final response = await ApiService.post(
        '/signal/signed-prekey',
        data: {'id': signedPreKeyId, 'data': publicKey, 'signature': signature},
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to upload signed pre key: ${response.statusCode}',
        );
      }

      debugPrint('[SIGNED_PRE_KEY_STORE] ✓ Signed pre key uploaded to server');
    } catch (e) {
      debugPrint('[SIGNED_PRE_KEY_STORE] Error uploading signed pre key: $e');
      rethrow;
    }

    // CRITICAL: After uploading new key, delete ALL other keys from server
    // This ensures server always advertises only the newest signedPreKey
    final allKeys = await loadAllStoredSignedPreKeys();
    for (final key in allKeys) {
      if (key.record.id != signedPreKeyId) {
        debugPrint(
          "[SIGNED_PREKEY] Auto-cleanup: Removing old server key ${key.record.id} (keeping only $signedPreKeyId)",
        );
        SocketService.instance.emit("removeSignedPreKey", <String, dynamic>{
          'id': key.record.id,
        });
      }
    }

    final serialized = record.serialize();
    final createdAt = DateTime.now().toIso8601String();
    final meta = jsonEncode({'createdAt': createdAt});

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.storeEncrypted(
      _storeName,
      _storeName,
      _signedPreKey(signedPreKeyId),
      base64Encode(serialized),
    );
    await storage.storeEncrypted(
      _storeName,
      _storeName,
      _signedPreKeyMeta(signedPreKeyId),
      meta,
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    var value = await storage.getDecrypted(
      _storeName,
      _storeName,
      _signedPreKey(signedPreKeyId),
    );
    return value != null;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    debugPrint("Removing signed pre key: $signedPreKeyId");
    SocketService.instance.emit("removeSignedPreKey", <String, dynamic>{
      'id': signedPreKeyId,
    });

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(
      _storeName,
      _storeName,
      _signedPreKey(signedPreKeyId),
    );
    await storage.deleteEncrypted(
      _storeName,
      _storeName,
      _signedPreKeyMeta(signedPreKeyId),
    );
  }

  /// Delete signed prekey from local storage only (not from server)
  /// Used during cleanup when we want to keep keys on server for grace period
  Future<void> _deleteLocalOnly(int signedPreKeyId) async {
    debugPrint(
      "[SIGNED_PREKEY_CLEANUP] Deleting local signed pre key: $signedPreKeyId",
    );
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(
      _storeName,
      _storeName,
      _signedPreKey(signedPreKeyId),
    );
    await storage.deleteEncrypted(
      _storeName,
      _storeName,
      _signedPreKeyMeta(signedPreKeyId),
    );
  }

  /// Check if SignedPreKey needs rotation (older than 7 days)
  /// Returns true if rotation is needed
  Future<bool> needsRotation() async {
    try {
      final allKeys = await loadAllStoredSignedPreKeys();
      if (allKeys.isEmpty) {
        debugPrint('[SIGNED_PREKEY_ROTATION] No SignedPreKeys found');
        return false;
      }

      // Find the newest key
      allKeys.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      final newestKey = allKeys.first;
      if (newestKey.createdAt == null) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] Newest key has no createdAt timestamp, assuming rotation needed',
        );
        return true;
      }

      final daysSinceCreation = DateTime.now()
          .difference(newestKey.createdAt!)
          .inDays;
      debugPrint(
        '[SIGNED_PREKEY_ROTATION] Newest SignedPreKey is $daysSinceCreation days old',
      );

      if (daysSinceCreation >= 7) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] ⚠️  SignedPreKey needs rotation (>= 7 days old)',
        );
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[SIGNED_PREKEY_ROTATION] Error checking rotation: $e');
      return false;
    }
  }

  /// Rotate SignedPreKey: Generate new key and apply cleanup strategy
  ///
  /// This ensures that:
  /// - New PreKeyBundles use the new SignedPreKey
  /// - Server gets only the newest key (old ones removed immediately)
  /// - Local keeps at least 2 keys for grace period
  /// - Very old keys (>30 days) are deleted locally
  Future<void> rotateSignedPreKey(IdentityKeyPair identityKeyPair) async {
    try {
      debugPrint('[SIGNED_PREKEY_ROTATION] Starting SignedPreKey rotation...');

      var allKeys = await loadAllStoredSignedPreKeys();
      final nextId = allKeys.isEmpty
          ? 0
          : allKeys.map((k) => k.record.id).reduce((a, b) => a > b ? a : b) + 1;

      // Generate new SignedPreKey
      debugPrint(
        '[SIGNED_PREKEY_ROTATION] Generating new SignedPreKey with ID $nextId',
      );
      final newSignedPreKey = generateSignedPreKey(identityKeyPair, nextId);

      // Store new SignedPreKey (automatically uploads to server)
      await storeSignedPreKey(newSignedPreKey.id, newSignedPreKey);

      // Track metrics for diagnostics
      KeyManagementMetrics.recordSignedPreKeyRotation(isScheduled: true);

      debugPrint(
        '[SIGNED_PREKEY_ROTATION] ✓ New SignedPreKey generated and stored',
      );

      // Re-fetch keys after rotation to get updated list
      allKeys = await loadAllStoredSignedPreKeys();
      allKeys.sort((a, b) {
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      // Local cleanup: Keep at least 2 keys, delete only those older than 30 days
      int localDeleted = 0;
      final cutoffDate = DateTime.now().subtract(const Duration(days: 30));

      for (int i = 0; i < allKeys.length; i++) {
        final key = allKeys[i];
        // Keep at least 2 keys (newest + 1 backup)
        if (i < 2) continue;

        // Delete only if older than 30 days
        if (key.createdAt != null && key.createdAt!.isBefore(cutoffDate)) {
          debugPrint(
            '[SIGNED_PREKEY_ROTATION] Deleting local key ${key.record.id} (${DateTime.now().difference(key.createdAt!).inDays} days old)',
          );
          await _deleteLocalOnly(key.record.id);
          localDeleted++;
        }
      }

      if (localDeleted > 0) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] ✓ Deleted $localDeleted old local keys',
        );
      }

      // Server cleanup: Remove old signedPreKeys from server IMMEDIATELY
      int serverDeleted = 0;

      for (final key in allKeys) {
        // Keep newest key always
        if (key.record.id == allKeys.first.record.id) continue;

        // Delete ALL old keys from server immediately
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] Removing old server key: ${key.record.id}',
        );
        SocketService.instance.emit("removeSignedPreKey", <String, dynamic>{
          'id': key.record.id,
        });
        serverDeleted++;
      }

      if (serverDeleted > 0) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] ✓ Removed $serverDeleted old keys from server',
        );
      }

      debugPrint(
        '[SIGNED_PREKEY_ROTATION] ✅ Rotation complete: ${allKeys.length} local keys, 1 server key (newest)',
      );
    } catch (e, stackTrace) {
      debugPrint('[SIGNED_PREKEY_ROTATION] ❌ ERROR during rotation: $e');
      debugPrint('[SIGNED_PREKEY_ROTATION] Stack trace: $stackTrace');
      rethrow;
    }
  }
}
