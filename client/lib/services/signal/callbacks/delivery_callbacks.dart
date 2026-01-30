import 'package:flutter/foundation.dart';

/// Delivery and read receipt callbacks
///
/// Manages callbacks for:
/// - Message delivery confirmations (server received message)
/// - Message read receipts (recipient opened/read message)
///
/// These callbacks enable UI updates for message status indicators
/// (single checkmark for delivered, double checkmark for read).
class DeliveryCallbacks {
  /// Delivery receipt callbacks (message delivered to server/recipient)
  final List<Function(String itemId)> _deliveryCallbacks = [];

  /// Read receipt callbacks (message read by recipient)
  /// Callback receives: {itemId, readByUserId, readByDeviceId, timestamp}
  final List<Function(Map<String, dynamic>)> _readCallbacks = [];

  /// Register delivery receipt callback
  ///
  /// Called when server confirms message was delivered to recipient.
  /// Useful for updating UI to show "delivered" status.
  void onDelivery(Function(String itemId) callback) {
    _deliveryCallbacks.add(callback);
    debugPrint(
      '[DELIVERY_CALLBACKS] Registered delivery callback (${_deliveryCallbacks.length} total)',
    );
  }

  /// Register read receipt callback
  ///
  /// Called when recipient reads the message.
  /// Useful for updating UI to show "read" status.
  ///
  /// Receipt info contains:
  /// - itemId: Message ID
  /// - readByUserId: User who read the message
  /// - readByDeviceId: Device that read the message
  /// - timestamp: When message was read
  void onRead(Function(Map<String, dynamic> receiptInfo) callback) {
    _readCallbacks.add(callback);
    debugPrint(
      '[DELIVERY_CALLBACKS] Registered read callback (${_readCallbacks.length} total)',
    );
  }

  /// Notify delivery receipt received
  void notifyDelivery(String itemId) {
    debugPrint(
      '[DELIVERY_CALLBACKS] Notifying ${_deliveryCallbacks.length} callbacks for delivery: $itemId',
    );

    for (final callback in _deliveryCallbacks) {
      try {
        callback(itemId);
      } catch (e, stack) {
        debugPrint('[DELIVERY_CALLBACKS] Error in delivery callback: $e');
        debugPrint('[DELIVERY_CALLBACKS] Stack: $stack');
      }
    }
  }

  /// Notify read receipt received
  void notifyRead(Map<String, dynamic> receiptInfo) {
    final itemId = receiptInfo['itemId'];
    debugPrint(
      '[DELIVERY_CALLBACKS] Notifying ${_readCallbacks.length} callbacks for read: $itemId',
    );

    for (final callback in _readCallbacks) {
      try {
        callback(receiptInfo);
      } catch (e, stack) {
        debugPrint('[DELIVERY_CALLBACKS] Error in read callback: $e');
        debugPrint('[DELIVERY_CALLBACKS] Stack: $stack');
      }
    }
  }

  /// Clear all delivery callbacks
  void clear() {
    _deliveryCallbacks.clear();
    debugPrint('[DELIVERY_CALLBACKS] ✓ Delivery callbacks cleared');
  }

  /// Clear all read callbacks
  void clearRead() {
    _readCallbacks.clear();
    debugPrint('[DELIVERY_CALLBACKS] ✓ Read callbacks cleared');
  }

  /// Get count of registered callbacks
  int get count => _deliveryCallbacks.length;
  int get readCount => _readCallbacks.length;
}
