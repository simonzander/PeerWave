import 'package:flutter/foundation.dart';
import '../../storage/sqlite_message_store.dart';
import '../../storage/sqlite_recent_conversations_store.dart';
import '../../user_profile_service.dart';

/// MessageCacheService
///
/// Handles caching of decrypted messages to SQLite database.
/// Manages conversation updates, unread counts, and profile loading.
///
/// Responsibilities:
/// - Cache decrypted 1:1 messages in SQLite (prevent re-decryption)
/// - Update recent conversations list
/// - Increment unread counts for received messages
/// - Load sender profiles for new messages
/// - Handle multi-device sync message storage
/// - Store failed decryptions with proper status
///
/// This service is extracted from SignalService to separate concerns.
class MessageCacheService {
  final String? _currentUserId;

  MessageCacheService({required String? currentUserId})
    : _currentUserId = currentUserId;

  /// Check if message is already cached (returns cached message if found)
  Future<String?> getCachedMessage(String itemId) async {
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final cached = await messageStore.getMessage(itemId);
      if (cached != null) {
        debugPrint(
          "[MESSAGE_CACHE] ✓ Using cached decrypted message from SQLite for itemId: $itemId",
        );
        return cached['message'] as String;
      }
      debugPrint(
        "[MESSAGE_CACHE] Cache miss for itemId: $itemId - will decrypt",
      );
      return null;
    } catch (e) {
      debugPrint("[MESSAGE_CACHE] ⚠️ Error checking cache: $e");
      return null;
    }
  }

  /// Cache a successfully decrypted message
  ///
  /// Parameters:
  /// - itemId: Unique message identifier
  /// - message: Decrypted plaintext message
  /// - data: Original message data containing metadata
  /// - sender: User ID of the sender
  /// - senderDeviceId: Device ID of the sender
  Future<void> cacheDecryptedMessage({
    required String itemId,
    required String message,
    required Map<String, dynamic> data,
    required String sender,
    required int senderDeviceId,
  }) async {
    if (message.isEmpty) {
      debugPrint("[MESSAGE_CACHE] Skipping cache for empty message");
      return;
    }

    // Don't cache group messages (they have channelId)
    if (data['channel'] != null) {
      debugPrint(
        "[MESSAGE_CACHE] ⚠ Skipping cache for group message (use DecryptedGroupItemsStore)",
      );
      return;
    }

    final messageType = data['type'] as String?;

    // Check if this is a session_reset with recovery reason (should be stored)
    bool isRecoverySessionReset = false;
    if (messageType == 'system:session_reset') {
      try {
        // Parse the message to check recovery reason
        // This is already decrypted plaintext, not JSON encoded
        if (message.contains('bad_mac_recovery') ||
            message.contains('no_session_recovery')) {
          isRecoverySessionReset = true;
        }
      } catch (e) {
        // If can't parse, treat as normal system message
      }
    }

    // Check if this is a system message that shouldn't be cached
    final isSystemMessage =
        messageType == 'read_receipt' ||
        messageType == 'delivery_receipt' ||
        messageType == 'senderKeyRequest' ||
        messageType == 'fileKeyRequest' ||
        messageType == 'call_notification' ||
        (messageType == 'system:session_reset' && !isRecoverySessionReset);

    if (isSystemMessage) {
      debugPrint(
        "[MESSAGE_CACHE] ⚠ Skipping cache for system message type: $messageType",
      );
      return;
    }

    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final messageTimestamp =
          data['timestamp'] ??
          data['createdAt'] ??
          DateTime.now().toIso8601String();

      // Check if message is from own user (multi-device sync)
      final isOwnMessage = sender == _currentUserId;
      final recipient = data['recipient'] as String?;
      final originalRecipient = data['originalRecipient'] as String?;

      String actualRecipient;

      if (isOwnMessage) {
        // Message from own device → Store as SENT message
        final isMultiDeviceSync = (recipient == _currentUserId);

        if (isMultiDeviceSync && originalRecipient == null) {
          debugPrint(
            '[MESSAGE_CACHE] ❌ Multi-device sync message missing originalRecipient during storage',
          );
          throw Exception(
            'Cannot store sync message: originalRecipient required but missing',
          );
        }

        actualRecipient = isMultiDeviceSync
            ? originalRecipient!
            : (recipient ?? _currentUserId ?? 'UNKNOWN');

        // Validate actualRecipient
        if (actualRecipient == _currentUserId || actualRecipient == 'UNKNOWN') {
          debugPrint(
            '[MESSAGE_CACHE] ⚠️ Warning: Attempting to store message to self (recipient=$actualRecipient)',
          );
        }

        debugPrint(
          "[MESSAGE_CACHE] 📤 Storing message from own device (Device $senderDeviceId) as SENT to $actualRecipient",
        );

        await messageStore.storeSentMessage(
          itemId: itemId,
          recipientId: actualRecipient,
          message: message,
          timestamp: messageTimestamp,
          type: messageType ?? 'message',
          status: 'delivered', // Already delivered (we received it!)
        );
      } else {
        // Message from another user → Store as RECEIVED message
        if (recipient == null) {
          debugPrint(
            '[MESSAGE_CACHE] ❌ Received message missing recipient field',
          );
          throw Exception(
            'Cannot store received message: recipient field missing',
          );
        }
        actualRecipient = recipient;

        debugPrint(
          "[MESSAGE_CACHE] 📥 Storing message from other user ($sender) as RECEIVED",
        );

        await messageStore.storeReceivedMessage(
          itemId: itemId,
          sender: sender,
          senderDeviceId: senderDeviceId,
          message: message,
          timestamp: messageTimestamp,
          type: messageType ?? 'message',
        );
      }

      // Update recent conversations list
      final conversationsStore =
          await SqliteRecentConversationsStore.getInstance();
      final conversationUserId = isOwnMessage ? actualRecipient : sender;

      await conversationsStore.addOrUpdateConversation(
        userId: conversationUserId,
        displayName: conversationUserId, // Will be enriched by UI layer
      );

      // Only increment unread count for messages from OTHER users
      if (!isOwnMessage) {
        await conversationsStore.incrementUnreadCount(sender);
      }

      debugPrint(
        "[MESSAGE_CACHE] ✓ Cached decrypted 1:1 message in SQLite for itemId: $itemId (direction: ${isOwnMessage ? 'sent' : 'received'})",
      );

      // Load sender's profile if not already cached
      await _loadSenderProfile(sender);
    } catch (e) {
      debugPrint("[MESSAGE_CACHE] ✗ Failed to cache in SQLite: $e");
      rethrow;
    }
  }

  /// Cache a failed decryption attempt
  Future<void> cacheFailedDecryption({
    required String itemId,
    required Map<String, dynamic> data,
    required String sender,
    required int senderDeviceId,
  }) async {
    // Don't cache failed group message decryptions
    if (data['channel'] != null) {
      return;
    }

    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final messageTimestamp =
          data['timestamp'] ??
          data['createdAt'] ??
          DateTime.now().toIso8601String();
      final messageType = data['type'] as String?;

      // Check if this is from own device (multi-device sync)
      final isOwnMessage = sender == _currentUserId;
      final recipient = data['recipient'] as String?;
      final originalRecipient = data['originalRecipient'] as String?;

      if (isOwnMessage) {
        // Failed to decrypt message from own device
        final isMultiDeviceSync = (recipient == _currentUserId);
        final actualRecipient = isMultiDeviceSync
            ? (originalRecipient ?? recipient ?? 'UNKNOWN')
            : (recipient ?? 'UNKNOWN');

        await messageStore.storeSentMessage(
          itemId: itemId,
          recipientId: actualRecipient,
          message: 'Decryption failed',
          timestamp: messageTimestamp,
          type: messageType ?? 'message',
          status: 'decrypt_failed',
        );
        debugPrint(
          "[MESSAGE_CACHE] ✓ Stored failed decryption as SENT with decrypt_failed status",
        );
      } else {
        // Failed to decrypt message from another user
        await messageStore.storeReceivedMessage(
          itemId: itemId,
          sender: sender,
          senderDeviceId: senderDeviceId,
          message: 'Decryption failed',
          timestamp: messageTimestamp,
          type: messageType ?? 'message',
          status: 'decrypt_failed',
        );
        debugPrint(
          "[MESSAGE_CACHE] ✓ Stored failed decryption as RECEIVED with decrypt_failed status",
        );
      }
    } catch (storageError) {
      debugPrint(
        "[MESSAGE_CACHE] ✗ Failed to store decrypt_failed message: $storageError",
      );
    }
  }

  /// Load sender profile if not already cached
  Future<void> _loadSenderProfile(String senderId) async {
    try {
      final profileService = UserProfileService.instance;
      if (!profileService.isProfileCached(senderId)) {
        debugPrint("[MESSAGE_CACHE] Loading profile for sender: $senderId");
        await profileService.loadProfiles([senderId]);
        debugPrint("[MESSAGE_CACHE] ✓ Sender profile loaded");
      }
    } catch (e) {
      debugPrint(
        "[MESSAGE_CACHE] ⚠ Failed to load sender profile (server may be unavailable): $e",
      );
      // Don't block message processing if profile loading fails
    }
  }
}
