import 'package:flutter/foundation.dart';
import '../../socket_service.dart';
import '../state/sync_state.dart';
import '../core/message_receiver.dart';
import '../core/group_message_receiver.dart';
import '../core/healing_service.dart';

/// Socket.IO listeners for background message synchronization
///
/// Handles:
/// - pendingMessagesAvailable: Server notifies of pending messages
/// - pendingMessagesResponse: Batch of pending messages from server
/// - syncComplete: Server finished sending all pending messages
///
/// These listeners enable offline message recovery and background sync.
class SyncListeners {
  static const String _registrationName = 'SyncListeners';
  static bool _registered = false;
  static MessageReceiver? _messageReceiver;
  static GroupMessageReceiver? _groupReceiver;
  static SignalHealingService? _healingService;
  static String? _currentUserId;
  static int? _currentDeviceId;

  /// Register all background sync listeners
  static Future<void> register({
    MessageReceiver? messageReceiver,
    GroupMessageReceiver? groupReceiver,
    SignalHealingService? healingService,
    String? currentUserId,
    int? currentDeviceId,
  }) async {
    if (_registered) {
      debugPrint('[SYNC_LISTENERS] Already registered');
      return;
    }

    _messageReceiver = messageReceiver;
    _groupReceiver = groupReceiver;
    _healingService = healingService;
    _currentUserId = currentUserId;
    _currentDeviceId = currentDeviceId;

    final socket = SocketService();
    final syncState = SyncState.instance;

    // Socket reconnected - process offline queue and trigger self-healing
    socket.registerListener('connect', (_) async {
      try {
        debugPrint('[SYNC_LISTENERS] Socket reconnected');

        // NOTE: Offline queue processing requires access to sendItem/sendGroupItem
        // which aren't available in the listener module.
        // Signal service should register its own connect listener to handle this.
        // See signal_service.dart:_processOfflineQueue() for implementation.

        // Trigger self-healing key verification (async, non-blocking, rate-limited)
        if (_healingService != null &&
            _currentUserId != null &&
            _currentDeviceId != null) {
          debugPrint(
            '[SYNC_LISTENERS] Triggering self-healing verification...',
          );
          _healingService!.triggerAsyncSelfVerification(
            reason: 'socket_reconnect',
            userId: _currentUserId!,
            deviceId: _currentDeviceId!,
          );
        }
      } catch (e, stack) {
        debugPrint('[SYNC_LISTENERS] Error processing connect: $e');
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
      }
    }, registrationName: _registrationName);

    // Server notifies that pending messages are available
    socket.registerListener('pendingMessagesAvailable', (data) async {
      try {
        final count = data['count'] as int? ?? 0;
        debugPrint('[SYNC_LISTENERS] Pending messages available: $count');

        if (count > 0) {
          syncState.startSync(
            totalMessages: count,
            syncType: SyncType.pendingMessages,
            statusText: 'Syncing $count messages...',
          );

          // Request pending messages in batches
          socket.emit('requestPendingMessages', {'batchSize': 50});
        }
      } catch (e, stack) {
        debugPrint(
          '[SYNC_LISTENERS] Error processing pendingMessagesAvailable: $e',
        );
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
        syncState.setError(e.toString());
      }
    }, registrationName: _registrationName);

    // Batch of pending messages received
    socket.registerListener('pendingMessagesResponse', (data) async {
      try {
        final messages = data['messages'] as List? ?? [];
        final hasMore = data['hasMore'] as bool? ?? false;

        debugPrint(
          '[SYNC_LISTENERS] Received ${messages.length} messages, '
          'hasMore: $hasMore',
        );

        // Process each message
        for (final message in messages) {
          await _processPendingMessage(message);
          syncState.incrementProcessed();
        }

        // Request next batch if available
        if (hasMore) {
          socket.emit('requestPendingMessages', {'batchSize': 50});
        } else {
          syncState.completeSync();
          debugPrint('[SYNC_LISTENERS] ✓ Sync complete');
        }
      } catch (e, stack) {
        debugPrint(
          '[SYNC_LISTENERS] Error processing pendingMessagesResponse: $e',
        );
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
        syncState.setError(e.toString());
      }
    }, registrationName: _registrationName);

    // Server explicitly signals sync completion
    socket.registerListener('syncComplete', (data) async {
      try {
        debugPrint('[SYNC_LISTENERS] Server confirmed sync complete');
        syncState.completeSync();
      } catch (e, stack) {
        debugPrint('[SYNC_LISTENERS] Error processing syncComplete: $e');
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
      }
    }, registrationName: _registrationName);

    // Error fetching pending messages
    socket.registerListener('fetchPendingMessagesError', (data) async {
      try {
        final error = data['error'] as String? ?? 'Unknown error';
        debugPrint('[SYNC_LISTENERS] Fetch pending messages error: $error');
        syncState.setError(error);
      } catch (e, stack) {
        debugPrint(
          '[SYNC_LISTENERS] Error processing fetchPendingMessagesError: $e',
        );
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
      }
    }, registrationName: _registrationName);

    _registered = true;
    debugPrint('[SYNC_LISTENERS] ✓ Registered 5 listeners');
  }

  /// Unregister all sync listeners
  static Future<void> unregister() async {
    if (!_registered) return;

    final socket = SocketService();
    socket.unregisterListener('connect', registrationName: _registrationName);
    socket.unregisterListener(
      'pendingMessagesAvailable',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'pendingMessagesResponse',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'syncComplete',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'fetchPendingMessagesError',
      registrationName: _registrationName,
    );

    _messageReceiver = null;
    _groupReceiver = null;
    _healingService = null;
    _currentUserId = null;
    _currentDeviceId = null;
    _registered = false;
    debugPrint('[SYNC_LISTENERS] ✓ Unregistered');
  }

  /// Process a single pending message
  static Future<void> _processPendingMessage(dynamic message) async {
    try {
      final channelId = message['channelId'] as String?;

      if (channelId != null) {
        // Group message
        debugPrint(
          '[SYNC_LISTENERS] Processing group message: ${message['itemId']}',
        );
        await _groupReceiver?.receiveItemChannel(message);
      } else {
        // 1:1 message
        debugPrint(
          '[SYNC_LISTENERS] Processing 1:1 message: ${message['itemId']}',
        );
        await _messageReceiver?.receiveItem(message);
      }
    } catch (e, stack) {
      debugPrint('[SYNC_LISTENERS] Error processing message: $e');
      debugPrint('[SYNC_LISTENERS] Stack: $stack');
      // Continue processing other messages
    }
  }
}
