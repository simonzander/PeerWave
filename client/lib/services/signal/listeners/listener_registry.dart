import 'package:flutter/foundation.dart';
import '../core/message_receiver.dart';
import '../core/group_message_receiver.dart';
import '../core/session_manager.dart';
import '../core/key_manager.dart';
import '../core/healing_service.dart';
import '../../../providers/unread_messages_provider.dart';
import 'message_listeners.dart';
import 'group_listeners.dart';
import 'session_listeners.dart';
import 'sync_listeners.dart';

/// Central registry for all Socket.IO listeners
///
/// Manages registration and cleanup of all Signal Protocol socket listeners.
/// Ensures listeners are registered only once and can be cleanly unregistered.
///
/// Usage:
/// ```dart
/// final registry = ListenerRegistry.instance;
/// await registry.registerAll(
///   messageReceiver: messageReceiver,
///   groupReceiver: groupReceiver,
///   sessionManager: sessionManager,
///   keyManager: keyManager,
/// );
///
/// // Later, on logout or cleanup:
/// await registry.unregisterAll();
/// ```
class ListenerRegistry {
  static final ListenerRegistry instance = ListenerRegistry._();
  ListenerRegistry._();

  bool _registered = false;
  bool get isRegistered => _registered;

  /// Register all socket listeners
  ///
  /// Should be called once after service initialization.
  /// Guards against duplicate registration.
  Future<void> registerAll({
    required MessageReceiver messageReceiver,
    required GroupMessageReceiver groupReceiver,
    required SessionManager sessionManager,
    required SignalKeyManager keyManager,
    required SignalHealingService healingService,
    UnreadMessagesProvider? unreadMessagesProvider,
    String? currentUserId,
    int? currentDeviceId,
  }) async {
    if (_registered) {
      debugPrint('[LISTENER_REGISTRY] Already registered, skipping');
      return;
    }

    try {
      debugPrint('[LISTENER_REGISTRY] Registering all socket listeners...');

      // Register message listeners (1:1 messages)
      await MessageListeners.register(messageReceiver);

      // Register group message listeners
      await GroupListeners.register(
        groupReceiver,
        unreadMessagesProvider: unreadMessagesProvider,
        currentUserId: currentUserId,
      );

      // Register session/key management listeners
      await SessionListeners.register(
        sessionManager: sessionManager,
        keyManager: keyManager,
      );

      // Register background sync listeners
      await SyncListeners.register(
        messageReceiver: messageReceiver,
        groupReceiver: groupReceiver,
        healingService: healingService,
        currentUserId: currentUserId,
        currentDeviceId: currentDeviceId,
      );

      _registered = true;
      debugPrint('[LISTENER_REGISTRY] ✓ All listeners registered');
    } catch (e, stack) {
      debugPrint('[LISTENER_REGISTRY] ✗ Registration failed: $e');
      debugPrint('[LISTENER_REGISTRY] Stack: $stack');
      rethrow;
    }
  }

  /// Unregister all socket listeners
  ///
  /// Should be called on logout or service cleanup.
  /// Removes all socket event handlers to prevent memory leaks.
  Future<void> unregisterAll() async {
    if (!_registered) {
      debugPrint('[LISTENER_REGISTRY] Not registered, nothing to clean up');
      return;
    }

    try {
      debugPrint('[LISTENER_REGISTRY] Unregistering all socket listeners...');

      // Unregister in reverse order
      await SyncListeners.unregister();
      await SessionListeners.unregister();
      await GroupListeners.unregister();
      await MessageListeners.unregister();

      _registered = false;
      debugPrint('[LISTENER_REGISTRY] ✓ All listeners unregistered');
    } catch (e, stack) {
      debugPrint('[LISTENER_REGISTRY] ✗ Unregister failed: $e');
      debugPrint('[LISTENER_REGISTRY] Stack: $stack');
      // Don't rethrow on cleanup - best effort
    }
  }

  /// Reset state (for testing or forced cleanup)
  void reset() {
    _registered = false;
  }
}
