import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../socket_service.dart';
import '../core/group_message_receiver.dart';
import '../../../providers/unread_messages_provider.dart';
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
/// These listeners delegate processing to GroupMessageReceiver service.
class GroupListeners {
  static const String _registrationName = 'GroupListeners';
  static bool _registered = false;
  static UnreadMessagesProvider? _unreadMessagesProvider;
  static String? _currentUserId;

  /// Register all group message listeners
  static Future<void> register(
    GroupMessageReceiver receiver, {
    UnreadMessagesProvider? unreadMessagesProvider,
    String? currentUserId,
  }) async {
    if (_registered) {
      debugPrint('[GROUP_LISTENERS] Already registered');
      return;
    }

    _unreadMessagesProvider = unreadMessagesProvider;
    _currentUserId = currentUserId;

    final socket = SocketService();

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

        // Update unread count for group messages (ONLY for messages from OTHER users)
        if (_unreadMessagesProvider != null &&
            channel != null &&
            type != null &&
            !isOwnMessage) {
          // Check if this is an activity notification type
          const activityTypes = {
            'emote',
            'mention',
            'missingcall',
            'addtochannel',
            'removefromchannel',
            'permissionchange',
          };

          if (activityTypes.contains(type)) {
            // Activity notification - increment activity counter
            if (itemId != null) {
              _unreadMessagesProvider!.incrementActivityNotification(itemId);
              debugPrint(
                '[GROUP_LISTENERS] ✓ Activity notification: $type ($itemId)',
              );
            }
          } else {
            // Regular message - increment channel counter
            _unreadMessagesProvider!.incrementIfBadgeType(type, channel, true);
          }
        }

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
            EventBus.instance.emit(AppEvent.newMessage, dataMap);
          } else if (activityTypes.contains(type)) {
            debugPrint(
              '[GROUP_LISTENERS] → EVENT_BUS: newNotification (group) - type=$type, channel=$channel',
            );
            EventBus.instance.emit(AppEvent.newNotification, dataMap);
          }
        }

        // Handle emote messages (reactions)
        if (type == 'emote') {
          await receiver.handleReaction(dataMap);
        } else {
          // Regular group message - decrypt and process
          await receiver.receiveItemChannel(dataMap);
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
        await receiver.handleReadReceipt(data);
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
        final distributionMessageBase64 =
            dataMap['distributionMessage'] as String;

        debugPrint(
          '[GROUP_LISTENERS] Received sender key distribution from $senderId:$senderDeviceId for group $groupId',
        );

        final distributionMessageBytes = base64Decode(
          distributionMessageBase64,
        );
        await receiver.processSenderKeyDistribution(
          groupId,
          senderId,
          senderDeviceId,
          distributionMessageBytes,
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

    final socket = SocketService();
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

    _unreadMessagesProvider = null;
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
