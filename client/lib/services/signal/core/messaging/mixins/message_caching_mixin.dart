import 'package:flutter/foundation.dart';

import '../../../../storage/sqlite_message_store.dart';
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
    if (message.isEmpty || data['channel'] != null) {
      return; // Don't cache empty or group messages
    }

    try {
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.storeReceivedMessage(
        itemId: itemId,
        sender: sender,
        message: message,
        timestamp:
            data['timestamp'] as String? ?? DateTime.now().toIso8601String(),
        type: data['type'] as String? ?? 'message',
      );
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
