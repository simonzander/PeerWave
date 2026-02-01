import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../core/events/event_bus.dart';
import '../../socket_service.dart';

/// Incoming Message Processor
///
/// Handles processing of incoming encrypted messages including:
/// - Message decryption coordination
/// - Multi-device sync validation
/// - System message handling (call notifications, read receipts, etc.)
/// - Event emission to EventBus
/// - Callback triggering for UI updates
///
/// This service coordinates the full message receive flow after decryption.
class IncomingMessageProcessor {
  final Future<String> Function(Map<String, dynamic> data) decryptMessage;
  final Future<void> Function(Map<String, dynamic> item) handleReadReceipt;
  final void Function(Map<String, dynamic> item, {required bool isGroupChat})
  handleEmoteMessage;
  final void Function(
    SignalProtocolAddress address, {
    required String reason,
    required String itemId,
  })
  notifyDecryptionFailure;
  final Map<String, List<Function(Map<String, dynamic>)>> receiveItemCallbacks;
  final Map<String, List<Function(dynamic)>> itemTypeCallbacks;
  final String? Function() getCurrentUserId;

  IncomingMessageProcessor({
    required this.decryptMessage,
    required this.handleReadReceipt,
    required this.handleEmoteMessage,
    required this.notifyDecryptionFailure,
    required this.receiveItemCallbacks,
    required this.itemTypeCallbacks,
    required this.getCurrentUserId,
  });

