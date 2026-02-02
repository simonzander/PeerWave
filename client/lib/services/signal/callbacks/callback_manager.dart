import 'package:flutter/foundation.dart';
import 'message_callbacks.dart';
import 'delivery_callbacks.dart';
import 'error_callbacks.dart';

/// Central callback management for Signal Protocol events
///
/// Provides unified interface for registering and notifying callbacks across
/// all Signal Protocol operations: messages, delivery receipts, read receipts,
/// and error handling.
///
/// Usage:
/// ```dart
/// final manager = CallbackManager.instance;
///
/// // Register callbacks
/// manager.messages.onReceive('message', senderId, (data) {
///   print('Message from $senderId: ${data['content']}');
/// });
///
/// manager.delivery.onDelivery((itemId) {
///   print('Message $itemId delivered');
/// });
///
/// // Notify callbacks
/// manager.notifyMessageReceived('message', senderId, messageData);
/// manager.notifyDelivery(itemId);
///
/// // Cleanup
/// manager.clearAll();
/// ```
class CallbackManager {
  static final CallbackManager instance = CallbackManager._();
  CallbackManager._();

  final MessageCallbacks messages = MessageCallbacks();
  final DeliveryCallbacks delivery = DeliveryCallbacks();
  final ErrorCallbacks errors = ErrorCallbacks();

  /// Register a message receive callback (1:1 messages)
  ///
  /// [type] - Message type (e.g., 'message', 'typing', 'reaction')
  /// [senderId] - Sender's user ID
  /// [callback] - Function to call when message is received
  void registerReceiveItem(
    String type,
    String senderId,
    Function(Map<String, dynamic>) callback,
  ) {
    messages.onReceive(type, senderId, callback);
  }

  /// Register a group message receive callback
  ///
  /// [type] - Message type
  /// [channelId] - Channel/group ID
  /// [callback] - Function to call when group message is received
  void registerReceiveItemChannel(
    String type,
    String channelId,
    Function(Map<String, dynamic>) callback,
  ) {
    messages.onGroupReceive(type, channelId, callback);
  }

  /// Register a message type callback (from any sender)
  ///
  /// Use this for system messages or broadcasts where sender is not known:
  /// - call_notification (incoming calls from any user)
  /// - system announcements
  /// - broadcast messages
  ///
  /// [type] - Message type (e.g., 'call_notification', 'system_message')
  /// [callback] - Function to call when message of this type is received
  void registerReceiveItemType(
    String type,
    Function(Map<String, dynamic>) callback,
  ) {
    messages.onTypeReceive(type, callback);
  }

  /// Register delivery receipt callback
  void registerDeliveryCallback(Function(String itemId) callback) {
    delivery.onDelivery(callback);
  }

  /// Register read receipt callback
  void registerReadCallback(
    Function(Map<String, dynamic> receiptInfo) callback,
  ) {
    delivery.onRead(callback);
  }

  /// Register error callback
  void registerErrorCallback(
    Function(SignalError) callback, {
    ErrorCategory? category,
  }) {
    errors.onError(callback, category: category);
  }

  /// Notify message received (1:1)
  void notifyMessageReceived(
    String type,
    String senderId,
    Map<String, dynamic> data,
  ) {
    messages.notifyReceive(type, senderId, data);
  }

  /// Notify group message received
  void notifyGroupMessageReceived(
    String type,
    String channelId,
    Map<String, dynamic> data,
  ) {
    messages.notifyGroupReceive(type, channelId, data);
  }

  /// Notify delivery receipt
  void notifyDelivery(String itemId) {
    delivery.notifyDelivery(itemId);
  }

  /// Notify read receipt
  void notifyRead(Map<String, dynamic> receiptInfo) {
    delivery.notifyRead(receiptInfo);
  }

  /// Notify error
  void notifyError(SignalError error) {
    errors.notifyError(error);
  }

  /// Unregister specific receive callback (1:1)
  void unregisterReceiveItem(
    String type,
    String senderId,
    Function(Map<String, dynamic>) callback,
  ) {
    messages.removeReceive(type, senderId, callback);
  }

  /// Unregister specific group receive callback
  void unregisterReceiveItemChannel(
    String type,
    String channelId,
    Function(Map<String, dynamic>) callback,
  ) {
    messages.removeGroupReceive(type, channelId, callback);
  }

  /// Unregister specific message type callback
  void unregisterReceiveItemType(
    String type,
    Function(Map<String, dynamic>) callback,
  ) {
    messages.removeTypeReceive(type, callback);
  }

  /// Clear all delivery callbacks
  void clearDeliveryCallbacks() {
    delivery.clear();
  }

  /// Clear all read callbacks
  void clearReadCallbacks() {
    delivery.clearRead();
  }

  /// Clear all callbacks (on logout)
  void clearAll() {
    messages.clear();
    delivery.clear();
    errors.clear();
    debugPrint('[CALLBACK_MANAGER] ✓ All callbacks cleared');
  }

  /// Get statistics about registered callbacks
  Map<String, int> getStats() {
    return {
      'messageCallbacks': messages.count,
      'groupCallbacks': messages.groupCount,
      'typeCallbacks': messages.typeCount,
      'deliveryCallbacks': delivery.count,
      'readCallbacks': delivery.readCount,
      'errorCallbacks': errors.count,
    };
  }
}
