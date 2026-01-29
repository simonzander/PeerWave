import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'dart:convert';
import '../../api_service.dart';
import '../../permanent_identity_key_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../sender_key_store.dart';
import '../../../core/metrics/key_management_metrics.dart';

/// Manages Signal Protocol cryptographic keys
///
/// Responsibilities:
/// - Key generation (Identity, SignedPreKey, PreKeys)
/// - Key rotation and lifecycle management
/// - Server validation and verification
/// - Key upload via REST API
/// - Store creation and initialization
///
/// This class is the source of truth for all key operations
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final keyManager = await SignalKeyManager.create();
///
/// // With progress tracking
/// final keyManager = SignalKeyManager();
/// await keyManager.initWithProgress((text, current, total, percentage) {
///   print('$text: $current/$total ($percentage%)');
/// });
/// ```
class SignalKeyManager {
  PermanentIdentityKeyStore? _identityStore;
  PermanentPreKeyStore? _preKeyStore;
  PermanentSignedPreKeyStore? _signedPreKeyStore;
  PermanentSenderKeyStore? _senderKeyStore;

  bool _initialized = false;

  // Getters for stores (throw if not initialized)
  PermanentIdentityKeyStore get identityStore {
    if (_identityStore == null) throw StateError('KeyManager not initialized');
    return _identityStore!;
  }

  PermanentPreKeyStore get preKeyStore {
    if (_preKeyStore == null) throw StateError('KeyManager not initialized');
    return _preKeyStore!;
  }

  PermanentSignedPreKeyStore get signedPreKeyStore {
    if (_signedPreKeyStore == null)
      throw StateError('KeyManager not initialized');
    return _signedPreKeyStore!;
  }

  PermanentSenderKeyStore get senderKeyStore {
    if (_senderKeyStore == null) throw StateError('KeyManager not initialized');
    return _senderKeyStore!;
  }

  bool get isInitialized => _initialized;

  // Private constructor for factory
  SignalKeyManager._();

  /// Self-initializing factory - creates stores and validates keys
  static Future<SignalKeyManager> create() async {
    final manager = SignalKeyManager._();
    await manager.init();
    return manager;
  }

