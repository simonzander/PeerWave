import 'package:flutter/foundation.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../../api_service.dart';
// import '../state/sync_state.dart'; // FIXME: SyncState removed
import '../core/messaging/messaging_service.dart';
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
  static MessagingService? _messagingService;
  static SignalHealingService? _healingService;
  static String? _currentUserId;
  static int? _currentDeviceId;

  /// Register all background sync listeners
  static Future<void> register({
    MessagingService? messagingService,
    SignalHealingService? healingService,
    String? currentUserId,
    int? currentDeviceId,
  }) async {
    if (_registered) {
      debugPrint('[SYNC_LISTENERS] Already registered');
      return;
    }

    _messagingService = messagingService;
    _healingService = healingService;
    _currentUserId = currentUserId;
    _currentDeviceId = currentDeviceId;

    final socket = SocketService.instance;
    // final syncState = // syncState.instance; // FIXME: SyncState removed

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
          debugPrint('[SYNC_LISTENERS] Syncing $count messages...');

          // Request pending messages in batches
          _requestPendingMessages(socket, limit: 50, offset: 0);
        }
      } catch (e, stack) {
        debugPrint(
          '[SYNC_LISTENERS] Error processing pendingMessagesAvailable: $e',
        );
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
        // syncState.setError(e.toString());
      }
    }, registrationName: _registrationName);

    // Batch of pending messages received
    socket.registerListener('pendingMessagesResponse', (data) async {
      try {
        final items =
            (data['items'] as List?) ?? (data['messages'] as List?) ?? [];
        final hasMore = data['hasMore'] as bool? ?? false;
        final offset = data['offset'] as int? ?? 0;

        debugPrint(
          '[SYNC_LISTENERS] Received ${items.length} messages, '
          'hasMore: $hasMore',
        );

        // Process each message
        for (final message in items) {
          await _processPendingMessage(message);
          // syncState.incrementProcessed();
        }

        // Request next batch if available
        if (hasMore) {
          _requestPendingMessages(
            socket,
            limit: 50,
            offset: offset + items.length,
          );
        } else {
          // syncState.completeSync();
          debugPrint('[SYNC_LISTENERS] ✓ Sync complete');
        }
      } catch (e, stack) {
        debugPrint(
          '[SYNC_LISTENERS] Error processing pendingMessagesResponse: $e',
        );
        debugPrint('[SYNC_LISTENERS] Stack: $stack');
        // syncState.setError(e.toString());
      }
    }, registrationName: _registrationName);

    // Server explicitly signals sync completion
    socket.registerListener('syncComplete', (data) async {
      try {
        debugPrint('[SYNC_LISTENERS] Server confirmed sync complete');
        // syncState.completeSync();
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
        // syncState.setError(error);
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

    final socket = SocketService.instance;
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

    _messagingService = null;
    _healingService = null;
    _currentUserId = null;
    _currentDeviceId = null;
    _registered = false;
    debugPrint('[SYNC_LISTENERS] ✓ Unregistered');
  }

  /// Process a single pending message
  static Future<void> _processPendingMessage(dynamic message) async {
    try {
      final dataMap = Map<String, dynamic>.from(message as Map);
      dataMap['_syncSource'] =
          dataMap['_syncSource'] ?? dataMap['syncSource'] ?? 'offline_socket';
      final channelId = dataMap['channelId'] as String?;
      final itemId = dataMap['itemId'] as String?;

      if (channelId != null) {
        // Group message
        debugPrint('[SYNC_LISTENERS] Processing group message: $itemId');
        final type = dataMap['type'] as String? ?? 'message';
        final sender = dataMap['sender'] as String? ?? '';
        final senderDeviceId = dataMap['senderDeviceId'] as int? ?? 0;
        final cipherType = dataMap['cipherType'] as int? ?? 3;

        await _messagingService?.receiveMessage(
          dataMap: dataMap,
          type: type,
          sender: sender,
          senderDeviceId: senderDeviceId,
          cipherType: cipherType,
          itemId: itemId ?? '',
        );
      } else {
        // 1:1 message
        debugPrint('[SYNC_LISTENERS] Processing 1:1 message: $itemId');
        final type = dataMap['type'] as String? ?? 'message';
        final sender = dataMap['sender'] as String? ?? '';
        final senderDeviceId = dataMap['senderDeviceId'] as int? ?? 0;
        final cipherType = dataMap['cipherType'] as int? ?? 1;

        await _messagingService?.receiveMessage(
          dataMap: dataMap,
          type: type,
          sender: sender,
          senderDeviceId: senderDeviceId,
          cipherType: cipherType,
          itemId: itemId ?? '',
        );
      }
    } catch (e, stack) {
      debugPrint('[SYNC_LISTENERS] Error processing message: $e');
      debugPrint('[SYNC_LISTENERS] Stack: $stack');
      // Continue processing other messages
    }
  }

  static void _requestPendingMessages(
    SocketService socket, {
    required int limit,
    required int offset,
  }) {
    socket.emit('fetchPendingMessagesV2', {'limit': limit, 'offset': offset});
  }

  /// Fetch pending messages via HTTP (useful on init/resume)
  static Future<void> fetchPendingMessagesViaHttp({
    required String reason,
    int limit = 50,
  }) async {
    if (_messagingService == null) {
      debugPrint('[SYNC_LISTENERS] HTTP fetch skipped - no messaging service');
      return;
    }

    try {
      debugPrint('[SYNC_LISTENERS] HTTP pending fetch started: $reason');

      var offset = 0;
      var hasMore = true;

      while (hasMore) {
        final response = await ApiService.instance.get(
          '/api/signal/pending-messages/v2',
          queryParameters: {'limit': limit, 'offset': offset, 'source': reason},
        );

        final raw = response.data;
        final data = raw is Map
            ? Map<String, dynamic>.from(raw as Map)
            : <String, dynamic>{};

        final items =
            (data['items'] as List?) ?? (data['messages'] as List?) ?? [];
        hasMore = data['hasMore'] as bool? ?? false;

        debugPrint(
          '[SYNC_LISTENERS] HTTP received ${items.length} messages, hasMore: $hasMore',
        );

        for (final message in items) {
          await _processPendingMessage(message);
        }

        if (items.isEmpty) {
          hasMore = false;
        } else {
          offset += items.length;
        }
      }

      debugPrint('[SYNC_LISTENERS] HTTP pending fetch complete');
    } catch (e, stack) {
      debugPrint('[SYNC_LISTENERS] HTTP pending fetch error: $e');
      debugPrint('[SYNC_LISTENERS] Stack: $stack');
    }
  }
}
