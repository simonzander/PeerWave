import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../permanent_session_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../permanent_identity_key_store.dart';
import '../../sender_key_store.dart';
import '../../api_service.dart';
import '../../key_management_metrics.dart';
import '../../storage/sqlite_recent_conversations_store.dart';
import 'dart:convert';

import 'key_manager.dart';

/// Manages Signal Protocol sessions
///
/// Responsibilities:
/// - Session building and initialization
/// - PreKeyBundle processing
/// - Session validation and recovery
/// - Session lifecycle management
///
/// Dependencies:
/// - KeyManager: For identity/preKey/signedPreKey/senderKey stores
///
/// Usage:
/// ```dart
/// // Self-initializing factory with KeyManager dependency
/// final sessionManager = await SessionManager.create(keyManager: keyManager);
/// ```
class SessionManager {
  final SignalKeyManager keyManager;
  PermanentSessionStore? _sessionStore;

  bool _initialized = false;

  // Getters for stores (throw if not initialized)
  PermanentSessionStore get sessionStore {
    if (_sessionStore == null)
      throw StateError('SessionManager not initialized');
    return _sessionStore!;
  }

  // Delegate to KeyManager for other stores
  PermanentPreKeyStore get preKeyStore => keyManager.preKeyStore;
  PermanentSignedPreKeyStore get signedPreKeyStore =>
      keyManager.signedPreKeyStore;
  PermanentIdentityKeyStore get identityStore => keyManager.identityStore;
  PermanentSenderKeyStore get senderKeyStore => keyManager.senderKeyStore;

  bool get isInitialized => _initialized;

  // Private constructor with KeyManager dependency
  SessionManager._({required this.keyManager});

  /// Self-initializing factory - requires KeyManager
  static Future<SessionManager> create({
    required SignalKeyManager keyManager,
  }) async {
    final manager = SessionManager._(keyManager: keyManager);
    await manager.init();
    return manager;
  }

