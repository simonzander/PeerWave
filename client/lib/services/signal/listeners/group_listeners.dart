import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../core/messaging/messaging_service.dart';
import '../../event_bus.dart';

/// Socket.IO listeners for group encrypted messages
///
/// Handles:
/// - groupItem: Incoming encrypted group messages (main event)
/// - groupMessageReadReceipt: Group message read confirmations
/// - groupItemDelivered: Delivery confirmations
/// - groupItemReadUpdate: Read receipt updates
/// - receiveSenderKeyDistribution: SenderKey distribution messages
///
/// These listeners delegate processing to MessagingService.
class GroupListeners {
  static const String _registrationName = 'GroupListeners';
  static bool _registered = false;
  static String? _currentUserId;

  /// Register all group message listeners
  static Future<void> register(
    MessagingService messagingService, {
    String? currentUserId,
  }) async {
    if (_registered) {
      debugPrint('[GROUP_LISTENERS] Already registered');
      return;
    }

    _currentUserId = currentUserId;

    final socket = SocketService.instance;

    // Main group item event (replaces receiveItemChannel)
    socket.registerListener('groupItem', (data) async {
      try {
        final dataMap = Map<String, dynamic>.from(data as Map);
        final type = dataMap['type'] as String?;
        final channel = dataMap['channel'] as String?;
        final sender = dataMap['sender'] as String?;
        final itemId = dataMap['itemId'] as String?;
        final isOwnMessage = sender == _currentUserId;

        debugPrint(
          '[GROUP_LISTENERS] Received groupItem: type=$type, channel=$channel, itemId=$itemId',
        );

        final serverId = dataMap['serverId'] ?? dataMap['_serverId'];
        final eventData = Map<String, dynamic>.from(dataMap);
        if (serverId is String && serverId.isNotEmpty) {
          eventData['serverId'] = serverId;
        }
        eventData['channelId'] ??= channel;
        eventData['isOwnMessage'] = isOwnMessage;

        // Emit EventBus event for new group message/item
        if (type != null && channel != null && !isOwnMessage) {
          const activityTypes = {
            'emote',
            'mention',
            'missingcall',
            'addtochannel',
            'removefromchannel',
            'permissionchange',
          };

          // Only emit newMessage event for messages from OTHER users
          if ((type == 'message' || type == 'file')) {
            debugPrint(
              '[GROUP_LISTENERS] → EVENT_BUS: newMessage (group) - type=$type, channel=$channel',
            );
            EventBus.instance.emit(AppEvent.newMessage, eventData);
          } else if (activityTypes.contains(type)) {
            debugPrint(
              '[GROUP_LISTENERS] → EVENT_BUS: newNotification (group) - type=$type, channel=$channel',
            );
            EventBus.instance.emit(AppEvent.newNotification, eventData);
          }
        }

        // Handle emote messages (reactions)
        if (type == 'emote') {
          debugPrint('[GROUP_LISTENERS] Processing emote message');

          // Decrypt the emote message using the same process as regular messages
          final cipherType = dataMap['cipherType'] as int? ?? 3;
          await messagingService.receiveMessage(
            dataMap: dataMap,
            type: 'emote',
            sender: sender ?? '',
            senderDeviceId: dataMap['senderDevice'] as int? ?? 0,
            cipherType: cipherType,
            itemId: itemId ?? '',
          );
        } else if (type == 'sender_key_request' ||
            type == 'sender_key_response') {
          // Handle sender key request/response messages
          // These are special control messages for targeted sender key exchange
          debugPrint('[GROUP_LISTENERS] Processing $type from $sender');

          final cipherType = dataMap['cipherType'] as int? ?? 3;

          // Decrypt the message first
          try {
            await messagingService.receiveMessage(
              dataMap: dataMap,
              type:
                  type!, // We know type is not null from the conditional check
              sender: sender ?? '',
              senderDeviceId: dataMap['senderDevice'] as int? ?? 0,
              cipherType: cipherType,
              itemId: itemId ?? '',
            );
          } catch (e) {
            debugPrint('[GROUP_LISTENERS] Failed to decrypt $type: $e');
            // If decryption fails, we can't process the request
          }
        } else {
          // Regular group message - decrypt and process
          // Extract message details
          final cipherType =
              dataMap['cipherType'] as int? ?? 3; // Default to SENDERKEY
          await messagingService.receiveMessage(
            dataMap: dataMap,
            type: type ?? 'message',
            sender: sender ?? '',
            senderDeviceId: dataMap['senderDevice'] as int? ?? 0,
            cipherType: cipherType,
            itemId: itemId ?? '',
          );
        }
      } catch (e, stack) {
        debugPrint('[GROUP_LISTENERS] Error processing groupItem: $e');
        debugPrint('[GROUP_LISTENERS] Stack: $stack');
        _handleError('groupItem', e, stack);
      }
    }, registrationName: _registrationName);

    // Group message read receipt
    socket.registerListener('groupMessageReadReceipt', (data) async {
      try {
        final itemId = data['itemId'] as String;
        debugPrint('[GROUP_LISTENERS] Group read receipt for: $itemId');
        // TODO: Implement read receipt handling in MessagingService
        debugPrint(
          '[GROUP_LISTENERS] Read receipt handling not yet implemented',
        );
      } catch (e, stack) {
        debugPrint(
          '[GROUP_LISTENERS] Error processing groupMessageReadReceipt: $e',
        );
        debugPrint('[GROUP_LISTENERS] Stack: $stack');
        _handleError('groupMessageReadReceipt', e, stack);
      }
    }, registrationName: _registrationName);

    // Group item delivery confirmation
    socket.registerListener('groupItemDelivered', (data) async {
      try {
        final itemId = data['itemId'] as String?;
        debugPrint('[GROUP_LISTENERS] Group item delivered: $itemId');
        // Notify delivery callbacks if needed
        // TODO: Integrate with CallbackManager when needed
      } catch (e, stack) {
        debugPrint('[GROUP_LISTENERS] Error processing groupItemDelivered: $e');
        debugPrint('[GROUP_LISTENERS] Stack: $stack');
        _handleError('groupItemDelivered', e, stack);
      }
    }, registrationName: _registrationName);

    // Group item read update
    socket.registerListener('groupItemReadUpdate', (data) async {
      try {
        final itemId = data['itemId'] as String?;
        debugPrint('[GROUP_LISTENERS] Group item read update: $itemId');
        // Notify read callbacks if needed
        // TODO: Integrate with CallbackManager when needed
      } catch (e, stack) {
        debugPrint(
          '[GROUP_LISTENERS] Error processing groupItemReadUpdate: $e',
        );
        debugPrint('[GROUP_LISTENERS] Stack: $stack');
        _handleError('groupItemReadUpdate', e, stack);
      }
    }, registrationName: _registrationName);

    // SenderKey distribution message (broadcast from another group member)
    socket.registerListener('receiveSenderKeyDistribution', (data) async {
      try {
        final dataMap = Map<String, dynamic>.from(data as Map);
        final groupId = dataMap['groupId'] as String;
        final senderId = dataMap['senderId'] as String;
        // Parse senderDeviceId as int (socket might send String)
        final senderDeviceId = dataMap['senderDeviceId'] is int
            ? dataMap['senderDeviceId'] as int
            : int.parse(dataMap['senderDeviceId'].toString());
        final encryptedDistributionBase64 =
            dataMap['distributionMessage'] as String;
        final messageType = dataMap['messageType'] as int;

        debugPrint(
          '[GROUP_LISTENERS] Received sender key distribution from $senderId:$senderDeviceId for group $groupId (type: $messageType)',
        );

        final encryptedDistributionBytes = base64Decode(
          encryptedDistributionBase64,
        );
        await messagingService.processSenderKeyDistribution(
          groupId,
          senderId,
          senderDeviceId,
          encryptedDistributionBytes,
          messageType,
        );

        debugPrint('[GROUP_LISTENERS] ✓ Sender key distribution processed');
      } catch (e, stack) {
        debugPrint(
          '[GROUP_LISTENERS] Error processing receiveSenderKeyDistribution: $e',
        );
        debugPrint('[GROUP_LISTENERS] Stack: $stack');
        _handleError('receiveSenderKeyDistribution', e, stack);
      }
    }, registrationName: _registrationName);

    _registered = true;
    debugPrint('[GROUP_LISTENERS] ✓ Registered 5 listeners');
  }

  /// Unregister all group message listeners
  static Future<void> unregister() async {
    if (!_registered) return;

    final socket = SocketService.instance;
    socket.unregisterListener('groupItem', registrationName: _registrationName);
    socket.unregisterListener(
      'groupMessageReadReceipt',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'groupItemDelivered',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'groupItemReadUpdate',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'receiveSenderKeyDistribution',
      registrationName: _registrationName,
    );

    _currentUserId = null;

    _registered = false;
    debugPrint('[GROUP_LISTENERS] ✓ Unregistered');
  }

  /// Handle listener errors
  static void _handleError(String listener, dynamic error, StackTrace stack) {
    // TODO: Integrate with ErrorHandler when implemented
    debugPrint('[GROUP_LISTENERS] ✗ Error in $listener: $error');
  }
}
