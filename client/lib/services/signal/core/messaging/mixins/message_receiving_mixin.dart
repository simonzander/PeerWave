import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../../socket_service.dart';
import '../../../../../core/events/event_bus.dart' as app_events;
import '../../encryption_service.dart';
import '../../session_manager.dart';
import '../../../callbacks/callback_manager.dart';

/// Mixin for receiving and decrypting messages
mixin MessageReceivingMixin {
  // Required getters from main service
  EncryptionService get encryptionService;
  SocketService get socketService;
  CallbackManager get callbackManager;
  SessionManager get sessionStore;

  // Required methods from other mixins
  Future<String?> getCachedMessage(String itemId);
  Future<void> cacheDecryptedMessage({
    required String itemId,
    required String message,
    required Map<String, dynamic> data,
    required String sender,
    required int senderDeviceId,
  });
  Future<String> decryptGroupMessage(
    Map<String, dynamic> data,
    String sender,
    int senderDeviceId,
  );

  /// Process incoming message (1-to-1 or group)
  ///
  /// Handles:
  /// - Message decryption (PreKey, Whisper, or SenderKey)
  /// - Cache checking
  /// - Session recovery on errors
  /// - Message processing and callbacks
  /// - Server deletion after processing
  Future<void> receiveMessage({
    required Map<String, dynamic> dataMap,
    required String type,
    required String sender,
    required int senderDeviceId,
    required int cipherType,
    required String itemId,
  }) async {
    debugPrint('[RECEIVE] Message: $itemId from $sender:$senderDeviceId');

    // PHASE 1: Check cache
    final cached = await getCachedMessage(itemId);
    if (cached != null) {
      debugPrint('[RECEIVE] Using cached message');
      await processDecryptedMessage(
        message: cached,
        dataMap: dataMap,
        type: type,
        sender: sender,
        itemId: itemId,
      );
      deleteItemFromServer(itemId);
      return;
    }

    // PHASE 2: Decrypt message
    String message;
    try {
      message = await decryptMessage(
        dataMap,
        sender,
        senderDeviceId,
        cipherType,
      );
      deleteItemFromServer(itemId);
      debugPrint('[RECEIVE] ✓ Message decrypted: $itemId');
    } catch (e) {
      debugPrint('[RECEIVE] ✗ Decryption error: $e');

      if (e.toString().contains('DuplicateMessageException')) {
        debugPrint('[RECEIVE] Duplicate message - already processed');
        deleteItemFromServer(itemId);
        return;
      }

      // Handle session corruption - delete and rebuild
      try {
        debugPrint(
          '[RECEIVE] Session corrupted, deleting session with $sender:$senderDeviceId',
        );
        final address = SignalProtocolAddress(sender, senderDeviceId);
        await sessionStore.deleteSession(address);

        // Attempt to rebuild session
        debugPrint('[RECEIVE] Rebuilding session with $sender');
        await sessionStore.establishSessionWithUser(sender);

        // Store a system message about the failure
        await processDecryptedMessage(
          message: '🔒 Message could not be decrypted. Session has been reset.',
          dataMap: dataMap,
          type: 'system:session_reset',
          sender: sender,
          itemId: itemId,
        );
      } catch (rebuildError) {
        debugPrint('[RECEIVE] Failed to rebuild session: $rebuildError');
      }

      // Notify UI of failure
      notifyDecryptionFailure(
        SignalProtocolAddress(sender, senderDeviceId),
        reason: e.toString(),
        itemId: itemId,
      );

      deleteItemFromServer(itemId);
      return;
    }

    if (message.isEmpty) {
      debugPrint('[RECEIVE] Empty message after decryption - skipping');
      return;
    }

    // PHASE 3: Cache the decrypted message
    await cacheDecryptedMessage(
      itemId: itemId,
      message: message,
      data: dataMap,
      sender: sender,
      senderDeviceId: senderDeviceId,
    );

    // PHASE 4: Process message
    await processDecryptedMessage(
      message: message,
      dataMap: dataMap,
      type: type,
      sender: sender,
      itemId: itemId,
    );
  }

  /// Decrypt message (1-to-1 or group)
  Future<String> decryptMessage(
    Map<String, dynamic> data,
    String sender,
    int senderDeviceId,
    int cipherType,
  ) async {
    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);

    // Group message (sender key)
    if (data['channel'] != null) {
      return await decryptGroupMessage(data, sender, senderDeviceId);
    }

    // 1-to-1 message (session cipher) - use unified decryptMessage
    final payload = data['message'] as String;

    return await encryptionService.decryptMessage(
      senderAddress: senderAddress,
      payload: payload,
      cipherType: cipherType,
    );
  }

  /// Process decrypted message - callbacks and events
  Future<void> processDecryptedMessage({
    required String message,
    required Map<String, dynamic> dataMap,
    required String type,
    required String sender,
    required String itemId,
  }) async {
    // Skip certain system messages
    if (isSystemMessage(type)) {
      await handleSystemMessage(type, message, dataMap);
      return;
    }

    // Emit event
    app_events.EventBus.instance.emit(app_events.AppEvent.newMessage, {
      'senderId': sender,
      'message': message,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // Trigger callbacks
    await triggerCallbacks(type, dataMap, message);
  }

  /// Check if message is a system message
  bool isSystemMessage(String type) {
    return type == 'read_receipt' ||
        type == 'delivery_receipt' ||
        type == 'senderKeyRequest' ||
        type == 'fileKeyRequest' ||
        type == 'call_notification';
  }

  /// Handle system messages
  Future<void> handleSystemMessage(
    String type,
    String message,
    Map<String, dynamic> data,
  ) async {
    if (type == 'read_receipt') {
      debugPrint('[RECEIVE] Received read receipt');
    }
  }

  /// Trigger registered callbacks
  Future<void> triggerCallbacks(
    String type,
    Map<String, dynamic> data,
    String message,
  ) async {
    // Notify via CallbackManager
    final sender = data['sender'] as String?;
    final channelId = data['channel'] as String?;

    final notificationData = {...data, 'decryptedMessage': message};

    if (channelId != null) {
      // Group message
      callbackManager.notifyGroupMessageReceived(
        type,
        channelId,
        notificationData,
      );
    } else if (sender != null) {
      // 1:1 message
      callbackManager.notifyMessageReceived(type, sender, notificationData);
    }

    // Also trigger type-specific callbacks (any sender)
    // This is for system messages like call_notification
    callbackManager.messages.notifyTypeReceive(type, notificationData);
  }

  /// Delete item from server after processing
  void deleteItemFromServer(String itemId) {
    socketService.emit("deleteItem", {'itemId': itemId});
  }

  /// Notify UI of decryption failure
  void notifyDecryptionFailure(
    SignalProtocolAddress address, {
    required String reason,
    required String itemId,
  }) {
    debugPrint(
      '[RECEIVE] Decryption failed for ${address.getName()}:${address.getDeviceId()}',
    );
    // Note: Could emit a custom event here if needed
    // For now, just log the failure
  }
}
