import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../device_scoped_storage_service.dart';
import '../../api_service.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../state/session_state.dart' as signal_state;

/// A persistent session store for Signal Protocol 1-to-1 sessions.
///
/// Core Operations:
/// - loadSession(address) - Load session for message encryption/decryption
/// - storeSession(address, record) - Save session after key exchange
/// - deleteSession(address) - Remove session when user/device is untrusted
/// - containsSession(address) - Check if session exists
/// - getSubDeviceSessions(name) - Get all device IDs for a user
///
/// 💡 Key Insights:
/// - Sessions enable end-to-end encryption for 1-to-1 messages
/// - Each session is per-user, per-device (user can have multiple devices)
/// - Sessions are created during initial key exchange (X3DH protocol)
/// - Sessions persist across app restarts (encrypted storage)
/// - Sessions must be deleted when identity key changes
///
/// 🔐 Storage:
/// - Uses DeviceScopedStorageService (encrypted, device-bound)
/// - Storage key format: 'session_{userId}_{deviceId}'
/// - Automatically persists SessionRecord state (ratchet chains, message keys)
///
/// 🔄 Session Lifecycle:
/// 1. **Establishment**: First message → X3DH key exchange → Session created
/// 2. **Active**: Messages encrypted/decrypted using Double Ratchet
/// 3. **Invalidation**: Identity key change → All sessions deleted
/// 4. **Re-establishment**: New key exchange required
///
/// Usage:
/// ```dart
/// // Check if session exists
/// if (await containsSession(recipientAddress)) {
///   // Encrypt message
///   final session = await loadSession(recipientAddress);
///   // SessionCipher will use this automatically
/// }
///
/// // After identity key regeneration
/// await deleteAllSessionsCompletely(); // All sessions invalid
/// ```
///
/// 🌐 Multi-Server Support:
/// This store is server-scoped via KeyManager.
/// - apiService: Used for HTTP uploads (server-scoped, knows baseUrl)
/// - socketService: Used for real-time events (server-scoped, knows serverUrl)
///
/// Storage isolation is automatic:
/// - DeviceIdentityService provides unique deviceId per server
/// - DeviceScopedStorageService creates isolated databases automatically
mixin PermanentSessionStore implements SessionStore {
  // Abstract getters - provided by KeyManager
  ApiService get apiService;
  SocketService get socketService;

  String get _storeName => 'peerwaveSignalSessions';
  String get _keyPrefix => 'session_';

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  /// Generate storage key for a session.
  /// Format: 'session_{userId}_{deviceId}'
  String _sessionKey(SignalProtocolAddress address) =>
      '$_keyPrefix${address.getName()}_${address.getDeviceId()}';

  /// Initialize session store - MUST be called after mixin is applied.
  ///
  /// This method is called during KeyManager initialization.
  /// Currently a placeholder for future setup if needed.
  ///
  /// Call this from KeyManager.init() after identity key pair is loaded.
  Future<void> initializeSessionStore() async {
    debugPrint('[SESSION_STORE] Session store initialized');
    // Future: Setup if needed
  }

  // ============================================================================
  // SIGNAL PROTOCOL INTERFACE (Required overrides)
  // ============================================================================

  // ============================================================================
  // SIGNAL PROTOCOL INTERFACE (Required overrides)
  // ============================================================================

  /// Check if a session exists for a given address (Signal protocol interface).
  ///
  /// Returns `true` if session exists, `false` otherwise.
  ///
  /// Called by libsignal before encrypting to determine if session establishment
  /// is needed (X3DH key exchange).
  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    try {
      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;
      final key = _sessionKey(address);
      final value = await storage.getDecrypted(_storeName, _storeName, key);
      return value != null;
    } catch (e) {
      debugPrint('[SESSION_STORE] Error checking session existence: $e');
      rethrow;
    }
  }

  /// Load a session record for encryption/decryption (Signal protocol interface).
  ///
  /// Returns existing SessionRecord or empty SessionRecord if not found.
  ///
  /// Called by SessionCipher when:
  /// - Encrypting outgoing message
  /// - Decrypting incoming message
  ///
  /// The SessionRecord contains:
  /// - Ratchet state (root key, chain keys)
  /// - Message keys for out-of-order delivery
  /// - Session version and configuration
  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    try {
      if (await containsSession(address)) {
        // ✅ ONLY encrypted device-scoped storage (Web + Native)
        final storage = DeviceScopedStorageService.instance;
        final value = await storage.getDecrypted(
          _storeName,
          _storeName,
          _sessionKey(address),
        );

        if (value != null) {
          return SessionRecord.fromSerialized(base64Decode(value));
        } else {
          return SessionRecord();
        }
      } else {
        return SessionRecord();
      }
    } catch (e) {
      debugPrint('[SESSION_STORE] Error loading session: $e');
      throw AssertionError(e);
    }
  }

  /// Store a session record after key exchange or ratchet update (Signal protocol interface).
  ///
  /// Called by SessionCipher when:
  /// - Session is first established (X3DH key exchange)
  /// - Double Ratchet advances (after sending/receiving message)
  /// - Message keys are updated
  ///
  /// The session is automatically serialized and encrypted before storage.
  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    final serialized = record.serialize();
    final sessionKey = _sessionKey(address);

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.storeEncrypted(
      _storeName,
      _storeName,
      sessionKey,
      base64Encode(serialized),
    );

    // Update session state
    final count = await getSessionCount();
    signal_state.SessionState.instance.updateStatus(count, 0);
  }

  /// Delete a specific session (Signal protocol interface).
  ///
  /// Use when:
  /// - User/device is untrusted
  /// - Manual session reset requested
  /// - Device is removed
  ///
  /// After deletion, new session establishment (X3DH) required.
  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    final sessionKey = _sessionKey(address);

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(_storeName, _storeName, sessionKey);

    debugPrint(
      '[SESSION_STORE] Deleted session for ${address.getName()}:${address.getDeviceId()}',
    );

    // Update session state
    final count = await getSessionCount();
    signal_state.SessionState.instance.updateStatus(count, 0);
  }

  /// Delete all sessions for a specific user (all devices) (Signal protocol interface).
  ///
  /// Use when:
  /// - User is blocked
  /// - User's identity key changed (safety number changed)
  /// - Clearing all sessions with a user
  ///
  /// This removes sessions for ALL devices owned by the user.
  @override
  Future<void> deleteAllSessions(String name) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);

    int deletedCount = 0;
    for (var key in keys) {
      if (key.startsWith('$_keyPrefix$name}_')) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
        deletedCount++;
      }
    }

    debugPrint(
      '[SESSION_STORE] Deleted all sessions for user $name ($deletedCount devices)',
    );

    // Update session state
    final count = await getSessionCount();
    signal_state.SessionState.instance.updateStatus(count, 0);
  }

  /// Get all device IDs for a user (excluding primary device 1) (Signal protocol interface).
  ///
  /// Returns list of secondary device IDs (device ID ≠ 1).
  ///
  /// Used for:
  /// - Multi-device messaging (send to all user's devices)
  /// - Device management UI
  /// - Session diagnostics
  ///
  /// Note: Device ID 1 is typically the primary/phone device.
  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final deviceIds = <int>[];

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);

    for (var key in keys) {
      if (key.startsWith('$_keyPrefix$name}_')) {
        final deviceIdStr = key.substring('$_keyPrefix$name}_'.length);
        final deviceId = int.tryParse(deviceIdStr);
        if (deviceId != null && deviceId != 1) {
          deviceIds.add(deviceId);
        }
      }
    }
    return deviceIds;
  }

  // ============================================================================
  // PUBLIC API METHODS (Extended functionality)
  // ============================================================================

  /// Delete ALL sessions for ALL users and devices.
  ///
  /// ⚠️ Use ONLY for:
  /// - Identity Key regeneration (all sessions become invalid)
  /// - Account deletion
  /// - Complete app reset
  /// - Testing cleanup
  ///
  /// This is the nuclear option - ALL encrypted conversations must be re-established.
  /// Users will see "Safety number changed" or need to verify keys again.
  Future<void> deleteAllSessionsCompletely() async {
    debugPrint('[SESSION_STORE] Deleting ALL sessions...');

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);

    int deletedCount = 0;
    for (var key in keys) {
      if (key.startsWith(_keyPrefix)) {
        await storage.deleteEncrypted(_storeName, _storeName, key);
        deletedCount++;
      }
    }

    debugPrint('[SESSION_STORE] ✓ Deleted $deletedCount sessions');

    // Reset session state
    signal_state.SessionState.instance.reset();
  }

  /// Get total count of all sessions.
  ///
  /// Use for:
  /// - Diagnostics
  /// - Monitoring
  /// - Storage management
  ///
  /// Returns: Number of active sessions (across all users and devices).
  Future<int> getSessionCount() async {
    try {
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);
      final sessionKeys = keys.where((k) => k.startsWith(_keyPrefix));
      return sessionKeys.length;
    } catch (e) {
      debugPrint('[SESSION_STORE] Error getting session count: $e');
      return 0;
    }
  }

  /// Get all device IDs for a user (including primary device).
  ///
  /// Unlike getSubDeviceSessions(), this includes device ID 1.
  ///
  /// Use for:
  /// - Complete device inventory
  /// - Multi-device messaging (send to ALL devices)
  /// - UI display of all user's devices
  Future<List<int>> getAllDeviceSessions(String name) async {
    final deviceIds = <int>[];

    final storage = DeviceScopedStorageService.instance;
    final keys = await storage.getAllKeys(_storeName, _storeName);

    for (var key in keys) {
      if (key.startsWith('$_keyPrefix$name}_')) {
        final deviceIdStr = key.substring('$_keyPrefix$name}_'.length);
        final deviceId = int.tryParse(deviceIdStr);
        if (deviceId != null) {
          deviceIds.add(deviceId);
        }
      }
    }

    return deviceIds;
  }

  /// Check if user has any sessions (any device).
  ///
  /// Use for:
  /// - Quick check before sending message
  /// - UI state (show "Start conversation" vs "Send message")
  /// - Session validation
  ///
  /// Returns `true` if user has at least one session.
  Future<bool> hasSessionsWithUser(String name) async {
    try {
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);
      return keys.any((k) => k.startsWith('$_keyPrefix$name}_'));
    } catch (e) {
      debugPrint('[SESSION_STORE] Error checking user sessions: $e');
      return false;
    }
  }

  /// Get list of all users with active sessions.
  ///
  /// Use for:
  /// - Session management UI
  /// - "Active conversations" list
  /// - Diagnostics
  ///
  /// Returns: List of unique user IDs/names.
  Future<List<String>> getAllSessionUsers() async {
    final userNames = <String>{};

    try {
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(_storeName, _storeName);

      for (var key in keys) {
        if (key.startsWith(_keyPrefix)) {
          // Extract username from 'session_{userId}_{deviceId}'
          final parts = key.substring(_keyPrefix.length).split('_');
          if (parts.isNotEmpty) {
            userNames.add(parts[0]);
          }
        }
      }
    } catch (e) {
      debugPrint('[SESSION_STORE] Error getting session users: $e');
    }

    return userNames.toList();
  }
}
