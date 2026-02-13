import 'package:flutter/foundation.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../core/messaging/messaging_service.dart';
import '../callbacks/callback_manager.dart';

/// Socket.IO listeners for 1:1 encrypted messages
///
/// Handles:
/// - receiveItem: Incoming encrypted messages
/// - deliveryReceipt: Message delivery confirmations
/// - readReceipt: Message read confirmations
///
/// These listeners delegate processing to MessagingService.
class MessageListeners {
  static const String _registrationName = 'MessageListeners';
  static bool _registered = false;

  /// Register all 1:1 message listeners
  static Future<void> register(
    MessagingService messagingService,
    CallbackManager callbackManager,
  ) async {
    if (_registered) {
      debugPrint('[MESSAGE_LISTENERS] Already registered');
      return;
    }

    final socket = SocketService.instance;

    // Incoming encrypted message
    socket.registerListener('receiveItem', (data) async {
      try {
        final dataMap = Map<String, dynamic>.from(data as Map);
        final itemId = dataMap['itemId'] as String;
        final type = dataMap['type'] as String? ?? 'message';
        final sender = dataMap['sender'] as String;
        final senderDeviceIdRaw = dataMap['senderDeviceId'];
        final senderDeviceId = senderDeviceIdRaw is int
            ? senderDeviceIdRaw
            : int.parse(senderDeviceIdRaw.toString());
        final cipherType = dataMap['cipherType'] as int;

        debugPrint('[MESSAGE_LISTENERS] Received item: $itemId');
        await messagingService.receiveMessage(
          dataMap: dataMap,
          type: type,
          sender: sender,
          senderDeviceId: senderDeviceId,
          cipherType: cipherType,
          itemId: itemId,
        );
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

        // Notify all registered delivery callbacks
        callbackManager.notifyDelivery(itemId);
      } catch (e, stack) {
        debugPrint('[MESSAGE_LISTENERS] Error processing deliveryReceipt: $e');
        debugPrint('[MESSAGE_LISTENERS] Stack: $stack');
        _handleError('deliveryReceipt', e, stack);
      }
    }, registrationName: _registrationName);

    // Read receipt (recipient read message)
    socket.registerListener('readReceipt', (data) async {
      try {
        final receiptInfo = Map<String, dynamic>.from(data as Map);
        final itemId = receiptInfo['itemId'] as String;
        debugPrint('[MESSAGE_LISTENERS] Read receipt for: $itemId');

        // Notify all registered read callbacks
        callbackManager.notifyRead(receiptInfo);
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

    final socket = SocketService.instance;
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
