import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../../socket_service.dart';
import '../../../../storage/sqlite_group_message_store.dart';
import '../../encryption_service.dart';
import '../../key_manager.dart';

/// Mixin for group messaging operations
mixin GroupMessagingMixin {
  // Required getters from main service
  EncryptionService get encryptionService;
  SocketService get socketService;
  String get currentUserId;
  int get currentDeviceId;

  SignalKeyManager get senderKeyStore;
  SqliteGroupMessageStore get groupMessageStore;

  /// Send encrypted group message using sender keys
  ///
  /// Handles:
  /// - Sender key creation and distribution
  /// - Group message encryption
  /// - Sender key rotation when needed
  /// - Local message storage
  Future<String> sendGroupMessage({
    required String channelId,
    required String message,
    String? itemId,
  }) async {
    final generatedItemId = itemId ?? const Uuid().v4();

    debugPrint('[GROUP] Sending message to $channelId');

    try {
      // Ensure sender key exists
      await ensureSenderKeyForGroup(channelId);

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);

      // Send to server
      final data = {
        'channelId': channelId,
        'itemId': generatedItemId,
        'message': encrypted['ciphertext'],
        'timestamp': DateTime.now().toIso8601String(),
        'type': 'message',
      };

      socketService.emit("sendGroupItem", data);

      // Store locally
      await groupMessageStore.storeSentGroupItem(
        itemId: generatedItemId,
        channelId: channelId,
        message: message,
        timestamp: data['timestamp'] as String,
        type: 'message',
      );

      debugPrint('[GROUP] ✓ Message sent: $generatedItemId');
      return generatedItemId;
    } catch (e, stackTrace) {
      debugPrint('[GROUP] ❌ Failed to send message: $e');
      debugPrint('[GROUP] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Ensure sender key exists for group
  Future<void> ensureSenderKeyForGroup(String groupId) async {
    final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
    final senderKeyName = SenderKeyName(groupId, myAddress);

    // Check if we have a sender key
    final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);

    if (!hasSenderKey) {
      debugPrint('[GROUP] Creating sender key for group $groupId');
      await createAndDistributeSenderKey(groupId);
    }
  }

  /// Create sender key and distribute to group
  Future<void> createAndDistributeSenderKey(String groupId) async {
    final myAddress = SignalProtocolAddress(currentUserId, currentDeviceId);
    final senderKeyName = SenderKeyName(groupId, myAddress);

    // Create sender key distribution message
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
    final distributionMessage = await groupSessionBuilder.create(senderKeyName);

    // Store locally
    await senderKeyStore.storeSenderKey(senderKeyName, SenderKeyRecord());

    // Upload to server
    final distributionBytes = distributionMessage.serialize();
    socketService.emit('storeSenderKey', {
      'groupId': groupId,
      'distributionMessage': base64Encode(distributionBytes),
    });

    // Broadcast to group members
    socketService.emit('broadcastSenderKey', {
      'groupId': groupId,
      'distributionMessage': base64Encode(distributionBytes),
    });

    debugPrint('[GROUP] ✓ Sender key created and distributed');
  }

  /// Process incoming sender key distribution
  Future<void> processSenderKeyDistribution(
    String groupId,
    String senderId,
    int senderDeviceId,
    Uint8List distributionMessageBytes,
  ) async {
    final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);

    final distributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
          distributionMessageBytes,
        );

    await groupSessionBuilder.process(senderKeyName, distributionMessage);

    debugPrint(
      '[GROUP] ✓ Processed sender key from $senderId:$senderDeviceId for group $groupId',
    );
  }

  /// Encrypt message for group using sender key
  Future<Map<String, dynamic>> encryptGroupMessage(
    String groupId,
    String message,
  ) async {
    final ciphertext = await encryptionService.encryptGroupMessage(
      groupId: groupId,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      message: message,
    );

    return {'ciphertext': ciphertext};
  }

  /// Decrypt group message using sender key
  Future<String> decryptGroupMessage(
    Map<String, dynamic> data,
    String sender,
    int senderDeviceId,
  ) async {
    final groupId = data['channel'] as String;
    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);

    // Check if we have sender key
    final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);

    if (!hasSenderKey) {
      debugPrint('[GROUP] Missing sender key - requesting from server');
      await requestSenderKey(groupId, sender, senderDeviceId);
      throw Exception('Sender key not available yet');
    }

    // Decrypt
    final encryptedData = data['message'] as String;
    final plaintext = await encryptionService.decryptGroupMessage(
      groupId: groupId,
      senderAddress: senderAddress,
      encryptedData: encryptedData,
    );

    return plaintext;
  }

  /// Request sender key from server
  Future<void> requestSenderKey(
    String groupId,
    String userId,
    int deviceId,
  ) async {
    socketService.emit('requestSenderKey', {
      'groupId': groupId,
      'userId': userId,
      'deviceId': deviceId,
    });
  }

  // ========================================================================
  // Additional methods for screen compatibility (match old SignalService API)
  // ========================================================================

  /// Check if sender key exists for a specific user/device in group
  Future<bool> hasSenderKey(
    String channelId,
    String userId,
    int deviceId,
  ) async {
    final senderAddress = SignalProtocolAddress(userId, deviceId);
    final senderKeyName = SenderKeyName(channelId, senderAddress);
    return await senderKeyStore.containsSenderKey(senderKeyName);
  }

  /// Send group item with any type (message, file, emote, etc.)
  Future<String> sendGroupItem({
    required String channelId,
    required String message,
    required String itemId,
    String type = 'message',
    Map<String, dynamic>? metadata,
  }) async {
    debugPrint('[GROUP] Sending $type to $channelId');

    try {
      // Ensure sender key exists
      await ensureSenderKeyForGroup(channelId);

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);

      // Send to server
      final data = {
        'channelId': channelId,
        'itemId': itemId,
        'type': type,
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': DateTime.now().toIso8601String(),
      };

      socketService.emit("sendGroupItem", data);

      // Store locally (only for displayable types)
      const displayableTypes = {'message', 'file', 'image', 'voice'};
      if (displayableTypes.contains(type)) {
        await groupMessageStore.storeSentGroupItem(
          itemId: itemId,
          channelId: channelId,
          message: message,
          timestamp: data['timestamp'] as String,
          type: type,
        );
      }

      debugPrint('[GROUP] ✓ $type sent: $itemId');
      return itemId;
    } catch (e, stackTrace) {
      debugPrint('[GROUP] ❌ Failed to send $type: $e');
      debugPrint('[GROUP] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Mark group item as read
  void markGroupItemAsRead(String itemId) {
    socketService.emit('markGroupItemAsRead', {'itemId': itemId});
    debugPrint('[GROUP] Marked item as read: $itemId');
  }
}
