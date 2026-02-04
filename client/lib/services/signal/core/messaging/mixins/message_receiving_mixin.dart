import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../../../socket_service.dart';
import '../../../../../core/events/event_bus.dart' as app_events;
import '../../../../user_profile_service.dart';
import '../../encryption_service.dart';
import '../../session_manager.dart';
import '../../healing_service.dart';
import '../../../callbacks/callback_manager.dart';

/// Mixin for receiving and decrypting messages
mixin MessageReceivingMixin {
  // Required getters from main service
  EncryptionService get encryptionService;
  SocketService get socketService;
  CallbackManager get callbackManager;
  SessionManager get sessionStore;
  SignalHealingService get healingService;
  String get currentUserId;
  int get currentDeviceId;

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
    int senderDeviceId, {
    Function(String)? onDecrypted,
  });

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
    debugPrint(
      '[RECEIVE] Message: $itemId from $sender:$senderDeviceId (receiver: $currentUserId)',
    );

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

      // ========================================================================
      // HEALING SERVICE INTEGRATION: Automatic session recovery
      // ========================================================================
      debugPrint('[RECEIVE] 🔧 Starting healing service recovery...');

      try {
        final address = SignalProtocolAddress(sender, senderDeviceId);

        // Step 1: Trigger proactive key verification
        debugPrint(
          '[RECEIVE] Step 1: Verifying our keys and identity with server...',
        );
        await healingService.triggerAsyncSelfVerification(
          reason: 'Decryption failure from $sender:$senderDeviceId',
          userId: currentUserId,
          deviceId: currentDeviceId,
        );

        // Step 2: Delete corrupted session
        debugPrint(
          '[RECEIVE] Step 2: Deleting corrupted session with $sender:$senderDeviceId',
        );
        await sessionStore.deleteSession(address);
        debugPrint('[RECEIVE] ✓ Corrupted session deleted');

        // Step 3: Rebuild session from fresh PreKeyBundle
        debugPrint('[RECEIVE] Step 3: Rebuilding session with $sender');
        final success = await sessionStore.establishSessionWithUser(sender);

        if (success) {
          debugPrint('[RECEIVE] ✅ Session successfully rebuilt');

          // Store a system message about the recovery
          await processDecryptedMessage(
            message:
                '🔒 Message could not be decrypted. Session has been automatically recovered.',
            dataMap: dataMap,
            type: 'system:session_reset',
            sender: sender,
            itemId: itemId,
          );
        } else {
          debugPrint('[RECEIVE] ⚠️ Session rebuild failed');

          // Store failure message
          await processDecryptedMessage(
            message:
                '❌ Message could not be decrypted. Session recovery failed. Please contact $sender.',
            dataMap: dataMap,
            type: 'system:session_reset',
            sender: sender,
            itemId: itemId,
          );
        }
      } catch (rebuildError) {
        debugPrint(
          '[RECEIVE] ✗ Healing service recovery failed: $rebuildError',
        );

        // Store error message
        await processDecryptedMessage(
          message:
              '❌ Message decryption and recovery failed: ${rebuildError.toString()}',
          dataMap: dataMap,
          type: 'system:session_reset',
          sender: sender,
          itemId: itemId,
        );
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
      final itemId = data['itemId'] as String?;

      // Pass callback to handle queued message processing
      return await decryptGroupMessage(
        data,
        sender,
        senderDeviceId,
        onDecrypted: (decryptedMessage) async {
          // Process the decrypted message from queue
          debugPrint('[RECEIVE] Processing queued message: $itemId');
          await processDecryptedMessage(
            message: decryptedMessage,
            dataMap: data,
            type: data['type'] as String? ?? 'message',
            sender: sender,
            itemId: itemId ?? 'unknown',
          );
        },
      );
    }

    // 1-to-1 message (session cipher) - use unified decryptMessage
    final payload = data['payload'] as String;

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

    // Check if this is own message (multi-device sync)
    final currentUserId = UserProfileService.instance.currentUserUuid;
    final isOwnMessage = (sender == currentUserId);

    // Get sender profile for UI (avoid stale cache lookups)
    final senderProfile = UserProfileService.instance.getProfile(sender);
    final displayName =
        senderProfile?['displayName']?.toString() ??
        UserProfileService.instance.getDisplayNameOrUuid(sender);
    final picture = senderProfile?['picture']?.toString() ?? '';
    final atName = senderProfile?['atName']?.toString() ?? '';

    // Emit event with complete message data for UI (including profile data)
    app_events.EventBus.instance.emit(app_events.AppEvent.newMessage, {
      'itemId': itemId,
      'senderId': sender,
      'message': message,
      'timestamp': dataMap['timestamp'] ?? DateTime.now().toIso8601String(),
      'type': type,
      'status': 'received',
      'direction': 'received',
      'sender': sender,
      'senderDeviceId': dataMap['senderDeviceId'],
      'channelId': dataMap['channel'],
      'metadata': dataMap['metadata'],
      'isOwnMessage': isOwnMessage,
      // Include profile data so UI doesn't need to query cache
      'displayName': displayName,
      'picture': picture,
      'atName': atName,
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
        type == 'call_notification' ||
        type == 'meeting_e2ee_key_request' ||
        type == 'meeting_e2ee_key_response' ||
        type == 'signal:senderKeyDistribution';
  }

  /// Handle system messages
  Future<void> handleSystemMessage(
    String type,
    String message,
    Map<String, dynamic> data,
  ) async {
    if (type == 'read_receipt') {
      debugPrint('[RECEIVE] Received read receipt');

      // Parse the read receipt payload
      try {
        final payload = message.isNotEmpty ? jsonDecode(message) : {};
        final itemId = payload['itemId'] as String?;
        final readByDeviceIdRaw = payload['readByDeviceId'];

        // Handle both String and int types for readByDeviceId
        int? readByDeviceId;
        if (readByDeviceIdRaw is int) {
          readByDeviceId = readByDeviceIdRaw;
        } else if (readByDeviceIdRaw is String) {
          readByDeviceId = int.tryParse(readByDeviceIdRaw);
        }

        if (itemId != null) {
          // Notify read receipt callbacks directly (not general message callbacks)
          final receiptInfo = {
            'itemId': itemId,
            'readByUserId': data['sender'] as String,
            'readByDeviceId': readByDeviceId,
            'timestamp': data['timestamp'] ?? DateTime.now().toIso8601String(),
          };

          callbackManager.delivery.notifyRead(receiptInfo);
          debugPrint('[RECEIVE] ✓ Read receipt notified for itemId: $itemId');
        }
      } catch (e) {
        debugPrint('[RECEIVE] Error parsing read receipt: $e');
      }
    } else if (type == 'signal:senderKeyDistribution') {
      debugPrint(
        '[RECEIVE] Sender key distribution from offline queue - will be handled by socket re-emission',
      );

      // Note: The sender key distribution was queued in Items table
      // The server will re-deliver it via socket when we come online
      // The 'receiveSenderKeyDistribution' socket listener will handle it
      // We just mark it as processed here to clear from queue
    }
  }

  /// Trigger registered callbacks
  Future<void> triggerCallbacks(
    String type,
    Map<String, dynamic> data,
    String message,
  ) async {
    // Emit EventBus events for system message types
    if (type == 'call_notification') {
      app_events.EventBus.instance.emit(app_events.AppEvent.incomingCall, {
        ...data,
        'decryptedMessage': message,
      });
    } else if (type == 'meeting_e2ee_key_request') {
      app_events.EventBus.instance.emit(app_events.AppEvent.meetingKeyRequest, {
        ...data,
        'decryptedMessage': message,
      });
    } else if (type == 'meeting_e2ee_key_response') {
      app_events.EventBus.instance.emit(
        app_events.AppEvent.meetingKeyResponse,
        {...data, 'decryptedMessage': message},
      );
    }

    // Legacy callback support (deprecated - use EventBus instead)
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
