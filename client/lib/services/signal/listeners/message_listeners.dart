import 'package:flutter/foundation.dart';
import '../../socket_service.dart';
import '../core/message_receiver.dart';

/// Socket.IO listeners for 1:1 encrypted messages
///
/// Handles:
/// - receiveItem: Incoming encrypted messages
/// - deliveryReceipt: Message delivery confirmations
/// - readReceipt: Message read confirmations
///
/// These listeners delegate processing to MessageReceiver service.
class MessageListeners {
  static const String _registrationName = 'MessageListeners';
  static bool _registered = false;

  /// Register all 1:1 message listeners
  static Future<void> register(MessageReceiver receiver) async {
    if (_registered) {
      debugPrint('[MESSAGE_LISTENERS] Already registered');
      return;
    }

    final socket = SocketService();

    // Incoming encrypted message
    socket.registerListener('receiveItem', (data) async {
      try {
        debugPrint('[MESSAGE_LISTENERS] Received item: ${data['itemId']}');
        await receiver.receiveItem(data);
      } catch (e, stack) {
        debugPrint('[MESSAGE_LISTENERS] Error processing receiveItem: $e');
        debugPrint('[MESSAGE_LISTENERS] Stack: $stack');
        // Notify error handler
        _handleError('receiveItem', e, stack);
      }
    }, registrationName: _registrationName);

    // Delivery receipt (server confirmed delivery)
    socket.registerListener('deliveryReceipt', (data) async {
      try {
        final itemId = data['itemId'] as String;
        debugPrint('[MESSAGE_LISTENERS] Delivery receipt for: $itemId');
        await receiver.handleDeliveryReceipt(data);
      } catch (e, stack) {
        debugPrint('[MESSAGE_LISTENERS] Error processing deliveryReceipt: $e');
        debugPrint('[MESSAGE_LISTENERS] Stack: $stack');
        _handleError('deliveryReceipt', e, stack);
      }
    }, registrationName: _registrationName);

    // Read receipt (recipient read message)
    socket.registerListener('readReceipt', (data) async {
      try {
        final itemId = data['itemId'] as String;
        debugPrint('[MESSAGE_LISTENERS] Read receipt for: $itemId');
        await receiver.handleReadReceipt(data);
      } catch (e, stack) {
        debugPrint('[MESSAGE_LISTENERS] Error processing readReceipt: $e');
        debugPrint('[MESSAGE_LISTENERS] Stack: $stack');
        _handleError('readReceipt', e, stack);
      }
    }, registrationName: _registrationName);

    _registered = true;
    debugPrint('[MESSAGE_LISTENERS] ✓ Registered 3 listeners');
  }

  /// Unregister all 1:1 message listeners
  static Future<void> unregister() async {
    if (!_registered) return;

    final socket = SocketService();
    socket.unregisterListener(
      'receiveItem',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'deliveryReceipt',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'readReceipt',
      registrationName: _registrationName,
    );

    _registered = false;
    debugPrint('[MESSAGE_LISTENERS] ✓ Unregistered');
  }

  /// Handle listener errors
  static void _handleError(String listener, dynamic error, StackTrace stack) {
    // TODO: Integrate with ErrorHandler when implemented
    debugPrint('[MESSAGE_LISTENERS] ✗ Error in $listener: $error');
  }
}
