import 'package:flutter/foundation.dart';
import 'socket_service.dart';
import 'signal_service.dart';

/// Global service that listens for all incoming messages (1:1 and group)
/// and stores them in local storage, regardless of which screen is open.
/// Also triggers notification callbacks for UI updates.
class MessageListenerService {
  static final MessageListenerService _instance = MessageListenerService._internal();
  static MessageListenerService get instance => _instance;
  
  MessageListenerService._internal();

  bool _isInitialized = false;
  final List<Function(MessageNotification)> _notificationCallbacks = [];

  /// Initialize global message listeners
  Future<void> initialize() async {
    if (_isInitialized) {
      print('[MESSAGE_LISTENER] Already initialized');
      return;
    }

    print('[MESSAGE_LISTENER] Initializing global message listeners...');

    // Listen for 1:1 messages
    SocketService().registerListener('receiveItem', _handleDirectMessage);

    // Listen for group messages
    SocketService().registerListener('groupItem', _handleGroupMessage);

    // Listen for delivery receipts
    SocketService().registerListener('deliveryReceipt', _handleDeliveryReceipt);
    SocketService().registerListener('groupItemDelivered', _handleGroupDeliveryReceipt);

    // Listen for read receipts
    SocketService().registerListener('groupItemReadUpdate', _handleGroupReadReceipt);

    _isInitialized = true;
    print('[MESSAGE_LISTENER] Global message listeners initialized');
  }

  /// Cleanup listeners
  void dispose() {
    if (!_isInitialized) return;

    SocketService().unregisterListener('receiveItem', _handleDirectMessage);
    SocketService().unregisterListener('groupItem', _handleGroupMessage);
    SocketService().unregisterListener('deliveryReceipt', _handleDeliveryReceipt);
    SocketService().unregisterListener('groupItemDelivered', _handleGroupDeliveryReceipt);
    SocketService().unregisterListener('groupItemReadUpdate', _handleGroupReadReceipt);

    _notificationCallbacks.clear();
    _isInitialized = false;
    print('[MESSAGE_LISTENER] Global message listeners disposed');
  }

  /// Register a callback for message notifications
  void registerNotificationCallback(Function(MessageNotification) callback) {
    if (!_notificationCallbacks.contains(callback)) {
      _notificationCallbacks.add(callback);
      print('[MESSAGE_LISTENER] Registered notification callback (total: ${_notificationCallbacks.length})');
    }
  }

  /// Unregister a callback
  void unregisterNotificationCallback(Function(MessageNotification) callback) {
    _notificationCallbacks.remove(callback);
    print('[MESSAGE_LISTENER] Unregistered notification callback (total: ${_notificationCallbacks.length})');
  }

  /// Trigger notification for all registered callbacks
  void _triggerNotification(MessageNotification notification) {
    print('[MESSAGE_LISTENER] Triggering notification: ${notification.type} from ${notification.senderId}');
    for (final callback in _notificationCallbacks) {
      try {
        callback(notification);
      } catch (e) {
        print('[MESSAGE_LISTENER] Error in notification callback: $e');
      }
    }
  }

  /// Handle incoming 1:1 message
  Future<void> _handleDirectMessage(dynamic data) async {
    try {
      print('[MESSAGE_LISTENER] Received 1:1 message');
      
      final itemId = data['itemId'] as String?;
      final sender = data['sender'] as String?;
      final deviceSender = data['deviceSender'] as int?;
      final payload = data['payload'] as String?;
      final timestamp = data['timestamp'] as String?;

      if (itemId == null || sender == null || deviceSender == null || payload == null) {
        print('[MESSAGE_LISTENER] Missing required fields in 1:1 message');
        return;
      }

      // Store in local storage via SignalService
      final signalService = SignalService.instance;
      
      // The message will be decrypted when the chat screen loads
      // For now, just trigger a notification
      _triggerNotification(MessageNotification(
        type: MessageType.direct,
        itemId: itemId,
        senderId: sender,
        senderDeviceId: deviceSender,
        timestamp: timestamp ?? DateTime.now().toIso8601String(),
        encrypted: true,
      ));

      print('[MESSAGE_LISTENER] 1:1 message notification triggered: $itemId');
    } catch (e) {
      print('[MESSAGE_LISTENER] Error handling 1:1 message: $e');
    }
  }

