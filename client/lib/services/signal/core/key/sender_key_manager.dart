import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../../sender_key_store.dart';

/// Manages Signal Protocol Sender Keys for Group Messaging
///
/// Core Operations:
/// - getGroupCipher() - Get cipher for group encryption/decryption (THE method!)
/// - shouldRotateSenderKey() - Check if key needs rotation (7+ days or 1000+ messages)
/// - clearGroupSenderKeys() - Remove all keys when leaving group
/// - removeSenderKey() - Remove specific member's key
///
/// 💡 Key Insights:
/// - Sender keys enable efficient group messaging (one encryption → many recipients)
/// - Unlike 1-to-1 sessions, group messages use shared sender keys
/// - GroupCipher is what you actually use - not SenderKeyRecord directly
/// - Keys are per-group, per-sender (each member has their own sender key)
/// - Rotation based on time (7 days) OR message count (1000 messages)
///
/// Usage:
/// ```dart
/// // Get cipher for encrypting group messages
/// final cipher = keyManager.getGroupCipher(
///   groupId: 'group123',
///   senderAddress: myAddress,
/// );
/// final encrypted = await cipher.encrypt(message);
///
/// // Check if rotation needed
/// if (await keyManager.shouldRotateSenderKey(...)) {
///   // Rotate and distribute new key
/// }
/// ```
///
/// This mixin expects the class to provide:
/// - `PermanentSenderKeyStore get senderKeyStore`
mixin SenderKeyManagerMixin {
  PermanentSenderKeyStore get senderKeyStore;

  // ============================================================================
  // Core Sender Key Operations
  // ============================================================================

  /// Get GroupCipher for encrypting/decrypting group messages
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
    return GroupCipher(senderKeyStore, senderKeyName);
  }

  /// Check if sender key needs rotation
  ///
  /// Returns true if:
  /// - Key is older than 7 days, OR
  /// - Key has been used for 1000+ messages
  ///
  /// When true, you should:
  /// 1. Generate new sender key
  /// 2. Distribute to all group members
  /// 3. Update rotation timestamp
  ///
  /// Call this periodically or after sending messages.
  Future<bool> shouldRotateSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      return await senderKeyStore.needsRotation(senderKeyName);
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error checking rotation: $e');
      return false;
    }
  }

  /// Check if sender key exists
  ///
  /// Use for:
  /// - Verifying group membership
  /// - Checking if key distribution is needed
  Future<bool> hasSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      return await senderKeyStore.containsSenderKey(senderKeyName);
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error checking key existence: $e');
      return false;
    }
  }

  // ============================================================================
  // Group Management
  // ============================================================================

  /// Clear all sender keys for a group
  ///
  /// Use when:
  /// - Leaving a group
  /// - Group is deleted
  /// - Starting fresh (re-establishing group)
  ///
  /// This removes all sender keys (from all members) for the group.
  Future<void> clearGroupSenderKeys(String groupId) async {
    try {
      await senderKeyStore.clearGroupSenderKeys(groupId);
      debugPrint('[SENDER_KEY_MANAGER] ✓ Cleared all keys for group $groupId');
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error clearing group keys: $e');
      rethrow;
    }
  }

  /// Remove sender key for specific member
  ///
  /// Use when:
  /// - Member leaves group
  /// - Member is removed/kicked
  /// - Member's device is untrusted
  ///
  /// Other members' keys remain intact.
  Future<void> removeSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      await senderKeyStore.removeSenderKey(senderKeyName);
      debugPrint(
        '[SENDER_KEY_MANAGER] ✓ Removed key for ${senderAddress.getName()}:${senderAddress.getDeviceId()} in group $groupId',
      );
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error removing sender key: $e');
      rethrow;
    }
  }

  /// Get list of all group IDs with sender keys
  ///
  /// Use for:
  /// - Diagnostics
  /// - Cleanup operations
  /// - Group membership audit
  Future<List<String>> getAllGroupIds() async {
    try {
      return await senderKeyStore.getAllGroupIds();
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error getting group IDs: $e');
      return [];
    }
  }

  // ============================================================================
  // Advanced Operations
  // ============================================================================

  /// Load sender key record (advanced use)
  ///
  /// ⚠️ Most code should use getGroupCipher() instead!
  ///
  /// Use only for:
  /// - Key distribution (sending key to new members)
  /// - Manual key inspection
  /// - Testing/debugging
  Future<SenderKeyRecord> loadSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      return await senderKeyStore.loadSenderKey(senderKeyName);
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error loading sender key: $e');
      rethrow;
    }
  }

  /// Store sender key record (advanced use)
  ///
  /// ⚠️ Usually handled automatically by GroupCipher!
  ///
  /// Use only for:
  /// - Receiving distributed key from group
  /// - Manual key restoration
  /// - Testing/debugging
  Future<void> storeSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
    required SenderKeyRecord record,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      await senderKeyStore.storeSenderKey(senderKeyName, record);
      debugPrint(
        '[SENDER_KEY_MANAGER] ✓ Stored key for ${senderAddress.getName()}:${senderAddress.getDeviceId()} in group $groupId',
      );
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error storing sender key: $e');
      rethrow;
    }
  }

  /// Update rotation timestamp after key rotation
  ///
  /// Call this after successfully distributing new sender key to group.
  /// Resets the 7-day rotation timer.
  Future<void> updateRotationTimestamp({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      await senderKeyStore.updateRotationTimestamp(senderKeyName);
      debugPrint(
        '[SENDER_KEY_MANAGER] ✓ Updated rotation timestamp for group $groupId',
      );
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error updating rotation timestamp: $e');
      rethrow;
    }
  }

  /// Delete all sender keys (dangerous!)
  ///
  /// ⚠️ Use ONLY for:
  /// - Account deletion
  /// - Complete app reset
  /// - Testing cleanup
  ///
  /// This removes ALL sender keys from ALL groups.
  /// You'll need to re-establish all group sessions.
  Future<void> deleteAllSenderKeys() async {
    try {
      await senderKeyStore.deleteAllSenderKeys();
      debugPrint('[SENDER_KEY_MANAGER] ✓ Deleted all sender keys');
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error deleting all sender keys: $e');
      rethrow;
    }
  }

  /// Validate sender key (diagnostics)
  ///
  /// Tests if key can encrypt successfully.
  /// Use for troubleshooting decryption failures.
  ///
  /// Returns true if key is valid and can encrypt.
  Future<bool> validateSenderKey({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final cipher = getGroupCipher(
        groupId: groupId,
        senderAddress: senderAddress,
      );

      // Test encryption with dummy data
      final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
      await cipher.encrypt(testMessage);

      debugPrint('[SENDER_KEY_MANAGER] ✓ Sender key validation passed');
      return true;
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] ⚠️ Sender key validation failed: $e');
      return false;
    }
  }

  // ============================================================================
  // Internal Tracking (automatic)
  // ============================================================================

  /// Increment message count for rotation tracking
  ///
  /// Called automatically after each message sent/received.
  /// Tracks toward 1000-message rotation threshold.
  ///
  /// ⚠️ Usually handled automatically - don't call manually!
  Future<void> incrementMessageCount({
    required String groupId,
    required SignalProtocolAddress senderAddress,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      await senderKeyStore.incrementMessageCount(senderKeyName);
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error incrementing message count: $e');
      // Non-critical - don't rethrow
    }
  }

  /// Load sender key for specific server (multi-server support)
  ///
  /// Use when connecting to multiple PeerWave servers.
  Future<SenderKeyRecord> loadSenderKeyForServer({
    required String groupId,
    required SignalProtocolAddress senderAddress,
    required String serverUrl,
  }) async {
    try {
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      return await senderKeyStore.loadSenderKeyForServer(
        senderKeyName,
        serverUrl,
      );
    } catch (e) {
      debugPrint('[SENDER_KEY_MANAGER] Error loading key for server: $e');
      rethrow;
    }
  }
}
