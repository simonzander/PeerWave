import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'dart:convert';
import '../../api_service.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../../permanent_identity_key_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../sender_key_store.dart';
import '../../../core/metrics/key_management_metrics.dart';
import 'healing_service.dart';
import 'key/identity_key_manager.dart';
import 'key/signed_pre_key_manager.dart';
import 'key/pre_key_manager.dart';

// Export specialized managers for external use
export 'key/identity_key_manager.dart';
export 'key/signed_pre_key_manager.dart';
export 'key/pre_key_manager.dart';

/// Manages Signal Protocol cryptographic keys
///
/// Responsibilities:
/// - Key generation (Identity, SignedPreKey, PreKeys)
/// - Key rotation and lifecycle management
/// - Server validation and verification
/// - Key upload via REST API
/// - Store creation and initialization
///
/// This class coordinates specialized key managers and is the source of truth
/// for all key operations.
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

  // Specialized key managers
  IdentityKeyManager? _identityKeyManager;
  SignedPreKeyManager? _signedPreKeyManager;
  PreKeyManager? _preKeyManager;

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

  // Getters for specialized managers
  IdentityKeyManager get identityKeyManager {
    if (_identityKeyManager == null)
      throw StateError('KeyManager not initialized');
    return _identityKeyManager!;
  }

  SignedPreKeyManager get signedPreKeyManager {
    if (_signedPreKeyManager == null)
      throw StateError('KeyManager not initialized');
    return _signedPreKeyManager!;
  }

  PreKeyManager get preKeyManager {
    if (_preKeyManager == null) throw StateError('KeyManager not initialized');
    return _preKeyManager!;
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

    // Initialize specialized managers
    _identityKeyManager = IdentityKeyManager(_identityStore!);
    _signedPreKeyManager = SignedPreKeyManager(
      _identityStore!,
      _signedPreKeyStore!,
    );
    _preKeyManager = PreKeyManager(_preKeyStore!);

    // Validate keys exist
    await _identityKeyManager!.ensureIdentityKeyExists();

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

    // Initialize specialized managers
    _identityKeyManager = IdentityKeyManager(_identityStore!);
    _signedPreKeyManager = SignedPreKeyManager(
      _identityStore!,
      _signedPreKeyStore!,
    );
    _preKeyManager = PreKeyManager(_preKeyStore!);

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

    // Step 3: Generate PreKeys (110 keys) - Delegate to PreKeyManager
    var existingPreKeyIds = await _preKeyStore!.getAllPreKeyIds();
    await _preKeyManager!.generatePreKeysForInit(
      onProgress,
      currentStep,
      existingPreKeyIds,
    );
    currentStep = 112; // Update to final step count

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    _initialized = true;
    debugPrint('[KEY_MANAGER] ✓ Initialization complete');
  }

  /// Regenerate PreKeys when already initialized but PreKeys are missing
  /// Delegates to PreKeyManager
  Future<void> _regeneratePreKeysWithProgress(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
    List<int> existingPreKeyIds,
  ) async {
    await _preKeyManager!.regeneratePreKeysWithProgress(
      onProgress,
      existingPreKeyIds,
    );
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
  /// Delegates to PreKeyManager
  Future<List<PreKeyRecord>> generatePreKeysInRange(int start, int end) async {
    return await _preKeyManager!.generatePreKeysInRange(start, end);
  }

  /// Generate and store a new SignedPreKey
  /// Returns the generated SignedPreKey record
  /// Delegates to SignedPreKeyManager
  Future<SignedPreKeyRecord> generateNewSignedPreKey(int keyId) async {
    return await _signedPreKeyManager!.generateNewSignedPreKey(keyId);
  }

  /// Ensure identity key pair exists, generate if missing
  /// Returns the identity key pair
  /// Delegates to IdentityKeyManager
  Future<IdentityKeyPair> ensureIdentityKeyExists() async {
    return await _identityKeyManager!.ensureIdentityKeyExists();
  }

  // ============================================================================
  // KEY VALIDATION & FINGERPRINTS
  // ============================================================================

  /// Get local identity public key as base64 string
  /// Delegates to IdentityKeyManager
  Future<String?> getLocalIdentityPublicKey() async {
    return await _identityKeyManager!.getLocalIdentityPublicKey();
  }

  /// Get latest SignedPreKey ID
  /// Delegates to SignedPreKeyManager
  Future<int?> getLatestSignedPreKeyId() async {
    return await _signedPreKeyManager!.getLatestSignedPreKeyId();
  }

  /// Get local PreKey count
  /// Delegates to PreKeyManager
  Future<int> getLocalPreKeyCount() async {
    return await _preKeyManager!.getLocalPreKeyCount();
  }

  /// Generate PreKey fingerprints (hashes) for validation
  /// Returns map of keyId -> hash for all keys
  /// Delegates to PreKeyManager
  Future<Map<String, String>> getPreKeyFingerprints() async {
    return await _preKeyManager!.getPreKeyFingerprints();
  }

  // ============================================================================
  // KEY ROTATION
  // ============================================================================

  /// Check if SignedPreKey needs rotation (older than 7 days)
  /// Delegates to SignedPreKeyManager
  Future<bool> needsSignedPreKeyRotation() async {
    return await _signedPreKeyManager!.needsSignedPreKeyRotation();
  }

  /// Rotate SignedPreKey and upload to server
  /// Delegates to SignedPreKeyManager
  Future<void> rotateSignedPreKey() async {
    return await _signedPreKeyManager!.rotateSignedPreKey();
  }

  /// Check and perform SignedPreKey rotation if needed
  /// Delegates to SignedPreKeyManager
  Future<void> checkAndRotateSignedPreKey() async {
    return await _signedPreKeyManager!.checkAndRotateSignedPreKey();
  }

  // ============================================================================
  // SERVER UPLOAD (REST API)
  // ============================================================================

  /// Upload identity key to server
  /// Delegates to IdentityKeyManager
  Future<void> uploadIdentityKey() async {
    return await _identityKeyManager!.uploadIdentityKey();
  }

  /// Upload SignedPreKey to server
  /// Delegates to SignedPreKeyManager
  Future<void> uploadSignedPreKey(SignedPreKeyRecord signedPreKey) async {
    return await _signedPreKeyManager!.uploadSignedPreKey(signedPreKey);
  }

  /// Upload PreKeys to server in batch
  /// Delegates to PreKeyManager
  Future<void> uploadPreKeys(List<PreKeyRecord> preKeys) async {
    return await _preKeyManager!.uploadPreKeys(preKeys);
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

  // ============================================================================
  // KEY EVENT HANDLERS (Socket.IO Integration)
  // ============================================================================

  /// Upload missing keys detected by server
  ///
  /// When the server notifies us that we're missing keys (via signalStatus event),
  /// this method generates and uploads the missing components.
  ///
  /// Called by: SessionListeners when server indicates missing keys
  Future<void> uploadMissingKeys() async {
    try {
      debugPrint('[KEY_MANAGER] Uploading missing keys...');

      // Re-upload all keys to ensure server has everything
      // This is a comprehensive fix that covers identity, signed, and prekeys
      await uploadAllKeysToServer();

      debugPrint('[KEY_MANAGER] ✓ Missing keys uploaded');
    } catch (e, stack) {
      debugPrint('[KEY_MANAGER] Error uploading missing keys: $e');
      debugPrint('[KEY_MANAGER] Stack: $stack');
      rethrow;
    }
  }

  /// Synchronize local PreKey IDs with server state
  ///
  /// The server sends us a list of PreKey IDs it has stored. We compare with
  /// our local store and upload any PreKeys that the server is missing.
  ///
  /// Called by: SessionListeners when 'preKeyIdsSyncResponse' socket event fires
  /// Delegates to PreKeyManager
  Future<void> syncPreKeyIds(List<int> serverKeyIds) async {
    return await _preKeyManager!.syncPreKeyIds(serverKeyIds);
  }

  // ============================================================================
  // KEY VALIDATION AND SYNC (Moved from SignalService)
  // ============================================================================

  /// Validate and sync keys with server (signalStatus response handler)
  ///
  /// This is the main entry point for key validation, called when server
  /// sends signalStatus response. Performs comprehensive validation:
  /// - Identity key matching
  /// - SignedPreKey validation
  /// - PreKey count synchronization
  ///
  /// Auto-recovers from most issues by re-uploading correct keys.
  ///
  /// Parameters:
  /// - status: Server response from signalStatus event
  /// - isInitialized: Whether signal service is fully initialized
  /// - healingService: Optional healing service for corruption recovery
  /// - currentUserId: Current user UUID (for healing)
  /// - currentDeviceId: Current device ID (for healing)
  Future<void> validateAndSyncKeys({
    required dynamic status,
    required bool isInitialized,
    SignalHealingService? healingService,
    String? currentUserId,
    int? currentDeviceId,
  }) async {
    debugPrint('[KEY_MANAGER][VALIDATION] validateAndSyncKeys called');

    // Check if user is authenticated
    if (status is Map && status['error'] != null) {
      debugPrint(
        '[KEY_MANAGER][VALIDATION] ERROR: ${status['error']} - Cannot upload Signal keys without authentication',
      );
      return;
    }

    // Guard: Only run after initialization is complete
    if (!isInitialized) {
      debugPrint(
        '[KEY_MANAGER][VALIDATION] ⚠️ Not initialized yet, skipping key sync check',
      );
      return;
    }

    // 1. Identity - Validate that server's public key matches local identity
    final identityData = await identityStore.getIdentityKeyPairData();
    final localPublicKey = identityData['publicKey'] as String;
    final serverPublicKey = (status is Map)
        ? status['identityPublicKey'] as String?
        : null;

    debugPrint('[KEY_MANAGER][VALIDATION] Local public key: $localPublicKey');
    debugPrint('[KEY_MANAGER][VALIDATION] Server public key: $serverPublicKey');

    if (serverPublicKey != null && serverPublicKey != localPublicKey) {
      // CRITICAL: Server has different public key than local!
      debugPrint(
        '[KEY_MANAGER][VALIDATION] ⚠️ CRITICAL: Identity key mismatch detected!',
      );
      debugPrint(
        '[KEY_MANAGER][VALIDATION] → AUTO-RECOVERY: Re-uploading correct identity from client',
      );

      // 🔧 AUTO-FIX: Client is source of truth - re-upload correct identity
      try {
        debugPrint(
          '[KEY_MANAGER][VALIDATION] Deleting incorrect server identity...',
        );
        SocketService().emit("deleteAllSignalKeys", {
          'reason':
              'Identity key mismatch - server has wrong key, re-uploading from client',
          'timestamp': DateTime.now().toIso8601String(),
        });

        await Future.delayed(Duration(milliseconds: 500));

        debugPrint(
          '[KEY_MANAGER][VALIDATION] Uploading correct identity from local storage...',
        );
        final registrationId = await identityStore.getLocalRegistrationId();
        SocketService().emit("signalIdentity", {
          'publicKey': localPublicKey,
          'registrationId': registrationId.toString(),
        });

        await Future.delayed(Duration(milliseconds: 500));

        debugPrint(
          '[KEY_MANAGER][VALIDATION] Uploading SignedPreKey and PreKeys...',
        );
        await uploadSignedPreKeyAndPreKeys();

        debugPrint(
          '[KEY_MANAGER][VALIDATION] ✅ Identity mismatch resolved - server now has correct keys',
        );
        return; // Skip rest of validation - keys are fresh
      } catch (e) {
        debugPrint('[KEY_MANAGER][VALIDATION] ❌ Auto-recovery failed: $e');
        throw Exception(
          'Identity key mismatch detected and auto-recovery failed. '
          'Server has different public key than local storage. '
          'Please logout and login again to fix this issue.',
        );
      }
    }

    if (status is Map && status['identity'] != true) {
      debugPrint('[KEY_MANAGER][VALIDATION] Uploading missing identity');
      final registrationId = await identityStore.getLocalRegistrationId();
      SocketService().emit("signalIdentity", {
        'publicKey': localPublicKey,
        'registrationId': registrationId.toString(),
      });
    } else if (serverPublicKey != null) {
      debugPrint(
        '[KEY_MANAGER][VALIDATION] ✓ Identity key validated - local matches server',
      );

      // 🔍 DEEP VALIDATION: Check if server state is internally consistent
      await validateServerKeyConsistency(
        status: Map<String, dynamic>.from(status as Map),
        healingService: healingService,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
      );
    }

    // 2. PreKeys - Sync check
    final int preKeysCount = (status is Map && status['preKeys'] is int)
        ? status['preKeys']
        : 0;
    debugPrint(
      '[KEY_MANAGER][VALIDATION] ========================================',
    );
    debugPrint('[KEY_MANAGER][VALIDATION] PreKey Sync Check:');
    debugPrint('[KEY_MANAGER][VALIDATION]   Server count: $preKeysCount');

    final localPreKeyIds = await preKeyStore.getAllPreKeyIds();
    debugPrint(
      '[KEY_MANAGER][VALIDATION]   Local count:  ${localPreKeyIds.length}',
    );
    debugPrint(
      '[KEY_MANAGER][VALIDATION]   Difference:   ${localPreKeyIds.length - preKeysCount}',
    );
    debugPrint(
      '[KEY_MANAGER][VALIDATION] ========================================',
    );

    if (preKeysCount < 20) {
      // Server critically low
      if (localPreKeyIds.isEmpty) {
        debugPrint(
          '[KEY_MANAGER][VALIDATION] ⚠️ CRITICAL: No local PreKeys found!',
        );
        return;
      } else if (preKeysCount == 0) {
        debugPrint(
          '[KEY_MANAGER][VALIDATION] ⚠️ Server has 0 PreKeys but local has ${localPreKeyIds.length}',
        );
        debugPrint(
          '[KEY_MANAGER][VALIDATION] Uploading local PreKeys to server (first-time sync)...',
        );
        final localPreKeys = await preKeyStore.getAllPreKeys();
        final preKeysPayload = localPreKeys
            .map(
              (pk) => {
                'id': pk.id,
                'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
              },
            )
            .toList();
        SocketService().emit("storePreKeys", <String, dynamic>{
          'preKeys': preKeysPayload,
        });
      } else if (preKeysCount < localPreKeyIds.length) {
        debugPrint(
          '[KEY_MANAGER][VALIDATION] ⚠️ Sync gap: Server has $preKeysCount, local has ${localPreKeyIds.length}',
        );

        final preKeysToUpload = [];
        for (final keyId in localPreKeyIds) {
          final keyRecord = await preKeyStore.loadPreKey(keyId);
          final keyPair = keyRecord.getKeyPair();
          preKeysToUpload.add({
            'id': keyId,
            'key': base64Encode(keyPair.publicKey.serialize()),
          });
        }

        if (preKeysToUpload.isNotEmpty) {
          debugPrint(
            '[KEY_MANAGER][VALIDATION] 📤 Uploading ${preKeysToUpload.length} PreKeys to close sync gap',
          );
          SocketService().emit("storePreKeys", <String, dynamic>{
            'preKeys': preKeysToUpload,
          });
        }
      }
    } else if (localPreKeyIds.length > preKeysCount) {
      final difference = localPreKeyIds.length - preKeysCount;

      if (difference > 5) {
        debugPrint(
          '[KEY_MANAGER][VALIDATION] 🔄 Local has $difference more PreKeys than server',
        );
        SocketService().emit("getMyPreKeyIds", null);
      }
    }

    // 3. SignedPreKey
    final signedPreKey = status is Map ? status['signedPreKey'] : null;
    if (signedPreKey == null) {
      debugPrint(
        '[KEY_MANAGER][VALIDATION] No signed pre-key on server, uploading',
      );
      final allSigned = await signedPreKeyStore.loadSignedPreKeys();
      if (allSigned.isNotEmpty) {
        final latest = allSigned.last;
        SocketService().emit("storeSignedPreKey", {
          'id': latest.id,
          'data': base64Encode(latest.getKeyPair().publicKey.serialize()),
          'signature': base64Encode(latest.signature),
        });
      }
    } else {
      await validateOwnSignedPreKey(Map<String, dynamic>.from(status as Map));
    }
  }

  /// Validate owner's own SignedPreKey on the server
  ///
  /// Ensures the device owner's SignedPreKey has valid signature.
  /// Auto-recovers by regenerating if signature is invalid.
  /// Delegates to SignedPreKeyManager
  Future<void> validateOwnSignedPreKey(Map<String, dynamic> status) async {
    return await _signedPreKeyManager!.validateOwnSignedPreKey(status);
  }

  /// Deep validation of server key consistency
  ///
  /// Detects if server has corrupted or inconsistent keys.
  /// CLIENT IS SOURCE OF TRUTH - if corruption detected, triggers healing.
  Future<void> validateServerKeyConsistency({
    required Map<String, dynamic> status,
    SignalHealingService? healingService,
    String? currentUserId,
    int? currentDeviceId,
  }) async {
    try {
      debugPrint(
        '[KEY_MANAGER][DEEP-VALIDATION] ========================================',
      );
      debugPrint(
        '[KEY_MANAGER][DEEP-VALIDATION] Checking server key consistency...',
      );

      bool corruptionDetected = false;
      final List<String> corruptionReasons = [];

      // Get local identity key (source of truth)
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      final localIdentityKey = identityKeyPair.getPublicKey();
      final localPublicKey = Curve.decodePoint(localIdentityKey.serialize(), 0);

      // Validate SignedPreKey consistency with Identity
      final signedPreKeyData = status['signedPreKey'];
      if (signedPreKeyData != null) {
        final signedPreKeyPublicBase64 =
            signedPreKeyData['signed_prekey_data'] as String?;
        final signedPreKeySignatureBase64 =
            signedPreKeyData['signed_prekey_signature'] as String?;

        if (signedPreKeyPublicBase64 != null &&
            signedPreKeySignatureBase64 != null) {
          try {
            final signedPreKeyPublicBytes = base64Decode(
              signedPreKeyPublicBase64,
            );
            final signedPreKeySignatureBytes = base64Decode(
              signedPreKeySignatureBase64,
            );
            final signedPreKeyPublic = Curve.decodePoint(
              signedPreKeyPublicBytes,
              0,
            );

            final isValid = Curve.verifySignature(
              localPublicKey,
              signedPreKeyPublic.serialize(),
              signedPreKeySignatureBytes,
            );

            if (!isValid) {
              corruptionDetected = true;
              corruptionReasons.add(
                'SignedPreKey signature does NOT match local Identity key',
              );
              debugPrint(
                '[KEY_MANAGER][DEEP-VALIDATION] ❌ SignedPreKey signature invalid!',
              );
            } else {
              debugPrint(
                '[KEY_MANAGER][DEEP-VALIDATION] ✓ SignedPreKey signature valid',
              );
            }
          } catch (e) {
            corruptionDetected = true;
            corruptionReasons.add('SignedPreKey data is malformed: $e');
            debugPrint(
              '[KEY_MANAGER][DEEP-VALIDATION] ❌ SignedPreKey malformed: $e',
            );
          }
        } else {
          corruptionDetected = true;
          corruptionReasons.add('SignedPreKey missing required fields');
          debugPrint(
            '[KEY_MANAGER][DEEP-VALIDATION] ❌ SignedPreKey incomplete',
          );
        }
      } else {
        corruptionDetected = true;
        corruptionReasons.add('No SignedPreKey on server');
        debugPrint(
          '[KEY_MANAGER][DEEP-VALIDATION] ❌ No SignedPreKey on server',
        );
      }

      // Check PreKey count consistency
      final preKeysCount = (status['preKeys'] is int) ? status['preKeys'] : 0;
      if (preKeysCount == 0) {
        final localPreKeyIds = await preKeyStore.getAllPreKeyIds();
        if (localPreKeyIds.isNotEmpty) {
          corruptionDetected = true;
          corruptionReasons.add(
            'Client has ${localPreKeyIds.length} PreKeys but server has 0',
          );
          debugPrint(
            '[KEY_MANAGER][DEEP-VALIDATION] ❌ PreKeys missing from server',
          );
        }
      }

      debugPrint(
        '[KEY_MANAGER][DEEP-VALIDATION] ========================================',
      );

      // If corruption detected, trigger healing
      if (corruptionDetected) {
        debugPrint(
          '[KEY_MANAGER][DEEP-VALIDATION] ⚠️⚠️⚠️  CORRUPTION DETECTED  ⚠️⚠️⚠️',
        );
        debugPrint('[KEY_MANAGER][DEEP-VALIDATION] Reasons:');
        for (final reason in corruptionReasons) {
          debugPrint('[KEY_MANAGER][DEEP-VALIDATION]   - $reason');
        }

        if (healingService != null &&
            currentUserId != null &&
            currentDeviceId != null) {
          debugPrint(
            '[KEY_MANAGER][DEEP-VALIDATION] 🔧 INITIATING AUTO-RECOVERY...',
          );

          final reinforcementSuccess = await healingService
              .forceServerKeyReinforcement(
                userId: currentUserId,
                deviceId: currentDeviceId,
              );

          if (reinforcementSuccess) {
            debugPrint(
              '[KEY_MANAGER][DEEP-VALIDATION] ✅ Auto-recovery completed - keys uploaded',
            );
          } else {
            debugPrint('[KEY_MANAGER][DEEP-VALIDATION] ❌ Auto-recovery failed');
          }
        } else {
          debugPrint(
            '[KEY_MANAGER][DEEP-VALIDATION] ⚠️ Cannot trigger healing - missing dependencies',
          );
        }
      } else {
        debugPrint(
          '[KEY_MANAGER][DEEP-VALIDATION] ✅ Server keys are consistent and valid',
        );
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[KEY_MANAGER][DEEP-VALIDATION] ⚠️ Error during validation: $e',
      );
      debugPrint('[KEY_MANAGER][DEEP-VALIDATION] Stack trace: $stackTrace');
    }
  }

  /// Upload SignedPreKey and PreKeys only (identity already uploaded separately)
  ///
  /// Used when identity was already uploaded and we just need to upload the other keys.
  /// Part of auto-recovery flow.
  Future<void> uploadSignedPreKeyAndPreKeys() async {
    try {
      debugPrint('[KEY_MANAGER][UPLOAD] Uploading SignedPreKey and PreKeys...');
      final identityKeyPair = await identityStore.getIdentityKeyPair();

      // Upload SignedPreKey
      final allSignedPreKeys = await signedPreKeyStore.loadSignedPreKeys();
      SignedPreKeyRecord signedPreKey;

      if (allSignedPreKeys.isEmpty) {
        debugPrint(
          '[KEY_MANAGER][UPLOAD] No local SignedPreKey - generating new one',
        );
        signedPreKey = generateSignedPreKey(identityKeyPair, 0);
        await signedPreKeyStore.storeSignedPreKey(
          signedPreKey.id,
          signedPreKey,
        );
      } else {
        signedPreKey = allSignedPreKeys.last;

        // Validate signature before uploading
        final localPublicKey = Curve.decodePoint(
          identityKeyPair.getPublicKey().serialize(),
          0,
        );
        final isValid = Curve.verifySignature(
          localPublicKey,
          signedPreKey.getKeyPair().publicKey.serialize(),
          signedPreKey.signature,
        );

        if (!isValid) {
          debugPrint(
            '[KEY_MANAGER][UPLOAD] Local SignedPreKey invalid - regenerating',
          );
          signedPreKey = generateSignedPreKey(identityKeyPair, 0);
          await signedPreKeyStore.storeSignedPreKey(
            signedPreKey.id,
            signedPreKey,
          );
        }
      }

      SocketService().emit("storeSignedPreKey", {
        'id': signedPreKey.id,
        'data': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signedPreKey.signature),
      });

      await Future.delayed(Duration(milliseconds: 500));

      // Cleanup old SignedPreKeys
      final allStoredKeys = await signedPreKeyStore
          .loadAllStoredSignedPreKeys();
      if (allStoredKeys.length > 1) {
        allStoredKeys.sort((a, b) {
          if (a.createdAt == null) return 1;
          if (b.createdAt == null) return -1;
          return b.createdAt!.compareTo(a.createdAt!);
        });

        for (final key in allStoredKeys) {
          if (key.record.id == allStoredKeys.first.record.id) continue;
          SocketService().emit("removeSignedPreKey", <String, dynamic>{
            'id': key.record.id,
          });
        }
      }

      // Upload PreKeys
      final localPreKeyIds = await preKeyStore.getAllPreKeyIds();

      if (localPreKeyIds.isEmpty) {
        debugPrint(
          '[KEY_MANAGER][UPLOAD] No local PreKeys - generating 110 new ones',
        );
        final newPreKeys = generatePreKeys(0, 109);
        for (final preKey in newPreKeys) {
          await preKeyStore.storePreKey(preKey.id, preKey);
        }

        KeyManagementMetrics.recordPreKeyRegeneration(
          newPreKeys.length,
          reason: 'Recovery upload',
        );

        final preKeysPayload = newPreKeys
            .map(
              (pk) => {
                'id': pk.id,
                'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
              },
            )
            .toList();

        SocketService().emit("storePreKeys", <String, dynamic>{
          'preKeys': preKeysPayload,
        });
      } else {
        final preKeysPayload = <Map<String, dynamic>>[];
        for (final id in localPreKeyIds) {
          try {
            final preKey = await preKeyStore.loadPreKey(id);
            preKeysPayload.add({
              'id': preKey.id,
              'data': base64Encode(preKey.getKeyPair().publicKey.serialize()),
            });
          } catch (e) {
            debugPrint(
              '[KEY_MANAGER][UPLOAD] ⚠️ Failed to load PreKey $id: $e',
            );
          }
        }

        SocketService().emit("storePreKeys", <String, dynamic>{
          'preKeys': preKeysPayload,
        });
      }

      debugPrint('[KEY_MANAGER][UPLOAD] ✅ Keys uploaded successfully');
    } catch (e, stackTrace) {
      debugPrint('[KEY_MANAGER][UPLOAD] ❌ Error uploading keys: $e');
      debugPrint('[KEY_MANAGER][UPLOAD] Stack trace: $stackTrace');
      rethrow;
    }
  }
}