  /// Handle incoming group message
  Future<void> _handleGroupMessage(dynamic data) async {
    try {
      print('[MESSAGE_LISTENER] Received group message');
      
      final itemId = data['itemId'] as String?;
      final channelId = data['channel'] as String?;
      final senderId = data['sender'] as String?;
      final senderDeviceId = data['senderDevice'] as int?;
      final payload = data['payload'] as String?;
      final timestamp = data['timestamp'] as String?;
      final itemType = data['type'] as String? ?? 'message';

      if (itemId == null || channelId == null || senderId == null || 
          senderDeviceId == null || payload == null) {
        print('[MESSAGE_LISTENER] Missing required fields in group message');
        return;
      }

      // Decrypt and store in local storage
      final signalService = SignalService.instance;
      
      try {
        // Decrypt using auto-reload on error
        final decrypted = await signalService.decryptGroupItem(
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          ciphertext: payload,
        );

        // Store in decryptedGroupItemsStore
        await signalService.decryptedGroupItemsStore.storeDecryptedGroupItem(
          itemId: itemId,
          channelId: channelId,
          sender: senderId,
          senderDevice: senderDeviceId,
          message: decrypted,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          type: itemType,
        );

        // Trigger notification with decrypted content
        _triggerNotification(MessageNotification(
          type: MessageType.group,
          itemId: itemId,
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          encrypted: false,
          message: decrypted,
        ));

        print('[MESSAGE_LISTENER] Group message decrypted and stored: $itemId');
      } catch (e) {
        print('[MESSAGE_LISTENER] Error decrypting group message: $e');
        
        // Still trigger notification, but mark as encrypted
        _triggerNotification(MessageNotification(
          type: MessageType.group,
          itemId: itemId,
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          encrypted: true,
        ));
      }
    } catch (e) {
      print('[MESSAGE_LISTENER] Error handling group message: $e');
    }
  }

  /// Handle delivery receipt for 1:1 messages
  void _handleDeliveryReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String?;
      if (itemId != null) {
        _triggerNotification(MessageNotification(
          type: MessageType.deliveryReceipt,
          itemId: itemId,
          timestamp: DateTime.now().toIso8601String(),
        ));
      }
    } catch (e) {
      print('[MESSAGE_LISTENER] Error handling delivery receipt: $e');
    }
  }

  /// Handle delivery receipt for group messages
  void _handleGroupDeliveryReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String?;
      final deliveredCount = data['deliveredCount'] as int?;
      final totalDevices = data['totalDevices'] as int?;
      
      if (itemId != null) {
        _triggerNotification(MessageNotification(
          type: MessageType.groupDeliveryReceipt,
          itemId: itemId,
          timestamp: DateTime.now().toIso8601String(),
          deliveredCount: deliveredCount,
          totalCount: totalDevices,
        ));
      }
    } catch (e) {
      print('[MESSAGE_LISTENER] Error handling group delivery receipt: $e');
    }
  }

  /// Handle read receipt for group messages
  void _handleGroupReadReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String?;
      final readCount = data['readCount'] as int?;
      final deliveredCount = data['deliveredCount'] as int?;
      final totalCount = data['totalCount'] as int?;
      final allRead = data['allRead'] as bool? ?? false;
      
      if (itemId != null) {
        _triggerNotification(MessageNotification(
          type: MessageType.groupReadReceipt,
          itemId: itemId,
          timestamp: DateTime.now().toIso8601String(),
          readCount: readCount,
          deliveredCount: deliveredCount,
          totalCount: totalCount,
          allRead: allRead,
        ));
      }
    } catch (e) {
      print('[MESSAGE_LISTENER] Error handling group read receipt: $e');
    }
  }
}

/// Type of message notification
enum MessageType {
  direct,
  group,
  deliveryReceipt,
  groupDeliveryReceipt,
  groupReadReceipt,
}

/// Message notification data
class MessageNotification {
  final MessageType type;
  final String itemId;
  final String? channelId;
  final String? senderId;
  final int? senderDeviceId;
  final String timestamp;
  final bool encrypted;
  final String? message;
  final int? deliveredCount;
  final int? readCount;
  final int? totalCount;
  final bool? allRead;

  MessageNotification({
    required this.type,
    required this.itemId,
    this.channelId,
    this.senderId,
    this.senderDeviceId,
    required this.timestamp,
    this.encrypted = false,
    this.message,
    this.deliveredCount,
    this.readCount,
    this.totalCount,
    this.allRead,
  });

  @override
  String toString() {
    return 'MessageNotification(type: $type, itemId: $itemId, channelId: $channelId, sender: $senderId, encrypted: $encrypted)';
  }
}
