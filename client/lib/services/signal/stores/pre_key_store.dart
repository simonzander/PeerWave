import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../device_scoped_storage_service.dart';
import '../../api_service.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../../../web_config.dart';
import '../../server_config_web.dart'
    if (dart.library.io) '../../server_config_native.dart';
import '../state/pre_key_state.dart';

/// A persistent pre-key store for Signal Protocol one-time pre-keys.
///
/// Core Operations:
/// - generatePreKeysInRange(start, end) - Generate and store keys in batch
/// - uploadPreKeys(preKeys) - Upload to server via HTTP
/// - syncPreKeyIds(serverIds) - Synchronize with server state
/// - checkPreKeys() - Auto-maintain 110 keys (regenerate when < 20)
/// - getAllPreKeyIds() - Get all stored key IDs
/// - getLocalPreKeyCount() - Get count of local keys
///
/// 💡 Key Insight: Maintains 110 one-time PreKeys, regenerates when below 20.
///
/// 🔢 ID Strategy:
/// - PreKey IDs increment continuously: 0 → 16,777,215 (0xFFFFFF)
/// - Start: 0-109, Next batch: 110-219, etc.
/// - At 16M: Wraps to 0 (old keys must be consumed by then)
///
/// 🌐 Multi-Server Support:
/// This store is server-scoped via KeyManager.
/// - apiService: Used for HTTP uploads (server-scoped, knows baseUrl)
/// - socketService: Used for real-time events (server-scoped, knows serverUrl)
///
/// Storage isolation is automatic:
/// - DeviceIdentityService provides unique deviceId per server
/// - DeviceScopedStorageService creates isolated databases automatically
mixin PermanentPreKeyStore implements PreKeyStore {
  // Abstract getters - provided by KeyManager
  ApiService get apiService;
  SocketService get socketService;

  /// State instance for this server - must be provided by KeyManager
  PreKeyState get preKeyState;

  // Retry policy for PreKey uploads (critical publication path)
  static const int _preKeyUploadMaxRetries = 3;
  static const Duration _preKeyUploadRetryDelay = Duration(seconds: 2);

  /// 🔒 Guard to prevent concurrent checkPreKeys() calls
  bool _isCheckingPreKeys = false;

  String get _storeName => 'peerwaveSignalPreKeys';
  String get _keyPrefix => 'prekey_';

  // ============================================================================
  // CORE STORAGE OPERATIONS (Low-level access)
  // ============================================================================

  /// Store multiple prekeys at once via HTTP POST (batch upload).
  ///
  /// **Use this when**:
  /// - Uploading during initialization (reliable, acknowledged)
  /// - Need confirmation of successful server storage
  /// - Uploading many keys at once (more efficient)
  ///
  /// **Behavior**:
  /// - Uses ApiService.post for reliable HTTP upload
  /// - Waits for server acknowledgment (200/202 status)
  /// - Stores locally after successful server upload
  /// - Handles 202 (queued) responses with 2s delay
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> storePreKeysBatch(List<PreKeyRecord> preKeys) async {
    if (preKeys.isEmpty) return true;

    debugPrint(
      "[PREKEY STORE] Storing ${preKeys.length} PreKeys via HTTP batch upload",
    );

    try {
      // Get server URL (platform-specific)
      if (kIsWeb) {
        await loadWebApiServer();
      } else {
        // Native: Get from ServerConfigService
        ServerConfigService.getActiveServer();
      }

      // Prepare payload
      final preKeyPayload = preKeys
          .map(
            (k) => {
              'id': k.id,
              'data': base64Encode(k.getKeyPair().publicKey.serialize()),
            },
          )
          .toList();

      // Send via HTTP POST
      final success = await _postPreKeysWithRetry(
        '/signal/prekeys/batch',
        data: {'preKeys': preKeyPayload},
      );

      if (success) {
        // Response already validated inside retry helper
        debugPrint(
          "[PREKEY STORE] ✓ Batch upload successful: ${preKeys.length} keys stored on server",
        );

        // Store locally after successful server upload
        for (final record in preKeys) {
          await storePreKey(record.id, record, sendToServer: false);
        }

        return true;
      }

      // If we reach here, retries exhausted
      debugPrint(
        "[PREKEY STORE] ✗ Batch upload failed after retries (${preKeys.length} keys)",
      );
      return false;
    } catch (e) {
      debugPrint("[PREKEY STORE] ✗ Batch upload error: $e");
      return false;
    }
  }

  /// Store multiple prekeys at once via HTTP POST.
  ///
  /// **Use this when**:
  /// - Regenerating keys after consumption
  /// - Quick key generation during operation
  /// - Uploading multiple keys at once
  ///
  /// **Behavior**:
  /// - Uses ApiService.post for reliable HTTP upload
  /// - Stores locally immediately
  /// - Continues even if server upload fails (local storage prioritized)
  ///
  /// For initialization with strict acknowledgment, use [storePreKeysBatch].
  Future<void> storePreKeys(List<PreKeyRecord> preKeys) async {
    if (preKeys.isEmpty) return;
    debugPrint("Storing ${preKeys.length} pre keys in batch");

    // Prepare payload
    final preKeyPayload = preKeys
        .map(
          (k) => {
            'id': k.id,
            'data': base64Encode(k.getKeyPair().publicKey.serialize()),
          },
        )
        .toList();

    // Upload to server via HTTP with retry; fail-fast if publication fails
    final success = await _postPreKeysWithRetry(
      '/signal/prekeys/batch',
      data: {'preKeys': preKeyPayload},
    );

    if (!success) {
      throw Exception('[PREKEY STORE] Server upload failed after retries');
    }

    // Store locally
    for (final record in preKeys) {
      await storePreKey(record.id, record, sendToServer: false);
    }
  }

  /// POST helper with bounded retries/backoff for PreKey publication.
  Future<bool> _postPreKeysWithRetry(
    String path, {
    required Map<String, dynamic> data,
  }) async {
    for (var attempt = 1; attempt <= _preKeyUploadMaxRetries; attempt++) {
      try {
        final response = await apiService.post(path, data: data);
        final code = response.statusCode;
        if (code == 200 || code == 202) {
          return true;
        }
        debugPrint(
          '[PREKEY STORE] ⚠️ PreKey upload attempt $attempt failed (status $code)',
        );
      } catch (e) {
        debugPrint(
          '[PREKEY STORE] ⚠️ PreKey upload attempt $attempt error: $e',
        );
      }

      if (attempt < _preKeyUploadMaxRetries) {
        await Future.delayed(_preKeyUploadRetryDelay);
      }
    }

    return false;
  }

  /// Get all PreKey IDs without decrypting (fast for validation/gap analysis).
  ///
  /// Returns list of all PreKey IDs stored locally.
  /// This is a fast operation that doesn't require decrypting key data.
  ///
  /// Used for:
  /// - Gap analysis (finding missing key IDs)
  /// - Count validation (should have 20-110 keys)
  /// - Sync operations with server
  Future<List<int>> getAllPreKeyIds() async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    // Storage service will wait for device identity to be initialized
    final storage = DeviceScopedStorageService.instance;

    debugPrint(
      '[PREKEY STORE] Getting all keys from storage (baseName: $_storeName, storeName: $_storeName)',
    );
    final keys = await storage.getAllKeys(_storeName, _storeName);

    final filtered = keys.where((k) => k.startsWith(_keyPrefix)).toList();

    final ids = filtered
        .map((k) => int.tryParse(k.replaceFirst(_keyPrefix, '')))
        .whereType<int>()
        .toList();

    // 🔧 REDUCED VERBOSITY: Only log count, not full list (reduces spam with 100+ keys)
    debugPrint('[PREKEY STORE] Found ${ids.length} PreKey IDs in storage');

    return ids;
  }

  /// Returns all locally stored PreKeyRecords.
  ///
  /// This loads and decrypts all PreKey records from storage.
  /// If any decryption fails, throws exception to trigger regeneration.
  ///
  /// ⚠️ This is a slow operation - use [getAllPreKeyIds] if you only need IDs.
  Future<List<PreKeyRecord>> getAllPreKeys() async {
    final ids = await getAllPreKeyIds();
    List<PreKeyRecord> preKeys = [];
    bool hasDecryptionFailure = false;

    for (final id in ids) {
      try {
        final preKey = await loadPreKey(id);
        preKeys.add(preKey);
      } catch (e) {
        // Check if this is a decryption failure
        if (e.toString().contains('InvalidCipherTextException') ||
            e.toString().contains('Decryption failed')) {
          debugPrint('[PREKEY STORE] ⚠️ Decryption failed for prekey_$id: $e');
          hasDecryptionFailure = true;
        } else {
          // Ignore other errors (missing prekeys, etc.)
          debugPrint('[PREKEY STORE] Ignoring error for prekey_$id: $e');
        }
      }
    }

    // If any decryption failed, throw exception to trigger key regeneration
    if (hasDecryptionFailure && preKeys.isEmpty) {
      throw Exception(
        'Decryption failed: All PreKeys are corrupted or encrypted with wrong key',
      );
    }

    return preKeys;
  }

  /// Check if enough prekeys are available, generates and stores more if needed.
  ///
  /// Maintenance strategy:
  /// - Target: 110 PreKeys (Signal Protocol recommendation)
  /// - Threshold: Regenerate when < 20 keys remain
  /// - Max ID: 16,777,215 (Signal Protocol limit)
  ///
  /// ID Strategy:
  /// - Normal: Incrementing IDs (safe, no reuse until 16M)
  /// - Wrapping: After 16M, reuse old IDs from 0 (old keys must be consumed)
  ///
  /// 🔒 Protected by lock to prevent concurrent regeneration.
  Future<void> checkPreKeys() async {
    // 🔒 Prevent concurrent calls (race condition protection)
    if (_isCheckingPreKeys) {
      debugPrint("[PREKEY STORE] checkPreKeys already running, skipping...");
      return;
    }

    try {
      _isCheckingPreKeys = true;

      final allKeyIds = await getAllPreKeyIds();

      // Update state
      preKeyState.updateCount(allKeyIds.length);

      // ✅ Signal Protocol: Keep 110 prekeys, regenerate when < 20
      const int MAX_PREKEY_ID = 16777215; // Signal Protocol max (0xFFFFFF)
      const int WRAP_THRESHOLD = 16000000; // Start wrapping at 16M
      const int TARGET_PREKEYS = 110; // Signal Protocol recommendation
      const int MIN_PREKEYS = 20; // Regenerate threshold

      if (allKeyIds.length < MIN_PREKEYS) {
        debugPrint(
          "[PREKEY STORE] Not enough pre keys (${allKeyIds.length}/$TARGET_PREKEYS), generating more",
        );

        // Mark generation in progress
        preKeyState.markGenerating();

        // Strategy:
        // 1. If maxId < WRAP_THRESHOLD: use incrementing IDs (safe, no reuse)
        // 2. If maxId >= WRAP_THRESHOLD: wrap to 0 and fill gaps (old keys consumed)
        final maxId = allKeyIds.isEmpty
            ? -1
            : allKeyIds.reduce((a, b) => a > b ? a : b);
        final needed = TARGET_PREKEYS - allKeyIds.length;

        List<int> missingIds;

        if (maxId >= WRAP_THRESHOLD) {
          // WRAP MODE: Find gaps from 0 upward (old keys must be consumed by now)
          debugPrint(
            "[PREKEY STORE] ⚠️ Max ID reached ($maxId/$MAX_PREKEY_ID), wrapping to fill gaps from 0...",
          );
          missingIds = _findGapsFromZero(allKeyIds, needed);
        } else {
          // INCREMENT MODE: Normal incrementing (safe, no race condition)
          final startId = maxId + 1;
          missingIds = List.generate(needed, (i) => startId + i);
          debugPrint(
            "[PREKEY STORE] Using incrementing IDs from $startId (safe mode)",
          );
        }

        // Find contiguous ranges for batch generation
        final contiguousRanges = _findContiguousRanges(missingIds);
        debugPrint(
          "[PREKEY STORE] Found ${contiguousRanges.length} range(s) to generate",
        );

        for (final range in contiguousRanges) {
          if (range.length > 1) {
            // BATCH GENERATION: Multiple contiguous IDs (FAST!)
            final start = range.first;
            final end = range.last;
            debugPrint(
              "[PREKEY STORE] Batch generating PreKeys $start-$end (${range.length} keys)",
            );
            await generatePreKeysInRange(start, end);
          } else {
            // SINGLE GENERATION: Isolated gap
            final id = range.first;
            debugPrint("[PREKEY STORE] Single generating PreKey $id");
            await generatePreKeysInRange(id, id);
          }
        }

        debugPrint("[PREKEY STORE] ✓ PreKey generation complete");

        // Update state with new count
        final newKeyIds = await getAllPreKeyIds();
        preKeyState.markGenerationComplete(newKeyIds.length);
      }
    } catch (e) {
      preKeyState.markError(e.toString());
      rethrow;
    } finally {
      _isCheckingPreKeys = false;
    }
  }

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  /// Find contiguous ranges in a list of IDs for batch generation (internal helper).
  ///
  /// Groups consecutive IDs together so they can be generated in a single batch.
  /// Example: [1, 2, 3, 7, 8, 15] → [[1,2,3], [7,8], [15]]
  ///
  /// This optimizes generation by using batch operations when possible.
  List<List<int>> _findContiguousRanges(List<int> ids) {
    if (ids.isEmpty) return [];

    final sortedIds = List<int>.from(ids)..sort();
    final ranges = <List<int>>[];
    var currentRange = <int>[sortedIds[0]];

    for (int i = 1; i < sortedIds.length; i++) {
      if (sortedIds[i] == currentRange.last + 1) {
        // Contiguous - add to current range
        currentRange.add(sortedIds[i]);
      } else {
        // Gap found - save current range, start new one
        ranges.add(currentRange);
        currentRange = [sortedIds[i]];
      }
    }
    ranges.add(currentRange); // Add last range

    return ranges;
  }

  /// Generate storage key for pre key record.
  /// Format: 'prekey_{id}'
  String _preKey(int preKeyId) => '$_keyPrefix$preKeyId';

  /// Find unused IDs starting from 0 for ID wrapping (internal helper).
  /// When we've reached 16M, old keys (0-109) must be consumed, so safe to reuse
  List<int> _findGapsFromZero(List<int> existingIds, int needed) {
    final existingSet = existingIds.toSet();
    final gaps = <int>[];

    // Scan from 0 upward to find unused IDs
    for (int id = 0; gaps.length < needed && id <= 16777215; id++) {
      if (!existingSet.contains(id)) {
        gaps.add(id);
      }
    }

    debugPrint(
      "[PREKEY STORE] Found ${gaps.length} gaps starting from ${gaps.isEmpty ? 'N/A' : gaps.first}",
    );

    return gaps;
  }

  /// Initialize pre key store - MUST be called after mixin is applied.
  ///
  /// This method is called during KeyManager initialization.
  /// Currently a placeholder for future socket listener registration if needed.
  ///
  /// Call this from KeyManager.init() after identity key pair is loaded.
  Future<void> initializePreKeyStore() async {
    debugPrint('[PREKEY STORE] Pre key store initialized');
    // Future: Register socket listeners for server sync if needed
  }

  // ============================================================================
  // SIGNAL PROTOCOL INTERFACE (Required overrides)
  // ============================================================================

  /// Check if a pre key exists in local storage (Signal protocol interface).
  ///
  /// Returns `true` if key exists, `false` otherwise.
  /// This only checks local storage, not server.
  @override
  Future<bool> containsPreKey(int preKeyId) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    try {
      final value = await storage.getDecrypted(
        _storeName,
        _storeName,
        _preKey(preKeyId),
      );
      return value != null;
    } catch (e) {
      debugPrint(
        '[PREKEY STORE] ⚠️ PreKey decrypt failed, purging $preKeyId: $e',
      );
      try {
        await storage.deleteEncrypted(
          _storeName,
          _storeName,
          _preKey(preKeyId),
        );
      } catch (deleteError) {
        debugPrint(
          '[PREKEY STORE] Warning: Failed to delete corrupted prekey $preKeyId: $deleteError',
        );
      }
      return false;
    }

    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_storeName, _storeName, _preKey(preKeyId));
      return value != null;
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _preKey(preKeyId));
      return value != null;
    }
    */
  }

  /// Load a pre key record by ID (Signal protocol interface).
  ///
  /// Called by libsignal when:
  /// - Receiving a message encrypted with this pre key
  /// - Establishing a new session with a peer
  ///
  /// After loading, the key is consumed (deleted) by the protocol.
  /// Throws exception if key not found.
  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    if (await containsPreKey(preKeyId)) {
      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      dynamic value;
      try {
        value = await storage.getDecrypted(
          _storeName,
          _storeName,
          _preKey(preKeyId),
        );
      } catch (e) {
        debugPrint(
          '[PREKEY STORE] ⚠️ PreKey decrypt failed, purging $preKeyId: $e',
        );
        try {
          await storage.deleteEncrypted(
            _storeName,
            _storeName,
            _preKey(preKeyId),
          );
        } catch (deleteError) {
          debugPrint(
            '[PREKEY STORE] Warning: Failed to delete corrupted prekey $preKeyId: $deleteError',
          );
        }
        throw Exception('PreKey corrupted and purged: $preKeyId');
      }

      if (value != null) {
        return PreKeyRecord.fromBuffer(base64Decode(value));
      } else {
        throw Exception('Invalid prekey data');
      }

      /* LEGACY NATIVE STORAGE - DISABLED
      if (kIsWeb) {
        // Use encrypted device-scoped storage
        final storage = DeviceScopedStorageService.instance;
        final value = await storage.getDecrypted(_storeName, _storeName, _preKey(preKeyId));
        
        if (value != null) {
          return PreKeyRecord.fromBuffer(base64Decode(value));
        } else {
          throw Exception('Invalid prekey data');
        }
      } else {
        final storage = FlutterSecureStorage();
        var value = await storage.read(key: _preKey(preKeyId));
        if (value != null) {
          return PreKeyRecord.fromBuffer(base64Decode(value));
        } else {
          throw Exception('No such prekeyrecord! - $preKeyId');
        }
      }
      */
    } else {
      throw Exception('No such prekeyrecord! - $preKeyId');
    }
  }

  /// Remove a pre key from storage (Signal protocol interface).
  ///
  /// Parameters:
  /// - `sendToServer`: If true, notifies server of deletion. Set to false for local-only cleanup.
  ///
  /// Called when:
  /// - Pre key is consumed during session establishment
  /// - Cleaning up old/excess keys
  /// - Syncing with server state
  ///
  /// ⚡ Auto-Regeneration: After removal, automatically checks if count drops
  /// below 20 and triggers regeneration to maintain 110-key buffer.
  @override
  Future<void> removePreKey(int preKeyId, {bool sendToServer = true}) async {
    debugPrint('[PREKEY STORE] Removing PreKey $preKeyId');

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(_storeName, _storeName, _preKey(preKeyId));

    // Track own prekey usage for diagnostics (only when actually consumed, not during sync cleanup)
    if (sendToServer) {
      // Metrics tracking removed - can be re-added later if needed
    }

    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.deleteEncrypted(_storeName, _storeName, _preKey(preKeyId));
    } else {
      final storage = FlutterSecureStorage();
      await storage.delete(key: _preKey(preKeyId));
    }
    */

    // Send to server if requested
    if (sendToServer) {
      try {
        final response = await apiService.delete('/signal/prekey/$preKeyId');

        if (response.statusCode != 200 && response.statusCode != 204) {
          debugPrint(
            '[PREKEY STORE] ⚠️ Failed to delete PreKey $preKeyId from server: ${response.statusCode}',
          );
        }
      } catch (e) {
        debugPrint(
          '[PREKEY STORE] ⚠️ Error deleting PreKey $preKeyId from server: $e',
        );
        // Already deleted locally, so continue
      }
    }

    // ⚡ AUTO-REGENERATION: Check if we need to generate more PreKeys
    // This ensures we always maintain 20-110 key buffer automatically
    // Run in background (don't await) to avoid blocking message decryption
    checkPreKeys().catchError((e) {
      debugPrint('[PREKEY STORE] ⚠️ Auto-regeneration check failed: $e');
      // Don't propagate error - key was already deleted successfully
    });
  }

  /// Store a pre key record locally and optionally upload to server (Signal protocol interface).
  ///
  /// Parameters:
  /// - `sendToServer`: If true, uploads public key to server. Set to false for local-only storage.
  ///
  /// This stores the full PreKeyRecord (including private key) locally,
  /// but only uploads the public key to the server.
  @override
  Future<void> storePreKey(
    int preKeyId,
    PreKeyRecord record, {
    bool sendToServer = true,
  }) async {
    debugPrint("Storing pre key: $preKeyId");

    // Upload to server if requested
    if (sendToServer) {
      try {
        final response = await apiService.post(
          '/signal/prekey',
          data: {
            'id': preKeyId,
            'data': base64Encode(record.getKeyPair().publicKey.serialize()),
          },
        );

        if (response.statusCode != 200 && response.statusCode != 202) {
          debugPrint(
            '[PREKEY STORE] ⚠️ Failed to upload PreKey $preKeyId: ${response.statusCode}',
          );
        }
      } catch (e) {
        debugPrint('[PREKEY STORE] ⚠️ Error uploading PreKey $preKeyId: $e');
        // Continue - local storage is critical
      }
    }

    final serialized = record.serialize();

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.storeEncrypted(
      _storeName,
      _storeName,
      _preKey(preKeyId),
      base64Encode(serialized),
    );

    /* LEGACY NATIVE STORAGE - DISABLED
    if (kIsWeb) {
      // Use encrypted device-scoped storage
      final storage = DeviceScopedStorageService.instance;
      await storage.putEncrypted(_storeName, _storeName, _preKey(preKeyId), base64Encode(serialized));
    } else {
      final storage = FlutterSecureStorage();
      await storage.write(key: _preKey(preKeyId), value: base64Encode(serialized));
      // Track prekey key
      String? keysJson = await storage.read(key: 'prekey_keys');
      List<String> keys = [];
      if (keysJson != null) {
        keys = List<String>.from(jsonDecode(keysJson));
      }
      final preKeyStr = _preKey(preKeyId);
      if (!keys.contains(preKeyStr)) {
        keys.add(preKeyStr);
        await storage.write(key: 'prekey_keys', value: jsonEncode(keys));
      }
    }
    */
  }

  // ============================================================================
  // PUBLIC API METHODS (High-level operations from PreKeyManager)
  // ============================================================================

  /// Target number of PreKeys to maintain.
  /// Signal Protocol recommendation: 110 keys.
  int get targetPreKeys => 110;

  /// Minimum threshold before regenerating PreKeys.
  /// Regenerate when count drops below this number.
  int get minPreKeys => 20;

  /// Maximum PreKey ID allowed by Signal Protocol.
  /// IDs wrap to 0 after reaching this limit.
  int get maxPreKeyId => 16777215; // 0xFFFFFF

  /// Check if any PreKeys exist in local storage.
  ///
  /// Returns:
  /// - `true`: At least one key exists
  /// - `false`: No keys exist (need to generate)
  ///
  /// Useful for initialization checks and diagnostics.
  Future<bool> hasPreKeys() async {
    final ids = await getAllPreKeyIds();
    return ids.isNotEmpty;
  }

  /// Generate and store PreKeys in a range (batch operation).
  ///
  /// Parameters:
  /// - `start`: First key ID (inclusive)
  /// - `end`: Last key ID (inclusive)
  ///
  /// Returns: List of generated [PreKeyRecord] objects.
  ///
  /// Example:
  /// ```dart
  /// // Generate keys 0-109 (110 keys total)
  /// final keys = await generatePreKeysInRange(0, 109);
  /// ```
  ///
  /// Note: Keys are automatically stored locally during generation.
  Future<List<PreKeyRecord>> generatePreKeysInRange(int start, int end) async {
    debugPrint(
      '[PRE_KEY_MANAGER] Generating PreKeys from $start to $end (${end - start + 1} keys)',
    );

    final preKeys = generatePreKeys(start, end);

    // Store locally first (no server upload yet)
    for (final preKey in preKeys) {
      await storePreKey(preKey.id, preKey, sendToServer: false);
    }

    // Upload all keys to server in one batch
    await uploadPreKeys(preKeys);

    debugPrint('[PRE_KEY_MANAGER] ✓ Generated ${preKeys.length} PreKeys');
    return preKeys;
  }

  /// Get count of locally stored PreKeys.
  ///
  /// Returns: Number of PreKeys in local storage (should be 20-110).
  ///
  /// Useful for:
  /// - Monitoring key availability
  /// - Determining if regeneration is needed
  /// - Diagnostics and logging
  ///
  /// Note: Returns cached count from PreKeyState (non-blocking).
  /// For accurate count, call checkPreKeys() first which updates the state.
  int getLocalPreKeyCount() {
    return preKeyState.count;
  }

  /// Generate PreKey fingerprints (hashes) for validation.
  ///
  /// Returns: Map of keyId (as string) -> base64 hash of public key.
  ///
  /// Use cases:
  /// - Verifying PreKeys match between client and server
  /// - Detecting corruption or tampering
  /// - Debugging sync issues
  ///
  /// Example:
  /// ```dart
  /// final fingerprints = await getPreKeyFingerprints();
  /// print('Key 5 hash: ${fingerprints["5"]}');
  /// ```
  Future<Map<String, String>> getPreKeyFingerprints() async {
    try {
      final keyIds = await getAllPreKeyIds();
      final fingerprints = <String, String>{};

      for (final id in keyIds) {
        try {
          final preKey = await loadPreKey(id);
          final publicKeyBytes = preKey.getKeyPair().publicKey.serialize();
          final hash = base64Encode(publicKeyBytes);
          fingerprints[id.toString()] = hash;
        } catch (e) {
          debugPrint(
            '[PRE_KEY_MANAGER] Failed to get fingerprint for PreKey $id: $e',
          );
        }
      }

      debugPrint(
        '[PRE_KEY_MANAGER] Generated ${fingerprints.length} PreKey fingerprints',
      );
      return fingerprints;
    } catch (e) {
      debugPrint('[PRE_KEY_MANAGER] Error generating PreKey fingerprints: $e');
      return {};
    }
  }

  /// Upload PreKeys to server in batch via HTTP.
  ///
  /// Parameters:
  /// - `preKeys`: List of PreKeyRecords to upload (only public keys sent)
  ///
  /// This uses ApiService.post for reliable acknowledgment.
  /// Throws exception if upload fails.
  ///
  /// Note: This is used for batch uploads. For single keys, use [storePreKey].
  Future<void> uploadPreKeys(List<PreKeyRecord> preKeys) async {
    debugPrint(
      '[PRE_KEY_MANAGER] Uploading ${preKeys.length} PreKeys to server...',
    );

    final preKeysPayload = preKeys
        .map(
          (pk) => {
            'id': pk.id,
            'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
          },
        )
        .toList();

    final success = await _postPreKeysWithRetry(
      '/signal/prekeys/batch',
      data: {'preKeys': preKeysPayload},
    );

    if (!success) {
      throw Exception('Failed to upload PreKeys after retries');
    }

    debugPrint('[PRE_KEY_MANAGER] ✓ ${preKeys.length} PreKeys uploaded');
  }

  /// Synchronize local PreKey IDs with server state.
  ///
  /// Parameters:
  /// - `serverKeyIds`: List of PreKey IDs that the server has
  ///
  /// This compares local storage with server and:
  /// 1. Finds PreKeys that exist locally but not on server
  /// 2. Uploads missing PreKeys to server
  ///
  /// Called by: SessionListeners when 'preKeyIdsSyncResponse' socket event fires.
  ///
  /// Example:
  /// ```dart
  /// // Server sends list of IDs it has
  /// await syncPreKeyIds([1, 2, 3, 5, 7]);
  /// // Will upload keys 4, 6, 8-110 if they exist locally
  /// ```
  Future<void> syncPreKeyIds(List<int> serverKeyIds) async {
    try {
      debugPrint(
        '[PRE_KEY_MANAGER] Syncing PreKey IDs (server has ${serverKeyIds.length})',
      );

      // Get local PreKey IDs - check ALL stored keys, not just 1-110
      // PreKey IDs increment continuously (can be 0-16777215)
      final localKeyIds = await getAllPreKeyIds();

      debugPrint('[PRE_KEY_MANAGER] Local PreKeys: ${localKeyIds.length}');

      // Find PreKeys that exist locally but not on server
      final missingOnServer = localKeyIds
          .where((id) => !serverKeyIds.contains(id))
          .toList();

      if (missingOnServer.isEmpty) {
        debugPrint('[PRE_KEY_MANAGER] ✓ Server has all local PreKeys');
        return;
      }

      debugPrint(
        '[PRE_KEY_MANAGER] Server missing ${missingOnServer.length} PreKeys: $missingOnServer',
      );

      // Upload missing PreKeys
      final preKeysToUpload = <PreKeyRecord>[];
      bool hadCorruptKeys = false;
      for (final id in missingOnServer) {
        try {
          final preKey = await loadPreKey(id);
          preKeysToUpload.add(preKey);
        } catch (e) {
          debugPrint('[PRE_KEY_MANAGER] Failed to load PreKey $id: $e');
          hadCorruptKeys = true;
          try {
            await removePreKey(id, sendToServer: false);
            debugPrint('[PRE_KEY_MANAGER] Removed corrupt PreKey $id');
          } catch (removeError) {
            debugPrint(
              '[PRE_KEY_MANAGER] Failed to remove corrupt PreKey $id: $removeError',
            );
          }
        }
      }

      if (preKeysToUpload.isNotEmpty) {
        await uploadPreKeys(preKeysToUpload);
        debugPrint(
          '[PRE_KEY_MANAGER] ✓ Uploaded ${preKeysToUpload.length} missing PreKeys',
        );
      }

      if (hadCorruptKeys) {
        try {
          await checkPreKeys();
        } catch (e) {
          debugPrint(
            '[PRE_KEY_MANAGER] PreKey regen after corruption failed: $e',
          );
        }
      }
    } catch (e, stack) {
      debugPrint('[PRE_KEY_MANAGER] Error syncing PreKey IDs: $e');
      debugPrint('[PRE_KEY_MANAGER] Stack: $stack');
      // Don't rethrow - this is a sync operation
    }
  }

  /// Regenerate PreKeys with progress tracking (for recovery scenarios).
  ///
  /// Parameters:
  /// - `onProgress`: Callback for progress updates (statusText, current, total, percentage)
  /// - `existingPreKeyIds`: List of PreKey IDs that already exist
  ///
  /// This method:
  /// 1. Calculates how many PreKeys needed to reach 110 total
  /// 2. Calls checkPreKeys() to generate missing keys
  /// 3. Reports progress via callback
  ///
  /// Used during account recovery or when corruption is detected.
  ///
  /// Note: PreKey IDs increment continuously (0-16,777,215), no ID is "invalid".
  Future<void> regeneratePreKeysWithProgress(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
    List<int> existingPreKeyIds,
  ) async {
    const int totalSteps = 110;
    int currentStep = existingPreKeyIds.length;

    void updateProgress(String status, int step) {
      final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
      onProgress(status, step, totalSteps, percentage);
    }

    debugPrint('[PRE_KEY_MANAGER] Starting PreKey regeneration...');
    debugPrint(
      '[PRE_KEY_MANAGER] Existing PreKeys: ${existingPreKeyIds.length}/110',
    );

    // Note: PreKey IDs increment continuously (0 to 16,777,215)
    // No need to check for "invalid" IDs - they're all valid until max limit

    final neededPreKeys = 110 - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[PRE_KEY_MANAGER] Need to generate $neededPreKeys pre keys');

      try {
        await checkPreKeys();
        final updatedIds = await getAllPreKeyIds();
        final keysGenerated = updatedIds.length - existingPreKeyIds.length;

        debugPrint('[PRE_KEY_MANAGER] ✓ Generated $keysGenerated PreKeys');
        updateProgress(
          'Pre keys ready (${updatedIds.length}/110)',
          currentStep + keysGenerated,
        );
      } catch (e) {
        debugPrint('[PRE_KEY_MANAGER] ⚠️ PreKey generation failed: $e');
      }
    }

    updateProgress('Signal Protocol ready', totalSteps);
    debugPrint('[PRE_KEY_MANAGER] ✓ PreKey regeneration successful');
  }

  /// Generate PreKeys for initialization with progress tracking.
  ///
  /// Parameters:
  /// - `onProgress`: Callback for progress updates
  /// - `currentStep`: Current initialization step number
  /// - `existingPreKeyIds`: PreKey IDs that already exist
  ///
  /// This method:
  /// 1. Cleans up excess PreKeys (if > 110)
  /// 2. Generates missing PreKeys to reach 110 total
  /// 3. Reports progress via callback
  ///
  /// Called during KeyManager initialization.
  Future<void> generatePreKeysForInit(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
    int currentStep,
    List<int> existingPreKeyIds,
  ) async {
    const int totalSteps = 112; // 1 KeyPair + 1 SignedPreKey + 110 PreKeys
    const int targetPrekeys = 110;

    // Cleanup excess PreKeys if > 110
    if (existingPreKeyIds.length > targetPrekeys) {
      debugPrint(
        '[PRE_KEY_MANAGER] Found ${existingPreKeyIds.length} PreKeys (expected $targetPrekeys)',
      );
      debugPrint('[PRE_KEY_MANAGER] Deleting excess PreKeys...');

      final sortedIds = List<int>.from(existingPreKeyIds)..sort();
      final toDelete = sortedIds.skip(targetPrekeys).toList();
      for (final id in toDelete) {
        await removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = sortedIds.take(targetPrekeys).toList();
      debugPrint(
        '[PRE_KEY_MANAGER] Cleanup complete, now have ${existingPreKeyIds.length} PreKeys',
      );
    }

    final neededPreKeys = targetPrekeys - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[PRE_KEY_MANAGER] Need to generate $neededPreKeys pre keys');

      try {
        await checkPreKeys();
        final updatedIds = await getAllPreKeyIds();
        final keysGenerated = updatedIds.length - existingPreKeyIds.length;

        debugPrint('[PRE_KEY_MANAGER] ✓ Generated $keysGenerated PreKeys');

        void updateProgress(String status, int step) {
          final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
          onProgress(status, step, totalSteps, percentage);
        }

        updateProgress(
          'Pre keys ready (${updatedIds.length}/110)',
          currentStep + keysGenerated,
        );
      } catch (e) {
        debugPrint('[PRE_KEY_MANAGER] ⚠️ PreKey generation failed: $e');
      }
    } else {
      debugPrint(
        '[PRE_KEY_MANAGER] Pre keys already sufficient (${existingPreKeyIds.length}/$targetPrekeys)',
      );

      void updateProgress(String status, int step) {
        final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
        onProgress(status, step, totalSteps, percentage);
      }

      updateProgress('Pre keys already ready', totalSteps);
    }
  }
}
