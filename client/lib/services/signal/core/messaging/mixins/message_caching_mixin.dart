import 'package:flutter/foundation.dart';

import '../../../../storage/sqlite_message_store.dart';
import '../../../../storage/sqlite_group_message_store.dart';
import '../../../../storage/sqlite_recent_conversations_store.dart';

/// Mixin for message caching operations
mixin MessageCachingMixin {
  /// Get cached decrypted message
  Future<String?> getCachedMessage(String itemId) async {
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final cached = await messageStore.getMessage(itemId);
      return cached?['message'] as String?;
    } catch (e) {
      return null;
    }
  }

  /// Cache decrypted message for faster access
  Future<void> cacheDecryptedMessage({
    required String itemId,
    required String message,
    required Map<String, dynamic> data,
    required String sender,
    required int senderDeviceId,
  }) async {
    if (message.isEmpty) {
      return; // Don't cache empty messages
    }

    // Skip ephemeral/system messages (control messages that shouldn't be stored)
    final messageType = data['type'] as String? ?? 'message';
    const ephemeralTypes = {
      // E2EE key exchange
      'meeting_e2ee_key_request',
      'meeting_e2ee_key_response',
      'video_e2ee_key_request',
      'video_e2ee_key_response',
      // Signal Protocol control messages
      'read_receipt',
      'delivery_receipt',
      'senderKeyRequest',
      'fileKeyRequest',
      'signal:senderKeyDistribution',
      'system:session_reset',
      // Call signaling
      'call_notification',
    };

    if (ephemeralTypes.contains(messageType)) {
      debugPrint(
        '[CACHE] Skipping storage for ephemeral message type: $messageType',
      );
      return;
    }

    try {
      // Check if this is a group message
      final channelId = data['channel'] as String?;

      if (channelId != null) {
        // Store group message
        final groupMessageStore = await SqliteGroupMessageStore.getInstance();
        await groupMessageStore.storeDecryptedGroupItem(
          itemId: itemId,
          channelId: channelId,
          sender: sender,
          senderDevice: senderDeviceId,
          message: message,
          timestamp:
              data['timestamp'] as String? ?? DateTime.now().toIso8601String(),
          type: messageType,
        );
        debugPrint('[CACHE] ✓ Stored group message: $itemId');
      } else {
        // Store 1-to-1 message
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.storeReceivedMessage(
          itemId: itemId,
          sender: sender,
          message: message,
          timestamp:
              data['timestamp'] as String? ?? DateTime.now().toIso8601String(),
          type: messageType,
        );
        debugPrint('[CACHE] ✓ Stored 1-to-1 message: $itemId');
      }
    } catch (e) {
      debugPrint('[CACHE] Failed to cache message: $e');
    }
  }

  /// Update recent conversations
  Future<void> updateRecentConversations(String userId, String message) async {
    try {
      final store = await SqliteRecentConversationsStore.getInstance();
      await store.incrementUnreadCount(userId);
    } catch (e) {
      debugPrint('[CACHE] Failed to update recent conversations: $e');
    }
  }
}
