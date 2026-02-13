import 'package:flutter/foundation.dart';

/// Message send/receive callbacks for 1:1 and group messages
///
/// Manages callbacks for:
/// - 1:1 message reception (type:sender combinations)
/// - Group message reception (type:channel combinations)
/// - Custom message types (typing indicators, reactions, etc.)
///
/// Callbacks are organized by message type and conversation identifier
/// to allow granular control over which messages trigger which handlers.
class MessageCallbacks {
  /// 1:1 message callbacks
  /// Key format: "type:senderId" (e.g., "message:user-123")
  final Map<String, List<Function(Map<String, dynamic>)>> _receiveCallbacks =
      {};

  /// Group message callbacks
  /// Key format: "type:channelId" (e.g., "message:channel-456")
  final Map<String, List<Function(Map<String, dynamic>)>>
  _receiveGroupCallbacks = {};

  /// Message type callbacks (any sender)
  /// Key format: "type" (e.g., "call_notification")
  /// Used for system messages and broadcasts where sender is not known
  final Map<String, List<Function(Map<String, dynamic>)>> _typeCallbacks = {};

  /// Register 1:1 message receive callback
  void onReceive(
    String type,
    String senderId,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$senderId';
    _receiveCallbacks.putIfAbsent(key, () => []).add(callback);
    debugPrint('[MESSAGE_CALLBACKS] Registered receive: $key');
  }

  /// Register group message receive callback
  void onGroupReceive(
    String type,
    String channelId,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$channelId';
    _receiveGroupCallbacks.putIfAbsent(key, () => []).add(callback);
    debugPrint('[MESSAGE_CALLBACKS] Registered group receive: $key');
  }

  /// Register message type callback (any sender)
  void onTypeReceive(String type, Function(Map<String, dynamic>) callback) {
    _typeCallbacks.putIfAbsent(type, () => []).add(callback);
    debugPrint('[MESSAGE_CALLBACKS] Registered type callback: $type');
  }

  /// Notify 1:1 message received
  void notifyReceive(String type, String senderId, Map<String, dynamic> data) {
    final key = '$type:$senderId';
    final callbacks = _receiveCallbacks[key];

    if (callbacks != null && callbacks.isNotEmpty) {
      debugPrint(
        '[MESSAGE_CALLBACKS] Notifying ${callbacks.length} callbacks for: $key',
      );
      for (final callback in callbacks) {
        try {
          callback(data);
        } catch (e, stack) {
          debugPrint('[MESSAGE_CALLBACKS] Error in callback for $key: $e');
          debugPrint('[MESSAGE_CALLBACKS] Stack: $stack');
        }
      }
    } else {
      debugPrint('[MESSAGE_CALLBACKS] No callbacks registered for: $key');
    }
  }

  /// Notify group message received
  void notifyGroupReceive(
    String type,
    String channelId,
    Map<String, dynamic> data,
  ) {
    final key = '$type:$channelId';
    final callbacks = _receiveGroupCallbacks[key];

    if (callbacks != null && callbacks.isNotEmpty) {
      debugPrint(
        '[MESSAGE_CALLBACKS] Notifying ${callbacks.length} group callbacks for: $key',
      );
      for (final callback in callbacks) {
        try {
          callback(data);
        } catch (e, stack) {
          debugPrint(
            '[MESSAGE_CALLBACKS] Error in group callback for $key: $e',
          );
          debugPrint('[MESSAGE_CALLBACKS] Stack: $stack');
        }
      }
    } else {
      debugPrint('[MESSAGE_CALLBACKS] No group callbacks registered for: $key');
    }
  }

  /// Notify message type received (any sender)
  void notifyTypeReceive(String type, Map<String, dynamic> data) {
    final callbacks = _typeCallbacks[type];

    if (callbacks != null && callbacks.isNotEmpty) {
      debugPrint(
        '[MESSAGE_CALLBACKS] Notifying ${callbacks.length} type callbacks for: $type',
      );
      for (final callback in callbacks) {
        try {
          callback(data);
        } catch (e, stack) {
          debugPrint(
            '[MESSAGE_CALLBACKS] Error in type callback for $type: $e',
          );
          debugPrint('[MESSAGE_CALLBACKS] Stack: $stack');
        }
      }
    } else {
      debugPrint('[MESSAGE_CALLBACKS] No type callbacks registered for: $type');
    }
  }

  /// Remove specific 1:1 receive callback
  void removeReceive(
    String type,
    String senderId,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$senderId';
    _receiveCallbacks[key]?.remove(callback);
    if (_receiveCallbacks[key]?.isEmpty ?? false) {
      _receiveCallbacks.remove(key);
    }
    debugPrint('[MESSAGE_CALLBACKS] Removed receive: $key');
  }

  /// Remove specific group receive callback
  void removeGroupReceive(
    String type,
    String channelId,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$channelId';
    _receiveGroupCallbacks[key]?.remove(callback);
    if (_receiveGroupCallbacks[key]?.isEmpty ?? false) {
      _receiveGroupCallbacks.remove(key);
    }
    debugPrint('[MESSAGE_CALLBACKS] Removed group receive: $key');
  }

  /// Remove specific type callback
  void removeTypeReceive(String type, Function(Map<String, dynamic>) callback) {
    _typeCallbacks[type]?.remove(callback);
    if (_typeCallbacks[type]?.isEmpty ?? false) {
      _typeCallbacks.remove(type);
    }
    debugPrint('[MESSAGE_CALLBACKS] Removed type callback: $type');
  }

  /// Clear all callbacks
  void clear() {
    _receiveCallbacks.clear();
    _receiveGroupCallbacks.clear();
    _typeCallbacks.clear();
    debugPrint('[MESSAGE_CALLBACKS] ✓ All callbacks cleared');
  }

  /// Get count of registered callbacks
  int get count => _receiveCallbacks.values.fold(
    0,
    (sum, callbacks) => sum + callbacks.length,
  );

  int get groupCount => _receiveGroupCallbacks.values.fold(
    0,
    (sum, callbacks) => sum + callbacks.length,
  );

  int get typeCount =>
      _typeCallbacks.values.fold(0, (sum, callbacks) => sum + callbacks.length);

  /// Get registered callback keys (for debugging)
  List<String> get registeredKeys => _receiveCallbacks.keys.toList();
  List<String> get registeredGroupKeys => _receiveGroupCallbacks.keys.toList();
}
