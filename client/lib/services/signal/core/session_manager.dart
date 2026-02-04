import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../stores/session_store.dart'; // Use mixin, not class
import '../models/key_bundle.dart';
import '../../api_service.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../../storage/sqlite_recent_conversations_store.dart';
import 'dart:convert';

import 'key_manager.dart';

/// Manages Signal Protocol sessions
///
/// Responsibilities:
/// - Session building and initialization
/// - PreKeyBundle processing
/// - Session validation and recovery
/// - Session lifecycle management (via mixin)
///
/// Architecture:
/// - Uses PermanentSessionStore mixin for session operations
/// - Accesses KeyManager for identity/preKey/signedPreKey stores
/// - Updates SessionState automatically via mixin
///
/// Usage:
/// ```dart
/// // Self-initializing factory with KeyManager dependency
/// final sessionManager = await SessionManager.create(
///   keyManager: keyManager,
///   apiService: apiService,
///   socketService: socketService,
/// );
/// ```
class SessionManager with PermanentSessionStore {
  final SignalKeyManager keyManager;

  // Required by PermanentSessionStore mixin
  @override
  final ApiService apiService;

  @override
  final SocketService socketService;

  bool _initialized = false;

  bool get isInitialized => _initialized;

  // Private constructor with dependencies
  SessionManager._({
    required this.keyManager,
    required this.apiService,
    required this.socketService,
  });

  /// Self-initializing factory - requires KeyManager and services
  static Future<SessionManager> create({
    required SignalKeyManager keyManager,
    required ApiService apiService,
    required SocketService socketService,
  }) async {
    final manager = SessionManager._(
      keyManager: keyManager,
      apiService: apiService,
      socketService: socketService,
    );
    await manager.init();
    return manager;
  }

