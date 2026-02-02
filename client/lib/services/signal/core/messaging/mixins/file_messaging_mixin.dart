import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Mixin for file messaging operations
mixin FileMessagingMixin {
  // Required getters from main service
  String get currentUserId;

  // Required methods from other mixins
  Future<String> send1to1Message({
    required String recipientUserId,
    required String type,
    required String payload,
    String? itemId,
  });

  Future<String> sendGroupMessage({
    required String channelId,
    required String message,
    String? itemId,
  });

  /// Send file message (1-to-1 or group)
  ///
  /// Creates file metadata payload and sends via appropriate channel
  Future<String> sendFileMessage({
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required String encryptedFileKey,
    String? recipientUserId, // For 1-to-1
    String? channelId, // For group
    String? message,
    String? itemId,
  }) async {
    if (recipientUserId == null && channelId == null) {
      throw ArgumentError(
        'Either recipientUserId or channelId must be provided',
      );
    }

    if (recipientUserId != null && channelId != null) {
      throw ArgumentError('Cannot specify both recipientUserId and channelId');
    }

    final generatedItemId = itemId ?? const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Create file message payload
    final filePayload = {
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

    final payloadJson = jsonEncode(filePayload);

    // Send as 1-to-1 or group message
    if (recipientUserId != null) {
      debugPrint('[FILE] Sending 1-to-1 file to $recipientUserId');
      return await send1to1Message(
        recipientUserId: recipientUserId,
        type: 'file',
        payload: payloadJson,
        itemId: generatedItemId,
      );
    } else {
      debugPrint('[FILE] Sending group file to $channelId');
      return await sendGroupMessage(
        channelId: channelId!,
        message: payloadJson,
        itemId: generatedItemId,
      );
    }
  }
}