  /// Initialize stores and validate keys exist
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[KEY_MANAGER] Already initialized');
      return;
    }

    debugPrint('[KEY_MANAGER] Initializing stores...');

    // Create stores
    _identityStore = PermanentIdentityKeyStore();
    _preKeyStore = PermanentPreKeyStore();

    // Get identity key pair (auto-generates if missing)
    final identityKeyPair = await _identityStore!.getIdentityKeyPair();
    _signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
    _senderKeyStore = await PermanentSenderKeyStore.create();

    // Validate keys exist
    await ensureIdentityKeyExists();

    debugPrint('[KEY_MANAGER] ✓ Initialized');
    _initialized = true;
  }

  /// Initialize with progress tracking for UI
  /// Generates keys in batches to prevent UI freeze
  ///
  /// Progress callback receives:
  /// - statusText: Current operation description
  /// - current: Current progress (0-112)
  /// - total: Total steps (112: 1 KeyPair + 1 SignedPreKey + 110 PreKeys)
  /// - percentage: Progress percentage (0-100)
  Future<void> initWithProgress(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
  ) async {
    if (_initialized) {
      debugPrint('[KEY_MANAGER] Already initialized, checking PreKeys...');

      // Check if PreKeys need regeneration
      final preKeyIds = await preKeyStore.getAllPreKeyIds();
      const int targetPrekeys = 110;
      const int minPrekeys = 20;

      if (preKeyIds.length >= minPrekeys) {
        debugPrint(
          '[KEY_MANAGER] PreKeys sufficient (${preKeyIds.length}/$targetPrekeys)',
        );
        onProgress('Signal Protocol ready', 112, 112, 100.0);
        return;
      }

      debugPrint(
        '[KEY_MANAGER] PreKeys insufficient (${preKeyIds.length}/$targetPrekeys), regenerating...',
      );
      await _regeneratePreKeysWithProgress(onProgress, preKeyIds);
      return;
    }

    debugPrint('[KEY_MANAGER] Initializing with progress tracking...');

    const int totalSteps = 112; // 1 KeyPair + 1 SignedPreKey + 110 PreKeys
    int currentStep = 0;

    // Helper to update progress
    void updateProgress(String status, int step) {
      final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
      onProgress(status, step, totalSteps, percentage);
    }

    // Create stores
    _identityStore = PermanentIdentityKeyStore();
    _preKeyStore = PermanentPreKeyStore();

    // Step 1: Generate Identity Key Pair (if needed)
    updateProgress('Generating identity key pair...', currentStep);
    final identityKeyPair = await _identityStore!.getIdentityKeyPair();
    _signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
    _senderKeyStore = await PermanentSenderKeyStore.create();
    currentStep++;
    updateProgress('Identity key pair ready', currentStep);
    await Future.delayed(const Duration(milliseconds: 50));

    // Step 2: Generate Signed PreKey (if needed)
    updateProgress('Generating signed pre key...', currentStep);
    final existingSignedKeys = await _signedPreKeyStore!.loadSignedPreKeys();
    if (existingSignedKeys.isEmpty) {
      final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
      await _signedPreKeyStore!.storeSignedPreKey(
        signedPreKey.id,
        signedPreKey,
      );
      debugPrint('[KEY_MANAGER] Signed pre key generated');
    } else {
      debugPrint('[KEY_MANAGER] Signed pre key already exists');
    }
    currentStep++;
    updateProgress('Signed pre key ready', currentStep);
    await Future.delayed(const Duration(milliseconds: 50));

    // Step 3: Generate PreKeys (110 keys)
    var existingPreKeyIds = await _preKeyStore!.getAllPreKeyIds();

    // Cleanup excess PreKeys if > 110
    const int targetPrekeys = 110;
    if (existingPreKeyIds.length > targetPrekeys) {
      debugPrint(
        '[KEY_MANAGER] Found ${existingPreKeyIds.length} PreKeys (expected $targetPrekeys)',
      );
      debugPrint('[KEY_MANAGER] Deleting excess PreKeys...');

      final sortedIds = List<int>.from(existingPreKeyIds)..sort();
      final toDelete = sortedIds.skip(targetPrekeys).toList();
      for (final id in toDelete) {
        await _preKeyStore!.removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = sortedIds.take(targetPrekeys).toList();
      debugPrint(
        '[KEY_MANAGER] Cleanup complete, now have ${existingPreKeyIds.length} PreKeys',
      );
    }

    final neededPreKeys = targetPrekeys - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[KEY_MANAGER] Need to generate $neededPreKeys pre keys');

      try {
        await _preKeyStore!.checkPreKeys();
        final updatedIds = await _preKeyStore!.getAllPreKeyIds();
        final keysGenerated = updatedIds.length - existingPreKeyIds.length;

        debugPrint('[KEY_MANAGER] ✓ Generated $keysGenerated PreKeys');

        updateProgress(
          'Pre keys ready (${updatedIds.length}/110)',
          currentStep + keysGenerated,
        );
        currentStep += keysGenerated;

        if (keysGenerated > 0) {
          KeyManagementMetrics.recordPreKeyRegeneration(
            keysGenerated,
            reason: 'Initialization',
          );
        }
      } catch (e) {
        debugPrint('[KEY_MANAGER] ⚠️ PreKey generation failed: $e');
      }
    } else {
      debugPrint(
        '[KEY_MANAGER] Pre keys already sufficient (${existingPreKeyIds.length}/$targetPrekeys)',
      );
      currentStep = totalSteps;
      updateProgress('Pre keys already ready', currentStep);
    }

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    _initialized = true;
    debugPrint('[KEY_MANAGER] ✓ Initialization complete');
  }

  /// Regenerate PreKeys when already initialized but PreKeys are missing
  Future<void> _regeneratePreKeysWithProgress(
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

    debugPrint('[KEY_MANAGER] Starting PreKey regeneration...');
    debugPrint(
      '[KEY_MANAGER] Existing PreKeys: ${existingPreKeyIds.length}/110',
    );

    // Check for invalid IDs (>= 110)
    final hasInvalidIds = existingPreKeyIds.any((id) => id >= 110);
    if (hasInvalidIds) {
      final invalidIds = existingPreKeyIds.where((id) => id >= 110).toList();
      debugPrint(
        '[KEY_MANAGER] ⚠️ Found invalid PreKey IDs (>= 110): $invalidIds',
      );
      debugPrint(
        '[KEY_MANAGER] 🔧 Deleting ALL PreKeys and regenerating fresh set...',
      );

      for (final id in existingPreKeyIds) {
        await preKeyStore.removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = [];
      debugPrint(
        '[KEY_MANAGER] ✓ Cleanup complete, will generate fresh 110 PreKeys',
      );
    }

    final neededPreKeys = 110 - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[KEY_MANAGER] Need to generate $neededPreKeys pre keys');

      try {
        await preKeyStore.checkPreKeys();
        final updatedIds = await preKeyStore.getAllPreKeyIds();
        final keysGenerated = updatedIds.length - existingPreKeyIds.length;

        debugPrint('[KEY_MANAGER] ✓ Generated $keysGenerated PreKeys');
        updateProgress(
          'Pre keys ready (${updatedIds.length}/110)',
          currentStep + keysGenerated,
        );
      } catch (e) {
        debugPrint('[KEY_MANAGER] ⚠️ PreKey generation failed: $e');
      }
    }

    updateProgress('Signal Protocol ready', totalSteps);
    debugPrint('[KEY_MANAGER] ✓ PreKey regeneration successful');
  }

  /// Validate keys with server
  Future<bool> validateKeysWithServer() async {
    if (!_initialized) {
      debugPrint('[KEY_MANAGER] Cannot validate - not initialized');
      return false;
    }

    try {
      final preKeyFingerprints = await getPreKeyFingerprints();

      final response = await ApiService.post(
        '/signal/validate-and-sync',
        data: {
          'localIdentityKey': await getLocalIdentityPublicKey(),
          'localSignedPreKeyId': await getLatestSignedPreKeyId(),
          'localPreKeyCount': await getLocalPreKeyCount(),
          'preKeyFingerprints': preKeyFingerprints,
        },
      );

      final keysValid = response.data['keysValid'] == true;
      debugPrint('[KEY_MANAGER] Server validation result: $keysValid');
      return keysValid;
    } catch (e) {
      debugPrint('[KEY_MANAGER] Key validation failed: $e');
      return false;
    }
  }

  /// Legacy constructor for compatibility (deprecated)
  @deprecated
  SignalKeyManager({
    required PermanentIdentityKeyStore identityStore,
    required PermanentPreKeyStore preKeyStore,
    required PermanentSignedPreKeyStore signedPreKeyStore,
    required PermanentSenderKeyStore senderKeyStore,
  }) {
    _identityStore = identityStore;
    _preKeyStore = preKeyStore;
    _signedPreKeyStore = signedPreKeyStore;
    _senderKeyStore = senderKeyStore;
    _initialized = true;
  }

  // ============================================================================
  // SENDER KEY VALIDATION & ROTATION
  // ============================================================================

  /// Check if sender key needs rotation
  /// Returns true if key is older than 7 days or has been used for 1000+ messages
  Future<bool> shouldRotateSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      return await senderKeyStore.needsRotation(senderKeyName);
    } catch (e) {
      debugPrint('[KEY_MANAGER] Error checking sender key rotation: $e');
      return false;
    }
  }

  /// Test sender key validity (prevent corruption errors)
  /// Returns true if key is valid
  Future<bool> validateSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      debugPrint('[KEY_MANAGER] Testing sender key validity...');

      final senderKeyName = SenderKeyName(groupId, senderAddress);
      final testCipher = GroupCipher(senderKeyStore, senderKeyName);
      final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);

      await testCipher.encrypt(testMessage);

      debugPrint('[KEY_MANAGER] ✓ Sender key validation passed');
      return true;
    } catch (e) {
      debugPrint('[KEY_MANAGER] ⚠️ Sender key validation failed: $e');
      return false;
    }
  }

  // ============================================================================
  // KEY GENERATION
  // ============================================================================

  /// Generate and store PreKeys in a range
  /// Returns list of generated PreKey records
  Future<List<PreKeyRecord>> generatePreKeysInRange(int start, int end) async {
    debugPrint(
      '[KEY_MANAGER] Generating PreKeys from $start to $end (${end - start + 1} keys)',
    );

    final preKeys = generatePreKeys(start, end);

    for (final preKey in preKeys) {
      await preKeyStore.storePreKey(preKey.id, preKey);
    }

    debugPrint('[KEY_MANAGER] ✓ Generated ${preKeys.length} PreKeys');
    return preKeys;
  }

  /// Generate and store a new SignedPreKey
  /// Returns the generated SignedPreKey record
  Future<SignedPreKeyRecord> generateNewSignedPreKey(int keyId) async {
    debugPrint('[KEY_MANAGER] Generating SignedPreKey with ID $keyId');

    final identityKeyPair = await identityStore.getIdentityKeyPair();
    final signedPreKey = generateSignedPreKey(identityKeyPair, keyId);

    await signedPreKeyStore.storeSignedPreKey(keyId, signedPreKey);

    debugPrint('[KEY_MANAGER] ✓ Generated SignedPreKey');
    return signedPreKey;
  }

  /// Ensure identity key pair exists, generate if missing
  /// Returns the identity key pair
  ///
  /// Note: The identity store handles generation automatically via getIdentityKeyPairData()
  /// This method just ensures the key pair is loaded
  Future<IdentityKeyPair> ensureIdentityKeyExists() async {
    try {
      // This will auto-generate if missing
      return await identityStore.getIdentityKeyPair();
    } catch (e) {
      debugPrint('[KEY_MANAGER] Error ensuring identity key exists: $e');
      rethrow;
    }
  }

  // ============================================================================
  // KEY VALIDATION & FINGERPRINTS
  // ============================================================================

  /// Get local identity public key as base64 string
  Future<String?> getLocalIdentityPublicKey() async {
    try {
      final identity = await identityStore.getIdentityKeyPairData();
      return identity['publicKey'];
    } catch (e) {
      debugPrint('[KEY_MANAGER] Error getting local identity public key: $e');
      return null;
    }
  }

  /// Get latest SignedPreKey ID
  Future<int?> getLatestSignedPreKeyId() async {
    try {
      final keys = await signedPreKeyStore.loadSignedPreKeys();
      return keys.isNotEmpty ? keys.last.id : null;
    } catch (e) {
      debugPrint('[KEY_MANAGER] Error getting latest SignedPreKey ID: $e');
      return null;
    }
  }

  /// Get local PreKey count
  Future<int> getLocalPreKeyCount() async {
    try {
      final ids = await preKeyStore.getAllPreKeyIds();
      return ids.length;
    } catch (e) {
      debugPrint('[KEY_MANAGER] Error getting local PreKey count: $e');
      return 0;
    }
  }

  /// Generate PreKey fingerprints (hashes) for validation
  /// Returns map of keyId -> hash for all keys
  Future<Map<String, String>> getPreKeyFingerprints() async {
    try {
      final keyIds = await preKeyStore.getAllPreKeyIds();
      final fingerprints = <String, String>{};

      for (final id in keyIds) {
        try {
          final preKey = await preKeyStore.loadPreKey(id);
          final publicKeyBytes = preKey.getKeyPair().publicKey.serialize();
          final hash = base64Encode(publicKeyBytes);
          fingerprints[id.toString()] = hash;
        } catch (e) {
          debugPrint(
            '[KEY_MANAGER] Failed to get fingerprint for PreKey $id: $e',
          );
        }
      }

      debugPrint(
        '[KEY_MANAGER] Generated ${fingerprints.length} PreKey fingerprints',
      );
      return fingerprints;
    } catch (e) {
      debugPrint('[KEY_MANAGER] Error generating PreKey fingerprints: $e');
      return {};
    }
  }

  // ============================================================================
  // KEY ROTATION
  // ============================================================================

  /// Check if SignedPreKey needs rotation (older than 7 days)
  Future<bool> needsSignedPreKeyRotation() async {
    return await signedPreKeyStore.needsRotation();
  }

  /// Rotate SignedPreKey and upload to server
  Future<void> rotateSignedPreKey() async {
    try {
      debugPrint('[KEY_MANAGER] Starting SignedPreKey rotation...');

      final identityKeyPair = await identityStore.getIdentityKeyPair();
      await signedPreKeyStore.rotateSignedPreKey(identityKeyPair);

      debugPrint('[KEY_MANAGER] ✓ SignedPreKey rotation completed');
    } catch (e, stackTrace) {
      debugPrint('[KEY_MANAGER] Error during SignedPreKey rotation: $e');
      debugPrint('[KEY_MANAGER] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Check and perform SignedPreKey rotation if needed
  Future<void> checkAndRotateSignedPreKey() async {
    try {
      final needsRotation = await needsSignedPreKeyRotation();
      if (needsRotation) {
        debugPrint('[KEY_MANAGER] SignedPreKey rotation needed');
        await rotateSignedPreKey();
      } else {
        debugPrint(
          '[KEY_MANAGER] SignedPreKey rotation not needed (< 7 days old)',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[KEY_MANAGER] Error during rotation check: $e');
      debugPrint('[KEY_MANAGER] Stack trace: $stackTrace');
    }
  }

  // ============================================================================
  // SERVER UPLOAD (REST API)
  // ============================================================================

  /// Upload identity key to server
  Future<void> uploadIdentityKey() async {
    debugPrint('[KEY_MANAGER] Uploading identity key to server...');

    final identityData = await identityStore.getIdentityKeyPairData();
    final registrationId = await identityStore.getLocalRegistrationId();

    final response = await ApiService.post(
      '/signal/identity',
      data: {
        'publicKey': identityData['publicKey'],
        'registrationId': registrationId.toString(),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to upload identity: ${response.statusCode}');
    }

    debugPrint('[KEY_MANAGER] ✓ Identity key uploaded');
  }

  /// Upload SignedPreKey to server
  Future<void> uploadSignedPreKey(SignedPreKeyRecord signedPreKey) async {
    debugPrint('[KEY_MANAGER] Uploading SignedPreKey to server...');

    final response = await ApiService.post(
      '/signal/signedprekey',
      data: {
        'id': signedPreKey.id,
        'data': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signedPreKey.signature),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to upload SignedPreKey: ${response.statusCode}');
    }

    debugPrint('[KEY_MANAGER] ✓ SignedPreKey uploaded');
  }

  /// Upload PreKeys to server in batch
  Future<void> uploadPreKeys(List<PreKeyRecord> preKeys) async {
    debugPrint(
      '[KEY_MANAGER] Uploading ${preKeys.length} PreKeys to server...',
    );

    final preKeysPayload = preKeys
        .map(
          (pk) => {
            'id': pk.id,
            'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
          },
        )
        .toList();

    final response = await ApiService.post(
      '/signal/prekeys/batch',
      data: {'preKeys': preKeysPayload},
    );

    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception('Failed to upload PreKeys: ${response.statusCode}');
    }

    debugPrint('[KEY_MANAGER] ✓ ${preKeys.length} PreKeys uploaded');
  }

  /// Delete all keys on server
  Future<Map<String, dynamic>> deleteAllKeysOnServer() async {
    debugPrint('[KEY_MANAGER] Deleting all keys on server...');

    final response = await ApiService.delete('/signal/keys');

    if (response.statusCode != 200) {
      throw Exception('Failed to delete keys: ${response.statusCode}');
    }

    final result = response.data as Map<String, dynamic>;
    debugPrint(
      '[KEY_MANAGER] ✓ Keys deleted: ${result['preKeysDeleted']} PreKeys, ${result['signedPreKeysDeleted']} SignedPreKeys',
    );

    return result;
  }

  // ============================================================================
  // SERVER VERIFICATION
  // ============================================================================

  /// Verify our own keys are valid on the server
  /// Returns true if all keys are valid, false if corruption detected
  ///
  /// Validates:
  /// - Identity key exists and matches
  /// - SignedPreKey exists and signature is valid
  /// - PreKeys exist in adequate quantity
  /// - PreKey fingerprints match (hash validation)
  Future<bool> verifyOwnKeysOnServer(String userId, int deviceId) async {
    try {
      debugPrint('[KEY_MANAGER] ========================================');
      debugPrint('[KEY_MANAGER] Starting key verification on server...');
      debugPrint('[KEY_MANAGER] User: $userId, Device: $deviceId');

      // Fetch key status from server
      final response = await ApiService.get(
        '/signal/status/minimal',
        queryParameters: {'userId': userId, 'deviceId': deviceId.toString()},
      );

      final serverData = response.data as Map<String, dynamic>;

      // 1. Verify identity key
      final serverIdentityKey = serverData['identityKey'] as String?;
      if (serverIdentityKey == null) {
        debugPrint('[KEY_MANAGER] ❌ Server has NO identity key!');
        return false;
      }

      final localIdentityKey = await getLocalIdentityPublicKey();
      if (serverIdentityKey != localIdentityKey) {
        debugPrint('[KEY_MANAGER] ❌ Identity key MISMATCH!');
        debugPrint('[KEY_MANAGER]   Local:  $localIdentityKey');
        debugPrint('[KEY_MANAGER]   Server: $serverIdentityKey');
        return false;
      }
      debugPrint('[KEY_MANAGER] ✓ Identity key matches');

      // 2. Verify SignedPreKey
      final serverSignedPreKey = serverData['signedPreKey'] as String?;
      final serverSignedPreKeySignature =
          serverData['signedPreKeySignature'] as String?;

      if (serverSignedPreKey == null || serverSignedPreKeySignature == null) {
        debugPrint('[KEY_MANAGER] ❌ Server has NO SignedPreKey!');
        return false;
      }

      // Verify SignedPreKey signature
      try {
        final identityKeyPair = await identityStore.getIdentityKeyPair();
        final localPublicKey = Curve.decodePoint(
          identityKeyPair.getPublicKey().serialize(),
          0,
        );
        final signedPreKeyBytes = base64Decode(serverSignedPreKey);
        final signatureBytes = base64Decode(serverSignedPreKeySignature);

        final isValid = Curve.verifySignature(
          localPublicKey,
          signedPreKeyBytes,
          signatureBytes,
        );

        if (!isValid) {
          debugPrint('[KEY_MANAGER] ❌ SignedPreKey signature INVALID!');
          return false;
        }
        debugPrint('[KEY_MANAGER] ✓ SignedPreKey valid');
      } catch (e) {
        debugPrint('[KEY_MANAGER] ❌ SignedPreKey validation error: $e');
        return false;
      }

      // 3. Verify PreKeys count
      final preKeysCount = serverData['preKeysCount'] as int? ?? 0;
      if (preKeysCount == 0) {
        debugPrint('[KEY_MANAGER] ❌ Server has ZERO PreKeys!');
        return false;
      }

      if (preKeysCount < 10) {
        debugPrint('[KEY_MANAGER] ⚠️ Low PreKey count: $preKeysCount');
      } else {
        debugPrint('[KEY_MANAGER] ✓ PreKeys count adequate: $preKeysCount');
      }

      // 4. Verify PreKey fingerprints (hash validation)
      final serverFingerprints =
          serverData['preKeyFingerprints'] as Map<String, dynamic>?;
      if (serverFingerprints != null && serverFingerprints.isNotEmpty) {
        debugPrint('[KEY_MANAGER] Validating PreKey fingerprints...');

        final localFingerprints = await getPreKeyFingerprints();

        int matchCount = 0;
        int mismatchCount = 0;
        final mismatches = <String>[];

        // Compare server vs local
        for (final entry in serverFingerprints.entries) {
          final keyId = entry.key;
          final serverHash = entry.value as String?;
          final localHash = localFingerprints[keyId];

          if (localHash == null) {
            debugPrint(
              '[KEY_MANAGER] ⚠️ PreKey $keyId on server but not local',
            );
            mismatchCount++;
            mismatches.add(keyId);
          } else if (serverHash != localHash) {
            debugPrint('[KEY_MANAGER] ❌ PreKey $keyId HASH MISMATCH!');
            mismatchCount++;
            mismatches.add(keyId);
          } else {
            matchCount++;
          }
        }

        // Check for local keys not on server
        for (final keyId in localFingerprints.keys) {
          if (!serverFingerprints.containsKey(keyId)) {
            debugPrint(
              '[KEY_MANAGER] ⚠️ PreKey $keyId local but not on server',
            );
            mismatchCount++;
            mismatches.add(keyId);
          }
        }

        debugPrint(
          '[KEY_MANAGER] PreKey validation: $matchCount matched, $mismatchCount mismatched',
        );

        if (mismatchCount > 0) {
          debugPrint(
            '[KEY_MANAGER] ❌ PreKey corruption detected! Mismatched: ${mismatches.take(5).join(", ")}',
          );
          return false;
        }

        debugPrint('[KEY_MANAGER] ✓ All PreKey hashes valid');
      } else {
        debugPrint('[KEY_MANAGER] ⚠️ No PreKey fingerprints from server');
      }

      debugPrint('[KEY_MANAGER] ========================================');
      debugPrint('[KEY_MANAGER] ✅ All keys verified successfully');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[KEY_MANAGER] ❌ Verification failed: $e');
      debugPrint('[KEY_MANAGER] Stack trace: $stackTrace');
      return false;
    }
  }

  // ============================================================================
  // COMPLETE KEY UPLOAD WORKFLOW
  // ============================================================================

  /// Upload all keys to server (Identity + SignedPreKey + PreKeys)
  /// Used during initialization and healing
  Future<void> uploadAllKeysToServer() async {
    debugPrint('[KEY_MANAGER] ========================================');
    debugPrint('[KEY_MANAGER] Uploading all keys to server...');

    try {
      // 1. Upload identity key
      await uploadIdentityKey();

      // 2. Get or generate SignedPreKey
      final signedPreKeys = await signedPreKeyStore.loadSignedPreKeys();
      SignedPreKeyRecord signedPreKey;

      if (signedPreKeys.isEmpty) {
        debugPrint('[KEY_MANAGER] No SignedPreKey found, generating...');
        signedPreKey = await generateNewSignedPreKey(0);
      } else {
        signedPreKey = signedPreKeys.last;
      }

      await uploadSignedPreKey(signedPreKey);

      // 3. Get or generate PreKeys
      final preKeyIds = await preKeyStore.getAllPreKeyIds();
      List<PreKeyRecord> preKeysToUpload;

      if (preKeyIds.isEmpty) {
        debugPrint('[KEY_MANAGER] No PreKeys found, generating 110...');
        preKeysToUpload = await generatePreKeysInRange(0, 109);

        KeyManagementMetrics.recordPreKeyRegeneration(
          preKeysToUpload.length,
          reason: 'Initial upload',
        );
      } else {
        debugPrint(
          '[KEY_MANAGER] Loading ${preKeyIds.length} existing PreKeys...',
        );
        preKeysToUpload = [];
        for (final id in preKeyIds) {
          try {
            final preKey = await preKeyStore.loadPreKey(id);
            preKeysToUpload.add(preKey);
          } catch (e) {
            debugPrint('[KEY_MANAGER] ⚠️ Failed to load PreKey $id: $e');
          }
        }
      }

      await uploadPreKeys(preKeysToUpload);

      debugPrint('[KEY_MANAGER] ========================================');
      debugPrint('[KEY_MANAGER] ✅ All keys uploaded successfully');
    } catch (e, stackTrace) {
      debugPrint('[KEY_MANAGER] ❌ Error uploading keys: $e');
      debugPrint('[KEY_MANAGER] Stack trace: $stackTrace');
      rethrow;
    }
  }
}
