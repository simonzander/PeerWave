import 'package:flutter/foundation.dart';
import '../../offline_message_queue.dart';

/// Offline Queue Processor
///
/// Handles processing of offline message queue when connection is restored.
/// This service coordinates between OfflineMessageQueue and message sending functions.
///
/// Usage:
/// ```dart
/// final processor = OfflineQueueProcessor();
/// await processor.processQueue(
///   sendDirectMessage: (recipientId, payload, itemId) async { ... },
///   sendGroupMessage: (channelId, message, itemId) async { ... },
/// );
/// ```
class OfflineQueueProcessor {
  /// Process offline message queue
  ///
  /// Sends all queued messages using the provided send functions.
  /// Automatically handles both direct and group messages.
  ///
  /// Parameters:
  /// - [sendDirectMessage]: Function to send direct messages
  /// - [sendGroupMessage]: Function to send group messages
  ///
  /// Returns true if processing started, false if already processing or no messages
  Future<bool> processQueue({
    required Future<String> Function({
      required String recipientUserId,
      required String type,
      required String payload,
      String? itemId,
    })
    sendDirectMessage,
    required Future<String> Function({
      required String channelId,
      required String message,
      String? itemId,
    })
    sendGroupMessage,
  }) async {
    final queue = OfflineMessageQueue.instance;

    if (!queue.hasMessages) {
      debugPrint('[OFFLINE_QUEUE_PROCESSOR] No messages in offline queue');
      return false;
    }

    debugPrint(
      '[OFFLINE_QUEUE_PROCESSOR] Processing ${queue.queueSize} queued messages...',
    );

    await queue.processQueue(
      sendFunction: (queuedMessage) async {
        try {
          if (queuedMessage.type == 'group') {
            // Send group message
            final channelId = queuedMessage.metadata['channelId'] as String;
            debugPrint(
              '[OFFLINE_QUEUE_PROCESSOR] Sending queued group message to channel $channelId',
            );

            await sendGroupMessage(
              channelId: channelId,
              message: queuedMessage.text,
              itemId: queuedMessage.itemId,
            );
            return true;
          } else if (queuedMessage.type == 'direct') {
            // Send direct message
            final recipientId = queuedMessage.metadata['recipientId'] as String;
            debugPrint(
              '[OFFLINE_QUEUE_PROCESSOR] Sending queued direct message to $recipientId',
            );

            await sendDirectMessage(
              recipientUserId: recipientId,
              type: 'message',
              payload: queuedMessage.text,
              itemId: queuedMessage.itemId,
            );
            return true;
          } else {
            debugPrint(
              '[OFFLINE_QUEUE_PROCESSOR] Unknown message type: ${queuedMessage.type}',
            );
            return false;
          }
        } catch (e) {
          debugPrint(
            '[OFFLINE_QUEUE_PROCESSOR] Failed to send queued message ${queuedMessage.itemId}: $e',
          );
          return false;
        }
      },
      onProgress: (processed, total) {
        debugPrint(
          '[OFFLINE_QUEUE_PROCESSOR] Queue progress: $processed/$total',
        );
      },
    );

    debugPrint('[OFFLINE_QUEUE_PROCESSOR] Offline queue processing complete');
    return true;
  }
}