  /// Initialize session manager (mixin already provides store)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[SESSION_MANAGER] Already initialized');
      return;
    }

    debugPrint('[SESSION_MANAGER] Initializing...');

    // Initialize session store (provided by mixin)
    await initializeSessionStore();

    debugPrint('[SESSION_MANAGER] ✓ Initialized');
    _initialized = true;
  }

  // ============================================================================
  // HELPER METHODS
  // ============================================================================

  /// Convert KeyBundle model to libsignal PreKeyBundle
  PreKeyBundle _toPreKeyBundle(KeyBundle bundle) {
    debugPrint(
      '[SESSION_MANAGER] _toPreKeyBundle for ${bundle.userId}:${bundle.deviceId}',
    );
    debugPrint(
      '[SESSION_MANAGER]   hasPreKey: ${bundle.preKey != null}, preKeyId: ${bundle.preKeyId}',
    );
    debugPrint('[SESSION_MANAGER]   signedPreKeyId: ${bundle.signedPreKeyId}');

    final identityKey = IdentityKey.fromBytes(bundle.identityKey, 0);

    // Only decode preKey if it exists and is not empty
    ECPublicKey? preKeyPublic;
    if (bundle.preKey != null && bundle.preKey!.isNotEmpty) {
      try {
        preKeyPublic = Curve.decodePoint(bundle.preKey!, 0);
        debugPrint('[SESSION_MANAGER]   ✓ PreKey decoded successfully');
      } catch (e) {
        debugPrint('[SESSION_MANAGER]   ✗ Failed to decode preKey: $e');
        preKeyPublic = null;
      }
    } else {
      debugPrint('[SESSION_MANAGER]   ℹ No preKey available (null or empty)');
    }

    final signedPreKeyPublic = Curve.decodePoint(bundle.signedPreKey, 0);
    debugPrint('[SESSION_MANAGER]   ✓ SignedPreKey decoded successfully');

    return PreKeyBundle(
      bundle.registrationId,
      bundle.deviceId,
      bundle.preKeyId,
      preKeyPublic,
      bundle.signedPreKeyId,
      signedPreKeyPublic,
      bundle.signedPreKeySignature,
      identityKey,
    );
  }

  /// Compare byte arrays
  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ============================================================================
  // CIPHER FACTORIES
  // ============================================================================

  /// Create SessionCipher for 1-to-1 communication
  SessionCipher createSessionCipher(SignalProtocolAddress address) {
    return SessionCipher(
      this, // SessionStore from mixin
      keyManager, // PreKeyStore from mixin
      keyManager, // SignedPreKeyStore from mixin
      keyManager, // IdentityKeyStore from mixin
      address,
    );
  }

  /// Create GroupCipher for group communication
  GroupCipher createGroupCipher(
    String groupId,
    SignalProtocolAddress senderAddress,
  ) {
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    return GroupCipher(keyManager, senderKeyName); // SenderKeyStore from mixin
  }

  /// Establish session with a user by fetching their PreKeyBundle
  /// Returns true if at least one device session was established
  Future<bool> establishSessionWithUser(String userId) async {
    try {
      debugPrint('[SESSION_MANAGER] Establishing session with: $userId');

      // Fetch PreKeyBundles for user
      final response = await ApiService.instance.get(
        '/signal/prekey_bundle/$userId',
      );

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

      for (final deviceData in devices) {
        try {
          final bundle = KeyBundle.fromServer(
            deviceData as Map<String, dynamic>,
          );
          await buildSessionFromBundle(bundle);
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

  /// Get device IDs for a user from local session storage.
  ///
  /// Returns list of device IDs we have active sessions with.
  /// Uses getAllDeviceSessions() which queries storage directly - no device ID limit.
  Future<List<int>> getDeviceIdsForUser(String userId) async {
    try {
      // Use PermanentSessionStore's method to get all device IDs from storage
      // This queries storage directly, so it finds ALL devices regardless of ID number
      final deviceIds = await getAllDeviceSessions(userId);

      debugPrint(
        '[SESSION_MANAGER] Found ${deviceIds.length} session(s) for $userId: $deviceIds',
      );
      return deviceIds;
    } catch (e) {
      debugPrint('[SESSION_MANAGER] Error getting device IDs: $e');
      return [];
    }
  }

  /// Build session from KeyBundle
  /// This creates a new session or rebuilds an existing one
  Future<void> buildSessionFromBundle(KeyBundle keyBundle) async {
    try {
      debugPrint(
        '[SESSION_MANAGER] Building session for ${keyBundle.bundleId}',
      );

      // Convert KeyBundle to PreKeyBundle
      final preKeyBundle = _toPreKeyBundle(keyBundle);

      // Build session
      final address = SignalProtocolAddress(
        keyBundle.userId,
        keyBundle.deviceId,
      );
      final sessionBuilder = SessionBuilder(
        this, // SessionStore from mixin
        keyManager, // PreKeyStore from mixin
        keyManager, // SignedPreKeyStore from mixin
        keyManager, // IdentityKeyStore from mixin
        address,
      );

      await sessionBuilder.processPreKeyBundle(preKeyBundle);
      debugPrint('[SESSION_MANAGER] ✓ Session built: ${keyBundle.bundleId}');
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
        this, // SessionStore from mixin
        keyManager, // PreKeyStore from mixin
        keyManager, // SignedPreKeyStore from mixin
        keyManager, // IdentityKeyStore from mixin
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
          final response = await ApiService.instance.get(
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
          final deviceData = devices.first as Map<String, dynamic>;
          final bundle = KeyBundle.fromServer(deviceData);

          await buildSessionFromBundle(bundle);
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

  /// Validate session against current KeyBundle
  /// Returns true if session is valid, false if keys have changed
  Future<bool> validateSessionWithBundle(
    SignalProtocolAddress address,
    KeyBundle bundle,
  ) async {
    try {
      // Check if session exists first
      if (!await containsSession(address)) {
        debugPrint(
          '[SESSION_MANAGER] No session exists for ${address.toString()}',
        );
        return false;
      }

      // Load existing session
      final sessionRecord = await loadSession(address);
      final sessionState = sessionRecord.sessionState;

      // Get identity key from bundle
      final bundleIdentityKey = IdentityKey.fromBytes(bundle.identityKey, 0);

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

  // ============================================================================
  // SESSION EVENT HANDLERS (Socket.IO Integration)
  // ============================================================================

  /// Handle session invalidation from remote party
  ///
  /// When a remote user deletes their session with us (e.g., due to errors,
  /// device reset, or security policy), we need to delete our session with them
  /// to stay synchronized.
  ///
  /// Called by: SessionListeners when 'sessionInvalidated' socket event fires
  Future<void> handleSessionInvalidation(String userId, int deviceId) async {
    try {
      debugPrint(
        '[SESSION_MANAGER] Handling session invalidation from $userId:$deviceId',
      );

      final address = SignalProtocolAddress(userId, deviceId);

      // Check if we have a session
      if (await containsSession(address)) {
        // Delete the session
        await deleteSession(address);
        debugPrint(
          '[SESSION_MANAGER] ✓ Deleted session with $userId:$deviceId due to remote invalidation',
        );
      } else {
        debugPrint(
          '[SESSION_MANAGER] No session exists with $userId:$deviceId, nothing to delete',
        );
      }

      // Session will be re-established on next message send
    } catch (e, stack) {
      debugPrint('[SESSION_MANAGER] Error handling session invalidation: $e');
      debugPrint('[SESSION_MANAGER] Stack: $stack');
      // Don't rethrow - this is a cleanup operation
    }
  }

  /// Handle identity key change from remote party
  ///
  /// When a remote user rotates their identity key (e.g., security policy,
  /// suspected compromise, or device reinstall), we need to:
  /// 1. Delete all sessions with that user
  /// 2. Trust the new identity key on next contact
  ///
  /// Called by: SessionListeners when 'identityKeyChanged' socket event fires
  Future<void> handleIdentityKeyChange(String userId) async {
    try {
      debugPrint('[SESSION_MANAGER] Handling identity key change for $userId');

      // Delete all sessions with this user (all devices)
      // We only know the userId, not specific deviceIds
      // In a full implementation, you'd enumerate all sessions for this user

      // For now, delete the primary session (device 1)
      final primaryAddress = SignalProtocolAddress(userId, 1);
      if (await containsSession(primaryAddress)) {
        await deleteSession(primaryAddress);
        debugPrint(
          '[SESSION_MANAGER] ✓ Deleted primary session with $userId due to identity key change',
        );
      }

      // TODO: Implement session enumeration to delete ALL sessions for this user
      // This would require enhancing the session store to query by userId

      // The new identity key will be trusted automatically on next session establishment
      debugPrint(
        '[SESSION_MANAGER] Sessions with $userId will be re-established with new identity key',
      );
    } catch (e, stack) {
      debugPrint('[SESSION_MANAGER] Error handling identity key change: $e');
      debugPrint('[SESSION_MANAGER] Stack: $stack');
      // Don't rethrow - this is a cleanup operation
    }
  }
}
