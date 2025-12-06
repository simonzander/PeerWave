import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'device_scoped_storage_service.dart';

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
    SocketService().registerListener("getSignedPreKeysResponse", (data) async {
      // Server does not store private keys; nothing to reconstruct here.
      if (data.isEmpty) {
        debugPrint("No signed pre keys found, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
    });
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

      // Check if the NEWEST signed prekey is older than 7 days
      final newest = keys.first;
      final createdAt = newest.createdAt;
      if (createdAt != null &&
          DateTime.now().difference(createdAt).inDays > 7) {
        debugPrint(
          "Found expired signed pre key (older than 7 days), creating new one",
        );
        var newPreSignedKey = generateSignedPreKey(
          identityKeyPair,
          keys.length,
        );
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }

      // Delete all old signed prekeys except the newest one
      for (int i = 1; i < keys.length; i++) {
        debugPrint("Removing old signed pre key: ${keys[i].record.id}");
        await removeSignedPreKey(keys[i].record.id);
      }
    });
  }

  String _signedPreKey(int signedPreKeyId) => '$_keyPrefix$signedPreKeyId';
  String _signedPreKeyMeta(int signedPreKeyId) =>
      '$_keyPrefix${signedPreKeyId}_meta';

  Future<void> loadRemoteSignedPreKeys() async {
    SocketService().emit("getSignedPreKeys", null);
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final stored = await loadStoredSignedPreKey(signedPreKeyId);
    if (stored != null) {
      return stored.record;
    } else {
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

    // Optionally, you can still store the full serialized record for compatibility
    SocketService().emit("storeSignedPreKey", {
      'id': signedPreKeyId,
      'data': publicKey,
      "signature": signature,
    });
    final serialized = record.serialize();
    final createdAt = DateTime.now().toIso8601String();
    final meta = jsonEncode({'createdAt': createdAt});

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.putEncrypted(
      _storeName,
      _storeName,
      _signedPreKey(signedPreKeyId),
      base64Encode(serialized),
    );
    await storage.putEncrypted(
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
    SocketService().emit("removeSignedPreKey", {'id': signedPreKeyId});

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

  /// Rotate SignedPreKey: Generate new key and keep old one for 7 days
  ///
  /// This ensures that:
  /// - New PreKeyBundles use the new SignedPreKey
  /// - Existing sessions can still use old SignedPreKey for a grace period
  /// - Old keys are automatically cleaned up after 7 days
  Future<void> rotateSignedPreKey(IdentityKeyPair identityKeyPair) async {
    try {
      debugPrint('[SIGNED_PREKEY_ROTATION] Starting SignedPreKey rotation...');

      final allKeys = await loadAllStoredSignedPreKeys();
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
      debugPrint(
        '[SIGNED_PREKEY_ROTATION] ✓ New SignedPreKey generated and stored',
      );

      // Clean up old keys (older than 30 days)
      // Keep 30 days to ensure pending messages can still be decrypted
      // even if someone fetched PreKeyBundle long ago but sent message later
      int deletedCount = 0;
      final cutoffDate = DateTime.now().subtract(const Duration(days: 30));

      for (final key in allKeys) {
        if (key.createdAt != null && key.createdAt!.isBefore(cutoffDate)) {
          debugPrint(
            '[SIGNED_PREKEY_ROTATION] Deleting old SignedPreKey ID ${key.record.id} (created ${key.createdAt})',
          );
          await removeSignedPreKey(key.record.id);
          deletedCount++;
        }
      }

      if (deletedCount > 0) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] ✓ Deleted $deletedCount old SignedPreKeys',
        );
      } else {
        debugPrint('[SIGNED_PREKEY_ROTATION] No old SignedPreKeys to delete');
      }

      debugPrint(
        '[SIGNED_PREKEY_ROTATION] ✅ SignedPreKey rotation completed successfully',
      );
    } catch (e, stackTrace) {
      debugPrint('[SIGNED_PREKEY_ROTATION] ❌ ERROR during rotation: $e');
      debugPrint('[SIGNED_PREKEY_ROTATION] Stack trace: $stackTrace');
      rethrow;
    }
  }
}