  /// Initialize session store only (other stores from KeyManager)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[SESSION_MANAGER] Already initialized');
      return;
    }

    debugPrint('[SESSION_MANAGER] Initializing session store...');

    // Create only session store (other stores from KeyManager)
    _sessionStore = await PermanentSessionStore.create();

    debugPrint('[SESSION_MANAGER] ✓ Initialized');
    _initialized = true;
  }

  // ============================================================================
  // CIPHER FACTORIES
  // ============================================================================

  /// Create SessionCipher for 1-to-1 communication
  SessionCipher createSessionCipher(SignalProtocolAddress address) {
    return SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      address,
    );
  }

  /// Create GroupCipher for group communication
  GroupCipher createGroupCipher(
    String groupId,
    SignalProtocolAddress senderAddress,
  ) {
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    return GroupCipher(senderKeyStore, senderKeyName);
  }

  /// Establish session with a user by fetching their PreKeyBundle
  /// Returns true if at least one device session was established
  Future<bool> establishSessionWithUser(String userId) async {
    try {
      debugPrint('[SESSION_MANAGER] Establishing session with: $userId');

      // Fetch PreKeyBundles for user
      final response = await ApiService.get('/signal/prekey_bundle/$userId');

      if (response.statusCode != 200) {
        debugPrint(
          '[SESSION_MANAGER] Failed to fetch bundles: ${response.statusCode}',
        );
        return false;
      }

      final devices = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      if (devices is! List || devices.isEmpty) {
        debugPrint('[SESSION_MANAGER] No devices found for $userId');
        return false;
      }

      int successCount = 0;

      for (final deviceBundle in devices) {
        try {
          final deviceId = deviceBundle['deviceId'] as int;
          await buildSessionFromBundle(userId, deviceId, deviceBundle);
          successCount++;
        } catch (e) {
          debugPrint('[SESSION_MANAGER] Failed to build session: $e');
        }
      }

      debugPrint(
        '[SESSION_MANAGER] Established $successCount/${devices.length} sessions',
      );
      return successCount > 0;
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error establishing session: $e');
      return false;
    }
  }

  /// Build session from PreKeyBundle data
  /// This creates a new session or rebuilds an existing one
  Future<void> buildSessionFromBundle(
    String userId,
    int deviceId,
    Map<String, dynamic> bundleData,
  ) async {
    try {
      debugPrint('[SESSION_MANAGER] Building session for $userId:$deviceId');

      // Parse and convert bundle data
      final registrationId = bundleData['registration_id'] is int
          ? bundleData['registration_id'] as int
          : int.parse(bundleData['registration_id'].toString());

      final preKeyId = bundleData['preKey']['prekey_id'] is int
          ? bundleData['preKey']['prekey_id'] as int
          : int.parse(bundleData['preKey']['prekey_id'].toString());

      final signedPreKeyId =
          bundleData['signedPreKey']['signed_prekey_id'] is int
          ? bundleData['signedPreKey']['signed_prekey_id'] as int
          : int.parse(
              bundleData['signedPreKey']['signed_prekey_id'].toString(),
            );

      final identityKeyBytes = base64Decode(bundleData['public_key']);
      final identityKey = IdentityKey.fromBytes(identityKeyBytes, 0);

      final preKeyPublic = Curve.decodePoint(
        base64Decode(bundleData['preKey']['prekey_data']),
        0,
      );

      final signedPreKeyPublic = Curve.decodePoint(
        base64Decode(bundleData['signedPreKey']['signed_prekey_data']),
        0,
      );

      final signedPreKeySignature = base64Decode(
        bundleData['signedPreKey']['signed_prekey_signature'],
      );

      // Build PreKeyBundle
      final bundle = PreKeyBundle(
        registrationId,
        deviceId,
        preKeyId,
        preKeyPublic,
        signedPreKeyId,
        signedPreKeyPublic,
        signedPreKeySignature,
        identityKey,
      );

      // Build session
      final address = SignalProtocolAddress(userId, deviceId);
      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        address,
      );

      await sessionBuilder.processPreKeyBundle(bundle);
      debugPrint('[SESSION_MANAGER] ✓ Session built: $userId:$deviceId');
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error building session: $e');
      rethrow;
    }
  }

  /// Build session from a PreKeyBundle object (already parsed)
  Future<void> buildSessionFromPreKeyBundle(
    String userId,
    int deviceId,
    PreKeyBundle bundle, {
    Function()? onUntrustedIdentity,
  }) async {
    try {
      debugPrint(
        '[SESSION_MANAGER] Building session from PreKeyBundle: $userId:$deviceId',
      );

      final address = SignalProtocolAddress(userId, deviceId);
      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        address,
      );

      await sessionBuilder.processPreKeyBundle(bundle);
      debugPrint('[SESSION_MANAGER] ✓ Session built: $userId:$deviceId');
    } on UntrustedIdentityException catch (e) {
      debugPrint('[SESSION_MANAGER] UntrustedIdentityException: $e');
      if (onUntrustedIdentity != null) {
        onUntrustedIdentity();
      }
      rethrow;
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error building session: $e');
      rethrow;
    }
  }

  /// Re-establish sessions with recent contacts
  /// Called after key healing or session deletion
  /// Proactively builds sessions so next messages don't require PreKey fetch
  Future<void> reestablishRecentSessions({
    String? currentUserId,
    int limit = 10,
  }) async {
    try {
      debugPrint('[SESSION_MANAGER] ========================================');
      debugPrint('[SESSION_MANAGER] Starting session re-establishment...');

      // Get recent conversations from SQLite
      final conversationsStore =
          await SqliteRecentConversationsStore.getInstance();
      final recentConvs = await conversationsStore.getRecentConversations(
        limit: limit,
      );

      if (recentConvs.isEmpty) {
        debugPrint('[SESSION_MANAGER] No recent conversations found');
        return;
      }

      debugPrint(
        '[SESSION_MANAGER] Found ${recentConvs.length} recent conversations',
      );

      int successCount = 0;
      int failCount = 0;

      // Process each contact
      for (final conv in recentConvs) {
        final userId = conv['userId'] as String?;
        if (userId == null || userId == currentUserId) continue;

        try {
          debugPrint('[SESSION_MANAGER] Fetching PreKeyBundle for: $userId');

          // Fetch their PreKeyBundle
          final response = await ApiService.get(
            '/signal/prekey_bundle/$userId',
          );
          final devices = response.data is String
              ? jsonDecode(response.data)
              : response.data;

          if (devices is! List || devices.isEmpty) {
            debugPrint('[SESSION_MANAGER] No devices for $userId');
            continue;
          }

          // Process first device only (primary device)
          final deviceData = devices.first;
          final deviceId = deviceData['deviceId'] as int;

          await buildSessionFromBundle(userId, deviceId, deviceData);
          successCount++;
        } catch (e) {
          debugPrint('[SESSION_MANAGER] Failed session with $userId: $e');
          failCount++;
        }

        // Small delay to avoid overwhelming the server
        await Future.delayed(Duration(milliseconds: 100));
      }

      debugPrint('[SESSION_MANAGER] ========================================');
      debugPrint(
        '[SESSION_MANAGER] ✅ Complete: $successCount succeeded, $failCount failed',
      );
    } catch (e, stackTrace) {
      debugPrint('[SESSION_MANAGER] Error during re-establishment: $e');
      debugPrint('[SESSION_MANAGER] Stack trace: $stackTrace');
    }
  }

  /// Validate session against current PreKeyBundle
  /// Returns true if session is valid, false if keys have changed
  Future<bool> validateSessionWithBundle(
    SignalProtocolAddress address,
    Map<String, dynamic> bundle,
  ) async {
    try {
      // Check if session exists first
      if (!await sessionStore.containsSession(address)) {
        debugPrint(
          '[SESSION_MANAGER] No session exists for ${address.toString()}',
        );
        return false;
      }

      // Load existing session
      final sessionRecord = await sessionStore.loadSession(address);
      final sessionState = sessionRecord.sessionState;

      // Get identity key from bundle
      final bundleIdentityKeyBytes = base64Decode(bundle['identityKeyBase64']);
      final bundleIdentityKey = IdentityKey.fromBytes(
        bundleIdentityKeyBytes,
        0,
      );

      // Compare with session's remote identity
      final sessionIdentityKey = sessionState.getRemoteIdentityKey();

      if (sessionIdentityKey == null) {
        debugPrint('[SESSION_MANAGER] Session has no remote identity key');
        return false;
      }

      // Compare public key bytes
      final sessionKeyBytes = sessionIdentityKey.serialize();
      final bundleKeyBytes = bundleIdentityKey.serialize();

      if (!_bytesEqual(sessionKeyBytes, bundleKeyBytes)) {
        debugPrint(
          '[SESSION_MANAGER] Identity key mismatch - keys have changed',
        );
        return false;
      }

      debugPrint('[SESSION_MANAGER] ✓ Session valid for ${address.toString()}');
      return true;
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error validating session: $e');
      return false;
    }
  }

  /// Check if session exists
  Future<bool> hasSession(String userId, int deviceId) async {
    try {
      final address = SignalProtocolAddress(userId, deviceId);
      return await sessionStore.containsSession(address);
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error checking session: $e');
      return false;
    }
  }

  /// Delete session and record metric
  Future<void> deleteSession(
    String userId,
    int deviceId, {
    String? reason,
  }) async {
    try {
      final address = SignalProtocolAddress(userId, deviceId);
      await sessionStore.deleteSession(address);

      if (reason != null) {
        KeyManagementMetrics.recordSessionInvalidation(
          address.getName(),
          reason: reason,
        );
      }

      debugPrint('[SESSION_MANAGER] ✓ Deleted session: $userId:$deviceId');
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error deleting session: $e');
    }
  }

  /// Delete all sessions
  Future<void> deleteAllSessions() async {
    try {
      await sessionStore.deleteAllSessionsCompletely();
      debugPrint('[SESSION_MANAGER] ✓ Deleted all sessions');
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error deleting all sessions: $e');
    }
  }

  /// Force session refresh by deleting existing session
  /// Used when forcePreKeyMessage=true
  Future<void> forceSessionRefresh(String userId, int deviceId) async {
    try {
      final address = SignalProtocolAddress(userId, deviceId);
      await sessionStore.deleteSession(address);
      debugPrint(
        '[SESSION_MANAGER] ✓ Forced session refresh: $userId:$deviceId',
      );
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error forcing refresh: $e');
    }
  }

  /// Helper: Compare byte arrays
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
