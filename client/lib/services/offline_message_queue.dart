import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Offline Message Queue - Stores messages when offline and retries when reconnected
///
/// This queue persists messages locally and automatically retries sending them
/// when the connection is restored.
class OfflineMessageQueue {
  static final OfflineMessageQueue instance = OfflineMessageQueue._internal();
  factory OfflineMessageQueue() => instance;
  OfflineMessageQueue._internal();

  static const String _queueKey = 'offline_message_queue';
  final List<QueuedMessage> _queue = [];
  bool _isProcessing = false;

  /// Add a message to the offline queue
  Future<void> enqueue(QueuedMessage message) async {
    _queue.add(message);
    await _saveQueue();
    debugPrint(
      '[OFFLINE QUEUE] Message queued: ${message.itemId} (${message.type})',
    );
  }

  /// Load the queue from persistent storage
  Future<void> loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString(_queueKey);

      if (queueJson != null) {
        final List<dynamic> queueList = jsonDecode(queueJson);
        _queue.clear();
        _queue.addAll(queueList.map((item) => QueuedMessage.fromJson(item)));
        debugPrint('[OFFLINE QUEUE] Loaded ${_queue.length} queued messages');
      }
    } catch (e) {
      debugPrint('[OFFLINE QUEUE] Error loading queue: $e');
    }
  }

  /// Save the queue to persistent storage
  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = jsonEncode(_queue.map((m) => m.toJson()).toList());
      await prefs.setString(_queueKey, queueJson);
    } catch (e) {
      debugPrint('[OFFLINE QUEUE] Error saving queue: $e');
    }
  }

  /// Process the queue - send all pending messages
  ///
  /// Parameters:
  /// - [sendFunction]: Function to send a single message (returns true on success)
  /// - [onProgress]: Optional callback for progress updates
  Future<void> processQueue({
    required Future<bool> Function(QueuedMessage message) sendFunction,
    void Function(int processed, int total)? onProgress,
  }) async {
    if (_isProcessing) {
      debugPrint('[OFFLINE QUEUE] Already processing queue');
      return;
    }

    if (_queue.isEmpty) {
      debugPrint('[OFFLINE QUEUE] Queue is empty');
      return;
    }

    _isProcessing = true;
    debugPrint(
      '[OFFLINE QUEUE] Processing ${_queue.length} queued messages...',
    );

    int processed = 0;
    final List<QueuedMessage> failedMessages = [];

    // Create a copy to iterate safely
    final messagesToProcess = List<QueuedMessage>.from(_queue);

    for (final message in messagesToProcess) {
      try {
        debugPrint(
          '[OFFLINE QUEUE] Sending queued message ${message.itemId}...',
        );
        final success = await sendFunction(message);

        if (success) {
          _queue.remove(message);
          processed++;
          debugPrint(
            '[OFFLINE QUEUE] ✓ Message sent successfully: ${message.itemId}',
          );
        } else {
          failedMessages.add(message);
          debugPrint(
            '[OFFLINE QUEUE] ✗ Message send failed: ${message.itemId}',
          );
        }
      } catch (e) {
        failedMessages.add(message);
        debugPrint(
          '[OFFLINE QUEUE] ✗ Error sending message ${message.itemId}: $e',
        );
      }

      onProgress?.call(processed, messagesToProcess.length);
    }

    await _saveQueue();
    _isProcessing = false;

    debugPrint(
      '[OFFLINE QUEUE] Processing complete: $processed/${messagesToProcess.length} sent, ${failedMessages.length} failed',
    );
  }

  /// Get the current queue size
  int get queueSize => _queue.length;

  /// Check if queue has messages
  bool get hasMessages => _queue.isNotEmpty;

  /// Clear the entire queue (use with caution)
  Future<void> clearQueue() async {
    _queue.clear();
    await _saveQueue();
    debugPrint('[OFFLINE QUEUE] Queue cleared');
  }

  /// Remove a specific message from queue
  Future<void> removeMessage(String itemId) async {
    _queue.removeWhere((m) => m.itemId == itemId);
    await _saveQueue();
    debugPrint('[OFFLINE QUEUE] Message removed: $itemId');
  }
}

/// Queued message model
class QueuedMessage {
  final String itemId;
  final String type; // 'direct' or 'group'
  final String text;
  final String timestamp;
  final Map<String, dynamic>
  metadata; // Additional data (recipientId, channelId, etc.)
  final int retryCount;
  final DateTime queuedAt;

  QueuedMessage({
    required this.itemId,
    required this.type,
    required this.text,
    required this.timestamp,
    required this.metadata,
    this.retryCount = 0,
    DateTime? queuedAt,
  }) : queuedAt = queuedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'itemId': itemId,
      'type': type,
      'text': text,
      'timestamp': timestamp,
      'metadata': metadata,
      'retryCount': retryCount,
      'queuedAt': queuedAt.toIso8601String(),
    };
  }

  factory QueuedMessage.fromJson(Map<String, dynamic> json) {
    return QueuedMessage(
      itemId: json['itemId'],
      type: json['type'],
      text: json['text'],
      timestamp: json['timestamp'],
      metadata: Map<String, dynamic>.from(json['metadata'] ?? {}),
      retryCount: json['retryCount'] ?? 0,
      queuedAt: DateTime.parse(json['queuedAt']),
    );
  }

  QueuedMessage withIncrementedRetry() {
    return QueuedMessage(
      itemId: itemId,
      type: type,
      text: text,
      timestamp: timestamp,
      metadata: metadata,
      retryCount: retryCount + 1,
      queuedAt: queuedAt,
    );
  }
}
