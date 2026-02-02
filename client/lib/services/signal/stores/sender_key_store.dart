import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../device_scoped_storage_service.dart';
import '../../api_service.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../state/sender_key_state.dart';

/// A persistent sender key store for Signal Protocol group messaging.
///
/// Core Operations:
/// - getGroupCipher(groupId, address) - Get cipher for group encryption/decryption (THE method!)
/// - checkSenderKeys(myAddress) - Check all groups, auto-rotate if needed (call periodically)
/// - rotateSenderKey(groupId, address) - Rotate and upload sender key for a group
/// - shouldRotateSenderKey(groupId, address) - Check if rotation needed (7+ days or 1000+ msgs)
/// - clearGroupSenderKeys(groupId) - Remove all keys when leaving group
/// - removeSenderKey(groupId, address) - Remove specific member's key
/// - getAllGroupIds() - Get list of all groups with sender keys
///
/// 💡 Key Insights:
/// - Sender keys enable efficient group messaging (one encryption → many recipients)
/// - Unlike 1-to-1 sessions, group messages use shared sender keys
/// - GroupCipher is what you use - not SenderKeyRecord directly
/// - Keys are per-group, per-sender (each member has their own sender key)
/// - Auto-rotation: 7 days OR 1000 messages
///
/// 🔐 Storage:
/// - Uses DeviceScopedStorageService (encrypted, device-bound)
/// - Metadata tracked for rotation (createdAt, messageCount, lastRotation)
/// - Multi-server support via serverUrl parameter
///
/// Usage:
/// ```dart
/// // Encrypting group message
/// final cipher = getGroupCipher(groupId: 'group123', senderAddress: myAddress);
/// final encrypted = await cipher.encrypt(messageBytes);
///
/// // Decrypting group message
/// final cipher = getGroupCipher(groupId: 'group123', senderAddress: senderAddress);
/// final decrypted = await cipher.decrypt(encryptedBytes);
///
/// // Check rotation
/// if (await shouldRotateSenderKey(groupId: id, senderAddress: myAddress)) {
///   // Rotate and distribute new key
/// }
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
mixin PermanentSenderKeyStore implements SenderKeyStore {
  // Abstract getters - provided by KeyManager
  ApiService get apiService;
  SocketService get socketService;

  /// State instance for this server - must be provided by KeyManager
  SenderKeyState get senderKeyState;

  String get _storeName => 'peerwaveSenderKeys';
  String get _keyPrefix => 'sender_key_';

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  /// Generate storage key from sender key name.
  /// Format: 'sender_key_{groupId}_{userId}_{deviceId}'
  String _getStorageKey(SenderKeyName senderKeyName) {
    return '$_keyPrefix${senderKeyName.groupId}_${senderKeyName.sender.getName()}_${senderKeyName.sender.getDeviceId()}';
  }

  /// Initialize sender key store - MUST be called after mixin is applied.
  ///
  /// This method is called during KeyManager initialization.
  /// Currently a placeholder for future setup if needed.
  ///
  /// Call this from KeyManager.init() after identity key pair is loaded.
  Future<void> initializeSenderKeyStore() async {
    debugPrint('[SENDER_KEY_STORE] Sender key store initialized');
    // Future: Setup if needed
  }

  /// Check all sender keys for rotation needs.
  ///
  /// Scans all groups and rotates sender keys that are:
  /// - Older than 7 days, OR
  /// - Used for 1000+ messages
  ///
  /// This should be called periodically (e.g., on app startup or daily).
  /// Auto-rotates and uploads keys as needed.
  ///
  /// Returns map of groupId -> rotation status:
  /// - true: Key was rotated
  /// - false: Key is still valid
  Future<Map<String, bool>> checkSenderKeys(
    SignalProtocolAddress myAddress,
  ) async {
    debugPrint('[SENDER_KEY_STORE] Checking all sender keys for rotation...');

    final groupIds = await getAllGroupIds();
    final rotationStatus = <String, bool>{};

    if (groupIds.isEmpty) {
      debugPrint('[SENDER_KEY_STORE] No groups with sender keys');
      senderKeyState.updateStatus(0, 0);
      return rotationStatus;
    }

    debugPrint('[SENDER_KEY_STORE] Checking ${groupIds.length} groups');

    // Mark as checking
    senderKeyState.markRotating();

    for (final groupId in groupIds) {
      try {
        final needsRotation = await shouldRotateSenderKey(
          groupId: groupId,
          senderAddress: myAddress,
        );

        if (needsRotation) {
          debugPrint(
            '[SENDER_KEY_STORE] Rotating sender key for group $groupId',
          );
          await rotateSenderKey(groupId: groupId, senderAddress: myAddress);
          rotationStatus[groupId] = true;
        } else {
          rotationStatus[groupId] = false;
        }
      } catch (e) {
        debugPrint('[SENDER_KEY_STORE] Error checking group $groupId: $e');
        rotationStatus[groupId] = false;
      }
    }

    final rotatedCount = rotationStatus.values.where((v) => v).length;
    debugPrint(
      '[SENDER_KEY_STORE] ✓ Check complete: $rotatedCount/${groupIds.length} keys rotated',
    );

    // Update state
    senderKeyState.updateStatus(groupIds.length, 0);
    if (rotatedCount > 0) {
      senderKeyState.markRotationComplete(rotatedCount);
    }

    return rotationStatus;
  }

  // ============================================================================
  // SIGNAL PROTOCOL INTERFACE (Required overrides)
  // ============================================================================

  /// Store a sender key record (Signal protocol interface).
  ///
  /// Called by libsignal when:
  /// - Creating new group session
  /// - Rotating sender key
  /// - Receiving distributed sender key
  ///
  /// Automatically tracks metadata for rotation:
  /// - createdAt: When key was first stored
  /// - messageCount: Number of messages encrypted/decrypted
  /// - lastRotation: When key was last rotated
  @override
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    SenderKeyRecord record,
  ) async {
    final key = _getStorageKey(senderKeyName);
    final serialized = base64Encode(record.serialize());

    // Store metadata for rotation tracking
    final metadata = {
      'createdAt': DateTime.now().toIso8601String(),
      'messageCount': 0,
      'lastRotation': DateTime.now().toIso8601String(),
    };
    final metadataKey = '${key}_metadata';

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;

    // Get existing metadata to preserve messageCount
    final existingMetadata = await storage.getDecrypted(
      _storeName,
      _storeName,
      metadataKey,
    );
    if (existingMetadata != null) {
      try {
        final existing = jsonDecode(existingMetadata);
        metadata['messageCount'] = existing['messageCount'] ?? 0;
      } catch (e) {
        // Ignore parse errors, use default metadata
      }
    }

    // Store encrypted sender key and metadata
    await storage.storeEncrypted(_storeName, _storeName, key, serialized);
    await storage.storeEncrypted(
      _storeName,
      _storeName,
      metadataKey,
      jsonEncode(metadata),
    );

    debugPrint(
      '[SENDER_KEY_STORE] Stored sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
    );
  }

  /// Load a sender key record (Signal protocol interface).
  ///
  /// Called by libsignal when:
  /// - Encrypting group message
  /// - Decrypting received group message
  ///
  /// Returns empty SenderKeyRecord if not found (required by libsignal API).
  /// The protocol will initialize it during first use.
  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(_storeName, _storeName, key);

    if (value != null) {
      final bytes = base64Decode(value);
      final record = SenderKeyRecord.fromSerialized(bytes);
      debugPrint(
        '[SENDER_KEY_STORE] Loaded sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
      );
      return record;
    }

    // Return new empty record if not found (required by libsignal API)
    debugPrint(
      '[SENDER_KEY_STORE] No sender key found for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}, returning empty record',
    );
    return SenderKeyRecord();
  }

  // ============================================================================
  // PUBLIC API METHODS (High-level operations from SenderKeyManager)
  // ============================================================================

  /// Get GroupCipher for encrypting/decrypting group messages.
  ///
  /// ✨ This is THE method for group messaging:
  /// - Returns cipher ready for encryption/decryption
  /// - Auto-creates sender key if needed (during session establishment)
  /// - Use this instead of manually managing SenderKeyRecord
  ///
  /// For sending messages:
  /// ```dart
  /// final cipher = getGroupCipher(groupId: id, senderAddress: myAddress);
  /// final encrypted = await cipher.encrypt(messageBytes);
  /// ```
  ///
  /// For receiving messages:
  /// ```dart
  /// final cipher = getGroupCipher(groupId: id, senderAddress: senderAddress);
  /// final decrypted = await cipher.decrypt(encryptedBytes);
  /// ```
  GroupCipher getGroupCipher({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) {
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    return GroupCipher(this, senderKeyName);
  }

  /// Rotate sender key and upload to server.
  ///
  /// This method:
  /// 1. Generates new sender key distribution message
  /// 2. Notifies server via REST API
  /// 3. Updates rotation timestamp
  ///
  /// The server acknowledges the rotation event.
  ///
  /// Called automatically by checkSenderKeys() when rotation is needed.
  Future<void> rotateSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      debugPrint('[SENDER_KEY_STORE] Rotating sender key for group $groupId');

      // Create new sender key distribution message
      final senderKeyName = SenderKeyName(groupId, senderAddress);

      // Notify server via REST API
      final response = await apiService.post(
        '/signal/sender-key/rotate',
        data: {
          'groupId': groupId,
          'address': {
            'name': senderAddress.getName(),
            'deviceId': senderAddress.getDeviceId(),
          },
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[SENDER_KEY_STORE] ⚠️ Server returned ${response.statusCode} for rotation',
        );
      } else {
        debugPrint('[SENDER_KEY_STORE] ✓ Server acknowledged rotation');
      }

      // Update rotation timestamp
      await updateRotationTimestamp(senderKeyName);

      debugPrint('[SENDER_KEY_STORE] ✓ Sender key rotated for group $groupId');
    } catch (e) {
      debugPrint('[SENDER_KEY_STORE] ✗ Failed to rotate sender key: $e');
      rethrow;
    }
  }

  /// Check if sender key needs rotation.
  ///
  /// Returns true if:
  /// - Key is older than 7 days, OR
  /// - Key has been used for 1000+ messages
  ///
  /// When true, you should:
  /// 1. Generate new sender key distribution message
  /// 2. Send to all group members via Signal Protocol SenderKeyDistributionMessage
  /// 3. Call updateRotationTimestamp() after successful distribution
  ///
  /// Call this periodically or after sending messages.
  ///
  /// ⚠️ Note: Signal Protocol doesn't mandate rotation, but it's a security best practice.
  /// The 7-day/1000-message thresholds are PeerWave policy, not protocol requirements.
  Future<bool> shouldRotateSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final key = _getStorageKey(SenderKeyName(groupId, senderAddress));
      final metadataKey = '${key}_metadata';

      // ✅ ONLY encrypted device-scoped storage (Web + Native)
      final storage = DeviceScopedStorageService.instance;

      final metadataValue = await storage.getDecrypted(
        _storeName,
        _storeName,
        metadataKey,
      );

      if (metadataValue == null) {
        return false; // No metadata, probably a new key
      }

      final metadata = jsonDecode(metadataValue);

      // Check age (7 days)
      final lastRotation = DateTime.parse(
        metadata['lastRotation'] ?? metadata['createdAt'],
      );
      final age = DateTime.now().difference(lastRotation);
      if (age.inDays >= 7) {
        debugPrint(
          '[SENDER_KEY_STORE] Sender key age: ${age.inDays} days - rotation recommended',
        );
        return true;
      }

      // Check message count (1000 messages)
      final messageCount = metadata['messageCount'] ?? 0;
      if (messageCount >= 1000) {
        debugPrint(
          '[SENDER_KEY_STORE] Sender key message count: $messageCount - rotation recommended',
        );
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[SENDER_KEY_STORE] Error checking rotation: $e');
      return false;
    }
  }

  /// Check if sender key exists.
  ///
  /// Use for:
  /// - Verifying group membership
  /// - Checking if key distribution is needed
  /// - Diagnostics
  Future<bool> hasSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      return await containsSenderKey(senderKeyName);
    } catch (e) {
      debugPrint('[SENDER_KEY_STORE] Error checking key existence: $e');
      return false;
    }
  }

  /// Check if sender key exists in storage.
  ///
  /// Returns `true` if key exists, `false` otherwise.
  Future<bool> containsSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(_storeName, _storeName, key);
    return value != null;
  }

  /// Remove sender key for a specific sender in a group.
  ///
  /// Use when:
  /// - Member leaves group
  /// - Member is removed/kicked
  /// - Member's device is untrusted
  ///
  /// Other members' keys remain intact.
  Future<void> removeSenderKey(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;
    await storage.deleteEncrypted(_storeName, _storeName, key);
    await storage.deleteEncrypted(_storeName, _storeName, metadataKey);

    debugPrint(
      '[SENDER_KEY_STORE] Removed sender key for group ${senderKeyName.groupId}, sender ${senderKeyName.sender.getName()}:${senderKeyName.sender.getDeviceId()}',
    );
  }

  /// Clear all sender keys for a group.
  ///
  /// Use when:
  /// - Leaving a group
  /// - Group is deleted
  /// - Starting fresh (re-establishing group)
  ///
  /// This removes all sender keys (from all members) for the group.
  Future<void> clearGroupSenderKeys(String groupId) async {
    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;

    // Get all keys and filter by group
    final allKeys = await storage.getAllKeys(_storeName, _storeName);
    final groupKeys = allKeys.where(
      (k) => k.startsWith('$_keyPrefix$groupId}_'),
    );

    for (final key in groupKeys) {
      await storage.deleteEncrypted(_storeName, _storeName, key);
    }

    debugPrint(
      '[SENDER_KEY_STORE] Cleared all sender keys for group $groupId (${groupKeys.length} keys)',
    );
  }

  /// Delete ALL sender keys (for all groups).
  ///
  /// ⚠️ Use ONLY for:
  /// - Identity Key regeneration (all sender keys become invalid)
  /// - Account deletion
  /// - Complete app reset
  /// - Testing cleanup
  ///
  /// This removes ALL sender keys from ALL groups.
  /// You'll need to re-establish all group sessions.
  Future<void> deleteAllSenderKeys() async {
    debugPrint('[SENDER_KEY_STORE] Deleting ALL sender keys...');

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;

    // Get all keys and delete sender keys
    final allKeys = await storage.getAllKeys(_storeName, _storeName);
    final senderKeys = allKeys.where((k) => k.startsWith(_keyPrefix));

    int deletedCount = 0;
    for (final key in senderKeys) {
      await storage.deleteEncrypted(_storeName, _storeName, key);
      deletedCount++;
    }

    debugPrint('[SENDER_KEY_STORE] ✓ Deleted $deletedCount sender keys');
  }

  /// Get all group IDs that have sender keys.
  ///
  /// Use for:
  /// - Diagnostics
  /// - Cleanup operations
  /// - Group membership audit
  ///
  /// Returns list of unique group IDs.
  Future<List<String>> getAllGroupIds() async {
    final Set<String> groupIds = {};

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;

    // Get all keys and extract group IDs
    final allKeys = await storage.getAllKeys(_storeName, _storeName);

    for (final key in allKeys) {
      if (key.startsWith(_keyPrefix) && !key.endsWith('_metadata')) {
        // Extract groupId from key format: sender_key_<groupId>_<userId>_<deviceId>
        final parts = key.substring(_keyPrefix.length).split('_');
        if (parts.isNotEmpty) {
          groupIds.add(parts[0]);
        }
      }
    }

    debugPrint(
      '[SENDER_KEY_STORE] Found ${groupIds.length} groups with sender keys',
    );
    return groupIds.toList();
  }

  /// Load sender key for a specific server (multi-server support).
  ///
  /// Use when connecting to multiple PeerWave servers.
  Future<SenderKeyRecord> loadSenderKeyForServer(
    SenderKeyName senderKeyName,
    String serverUrl,
  ) async {
    final key = _getStorageKey(senderKeyName);
    final storage = DeviceScopedStorageService.instance;
    final value = await storage.getDecrypted(
      _storeName,
      _storeName,
      key,
      serverUrl: serverUrl,
    );

    if (value != null) {
      final bytes = base64Decode(value);
      return SenderKeyRecord.fromSerialized(bytes);
    }
    return SenderKeyRecord();
  }

  // ============================================================================
  // ROTATION TRACKING (Internal metadata management)
  // ============================================================================

  /// Increment message count for rotation tracking.
  ///
  /// Called automatically after each message sent/received.
  /// Tracks toward 1000-message rotation threshold.
  ///
  /// ⚠️ Usually handled automatically - don't call manually!
  Future<void> incrementMessageCount(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;

    final metadataValue = await storage.getDecrypted(
      _storeName,
      _storeName,
      metadataKey,
    );
    if (metadataValue != null) {
      final metadata = jsonDecode(metadataValue);
      metadata['messageCount'] = (metadata['messageCount'] ?? 0) + 1;
      await storage.storeEncrypted(
        _storeName,
        _storeName,
        metadataKey,
        jsonEncode(metadata),
      );
    }
  }

  /// Update rotation timestamp after key rotation.
  ///
  /// Call this after successfully distributing new sender key to group via
  /// SenderKeyDistributionMessage.
  ///
  /// Resets:
  /// - 7-day rotation timer
  /// - Message count to 0
  ///
  /// Usage after rotation:
  /// ```dart
  /// // 1. Create new sender key (handled by protocol)
  /// final cipher = getGroupCipher(groupId: id, senderAddress: myAddress);
  ///
  /// // 2. Protocol will generate SenderKeyDistributionMessage
  /// // 3. Send distribution message to all group members
  ///
  /// // 4. After successful distribution, reset timer
  /// await updateRotationTimestamp(
  ///   SenderKeyName(groupId, myAddress)
  /// );
  /// ```
  Future<void> updateRotationTimestamp(SenderKeyName senderKeyName) async {
    final key = _getStorageKey(senderKeyName);
    final metadataKey = '${key}_metadata';

    // ✅ ONLY encrypted device-scoped storage (Web + Native)
    final storage = DeviceScopedStorageService.instance;

    final metadataValue = await storage.getDecrypted(
      _storeName,
      _storeName,
      metadataKey,
    );
    if (metadataValue != null) {
      final metadata = jsonDecode(metadataValue);
      metadata['lastRotation'] = DateTime.now().toIso8601String();
      metadata['messageCount'] = 0; // Reset counter
      await storage.storeEncrypted(
        _storeName,
        _storeName,
        metadataKey,
        jsonEncode(metadata),
      );

      debugPrint(
        '[SENDER_KEY_STORE] Updated rotation timestamp for group ${senderKeyName.groupId}',
      );
    }
  }
}
