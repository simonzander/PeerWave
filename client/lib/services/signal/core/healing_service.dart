import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'key_manager.dart';
import 'session_manager.dart';
import '../../device_scoped_storage_service.dart';
import '../../permanent_session_store.dart';
import '../../sender_key_store.dart';
import '../../storage/sqlite_recent_conversations_store.dart';

/// Manages automatic healing and recovery of Signal Protocol keys
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
/// ```
class SignalHealingService {
  final SignalKeyManager keyManager;
  final SessionManager sessionManager;

  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;

  // Rate limiting
  bool _keyReinforcementInProgress = false;
  DateTime? _lastKeyReinforcementTime;
  DateTime? _lastSelfVerificationCheck;

  bool _initialized = false;

  // Delegate to SessionManager and KeyManager for stores
  PermanentSessionStore get sessionStore => sessionManager.sessionStore;
  // KeyManager has PermanentSenderKeyStore mixin, can be used directly
  PermanentSenderKeyStore get senderKeyStore =>
      keyManager as PermanentSenderKeyStore;

  bool get isInitialized => _initialized;

  // Private constructor
  SignalHealingService._({
    required this.keyManager,
    required this.sessionManager,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
  });

  /// Self-initializing factory
  static Future<SignalHealingService> create({
    required SignalKeyManager keyManager,
    required SessionManager sessionManager,
    required String? Function() getCurrentUserId,
    required int? Function() getCurrentDeviceId,
  }) async {
    final service = SignalHealingService._(
      keyManager: keyManager,
      sessionManager: sessionManager,
      getCurrentUserId: getCurrentUserId,
      getCurrentDeviceId: getCurrentDeviceId,
    );
    await service.init();
    return service;
  }