  /// Process incoming message with full orchestration
  Future<void> processMessage({
    required Map<String, dynamic> dataMap,
    required dynamic type,
    required dynamic sender,
    required dynamic senderDeviceId,
    required dynamic cipherType,
    required String itemId,
  }) async {
    final currentUserId = getCurrentUserId();

    // PHASE 1: Decrypt message
    String message;
    try {
      message = await decryptMessage(dataMap);

      // Delete from server AFTER successful decryption
      _deleteItemFromServer(itemId);
      debugPrint(
        "[INCOMING_PROCESSOR] ✓ Message decrypted and deleted from server: $itemId",
      );
    } catch (e) {
      debugPrint("[INCOMING_PROCESSOR] ✗ Decryption error: $e");

      // If it's a DuplicateMessageException, the message was already processed
      if (e.toString().contains('DuplicateMessageException')) {
        debugPrint(
          "[INCOMING_PROCESSOR] ⚠️ Duplicate message detected (already processed)",
        );
        // Still delete from server to clean up
        _deleteItemFromServer(itemId);
        return;
      }

      // For other errors, notify UI and attempt recovery
      notifyDecryptionFailure(
        SignalProtocolAddress(sender, senderDeviceId),
        reason: e.toString(),
        itemId: itemId,
      );

      debugPrint(
        "[INCOMING_PROCESSOR] ⚠️ Decryption failed - deleting from server to prevent stuck message",
      );
      _deleteItemFromServer(itemId);

      // Set message to 'Decryption failed' to continue processing and show user
      message = 'Decryption failed';
    }

    // Check if decryption failed
    if (message.isEmpty) {
      debugPrint(
        "[INCOMING_PROCESSOR] Skipping message - decryption returned empty",
      );
      return;
    }

    debugPrint(
      "[INCOMING_PROCESSOR] Message decrypted successfully: '$message' (cipherType: $cipherType)",
    );

    // PHASE 2: Validate multi-device sync
    final recipient = dataMap['recipient'];
    final originalRecipient = dataMap['originalRecipient'];

    final isMultiDeviceSync =
        (sender == currentUserId && recipient == currentUserId);

    if (isMultiDeviceSync && originalRecipient == null) {
      debugPrint(
        '[INCOMING_PROCESSOR] ❌ CRITICAL: Multi-device sync message missing originalRecipient!',
      );
      throw Exception(
        'Protocol violation: Multi-device sync message missing originalRecipient field',
      );
    }

    // Determine actual recipient (conversation context)
    final actualRecipient = isMultiDeviceSync ? originalRecipient! : recipient;

    if (actualRecipient == null) {
      debugPrint('[INCOMING_PROCESSOR] ❌ CRITICAL: Message has no recipient!');
      throw Exception('Protocol violation: Message missing recipient field');
    }

    // Calculate message direction and conversation context
    final isOwnMessage = sender == currentUserId;
    final conversationWith = isOwnMessage ? actualRecipient : sender;

    final item = {
      'itemId': itemId,
      'sender': sender,
      'senderDeviceId': senderDeviceId,
      'recipient': actualRecipient,
      'conversationWith': conversationWith,
      'type': type,
      'message': message,
      'isOwnMessage': isOwnMessage,
      if (originalRecipient != null) 'originalRecipient': originalRecipient,
    };

    if (originalRecipient != null) {
      debugPrint(
        "[INCOMING_PROCESSOR] Multi-device sync message - original recipient: $originalRecipient",
      );
    }

    // PHASE 3: Handle system messages
    bool isSystemMessage = false;

    // Handle call notifications
    if (type == 'call_notification') {
      debugPrint(
        '[INCOMING_PROCESSOR] Received call_notification - triggering callbacks',
      );

      if (itemTypeCallbacks.containsKey(type)) {
        final callbackItem = {
          'type': type,
          'payload': message,
          'sender': sender,
          'itemId': itemId,
        };

        for (final callback in itemTypeCallbacks[type]!) {
          try {
            callback(callbackItem);
          } catch (e) {
            debugPrint(
              '[INCOMING_PROCESSOR] Error in call_notification callback: $e',
            );
          }
        }
      }

      isSystemMessage = true;
    }
    // Handle read receipts
    else if (type == 'read_receipt') {
      debugPrint(
        '[INCOMING_PROCESSOR] Detected read_receipt type, calling handler',
      );
      await handleReadReceipt(item);
      isSystemMessage = true;
    }

    // PHASE 4: Emit EventBus events for regular messages
    if (!isSystemMessage) {
      // Check if this is an activity notification type
      final activityTypes = [
        'meeting:e2ee:key:request',
        'meeting:e2ee:key:response',
      ];

      if (activityTypes.contains(type)) {
        debugPrint(
          '[INCOMING_PROCESSOR] Activity notification type: $type - incrementing badge',
        );
      } else if (!activityTypes.contains(type)) {
        debugPrint(
          '[INCOMING_PROCESSOR] → EVENT_BUS: newMessage (1:1) - type=$type, sender=$sender, isOwnMessage=$isOwnMessage',
        );

        // Add isOwnMessage flag to item for UI
        final enrichedItem = {...item, 'isOwnMessage': isOwnMessage};

        EventBus.instance.emit(AppEvent.newMessage, enrichedItem);

        // Handle emote messages (reactions) for DMs
        if (type == 'emote') {
          handleEmoteMessage(item, isGroupChat: false);
        }

        // Emit newConversation event
        EventBus.instance.emit(AppEvent.newConversation, {
          'conversationId': conversationWith,
          'isChannel': false,
          'isOwnMessage': isOwnMessage,
        });
      }
    }

    // System messages are processed and done
    if (isSystemMessage) {
      debugPrint(
        "[INCOMING_PROCESSOR] ✓ System message processed: type=$type, itemId=$itemId",
      );
      return;
    }

    // PHASE 5: Handle session_reset recovery messages
    if (type == 'system:session_reset') {
      debugPrint(
        '[INCOMING_PROCESSOR] → EVENT_BUS: newMessage (session_reset) - sender=$sender',
      );

      EventBus.instance.emit(AppEvent.newMessage, {
        ...item,
        'isOwnMessage': isOwnMessage,
      });

      EventBus.instance.emit(AppEvent.newConversation, {
        'conversationId': conversationWith,
        'isChannel': false,
        'isOwnMessage': isOwnMessage,
      });
    }

    // PHASE 6: Trigger type-based callbacks
    if (cipherType != CiphertextMessage.whisperType &&
        itemTypeCallbacks.containsKey(cipherType)) {
      for (final callback in itemTypeCallbacks[cipherType]!) {
        callback(message);
      }
    }

    if (type != null && itemTypeCallbacks.containsKey(type)) {
      for (final callback in itemTypeCallbacks[type]!) {
        callback(item);
      }
    }

    // PHASE 7: Trigger specific receiveItem callbacks (type:conversationWith)
    if (type != null && conversationWith != null) {
      final key = '$type:$conversationWith';
      if (receiveItemCallbacks.containsKey(key)) {
        for (final callback in receiveItemCallbacks[key]!) {
          callback(item);
        }
        debugPrint(
          '[INCOMING_PROCESSOR] Triggered ${receiveItemCallbacks[key]!.length} receiveItem callbacks for $key',
        );
      }
    }

    debugPrint(
      "[INCOMING_PROCESSOR] ✓ Message processing complete for itemId: $itemId",
    );
  }

  /// Delete item from server
  void _deleteItemFromServer(String itemId) {
    debugPrint("[INCOMING_PROCESSOR] Deleting item with itemId: $itemId");
    SocketService.instance.emit("deleteItem", <String, dynamic>{
      'itemId': itemId,
    });
  }
}
