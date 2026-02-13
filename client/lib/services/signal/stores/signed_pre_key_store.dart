import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../device_scoped_storage_service.dart';
import '../../api_service.dart';
import '../state/signed_pre_key_state.dart';

/// A persistent signed pre-key store for Signal signed pre-keys.
/// Uses encrypted device-scoped storage (IndexedDB on web, native platform storage on Windows/macOS/Linux).
///
/// Core Operations:
/// - getSignedPreKey() - Get/ensure fresh signed pre key (auto-generates, auto-rotates, auto-cleans)
/// - generateSignedPreKeyManual({keyId?}) - Manual generation with specific ID
/// - needsRotation() - Check if rotation needed (7+ days old)
/// - rotateSignedPreKey() - Manual rotation
/// - getLatestSignedPreKeyId() - Get current key ID
/// - removeOldSignedPreKeys() - Cleanup old keys
/// - validateServerSignedPreKey() - Server validation and recovery
///
/// 💡 Key Insight: Just call getSignedPreKey() everywhere - it handles everything!
///
/// 🌐 Multi-Server Support:
/// This store is server-scoped via KeyManager.
/// - apiService: Used for HTTP uploads (server-scoped, knows baseUrl)
/// - socketService: Used for real-time events (server-scoped, knows serverUrl)
///
/// Storage isolation is automatic:
/// - DeviceIdentityService provides unique deviceId per server
/// - DeviceScopedStorageService creates isolated databases automatically
mixin PermanentSignedPreKeyStore implements SignedPreKeyStore {
  // Abstract getters - provided by KeyManager
  ApiService get apiService;
  SocketService get socketService;

  /// Identity key pair - must be provided by the class using this mixin
  IdentityKeyPair get identityKeyPair;

  /// State instance for this server - must be provided by KeyManager
  SignedPreKeyState get signedPreKeyState;

  String get _storeName => 'peerwaveSignalSignedPreKeys';
  String get _keyPrefix => 'signedprekey_';

  // ============================================================================
  // CORE STORAGE OPERATIONS (Low-level access)
  // ============================================================================

  /// Load a single signed pre key from storage.
  ///
  /// Returns SignedPreKeyRecord or `null` if key doesn't exist.
  ///
  /// Note: Use [_loadSignedPreKeyMetadata] separately if you need the createdAt timestamp.
  Future<SignedPreKeyRecord?> loadStoredSignedPreKey(int signedPreKeyId) async {
    if (await containsSignedPreKey(signedPreKeyId)) {
      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      dynamic value;
      try {
        value = await storage.getDecrypted(
          _storeName,
          _storeName,
          _signedPreKey(signedPreKeyId),
        );
      } catch (e) {
        debugPrint(
          '[SIGNED_PREKEY] ⚠️ SignedPreKey decrypt failed, purging $signedPreKeyId: $e',
        );
        try {
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
        } catch (deleteError) {
          debugPrint(
            '[SIGNED_PREKEY] Warning: Failed to delete corrupted signed prekey $signedPreKeyId: $deleteError',
          );
        }
        return null;
      }

      SignedPreKeyRecord? record;
      if (value is String) {
        record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
      } else if (value is Uint8List) {
        record = SignedPreKeyRecord.fromSerialized(value);
      } else {
        throw Exception('Invalid signed prekey data');
      }
      return record;
    } else {
      return null;
    }
  }

  /// Load metadata for a signed pre key (internal helper).
  ///
  /// Returns Map with 'createdAt' timestamp, or empty map if not found.
  Future<Map<String, dynamic>> _loadSignedPreKeyMetadata(
    int signedPreKeyId,
  ) async {
    final storage = DeviceScopedStorageService.instance;
    dynamic metaValue;
    try {
      metaValue = await storage.getDecrypted(
        _storeName,
        _storeName,
        _signedPreKeyMeta(signedPreKeyId),
      );
    } catch (e) {
      debugPrint(
        '[SIGNED_PREKEY] ⚠️ SignedPreKey metadata decrypt failed, purging $signedPreKeyId: $e',
      );
      try {
        await storage.deleteEncrypted(
          _storeName,
          _storeName,
          _signedPreKeyMeta(signedPreKeyId),
        );
      } catch (deleteError) {
        debugPrint(
          '[SIGNED_PREKEY] Warning: Failed to delete corrupted metadata $signedPreKeyId: $deleteError',
        );
      }
      return {};
    }

    if (metaValue is String) {
      try {
        final meta = jsonDecode(metaValue);
        if (meta is Map<String, dynamic>) {
          return meta;
        }
      } catch (e) {
        debugPrint('[SIGNED_PREKEY] Error parsing metadata: $e');
      }
    }
    return {};
  }

  /// Load all signed pre keys from storage.
  ///
  /// Returns list of SignedPreKeyRecord objects.
  ///
  /// Used for:
  /// - Finding newest key for rotation checks
  /// - Cleanup operations (identifying old keys)
  /// - Initialization validation
  ///
  /// Note: Use [_loadSignedPreKeyMetadata] separately if you need timestamps.
  Future<List<SignedPreKeyRecord>> loadAllStoredSignedPreKeys() async {
    final results = <SignedPreKeyRecord>[];
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    var keys = await storage.getAllKeys(_storeName, _storeName);

    for (var key in keys) {
      if (key.startsWith(_keyPrefix) && !key.endsWith('_meta')) {
        try {
          var value = await storage.getDecrypted(_storeName, _storeName, key);
          if (value != null) {
            SignedPreKeyRecord? record;
            if (value is String) {
              record = SignedPreKeyRecord.fromSerialized(base64Decode(value));
            } else if (value is Uint8List) {
              record = SignedPreKeyRecord.fromSerialized(value);
            }
            if (record != null) {
              results.add(record);
            }
          }
        } catch (e) {
          debugPrint(
            '[SIGNED_PREKEY] ⚠️ SignedPreKey decrypt failed, purging $key: $e',
          );
          try {
            await storage.deleteEncrypted(_storeName, _storeName, key);
            await storage.deleteEncrypted(
              _storeName,
              _storeName,
              '${key}_meta',
            );
          } catch (deleteError) {
            debugPrint(
              '[SIGNED_PREKEY] Warning: Failed to delete corrupted signed prekey $key: $deleteError',
            );
          }
        }
      }
    }
    return results;
  }

  /// Generate storage key for signed pre key record.
  /// Format: 'signedprekey_{id}'
  String _signedPreKey(int signedPreKeyId) => '$_keyPrefix$signedPreKeyId';

  /// Generate storage key for signed pre key metadata.
  /// Format: 'signedprekey_{id}_meta'
  String _signedPreKeyMeta(int signedPreKeyId) =>
      '$_keyPrefix${signedPreKeyId}_meta';

  /// Initialize signed pre key store - MUST be called after mixin is applied
  ///
  /// This registers socket listeners and performs initial setup:
  /// - Generates initial key if none exist
  /// - Auto-rotates if key is 7+ days old
  /// - Syncs with server
  /// - Keeps max 3 local keys (newest + 2 backups)
  /// - Server only keeps newest key
  ///
  /// Call this from KeyManager.init() after identity key pair is loaded.
  Future<void> initializeSignedPreKeyStore() async {
    // Mark as rotating
    signedPreKeyState.markRotating();

    // Listen for incoming signed prekeys from server
    socketService.registerListener("getSignedPreKeysResponse", (data) async {
      // Server does not store private keys; nothing to reconstruct here.
      if (data.isEmpty) {
        debugPrint("No signed pre keys found, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
        signedPreKeyState.markRotationComplete(
          newPreSignedKey.id,
          DateTime.now(),
        );
      }
    }, registrationName: 'SignedPreKeyStore');

    // Check if we have any signed prekeys, if not create one
    final keys = await loadAllStoredSignedPreKeys();

    if (keys.isEmpty) {
      debugPrint("No signed pre keys found locally, creating new one");
      var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
      await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      signedPreKeyState.markRotationComplete(
        newPreSignedKey.id,
        DateTime.now(),
      );
      return;
    }

    // Sort by ID (highest = newest)
    keys.sort((a, b) => b.id.compareTo(a.id));

    final newest = keys.first;
    debugPrint(
      '[SIGNED_PREKEY_SETUP] Found ${keys.length} local signed prekeys, newest ID: ${newest.id}',
    );

    // Check if the NEWEST signed prekey is older than 7 days
    final metadata = await _loadSignedPreKeyMetadata(newest.id);
    final createdAtStr = metadata['createdAt'] as String?;
    if (createdAtStr != null) {
      final createdAt = DateTime.parse(createdAtStr);
      if (DateTime.now().difference(createdAt).inDays > 7) {
        debugPrint(
          '[SIGNED_PREKEY_SETUP] Newest key is ${DateTime.now().difference(createdAt).inDays} days old - rotating',
        );
        signedPreKeyState.markRotating();
        var newPreSignedKey = generateSignedPreKey(
          identityKeyPair,
          keys.length,
        );
        await storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
        signedPreKeyState.markRotationComplete(
          newPreSignedKey.id,
          DateTime.now(),
        );
        // Re-fetch keys after rotation
        final updatedKeys = await loadAllStoredSignedPreKeys();
        updatedKeys.sort((a, b) => b.id.compareTo(a.id));
      } else {
        // Key is still fresh
        signedPreKeyState.markRotationComplete(newest.id, createdAt);
      }
    } else {
      // No metadata, assume fresh
      signedPreKeyState.markRotationComplete(newest.id, DateTime.now());
    }

    // Ensure the newest key is uploaded to server (re-upload to be safe)
    debugPrint(
      '[SIGNED_PREKEY_SETUP] Ensuring newest signed prekey (ID ${keys.first.id}) is on server',
    );
    await storeSignedPreKey(keys.first.id, keys.first);

    // Local cleanup: Keep max 3 keys (newest + 2 backups)
    // Delete oldest keys when exceeding limit
    if (keys.length > 3) {
      final keysToDelete = keys.skip(3).toList();
      debugPrint(
        '[SIGNED_PREKEY_SETUP] Deleting ${keysToDelete.length} old local keys (keeping max 3)...',
      );

      for (final key in keysToDelete) {
        debugPrint('[SIGNED_PREKEY_SETUP] Deleting local key ${key.id}');
        await _deleteLocalOnly(key.id);
      }

      debugPrint(
        '[SIGNED_PREKEY_SETUP] ✓ Deleted ${keysToDelete.length} old local keys',
      );
    }

    // Server cleanup: Remove old signedPreKeys from server IMMEDIATELY
    // This ensures PreKey bundles always use the newest signedPreKey
    // Local keeps grace period (30 days) to decrypt delayed messages
    int serverDeleted = 0;

    for (final key in keys) {
      // Keep newest key always
      if (key.id == keys.first.id) continue;

      // Delete ALL old keys from server immediately
      debugPrint('[SIGNED_PREKEY_SETUP] Removing old server key: ${key.id}');
      try {
        await apiService.delete('/signal/signedprekey/${key.id}');
        serverDeleted++;
      } catch (e) {
        debugPrint(
          '[SIGNED_PREKEY_SETUP] ⚠️ Failed to delete key ${key.id}: $e',
        );
      }
    }

    if (serverDeleted > 0) {
      debugPrint(
        '[SIGNED_PREKEY_SETUP] ✓ Removed $serverDeleted old keys from server',
      );
    }

    debugPrint(
      '[SIGNED_PREKEY_SETUP] ✅ Setup complete: ${keys.length} local keys, 1 server key (newest)',
    );
  }

  /// Request signed pre keys from server (legacy method).
  ///
  /// ⚠️ NOTE: Server doesn't store private keys, so this only checks server state.
  /// Used during initialization to verify server has our public key.
  Future<void> loadRemoteSignedPreKeys() async {
    // Use GET /signal/signedprekeys REST endpoint
    try {
      final response = await apiService.get('/signal/signedprekeys');
      debugPrint(
        '[SIGNED_PREKEY] Fetched ${response.data['signedPreKeys']?.length ?? 0} keys from server',
      );
    } catch (e) {
      debugPrint('[SIGNED_PREKEY] ⚠️ Failed to fetch keys from server: $e');
    }
  }

  // ============================================================================
  // SIGNAL PROTOCOL INTERFACE (Required overrides)
  // ============================================================================

  /// Load a signed pre key record by ID (Signal protocol interface).
  ///
  /// Called by libsignal when:
  /// - Receiving a message encrypted with this signed pre key
  /// - Establishing a new session with a peer
  ///
  /// Throws exception if key not found. This can happen when:
  /// - Sender used old/cached PreKey bundle
  /// - Local storage was cleared
  /// - Key was rotated and cleaned up
  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final record = await loadStoredSignedPreKey(signedPreKeyId);
    if (record != null) {
      return record;
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
        '[SIGNED_PREKEY] Available local keys: ${allKeys.map((k) => k.id).toList()}',
      );

      debugPrint(
        '[SIGNED_PREKEY] This usually means sender used cached/stale PreKey bundle',
      );
      throw Exception('No such signedprekeyrecord! $signedPreKeyId');
    }
  }

  /// Load all signed pre key records (Signal protocol interface).
  ///
  /// Returns list of [SignedPreKeyRecord] objects.
  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    return await loadAllStoredSignedPreKeys();
  }

  /// Store a signed pre key record locally and upload to server (Signal protocol interface).
  ///
  /// This method:
  /// 1. Uploads public key + signature to server via ApiService
  /// 2. Stores full record (including private key) locally with metadata
  /// 3. Auto-cleans server: keeps newest + previous key for in-flight bundles
  ///
  /// Throws exception if server upload fails.
  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    debugPrint("Storing signed pre key: $signedPreKeyId");
    // Split SignedPreKeyRecord into publicKey and signature for storage
    final publicKey = base64Encode(record.getKeyPair().publicKey.serialize());
    final signature = base64Encode(record.signature);

    // Ensure ApiService for the active server is initialized (HMAC via interceptor on native)
    await apiService.init();

    // Upload to server with acknowledgment
    try {
      final response = await apiService.post(
        '/signal/signedprekey',
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

    // Keep newest + previous on server to accommodate in-flight bundles
    final allKeys = await loadAllStoredSignedPreKeys();
    allKeys.sort((a, b) => b.id.compareTo(a.id));
    final previousId = allKeys.isNotEmpty ? allKeys.first.id : null;
    final serverKeepIds = <int>{signedPreKeyId};
    if (previousId != null) {
      serverKeepIds.add(previousId);
    }

    for (final key in allKeys) {
      if (serverKeepIds.contains(key.id)) continue;

      debugPrint(
        '[SIGNED_PREKEY] Auto-cleanup: Removing old server key ${key.id} (keeping ${serverKeepIds.join(', ')})',
      );
      try {
        await apiService.delete('/signal/signedprekey/${key.id}');
      } catch (e) {
        debugPrint('[SIGNED_PREKEY] ⚠️ Failed to delete old key ${key.id}: $e');
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

  /// Check if a signed pre key exists in local storage (Signal protocol interface).
  ///
  /// Returns `true` if key exists, `false` otherwise.
  /// This only checks local storage, not server.
  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    try {
      var value = await storage.getDecrypted(
        _storeName,
        _storeName,
        _signedPreKey(signedPreKeyId),
      );
      return value != null;
    } catch (e) {
      debugPrint(
        '[SIGNED_PREKEY] ⚠️ SignedPreKey decrypt failed, purging $signedPreKeyId: $e',
      );
      try {
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
      } catch (deleteError) {
        debugPrint(
          '[SIGNED_PREKEY] Warning: Failed to delete corrupted signed prekey $signedPreKeyId: $deleteError',
        );
      }
      return false;
    }
  }

  /// Remove a signed pre key from both local storage and server (Signal protocol interface).
  ///
  /// This method:
  /// 1. Sends delete request to server via SocketService
  /// 2. Deletes record from local storage
  /// 3. Deletes metadata from local storage
  ///
  /// Use [_deleteLocalOnly] if you only want to delete locally.
  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    debugPrint("Removing signed pre key: $signedPreKeyId");

    // Delete from server via REST API
    try {
      await apiService.delete('/signal/signedprekey/$signedPreKeyId');
      debugPrint('[SIGNED_PREKEY] ✓ Deleted key $signedPreKeyId from server');
    } catch (e) {
      debugPrint(
        '[SIGNED_PREKEY] ⚠️ Failed to delete key $signedPreKeyId from server: $e',
      );
    }

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

  /// Delete signed pre key from local storage only (private helper).
  ///
  /// This does NOT notify the server - use when:
  /// - Cleaning up old local keys while keeping server copy
  /// - Managing local storage limits (max 3 keys)
  ///
  /// For deletion from both local + server, use [removeSignedPreKey].
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

  // ============================================================================
  // ROTATION & MAINTENANCE
  // ============================================================================

  /// Check if the newest signed pre key needs rotation.
  ///
  /// Returns `true` if:
  /// - Newest key is 7+ days old (security best practice)
  /// - No keys exist (needs initial generation)
  /// - Newest key has no timestamp (corrupted metadata)
  ///
  /// Returns `false` if:
  /// - Newest key is less than 7 days old (still fresh)
  /// - Error occurs during check (safe default)
  ///
  /// ⏱️ Rotation threshold: 7 days
  Future<bool> needsRotation() async {
    try {
      final allKeys = await loadAllStoredSignedPreKeys();
      if (allKeys.isEmpty) {
        debugPrint('[SIGNED_PREKEY_ROTATION] No SignedPreKeys found');
        return false;
      }

      // Find the newest key (highest ID)
      allKeys.sort((a, b) => b.id.compareTo(a.id));
      final newestKey = allKeys.first;

      // Load metadata for newest key
      final metadata = await _loadSignedPreKeyMetadata(newestKey.id);
      final createdAtStr = metadata['createdAt'] as String?;

      if (createdAtStr == null) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] Newest key has no createdAt timestamp, assuming rotation needed',
        );
        return true;
      }

      final createdAt = DateTime.parse(createdAtStr);
      final daysSinceCreation = DateTime.now().difference(createdAt).inDays;
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

  /// Rotate signed pre key: Generate new key and apply cleanup strategy.
  ///
  /// Complete rotation process:
  /// 1. Generate new SignedPreKey with next sequential ID
  /// 2. Upload to server (becomes active for new PreKey bundles)
  /// 3. Server cleanup: Remove ALL old keys from server immediately
  /// 4. Local cleanup: Keep max 3 keys (newest + 2 backups for decryption)
  ///
  /// This ensures:
  /// - ✅ New connections always use fresh keys
  /// - ✅ Server only advertises newest key
  /// - ✅ Local keeps backups for delayed messages
  /// - ✅ Storage limit maintained (max 3 local keys)
  ///
  /// Call this when [needsRotation] returns true, or manually for forced rotation.
  Future<void> rotateSignedPreKey(IdentityKeyPair identityKeyPair) async {
    try {
      debugPrint('[SIGNED_PREKEY_ROTATION] Starting SignedPreKey rotation...');

      // Mark rotation in progress
      signedPreKeyState.markRotating();

      var allKeys = await loadAllStoredSignedPreKeys();
      final nextId = allKeys.isEmpty
          ? 0
          : allKeys.map((k) => k.id).reduce((a, b) => a > b ? a : b) + 1;

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

      // Re-fetch keys after rotation to get updated list
      allKeys = await loadAllStoredSignedPreKeys();
      allKeys.sort((a, b) => b.id.compareTo(a.id));

      // Local cleanup: Keep max 3 keys (newest + 2 backups)
      // Delete oldest keys when exceeding limit
      if (allKeys.length > 3) {
        final keysToDelete = allKeys.skip(3).toList();
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] Deleting ${keysToDelete.length} old local keys (keeping max 3)...',
        );

        for (final key in keysToDelete) {
          debugPrint('[SIGNED_PREKEY_ROTATION] Deleting local key ${key.id}');
          await _deleteLocalOnly(key.id);
        }

        debugPrint(
          '[SIGNED_PREKEY_ROTATION] ✓ Deleted ${keysToDelete.length} old local keys',
        );
      }

      // Server cleanup: Remove old signedPreKeys from server IMMEDIATELY
      int serverDeleted = 0;

      // Keep newest + previous on server to accommodate in-flight bundles
      final serverKeepIds = allKeys.take(2).map((k) => k.id).toSet();

      for (final key in allKeys) {
        if (serverKeepIds.contains(key.id)) continue;

        debugPrint(
          '[SIGNED_PREKEY_ROTATION] Removing old server key: ${key.id}',
        );
        try {
          await apiService.delete('/signal/signedprekey/${key.id}');
          serverDeleted++;
        } catch (e) {
          debugPrint(
            '[SIGNED_PREKEY_ROTATION] ⚠️ Failed to delete key ${key.id}: $e',
          );
        }
      }

      if (serverDeleted > 0) {
        debugPrint(
          '[SIGNED_PREKEY_ROTATION] ✓ Removed $serverDeleted old keys from server',
        );
      }

      debugPrint(
        '[SIGNED_PREKEY_ROTATION] ✅ Rotation complete: ${allKeys.length} local keys, ${serverKeepIds.length} server keys (newest first)',
      );

      // Update state
      final metadata = await _loadSignedPreKeyMetadata(allKeys.first.id);
      final createdAt = metadata['createdAt'] != null
          ? DateTime.parse(metadata['createdAt'] as String)
          : DateTime.now();
      signedPreKeyState.markRotationComplete(allKeys.first.id, createdAt);
    } catch (e, stackTrace) {
      debugPrint('[SIGNED_PREKEY_ROTATION] ❌ ERROR during rotation: $e');
      debugPrint('[SIGNED_PREKEY_ROTATION] Stack trace: $stackTrace');
      signedPreKeyState.markError(e.toString());
      rethrow;
    }
  }

  // ============================================================================
  // PUBLIC API METHODS (High-level operations)
  // ============================================================================

  /// Maximum number of signed pre keys to keep in local storage.
  ///
  /// Strategy: Keep newest + 2 backups for decrypting delayed messages.
  int get maxSignedPreKeys => 3;

  /// Get current signed pre key with auto-management (🌟 PRIMARY METHOD).
  ///
  /// ✨ **This is THE method to use** - one call handles everything:
  ///
  /// Auto-generation:
  /// - If no keys exist → generates new key (ID: 0) and uploads
  ///
  /// Auto-rotation:
  /// - If newest key is 7+ days old → generates new key and uploads
  ///
  /// Auto-cleanup:
  /// - Keeps max 3 local keys (newest + 2 backups)
  /// - Server keeps only newest key
  ///
  /// Returns: Fresh, valid [SignedPreKeyRecord] ready for use.
  ///
  /// Example:
  /// ```dart
  /// final signedPreKey = await getSignedPreKey();
  /// // Use in PreKey bundle generation
  /// ```
  Future<SignedPreKeyRecord> getSignedPreKey() async {
    try {
      final keys = await loadSignedPreKeys();

      if (keys.isEmpty) {
        debugPrint(
          '[SIGNED_PRE_KEY_STORE] No SignedPreKey found, generating...',
        );
        return await generateSignedPreKeyManual(keyId: 0);
      }

      final needsRotationNow = await needsRotation();

      if (needsRotationNow) {
        debugPrint(
          '[SIGNED_PRE_KEY_STORE] SignedPreKey is old (7+ days), auto-rotating...',
        );
        await rotateSignedPreKey(identityKeyPair);

        final newKeys = await loadSignedPreKeys();
        debugPrint('[SIGNED_PRE_KEY_STORE] ✓ Auto-rotation complete');

        await removeOldSignedPreKeys();
        return newKeys.last;
      }

      debugPrint('[SIGNED_PRE_KEY_STORE] Using existing SignedPreKey (fresh)');
      await removeOldSignedPreKeys();
      return keys.last;
    } catch (e) {
      debugPrint('[SIGNED_PRE_KEY_STORE] Error getting SignedPreKey: $e');
      rethrow;
    }
  }

  /// Generate and store a new signed pre key manually.
  ///
  /// Parameters:
  /// - `keyId`: Optional specific ID. If null, uses next sequential ID.
  ///
  /// This method:
  /// 1. Generates new SignedPreKeyRecord with specified ID
  /// 2. Uploads to server (public key + signature)
  /// 3. Stores locally (full record + metadata)
  ///
  /// Use cases:
  /// - Testing with specific IDs
  /// - Manual key regeneration
  /// - Recovery from corrupted state
  ///
  /// ⚠️ Prefer [getSignedPreKey] for normal use (handles auto-rotation).
  Future<SignedPreKeyRecord> generateSignedPreKeyManual({int? keyId}) async {
    try {
      final id = keyId ?? await _getNextKeyId();
      debugPrint('[SIGNED_PRE_KEY_STORE] Generating SignedPreKey (ID: $id)...');

      final signedPreKey = generateSignedPreKey(identityKeyPair, id);
      await storeSignedPreKey(id, signedPreKey);

      debugPrint(
        '[SIGNED_PRE_KEY_STORE] ✓ SignedPreKey generated and uploaded',
      );
      return signedPreKey;
    } catch (e) {
      debugPrint('[SIGNED_PRE_KEY_STORE] Error generating SignedPreKey: $e');
      rethrow;
    }
  }

  /// Get the ID of the newest signed pre key.
  ///
  /// Returns:
  /// - ID of newest key if any exist
  /// - `null` if no keys exist or error occurs
  ///
  /// Used internally for calculating next ID during generation.
  Future<int?> getLatestSignedPreKeyId() async {
    try {
      final keys = await loadSignedPreKeys();
      return keys.isNotEmpty ? keys.last.id : null;
    } catch (e) {
      debugPrint('[SIGNED_PRE_KEY_STORE] Error getting latest ID: $e');
      return null;
    }
  }

  /// Remove old signed pre keys to maintain storage limit.
  ///
  /// Cleanup strategy:
  /// - Keeps max 3 keys (newest + 2 backups)
  /// - Sorts by ID (highest = newest)
  /// - Deletes excess keys from both local and server
  ///
  /// Called automatically by [getSignedPreKey], but can be called manually.
  ///
  /// ⚠️ This deletes from BOTH local storage AND server.
  Future<void> removeOldSignedPreKeys() async {
    try {
      final allKeys = await loadAllStoredSignedPreKeys();

      if (allKeys.length <= maxSignedPreKeys) return;

      allKeys.sort((a, b) => b.id.compareTo(a.id));
      final keysToDelete = allKeys.skip(maxSignedPreKeys).toList();

      if (keysToDelete.isEmpty) return;

      debugPrint(
        '[SIGNED_PRE_KEY_STORE] Removing ${keysToDelete.length} old keys...',
      );

      for (final key in keysToDelete) {
        await removeSignedPreKey(key.id);
      }

      debugPrint('[SIGNED_PRE_KEY_STORE] ✓ Cleanup complete');
    } catch (e) {
      debugPrint('[SIGNED_PRE_KEY_STORE] Error cleaning up old keys: $e');
    }
  }

  /// Check if any signed pre keys exist in local storage.
  ///
  /// Returns:
  /// - `true`: At least one key exists
  /// - `false`: No keys exist (need to generate)
  ///
  /// Useful for initialization checks and diagnostics.
  Future<bool> hasSignedPreKeys() async {
    final keys = await loadAllStoredSignedPreKeys();
    return keys.isNotEmpty;
  }

  /// Get total count of signed pre keys in local storage.
  ///
  /// Returns: Number of stored keys (should be 0-3).
  ///
  /// Useful for:
  /// - Diagnostics and logging
  /// - Verifying cleanup worked correctly
  /// - Debug UI displays
  Future<int> getSignedPreKeyCount() async {
    final keys = await loadAllStoredSignedPreKeys();
    return keys.length;
  }

  /// Validate signed pre key on server and auto-recover if invalid.
  ///
  /// Validation checks:
  /// 1. ✅ Server has signed pre key data
  /// 2. ✅ Public key and signature are present
  /// 3. ✅ Signature is valid (verifies against local identity key)
  /// 4. ✅ Signature length is correct (64 bytes)
  ///
  /// If validation fails:
  /// - Automatically regenerates new signed pre key
  /// - Uploads to server
  /// - Logs detailed error information
  ///
  /// Parameters:
  /// - `status`: Server response containing 'signedPreKey' with:
  ///   - `signed_prekey_data`: Base64 encoded public key
  ///   - `signed_prekey_signature`: Base64 encoded signature
  ///
  /// Called during account validation and periodic health checks.
  Future<void> validateServerSignedPreKey(Map<String, dynamic> status) async {
    try {
      debugPrint('[SIGNED_PRE_KEY_STORE] Validating server SignedPreKey...');

      final localIdentityKey = identityKeyPair.getPublicKey();
      final localPublicKey = Curve.decodePoint(localIdentityKey.serialize(), 0);

      final signedPreKeyData = status['signedPreKey'];
      if (signedPreKeyData == null) {
        debugPrint('[SIGNED_PRE_KEY_STORE] ⚠️ No SignedPreKey on server');
        await _regenerateAndUpload();
        return;
      }

      final signedPreKeyPublicBase64 =
          signedPreKeyData['signed_prekey_data'] as String?;
      final signedPreKeySignatureBase64 =
          signedPreKeyData['signed_prekey_signature'] as String?;

      if (signedPreKeyPublicBase64 == null ||
          signedPreKeySignatureBase64 == null) {
        debugPrint('[SIGNED_PRE_KEY_STORE] ⚠️ Incomplete data on server');
        await _regenerateAndUpload();
        return;
      }

      final signedPreKeyPublicBytes = base64Decode(signedPreKeyPublicBase64);
      final signedPreKeySignatureBytes = base64Decode(
        signedPreKeySignatureBase64,
      );
      final signedPreKeyPublic = Curve.decodePoint(signedPreKeyPublicBytes, 0);

      final isValid = Curve.verifySignature(
        localPublicKey,
        signedPreKeyPublic.serialize(),
        signedPreKeySignatureBytes,
      );

      if (!isValid) {
        debugPrint('[SIGNED_PRE_KEY_STORE] ❌ Invalid signature!');
        await _regenerateAndUpload();
        return;
      }

      if (signedPreKeySignatureBytes.length != 64) {
        debugPrint(
          '[SIGNED_PRE_KEY_STORE] ⚠️ Invalid signature length: ${signedPreKeySignatureBytes.length}',
        );
        await _regenerateAndUpload();
        return;
      }

      debugPrint('[SIGNED_PRE_KEY_STORE] ✓ Server SignedPreKey valid');
    } catch (e, stackTrace) {
      debugPrint('[SIGNED_PRE_KEY_STORE] Error validating server key: $e');
      debugPrint('[SIGNED_PRE_KEY_STORE] Stack trace: $stackTrace');
    }
  }

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  /// Calculate next sequential key ID (internal helper).
  ///
  /// Returns: (latest ID + 1), or 0 if no keys exist.
  ///
  /// Used by [generateSignedPreKeyManual] when keyId is not specified.
  Future<int> _getNextKeyId() async {
    final latestId = await getLatestSignedPreKeyId();
    return (latestId ?? -1) + 1;
  }

  /// Regenerate signed pre key and upload to server (internal recovery helper).
  ///
  /// Used by [validateServerSignedPreKey] when validation fails.
  /// Always generates with ID 0 for consistency during recovery.
  Future<void> _regenerateAndUpload() async {
    debugPrint('[SIGNED_PRE_KEY_STORE] → Regenerating SignedPreKey...');
    final newSignedPreKey = generateSignedPreKey(identityKeyPair, 0);
    await storeSignedPreKey(newSignedPreKey.id, newSignedPreKey);
    debugPrint('[SIGNED_PRE_KEY_STORE] ✓ SignedPreKey regenerated');
  }
}
