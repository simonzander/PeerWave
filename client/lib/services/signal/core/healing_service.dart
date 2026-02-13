import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'key_manager.dart';
import 'session_manager.dart';
import '../../device_scoped_storage_service.dart';
import '../../storage/sqlite_recent_conversations_store.dart';

/// Represents verification outcome without forcing immediate healing on transient
/// or recoverable issues.
/// - [isValid]: overall pass/fail for the current check
/// - [needsHealing]: true only when corruption is confirmed (identity/SPK mismatch or PreKey hash mismatch)
/// - [reason]: short code describing the outcome
class VerificationResult {
  final bool isValid;
  final bool needsHealing;
  final String reason;
  const VerificationResult({
    required this.isValid,
    required this.needsHealing,
    required this.reason,
  });

  static const ok = VerificationResult(
    isValid: true,
    needsHealing: false,
    reason: 'ok',
  );
}

/// Manages automatic healing and recovery of Signal Protocol keys.
///
/// Responsibilities:
/// - Self-verification triggers with rate limiting
/// - Automatic corruption detection
/// - Key reinforcement (healing) process
/// - Session re-establishment after healing
///
/// Dependencies:
/// - KeyManager: For key operations and stores
/// - SessionManager: For session management
///
/// This service ensures the client can automatically recover from
/// key corruption or desync with the server
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final healingService = await SignalHealingService.create(
///   keyManager: keyManager,
///   sessionManager: sessionManager,
///   getCurrentUserId: () => userId,
///   getCurrentDeviceId: () => deviceId,
/// );
///
/// Healing actions (what is healed, trigger, source):
/// | Component      | What we heal                                  | Trigger (source)                          | Notes |
/// |----------------|-----------------------------------------------|-------------------------------------------|-------|
/// | Identity key   | Verify match; on mismatch → full healing      | `verifyOwnKeysOnServer` (auto)            | Lives on server + local |
/// | Signed PreKey  | Verify signature; on missing/invalid → heal   | `verifyOwnKeysOnServer` (auto)            | Server + local |
/// | PreKeys        | Count + hash check; mismatch → heal; missing → resync | `verifyOwnKeysOnServer` (auto)       | Server + local |
/// | Sessions       | Delete all during healing                     | `forceServerKeyReinforcement` (auto)      | Local only |
/// | SenderKeys     | Delete all during healing                     | `forceServerKeyReinforcement` (auto)      | Local only (not stored on server) |
/// | Recent sessions| Re-establish after healing                    | `_reestablishRecentSessions` (auto async) | Local rebuild |
/// ```
class SignalHealingService {
  final SignalKeyManager keyManager;
  final SessionManager sessionManager;

  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;

  final bool _runInitialVerification;

  // Rate limiting
  bool _keyReinforcementInProgress = false;
  DateTime? _lastKeyReinforcementTime;
  DateTime? _lastSelfVerificationCheck;

  bool _initialized = false;

  // Healing backoff (persisted)
  static const _healingStateNamespace = 'signal_healing';
  static const _healingReasonKey = 'last_reason';
  static const _healingTimestampKey = 'last_timestamp_iso';

  // Verification result descriptor to avoid over-triggering healing
  static const int _preKeyHealthyThreshold = 50; // maintain a healthy buffer
  static const Duration _healingBackoff = Duration(minutes: 10);

  // Use SessionManager which has PermanentSessionStore mixin
  // SessionManager provides all session operations via the mixin
  // Use keyManager directly which has PermanentSenderKeyStore mixin

  bool get isInitialized => _initialized;

  // Private constructor
  SignalHealingService._({
    required this.keyManager,
    required this.sessionManager,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
    required bool runInitialVerification,
  }) : _runInitialVerification = runInitialVerification;

  /// Self-initializing factory.
  ///
  /// Parameters: concrete [keyManager], [sessionManager], and callbacks to fetch
  /// current user/device ids.
  /// Returns: initialized [SignalHealingService].
  static Future<SignalHealingService> create({
    required SignalKeyManager keyManager,
    required SessionManager sessionManager,
    required String? Function() getCurrentUserId,
    required int? Function() getCurrentDeviceId,
    bool runInitialVerification = true,
  }) async {
    final service = SignalHealingService._(
      keyManager: keyManager,
      sessionManager: sessionManager,
      getCurrentUserId: getCurrentUserId,
      getCurrentDeviceId: getCurrentDeviceId,
      runInitialVerification: runInitialVerification,
    );
    await service.init();
    return service;
  }

  /// Initialize the service (idempotent). No stores are created here because
  /// dependencies own them.
  /// Returns when initialization is complete.
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[HEALING_SERVICE] Already initialized');
      return;
    }

    debugPrint('[HEALING_SERVICE] Initialized (using dependency stores)');
    _initialized = true;
    if (_runInitialVerification) {
      // Run an immediate self-verification after init (bypass cooldown once)
      // to avoid waiting for the 5-minute window on fresh startup.
      unawaited(
        triggerAsyncSelfVerification(
          reason: 'init-boot-check',
          userId: getCurrentUserId() ?? '',
          deviceId: getCurrentDeviceId() ?? 0,
          force: true,
        ),
      );
    }
  }

  // ============================================================================
  // SELF-VERIFICATION WITH RATE LIMITING
  // ============================================================================

  /// Trigger async self-verification with rate limiting.
  ///
  /// Parameters: [reason] for telemetry, [userId], [deviceId] as fallbacks.
  /// Behavior: skips if recently checked; runs verification; triggers healing
  /// only on confirmed corruption with backoff; remains silent to the user.
  Future<void> triggerAsyncSelfVerification({
    required String reason,
    required String userId,
    required int deviceId,
    bool force = false,
  }) async {
    try {
      // Check if should run self-verification
      final shouldRun = force ? true : await _shouldRunSelfVerification();
      if (!shouldRun) return;

      // Store timestamp
      await _storeSelfVerificationTimestamp();

      debugPrint('[HEALING] 🛡️ Triggering async self-verification: $reason');

      // Run verification asynchronously (non-blocking)
      verifyOwnKeysOnServer(userId, deviceId)
          .then((result) async {
            if (result.isValid) {
              debugPrint('[HEALING] ✅ Self-verification passed - keys valid');
              return;
            }

            if (!result.needsHealing) {
              debugPrint(
                '[HEALING] ⚠️ Verification failed but recoverable/ transient (reason: ${result.reason}) — skipping healing',
              );
              return;
            }

            // Check if we can trigger healing (rate-limited to prevent loops)
            if (_keyReinforcementInProgress) {
              debugPrint('[HEALING] ⏳ Key reinforcement already in progress');
              return;
            }

            final canHeal = await _shouldHealNow(result.reason);
            if (!canHeal) {
              debugPrint(
                '[HEALING] ⏳ Backing off healing for reason=${result.reason} (recent attempt)',
              );
              return;
            }

            if (_lastKeyReinforcementTime != null) {
              final timeSinceLastReinforcement = DateTime.now().difference(
                _lastKeyReinforcementTime!,
              );
              if (timeSinceLastReinforcement < _healingBackoff) {
                debugPrint(
                  '[HEALING] ⏳ Key reinforcement done ${timeSinceLastReinforcement.inMinutes}min ago, waiting',
                );
                return;
              }
            }

            debugPrint(
              '[HEALING] 🔧 Triggering automatic key reinforcement (reason=${result.reason})...',
            );

            final healingSuccess = await forceServerKeyReinforcement(
              userId: userId,
              deviceId: deviceId,
            );

            await _recordHealingAttempt(result.reason);

            if (healingSuccess) {
              debugPrint('[HEALING] ✅ Automatic healing completed');

              // Re-verify to confirm healing worked
              debugPrint('[HEALING] 🔍 Re-verifying keys after healing...');
              final postHealResult = await verifyOwnKeysOnServer(
                userId,
                deviceId,
              );

              if (postHealResult.isValid) {
                debugPrint('[HEALING] ✅ Verification after healing: PASSED');
              } else {
                debugPrint(
                  '[HEALING] ❌ Verification after healing: STILL FAILED (reason=${postHealResult.reason})',
                );
                debugPrint(
                  '[HEALING] → Keys may need more time to propagate or manual attention required',
                );
              }
            } else {
              debugPrint('[HEALING] ❌ Automatic healing failed');
            }
          })
          .catchError((error) {
            debugPrint('[HEALING] ⚠️ Self-verification error: $error');
          });
    } catch (e) {
      debugPrint('[HEALING] ⚠️ Error in self-verification trigger: $e');
    }
  }

  /// Check if self-verification should run based on rate limiting.
  /// Returns: true if allowed to verify now, false if still in cooldown.
  Future<bool> _shouldRunSelfVerification() async {
    // Check persistent rate limiting
    final storage = DeviceScopedStorageService.instance;
    final lastCheckStr = await storage.getDecrypted(
      'signal_verification',
      'signal_verification',
      'last_self_verification_check',
    );

    if (lastCheckStr != null) {
      try {
        final lastCheck = DateTime.parse(lastCheckStr);
        final timeSinceLastCheck = DateTime.now().difference(lastCheck);

        if (timeSinceLastCheck.inMinutes < 5) {
          debugPrint(
            '[HEALING] ⏳ Skipping self-verification (last checked ${timeSinceLastCheck.inMinutes}min ago, persisted)',
          );
          return false;
        }
      } catch (e) {
        debugPrint('[HEALING] Failed to parse last check time: $e');
      }
    }

    // Check in-memory rate limiting
    if (_lastSelfVerificationCheck != null) {
      final timeSinceLastCheck = DateTime.now().difference(
        _lastSelfVerificationCheck!,
      );
      if (timeSinceLastCheck.inMinutes < 5) {
        debugPrint(
          '[HEALING] ⏳ Skipping self-verification (checked ${timeSinceLastCheck.inMinutes}min ago, in-memory)',
        );
        return false;
      }
    }

    return true;
  }

  /// Store self-verification timestamp (both in-memory and persistent).
  Future<void> _storeSelfVerificationTimestamp() async {
    _lastSelfVerificationCheck = DateTime.now();

    final storage = DeviceScopedStorageService.instance;
    await storage.storeEncrypted(
      'signal_verification',
      'signal_verification',
      'last_self_verification_check',
      DateTime.now().toIso8601String(),
    );
  }

  /// Decide if healing is allowed now for a given [reason] using persisted backoff.
  /// Returns: false when the same reason was recently healed and is still in backoff.
  Future<bool> _shouldHealNow(String reason) async {
    try {
      final storage = DeviceScopedStorageService.instance;
      final lastReason = await storage.getDecrypted(
        _healingStateNamespace,
        _healingStateNamespace,
        _healingReasonKey,
      );
      final lastTsIso = await storage.getDecrypted(
        _healingStateNamespace,
        _healingStateNamespace,
        _healingTimestampKey,
      );

      if (lastReason != null && lastTsIso != null && lastReason == reason) {
        final lastTs = DateTime.tryParse(lastTsIso);
        if (lastTs != null) {
          final elapsed = DateTime.now().difference(lastTs);
          if (elapsed < _healingBackoff) {
            return false; // backoff for same reason
          }
        }
      }
    } catch (_) {
      // Best effort; do not block healing if storage fails
    }
    return true;
  }

  /// Persist the most recent healing reason/timestamp (best effort, non-fatal).
  Future<void> _recordHealingAttempt(String reason) async {
    try {
      final storage = DeviceScopedStorageService.instance;
      await storage.storeEncrypted(
        _healingStateNamespace,
        _healingStateNamespace,
        _healingReasonKey,
        reason,
      );
      await storage.storeEncrypted(
        _healingStateNamespace,
        _healingStateNamespace,
        _healingTimestampKey,
        DateTime.now().toIso8601String(),
      );
    } catch (_) {
      // Non-fatal; healing should not fail because of telemetry persistence
    }
  }

  // ============================================================================
  // KEY REINFORCEMENT (HEALING)
  // ============================================================================

  /// Force complete key reinforcement to server.
  /// Deletes server identity/SignedPreKey/PreKeys, re-uploads fresh keys,
  /// purges local sessions and SenderKeys, then rebuilds recent sessions.
  /// Returns: true on success, false on error.
  Future<bool> forceServerKeyReinforcement({
    required String userId,
    required int deviceId,
  }) async {
    // Loop prevention: Mark reinforcement in progress
    _keyReinforcementInProgress = true;
    _lastKeyReinforcementTime = DateTime.now();

    bool success = false;

    try {
      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] Starting forced key reinforcement...');

      // Step 1: Delete all keys on server via REST API
      debugPrint('[HEALING] Step 1: Deleting corrupted server keys...');
      final deleteResult = await keyManager.deleteAllKeysOnServer();

      debugPrint(
        '[HEALING] ✓ Keys deleted: ${deleteResult['preKeysDeleted']} PreKeys, ${deleteResult['signedPreKeysDeleted']} SignedPreKeys',
      );

      // Step 2-4: Re-upload all keys via REST API
      debugPrint('[HEALING] Step 2-4: Re-uploading all keys...');
      await _uploadKeysViaRestApi();

      // Step 5: Delete all sessions and SenderKeys
      debugPrint('[HEALING] Step 5: Deleting sessions and SenderKeys...');
      try {
        await sessionManager.deleteAllSessionsCompletely();
        debugPrint('[HEALING] ✓ All sessions deleted');
      } catch (e) {
        debugPrint('[HEALING] ⚠️ Error deleting sessions: $e');
      }

      try {
        await keyManager.deleteAllSenderKeys();
        debugPrint('[HEALING] ✓ All SenderKeys deleted');
      } catch (e) {
        debugPrint('[HEALING] ⚠️ Error deleting SenderKeys: $e');
      }

      // Step 6: Re-establish sessions with recent contacts (non-blocking)
      debugPrint('[HEALING] Step 6: Re-establishing sessions...');
      _reestablishRecentSessions(userId, deviceId);

      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] ✅ Key reinforcement completed successfully!');
      debugPrint(
        '[HEALING] All keys re-uploaded from client (source of truth)',
      );
      debugPrint('[HEALING] Server state should now match client state');

      // Loop prevention: Don't trigger immediate signalStatus
      debugPrint(
        '[HEALING] ℹ️ Skipping immediate status check to prevent validation loop',
      );
      debugPrint('[HEALING] Next scheduled status check will verify the fix');

      success = true;
    } catch (e, stackTrace) {
      debugPrint('[HEALING] ❌ Error during key reinforcement: $e');
      debugPrint('[HEALING] Stack trace: $stackTrace');
      success = false;
    } finally {
      // Always clear in-progress flag
      _keyReinforcementInProgress = false;
      debugPrint('[HEALING] Reinforcement operation completed (flag cleared)');
    }

    return success;
  }

  /// Upload all keys via REST API (identity, signed prekey, prekeys) and wait for completion.
  Future<void> _uploadKeysViaRestApi() async {
    try {
      await keyManager.uploadAllKeysToServer();
      debugPrint('[HEALING] ✅ All keys uploaded via REST API');
    } catch (e, stackTrace) {
      debugPrint('[HEALING] ❌ Error uploading keys via REST API: $e');
      debugPrint('[HEALING] Stack trace: $stackTrace');
      rethrow;
    }
  }

  // ============================================================================
  // SESSION RE-ESTABLISHMENT
  // ============================================================================

  /// Re-establish sessions with recent contacts after key healing.
  /// Called asynchronously to proactively rebuild sessions for smoother sends.
  void _reestablishRecentSessions(String userId, int deviceId) async {
    try {
      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] Starting session re-establishment...');

      // Get recent conversation partners (last 10)
      final recentPartners = await _getRecentConversationPartners(10);

      if (recentPartners.isEmpty) {
        debugPrint('[HEALING] No recent conversations found');
        return;
      }

      debugPrint(
        '[HEALING] Found ${recentPartners.length} recent conversations',
      );

      int succeeded = 0;
      int failed = 0;

      for (final partnerId in recentPartners) {
        if (partnerId == userId) {
          debugPrint('[HEALING] Skipping self ($userId)');
          continue;
        }

        try {
          debugPrint('[HEALING] Fetching PreKeyBundle for: $partnerId');

          // Fetch bundle and establish session
          final success = await sessionManager.establishSessionWithUser(
            partnerId,
          );

          if (success) {
            succeeded++;
            debugPrint('[HEALING] ✓ Session established with $partnerId');
          } else {
            failed++;
            debugPrint(
              '[HEALING] ⚠️ Could not establish session with $partnerId',
            );
          }
        } catch (e) {
          failed++;
          debugPrint(
            '[HEALING] ⚠️ Failed to establish session with $partnerId: $e',
          );
        }
      }

      debugPrint('[HEALING] ========================================');
      debugPrint(
        '[HEALING] ✅ Re-establishment complete: $succeeded succeeded, $failed failed',
      );
    } catch (e, stackTrace) {
      debugPrint('[HEALING] ❌ Error during session re-establishment: $e');
      debugPrint('[HEALING] Stack trace: $stackTrace');
    }
  }

  /// Get list of recent conversation partners.
  /// Returns: list of user IDs ordered by recency (best effort).
  Future<List<String>> _getRecentConversationPartners(int limit) async {
    try {
      final recentConversationsStore =
          await SqliteRecentConversationsStore.getInstance();
      final conversations = await recentConversationsStore
          .getRecentConversations(limit: limit);

      return conversations.map((c) => c['userId'] as String).toList();
    } catch (e) {
      debugPrint('[HEALING] Error getting recent conversations: $e');
      return [];
    }
  }

  // ============================================================================
  // GETTERS
  // ============================================================================

  /// Check if key reinforcement is currently in progress
  bool get isKeyReinforcementInProgress => _keyReinforcementInProgress;

  /// Get time of last key reinforcement (for rate limiting)
  DateTime? get lastKeyReinforcementTime => _lastKeyReinforcementTime;

  // ============================================================================
  // KEY VALIDATION METHODS
  // ============================================================================

  /// Verify our own keys are valid on the server.
  /// Returns: [VerificationResult] to distinguish corruption vs recoverable/transient states.
  /// Validates: identity match, SignedPreKey presence/signature, PreKey count/buffer,
  /// and PreKey fingerprints (hash) equivalence.
  Future<VerificationResult> verifyOwnKeysOnServer(
    String userId,
    int deviceId,
  ) async {
    try {
      // Use callbacks to get current user ID and device ID (more reliable than parameters)
      final actualUserId = getCurrentUserId() ?? userId;
      final actualDeviceId = getCurrentDeviceId() ?? deviceId;

      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] Starting key verification on server...');
      debugPrint('[HEALING] User: $actualUserId, Device: $actualDeviceId');

      // Fetch key status from server
      final response = await keyManager.apiService.get(
        '/signal/status/minimal',
        queryParameters: {
          'userId': actualUserId,
          'deviceId': actualDeviceId.toString(),
        },
      );

      final serverData = response.data as Map<String, dynamic>;

      // 1. Verify identity key
      final serverIdentityKey = serverData['identityKey'] as String?;
      if (serverIdentityKey == null) {
        debugPrint('[HEALING] ❌ Server has NO identity key!');
        debugPrint('[HEALING] ⚠️ Attempting identity re-upload before healing');
        try {
          await keyManager.uploadAllKeysToServer();
          debugPrint('[HEALING] ✓ Identity re-upload attempted');
          return const VerificationResult(
            isValid: true,
            needsHealing: false,
            reason: 'identity_reuploaded',
          );
        } catch (e) {
          debugPrint('[HEALING] ⚠️ Identity re-upload failed: $e');
          return const VerificationResult(
            isValid: false,
            needsHealing: true,
            reason: 'identity_missing',
          );
        }
      }

      final localIdentityKey = await keyManager.getPublicKey();
      if (serverIdentityKey != localIdentityKey) {
        debugPrint('[HEALING] ❌ Identity key MISMATCH!');
        debugPrint('[HEALING]   Local:  $localIdentityKey');
        debugPrint('[HEALING]   Server: $serverIdentityKey');
        return const VerificationResult(
          isValid: false,
          needsHealing: true,
          reason: 'identity_mismatch',
        );
      }
      debugPrint('[HEALING] ✓ Identity key matches');

      // 2. Verify SignedPreKey
      final serverSignedPreKey = serverData['signedPreKey'] as String?;
      final serverSignedPreKeySignature =
          serverData['signedPreKeySignature'] as String?;

      if (serverSignedPreKey == null || serverSignedPreKeySignature == null) {
        debugPrint(
          '[HEALING] ⚠️ Server has NO SignedPreKey — attempting re-upload before healing',
        );
        try {
          await keyManager.uploadAllKeysToServer();
          debugPrint('[HEALING] ✓ SignedPreKey re-upload attempted');
        } catch (e) {
          debugPrint('[HEALING] ⚠️ SignedPreKey re-upload failed: $e');
          return const VerificationResult(
            isValid: false,
            needsHealing: true,
            reason: 'signed_prekey_missing',
          );
        }
        // After a successful re-upload attempt, consider this pass and let next verification re-check
        return const VerificationResult(
          isValid: true,
          needsHealing: false,
          reason: 'signed_prekey_reuploaded',
        );
      }

      // Verify SignedPreKey signature
      try {
        final identityKeyPair = await keyManager.getIdentityKeyPair();
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
          debugPrint('[HEALING] ❌ SignedPreKey signature INVALID!');
          return const VerificationResult(
            isValid: false,
            needsHealing: true,
            reason: 'signed_prekey_invalid',
          );
        }
        debugPrint('[HEALING] ✓ SignedPreKey valid');
      } catch (e) {
        debugPrint('[HEALING] ❌ SignedPreKey validation error: $e');
        return const VerificationResult(
          isValid: false,
          needsHealing: true,
          reason: 'signed_prekey_validation_error',
        );
      }

      // 3. Verify PreKeys count
      final preKeysCount = serverData['preKeysCount'] as int? ?? 0;
      final localFingerprints = await keyManager.getPreKeyFingerprints();

      if (preKeysCount == 0) {
        debugPrint('[HEALING] ⚠️ Server has ZERO PreKeys (recoverable)');
        try {
          // Upload all local PreKeys to server (server list is empty)
          await keyManager.syncPreKeyIds(const []);
          debugPrint('[HEALING] ✓ Uploaded local PreKeys to empty server set');
        } catch (e) {
          debugPrint(
            '[HEALING] ⚠️ Failed to upload PreKeys to empty server: $e',
          );
        }
        try {
          await keyManager.checkPreKeys();
          debugPrint('[HEALING] ✓ Ensured local PreKey buffer is healthy');
        } catch (e) {
          debugPrint('[HEALING] ⚠️ Failed to top-up PreKeys: $e');
        }
      } else if (preKeysCount < _preKeyHealthyThreshold) {
        debugPrint(
          '[HEALING] ⚠️ Low PreKey count: $preKeysCount (target ≥ $_preKeyHealthyThreshold)',
        );
        try {
          await keyManager.checkPreKeys();
          debugPrint('[HEALING] ✓ Triggered PreKey top-up (low buffer)');
        } catch (e) {
          debugPrint('[HEALING] ⚠️ Failed to top-up PreKeys: $e');
        }
      } else {
        debugPrint('[HEALING] ✓ PreKeys count adequate: $preKeysCount');
      }

      // 4. Verify PreKey fingerprints (hash validation)
      final serverFingerprints =
          serverData['preKeyFingerprints'] as Map<String, dynamic>?;
      if (serverFingerprints != null && serverFingerprints.isNotEmpty) {
        debugPrint('[HEALING] Validating PreKey fingerprints...');

        int matchCount = 0;
        final hashMismatches = <String>[]; // Same ID, different hash
        final missingOnServer = <String>[]; // Local key absent on server
        final serverOnly = <String>[]; // Server key absent locally

        // Compare server vs local
        for (final entry in serverFingerprints.entries) {
          final keyId = entry.key;
          final serverHash = entry.value as String?;
          final localHash = localFingerprints[keyId];

          if (localHash == null) {
            serverOnly.add(keyId);
          } else if (serverHash != localHash) {
            hashMismatches.add(keyId);
          } else {
            matchCount++;
          }
        }

        // Check for local keys not on server
        for (final keyId in localFingerprints.keys) {
          if (!serverFingerprints.containsKey(keyId)) {
            missingOnServer.add(keyId);
          }
        }

        debugPrint(
          '[HEALING] PreKey validation: $matchCount matched, ${hashMismatches.length} hash mismatches, ${missingOnServer.length} missing on server, ${serverOnly.length} server-only',
        );

        if (hashMismatches.isNotEmpty) {
          debugPrint(
            '[HEALING] ❌ PreKey hash mismatches detected: ${hashMismatches.take(5).join(", ")}',
          );
          return const VerificationResult(
            isValid: false,
            needsHealing: true,
            reason: 'prekey_hash_mismatch',
          ); // Corruption: same IDs differ
        }

        // Missing or extra keys are recoverable – resync/upload missing to server
        if (missingOnServer.isNotEmpty || serverOnly.isNotEmpty) {
          debugPrint(
            '[HEALING] ⚠️ PreKey set diverged (recoverable). Missing on server: ${missingOnServer.take(5).join(", ")}; server-only: ${serverOnly.take(5).join(", ")}',
          );
          // Delete server-only PreKeys (we lost local private parts)
          if (serverOnly.isNotEmpty) {
            for (final idStr in serverOnly) {
              try {
                await keyManager.apiService.delete('/signal/prekey/$idStr');
                debugPrint('[HEALING] ✓ Deleted server-only PreKey $idStr');
              } catch (e) {
                debugPrint(
                  '[HEALING] ⚠️ Failed to delete server-only PreKey $idStr: $e',
                );
              }
            }
          }
          try {
            final serverIds = serverFingerprints.keys.map(int.parse).toList();
            await keyManager.syncPreKeyIds(serverIds);
            debugPrint(
              '[HEALING] ✓ Triggered PreKey resync/upload for missing keys',
            );
          } catch (e) {
            debugPrint('[HEALING] ⚠️ Failed to resync/upload PreKeys: $e');
          }
          try {
            await keyManager.checkPreKeys();
            debugPrint('[HEALING] ✓ Ensured local PreKey buffer after resync');
          } catch (e) {
            debugPrint('[HEALING] ⚠️ Failed to top-up PreKeys post-resync: $e');
          }
        }

        debugPrint('[HEALING] ✓ PreKey hashes validated (no corruption)');
      } else {
        debugPrint('[HEALING] ⚠️ No PreKey fingerprints from server');
      }

      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] ✅ All keys verified successfully');
      return VerificationResult.ok;
    } catch (e, stackTrace) {
      debugPrint('[HEALING] ❌ Verification failed: $e');
      debugPrint('[HEALING] Stack trace: $stackTrace');
      return const VerificationResult(
        isValid: false,
        needsHealing: false,
        reason: 'network_or_unknown',
      );
    }
  }
}