  /// Initialize (no stores to create - all from dependencies)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[HEALING_SERVICE] Already initialized');
      return;
    }

    debugPrint('[HEALING_SERVICE] Initialized (using dependency stores)');
    _initialized = true;
  }

  // ============================================================================
  // SELF-VERIFICATION WITH RATE LIMITING
  // ============================================================================

  /// Trigger async self-verification with rate limiting
  ///
  /// Called when we encounter issues that suggest our keys might be invalid
  /// Rate-limited to once every 5 minutes to avoid excessive server load
  /// Uses persistent storage to prevent re-checks across page reloads
  ///
  /// If corruption is detected, automatically triggers key reinforcement
  Future<void> triggerAsyncSelfVerification({
    required String reason,
    required String userId,
    required int deviceId,
  }) async {
    try {
      // Check if should run self-verification
      final shouldRun = await _shouldRunSelfVerification();
      if (!shouldRun) return;

      // Store timestamp
      await _storeSelfVerificationTimestamp();

      debugPrint('[HEALING] 🛡️ Triggering async self-verification: $reason');

      // Run verification asynchronously (non-blocking)
      verifyOwnKeysOnServer(userId, deviceId)
          .then((isValid) async {
            if (!isValid) {
              debugPrint(
                '[HEALING] ❌ Self-verification FAILED - keys corrupted!',
              );

              // Check if we can trigger healing (rate-limited to prevent loops)
              if (_keyReinforcementInProgress) {
                debugPrint('[HEALING] ⏳ Key reinforcement already in progress');
                return;
              }

              if (_lastKeyReinforcementTime != null) {
                final timeSinceLastReinforcement = DateTime.now().difference(
                  _lastKeyReinforcementTime!,
                );
                if (timeSinceLastReinforcement.inMinutes < 10) {
                  debugPrint(
                    '[HEALING] ⏳ Key reinforcement done ${timeSinceLastReinforcement.inMinutes}min ago, waiting',
                  );
                  return;
                }
              }

              debugPrint(
                '[HEALING] 🔧 Triggering automatic key reinforcement...',
              );

              final healingSuccess = await forceServerKeyReinforcement(
                userId: userId,
                deviceId: deviceId,
              );

              if (healingSuccess) {
                debugPrint('[HEALING] ✅ Automatic healing completed');

                // Re-verify to confirm healing worked
                debugPrint('[HEALING] 🔍 Re-verifying keys after healing...');
                final isNowValid = await verifyOwnKeysOnServer(
                  userId,
                  deviceId,
                );

                if (isNowValid) {
                  debugPrint('[HEALING] ✅ Verification after healing: PASSED');
                } else {
                  debugPrint(
                    '[HEALING] ❌ Verification after healing: STILL FAILED',
                  );
                  debugPrint(
                    '[HEALING] → Keys may need more time to propagate',
                  );
                }
              } else {
                debugPrint('[HEALING] ❌ Automatic healing failed');
              }
            } else {
              debugPrint('[HEALING] ✅ Self-verification passed - keys valid');
            }
          })
          .catchError((error) {
            debugPrint('[HEALING] ⚠️ Self-verification error: $error');
          });
    } catch (e) {
      debugPrint('[HEALING] ⚠️ Error in self-verification trigger: $e');
    }
  }

  /// Check if self-verification should run based on rate limiting
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

  /// Store self-verification timestamp (both in-memory and persistent)
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

  // ============================================================================
  // KEY REINFORCEMENT (HEALING)
  // ============================================================================

  /// Force complete key reinforcement to server
  ///
  /// Deletes corrupted server keys and re-uploads fresh set from client
  /// CLIENT IS SOURCE OF TRUTH
  ///
  /// Returns true if successful, false on error
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
        await sessionStore.deleteAllSessionsCompletely();
        debugPrint('[HEALING] ✓ All sessions deleted');
      } catch (e) {
        debugPrint('[HEALING] ⚠️ Error deleting sessions: $e');
      }

      try {
        await senderKeyStore.deleteAllSenderKeys();
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

  /// Upload all keys via REST API (synchronous, waits for confirmation)
  /// Used during healing to ensure keys are persisted before verification
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

  /// Re-establish sessions with recent contacts after key healing
  ///
  /// Called asynchronously (non-blocking) after session/key deletion
  /// Proactively builds sessions so next messages don't require PreKey fetch
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

  /// Get list of recent conversation partners
  /// Returns list of user IDs
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
      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] Starting key verification on server...');
      debugPrint('[HEALING] User: $userId, Device: $deviceId');

      // Fetch key status from server
      final response = await keyManager.apiService.get(
        '/signal/status/minimal',
        queryParameters: {'userId': userId, 'deviceId': deviceId.toString()},
      );

      final serverData = response.data as Map<String, dynamic>;

      // 1. Verify identity key
      final serverIdentityKey = serverData['identityKey'] as String?;
      if (serverIdentityKey == null) {
        debugPrint('[HEALING] ❌ Server has NO identity key!');
        return false;
      }

      final localIdentityKey = await keyManager.getPublicKey();
      if (serverIdentityKey != localIdentityKey) {
        debugPrint('[HEALING] ❌ Identity key MISMATCH!');
        debugPrint('[HEALING]   Local:  $localIdentityKey');
        debugPrint('[HEALING]   Server: $serverIdentityKey');
        return false;
      }
      debugPrint('[HEALING] ✓ Identity key matches');

      // 2. Verify SignedPreKey
      final serverSignedPreKey = serverData['signedPreKey'] as String?;
      final serverSignedPreKeySignature =
          serverData['signedPreKeySignature'] as String?;

      if (serverSignedPreKey == null || serverSignedPreKeySignature == null) {
        debugPrint('[HEALING] ❌ Server has NO SignedPreKey!');
        return false;
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
          return false;
        }
        debugPrint('[HEALING] ✓ SignedPreKey valid');
      } catch (e) {
        debugPrint('[HEALING] ❌ SignedPreKey validation error: $e');
        return false;
      }

      // 3. Verify PreKeys count
      final preKeysCount = serverData['preKeysCount'] as int? ?? 0;
      if (preKeysCount == 0) {
        debugPrint('[HEALING] ❌ Server has ZERO PreKeys!');
        return false;
      }

      if (preKeysCount < 10) {
        debugPrint('[HEALING] ⚠️ Low PreKey count: $preKeysCount');
      } else {
        debugPrint('[HEALING] ✓ PreKeys count adequate: $preKeysCount');
      }

      // 4. Verify PreKey fingerprints (hash validation)
      final serverFingerprints =
          serverData['preKeyFingerprints'] as Map<String, dynamic>?;
      if (serverFingerprints != null && serverFingerprints.isNotEmpty) {
        debugPrint('[HEALING] Validating PreKey fingerprints...');

        final localFingerprints = await keyManager.getPreKeyFingerprints();

        int matchCount = 0;
        int mismatchCount = 0;
        final mismatches = <String>[];

        // Compare server vs local
        for (final entry in serverFingerprints.entries) {
          final keyId = entry.key;
          final serverHash = entry.value as String?;
          final localHash = localFingerprints[keyId];

          if (localHash == null) {
            debugPrint('[HEALING] ⚠️ PreKey $keyId on server but not local');
            mismatchCount++;
            mismatches.add(keyId);
          } else if (serverHash != localHash) {
            debugPrint('[HEALING] ❌ PreKey $keyId HASH MISMATCH!');
            mismatchCount++;
            mismatches.add(keyId);
          } else {
            matchCount++;
          }
        }

        // Check for local keys not on server
        for (final keyId in localFingerprints.keys) {
          if (!serverFingerprints.containsKey(keyId)) {
            debugPrint('[HEALING] ⚠️ PreKey $keyId local but not on server');
            mismatchCount++;
            mismatches.add(keyId);
          }
        }

        debugPrint(
          '[HEALING] PreKey validation: $matchCount matched, $mismatchCount mismatched',
        );

        if (mismatchCount > 0) {
          debugPrint(
            '[HEALING] ❌ PreKey corruption detected! Mismatched: ${mismatches.take(5).join(", ")}',
          );
          return false;
        }

        debugPrint('[HEALING] ✓ All PreKey hashes valid');
      } else {
        debugPrint('[HEALING] ⚠️ No PreKey fingerprints from server');
      }

      debugPrint('[HEALING] ========================================');
      debugPrint('[HEALING] ✅ All keys verified successfully');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[HEALING] ❌ Verification failed: $e');
      debugPrint('[HEALING] Stack trace: $stackTrace');
      return false;
    }
  }
}
