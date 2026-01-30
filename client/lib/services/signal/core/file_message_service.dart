import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../socket_service.dart';
import '../../storage/sqlite_message_store.dart';
import '../../sent_group_items_store.dart';

/// Service for handling file-related message operations via Signal Protocol
class FileMessageService {
  final Future<Map<String, dynamic>> Function(String channelId, String message)
  encryptGroupMessage;
  final Future<void> Function({
    required String recipientUserId,
    required String type,
    required String payload,
    String? itemId,
  })
  sendItem;
  final SentGroupItemsStore sentGroupItemsStore;
  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;

  FileMessageService({
    required this.encryptGroupMessage,
    required this.sendItem,
    required this.sentGroupItemsStore,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
  });

  Future<void> sendFileMessage({
    required String channelId,
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required String encryptedFileKey,
    String? message,
  }) async {
    try {
      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final itemId = const Uuid().v4();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Create file message payload
      final fileMessagePayload = {
        'fileId': fileId,
        'fileName': fileName,
        'mimeType': mimeType,
        'fileSize': fileSize,
        'checksum': checksum,
        'chunkCount': chunkCount,
        'encryptedFileKey': encryptedFileKey,
        'uploaderId': currentUserId,
        'timestamp': timestamp,
        if (message != null && message.isNotEmpty) 'message': message,
      };

      final payloadJson = jsonEncode(fileMessagePayload);

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, payloadJson);
      final timestampIso = DateTime.fromMillisecondsSinceEpoch(
        timestamp,
      ).toIso8601String();

      // Store locally first
      await sentGroupItemsStore.storeSentGroupItem(
        channelId: channelId,
        itemId: itemId,
        message: payloadJson,
        timestamp: timestampIso,
        type: 'file',
        status: 'sending',
      );

      // ALSO store in new SQLite database for performance
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.storeSentMessage(
          itemId: itemId,
          recipientId: channelId,
          channelId: channelId,
          message: payloadJson,
          timestamp: timestampIso,
          type: 'file',
        );
        debugPrint('[SIGNAL_SERVICE] Stored file message in SQLite');
      } catch (e) {
        debugPrint(
          '[SIGNAL_SERVICE] ✗ Failed to store file message in SQLite: $e',
        );
      }

      // Send via Socket.IO
      SocketService().emit("sendGroupItem", {
        'channelId': channelId,
        'itemId': itemId,
        'type': 'file',
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': timestampIso,
      });

      debugPrint(
        '[SIGNAL_SERVICE] Sent file message $itemId ($fileName) to channel $channelId',
      );
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending file message: $e');
      rethrow;
    }
  }

  /// Send P2P file share update via Signal Protocol (uses Sender Key for groups, Session for direct)
  Future<void> sendFileShareUpdate({
    required String chatId,
    required String chatType, // 'group' | 'direct'
    required String fileId,
    required String action, // 'add' | 'revoke'
    required List<String> affectedUserIds,
    String? checksum, // ← NEW: Canonical checksum for verification
    String? encryptedFileKey, // Only for 'add' action
  }) async {
    try {
      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Create share update payload
      final shareUpdatePayload = {
        'fileId': fileId,
        'action': action,
        'affectedUserIds': affectedUserIds,
        'senderId': currentUserId,
        'timestamp': timestamp,
        if (checksum != null) 'checksum': checksum, // ← NEW: Include checksum
        if (encryptedFileKey != null) 'encryptedFileKey': encryptedFileKey,
      };

      final payloadJson = jsonEncode(shareUpdatePayload);

      if (chatType == 'group') {
        // GROUP: Send via Sender Key
        final itemId = const Uuid().v4();
        final encrypted = await encryptGroupMessage(chatId, payloadJson);
        final timestampIso = DateTime.fromMillisecondsSinceEpoch(
          timestamp,
        ).toIso8601String();

        // Store locally
        await sentGroupItemsStore.storeSentGroupItem(
          channelId: chatId,
          itemId: itemId,
          message: payloadJson,
          timestamp: timestampIso,
          type: 'file_share_update',
          status: 'sending',
        );

        // Send via Socket.IO
        SocketService().emit("sendGroupItem", {
          'channelId': chatId,
          'itemId': itemId,
          'type': 'file_share_update',
          'payload': encrypted['ciphertext'],
          'cipherType': 4, // Sender Key
          'timestamp': timestampIso,
        });

        debugPrint(
          '[SIGNAL_SERVICE] Sent file share update ($action) to group $chatId',
        );
      } else if (chatType == 'direct') {
        // DIRECT: Send via Session encryption to each affected user
        for (final userId in affectedUserIds) {
          if (userId == currentUserId) continue; // Skip self

          // Use sendItem to encrypt for all devices
          await sendItem(
            recipientUserId: userId,
            type: 'file_share_update',
            payload: payloadJson,
          );

          debugPrint(
            '[SIGNAL_SERVICE] Sent file share update ($action) to user $userId',
          );
        }
      } else {
        throw Exception('Invalid chatType: $chatType');
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending file share update: $e');
      rethrow;
    }
  }

  /// Send video E2EE key via Signal Protocol (Sender Key for groups, Session for direct)
  Future<void> sendVideoKey({
    required String channelId,
    required String chatType, // 'group' | 'direct'
    required List<int> encryptedKey, // AES-256 key (32 bytes)
    required List<String> recipientUserIds, // Users in the video call
  }) async {
    try {
      final currentUserId = getCurrentUserId();
      final currentDeviceId = getCurrentDeviceId();

      if (currentUserId == null || currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Convert key to base64 for JSON transport
      final keyBase64 = base64Encode(encryptedKey);

      // Create video key payload
      final videoKeyPayload = {
        'channelId': channelId,
        'key': keyBase64,
        'senderId': currentUserId,
        'timestamp': timestamp,
        'type': 'video_e2ee_key',
      };

      final payloadJson = jsonEncode(videoKeyPayload);

      if (chatType == 'group') {
        // GROUP: Send via Sender Key
        final itemId = const Uuid().v4();
        final encrypted = await encryptGroupMessage(channelId, payloadJson);
        final timestampIso = DateTime.fromMillisecondsSinceEpoch(
          timestamp,
        ).toIso8601String();

        // Store locally
        await sentGroupItemsStore.storeSentGroupItem(
          channelId: channelId,
          itemId: itemId,
          message: payloadJson,
          timestamp: timestampIso,
          type: 'video_e2ee_key',
          status: 'sending',
        );

        // Send via Socket.IO
        SocketService().emit("sendGroupItem", {
          'channelId': channelId,
          'itemId': itemId,
          'type': 'video_e2ee_key',
          'payload': encrypted['ciphertext'],
          'cipherType': 4, // Sender Key
          'timestamp': timestampIso,
        });

        debugPrint('[SIGNAL_SERVICE] Sent video E2EE key to group $channelId');
      } else if (chatType == 'direct') {
        // DIRECT: Send via Session encryption to each recipient
        for (final userId in recipientUserIds) {
          if (userId == currentUserId) continue; // Skip self

          // Use sendItem to encrypt for all devices
          await sendItem(
            recipientUserId: userId,
            type: 'video_e2ee_key',
            payload: payloadJson,
          );

          debugPrint('[SIGNAL_SERVICE] Sent video E2EE key to user $userId');
        }
      } else {
        throw Exception('Invalid chatType: $chatType');
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending video E2EE key: $e');
      rethrow;
    }
  }
}
