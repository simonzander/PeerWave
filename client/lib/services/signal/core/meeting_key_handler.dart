import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Meeting E2EE Key Handler
///
/// Handles meeting end-to-end encryption key exchange messages.
/// This service processes key requests and responses for LiveKit meeting encryption.
///
/// Usage:
/// ```dart
/// final handler = MeetingKeyHandler();
/// handler.registerRequestCallback(meetingId, (data) { ... });
/// handler.registerResponseCallback(meetingId, (data) { ... });
/// await handler.handleKeyRequest(item);
/// await handler.handleKeyResponse(item);
/// ```
class MeetingKeyHandler {
  // Callbacks for meeting E2EE key requests
  final Map<String, Function(Map<String, dynamic>)>
  _meetingE2EEKeyRequestCallbacks = {};

  // Callbacks for meeting E2EE key responses
  final Map<String, Function(Map<String, dynamic>)>
  _meetingE2EEKeyResponseCallbacks = {};

  /// Register a callback for meeting E2EE key requests
  void registerRequestCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    _meetingE2EEKeyRequestCallbacks[meetingId] = callback;
    debugPrint(
      '[MEETING_KEY_HANDLER] Registered request callback for meeting: $meetingId',
    );
  }

  /// Register a callback for meeting E2EE key responses
  void registerResponseCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    _meetingE2EEKeyResponseCallbacks[meetingId] = callback;
    debugPrint(
      '[MEETING_KEY_HANDLER] Registered response callback for meeting: $meetingId',
    );
  }

  /// Unregister callbacks for a specific meeting
  void unregisterCallbacks(String meetingId) {
    _meetingE2EEKeyRequestCallbacks.remove(meetingId);
    _meetingE2EEKeyResponseCallbacks.remove(meetingId);
    debugPrint(
      '[MEETING_KEY_HANDLER] Unregistered callbacks for meeting: $meetingId',
    );
  }

  /// Handle meeting E2EE key request (via 1-to-1 Signal message)
  /// Called when someone in the meeting requests the E2EE key from us
  Future<void> handleKeyRequest(Map<String, dynamic> item) async {
    try {
      debugPrint('[MEETING_KEY_HANDLER] 📨 Meeting E2EE key REQUEST received');

      // Parse the decrypted message content
      final messageJson = jsonDecode(item['message'] as String);
      final meetingId = messageJson['meetingId'] as String?;
      final requesterId = messageJson['requesterId'] as String?;
      final timestamp = messageJson['timestamp'] as int?;

      debugPrint('[MEETING_KEY_HANDLER] Meeting ID: $meetingId');
      debugPrint('[MEETING_KEY_HANDLER] Requester: $requesterId');
      debugPrint('[MEETING_KEY_HANDLER] Timestamp: $timestamp');

      if (meetingId == null || requesterId == null) {
        debugPrint(
          '[MEETING_KEY_HANDLER] ⚠️ Missing meetingId or requesterId in key request',
        );
        return;
      }

      // Trigger registered callback for this meeting
      final callback = _meetingE2EEKeyRequestCallbacks[meetingId];
      if (callback != null) {
        callback({
          'meetingId': meetingId,
          'requesterId': requesterId,
          'senderId': item['sender'],
          'senderDeviceId': item['senderDeviceId'],
          'timestamp': timestamp,
        });
        debugPrint(
          '[MEETING_KEY_HANDLER] ✓ Meeting E2EE key request callback triggered',
        );
      } else {
        debugPrint(
          '[MEETING_KEY_HANDLER] ⚠️ No callback registered for meeting: $meetingId',
        );
      }
    } catch (e, stack) {
      debugPrint(
        '[MEETING_KEY_HANDLER] ❌ Error handling meeting E2EE key request: $e',
      );
      debugPrint('[MEETING_KEY_HANDLER] Stack trace: $stack');
    }
  }

  /// Handle meeting E2EE key response (via 1-to-1 Signal message)
  /// Called when someone sends us the E2EE key for a meeting
  Future<void> handleKeyResponse(Map<String, dynamic> item) async {
    try {
      debugPrint('[MEETING_KEY_HANDLER] 🔑 Meeting E2EE key RESPONSE received');

      // Parse the decrypted message content
      final messageJson = jsonDecode(item['message'] as String);
      final meetingId = messageJson['meetingId'] as String?;
      final encryptedKey = messageJson['encryptedKey'] as String?;
      final timestamp = messageJson['timestamp'] as int?;
      final targetUserId = messageJson['targetUserId'] as String?;

      debugPrint('[MEETING_KEY_HANDLER] Meeting ID: $meetingId');
      debugPrint('[MEETING_KEY_HANDLER] Target User: $targetUserId');
      debugPrint('[MEETING_KEY_HANDLER] Timestamp: $timestamp');
      debugPrint(
        '[MEETING_KEY_HANDLER] Key Length: ${encryptedKey?.length ?? 0} chars (base64)',
      );

      if (meetingId == null || encryptedKey == null || timestamp == null) {
        debugPrint(
          '[MEETING_KEY_HANDLER] ⚠️ Missing required fields in key response',
        );
        return;
      }

      // Trigger registered callback for this meeting
      final callback = _meetingE2EEKeyResponseCallbacks[meetingId];
      if (callback != null) {
        callback({
          'meetingId': meetingId,
          'encryptedKey': encryptedKey,
          'timestamp': timestamp,
          'targetUserId': targetUserId,
          'senderId': item['sender'],
          'senderDeviceId': item['senderDeviceId'],
        });
        debugPrint(
          '[MEETING_KEY_HANDLER] ✓ Meeting E2EE key response callback triggered',
        );
      } else {
        debugPrint(
          '[MEETING_KEY_HANDLER] ⚠️ No callback registered for meeting: $meetingId',
        );
      }
    } catch (e, stack) {
      debugPrint(
        '[MEETING_KEY_HANDLER] ❌ Error handling meeting E2EE key response: $e',
      );
      debugPrint('[MEETING_KEY_HANDLER] Stack trace: $stack');
    }
  }
}
