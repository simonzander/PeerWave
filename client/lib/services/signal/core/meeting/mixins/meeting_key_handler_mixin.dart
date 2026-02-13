import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Mixin for meeting E2EE key request/response handling
mixin MeetingKeyHandlerMixin {
  // Callbacks
  final Map<String, Function(Map<String, dynamic>)>
  _meetingE2EEKeyRequestCallbacks = {};
  final Map<String, Function(Map<String, dynamic>)>
  _meetingE2EEKeyResponseCallbacks = {};

  /// Register a callback for meeting E2EE key requests
  void registerRequestCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    _meetingE2EEKeyRequestCallbacks[meetingId] = callback;
    debugPrint(
      '[MEETING_KEYS] Registered request callback for meeting: $meetingId',
    );
  }

  /// Register a callback for meeting E2EE key responses
  void registerResponseCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    _meetingE2EEKeyResponseCallbacks[meetingId] = callback;
    debugPrint(
      '[MEETING_KEYS] Registered response callback for meeting: $meetingId',
    );
  }

  /// Unregister callbacks for a specific meeting
  void unregisterCallbacks(String meetingId) {
    _meetingE2EEKeyRequestCallbacks.remove(meetingId);
    _meetingE2EEKeyResponseCallbacks.remove(meetingId);
    debugPrint('[MEETING_KEYS] Unregistered callbacks for meeting: $meetingId');
  }

  /// Handle meeting E2EE key request (via 1-to-1 Signal message)
  Future<void> handleKeyRequest(Map<String, dynamic> item) async {
    try {
      final messageText = item['decryptedMessage'] as String?;
      if (messageText == null) return;

      final data = jsonDecode(messageText) as Map<String, dynamic>;
      final meetingId = data['meetingId'] as String?;

      if (meetingId == null) {
        debugPrint('[MEETING_KEYS] Missing meetingId in key request');
        return;
      }

      final callback = _meetingE2EEKeyRequestCallbacks[meetingId];
      if (callback != null) {
        debugPrint(
          '[MEETING_KEYS] Triggering key request callback for meeting: $meetingId',
        );
        callback(data);
      } else {
        debugPrint(
          '[MEETING_KEYS] No callback registered for meeting: $meetingId',
        );
      }
    } catch (e) {
      debugPrint('[MEETING_KEYS] Error handling key request: $e');
    }
  }

  /// Handle meeting E2EE key response (via 1-to-1 Signal message)
  Future<void> handleKeyResponse(Map<String, dynamic> item) async {
    try {
      final messageText = item['decryptedMessage'] as String?;
      if (messageText == null) return;

      final data = jsonDecode(messageText) as Map<String, dynamic>;
      final meetingId = data['meetingId'] as String?;

      if (meetingId == null) {
        debugPrint('[MEETING_KEYS] Missing meetingId in key response');
        return;
      }

      final callback = _meetingE2EEKeyResponseCallbacks[meetingId];
      if (callback != null) {
        debugPrint(
          '[MEETING_KEYS] Triggering key response callback for meeting: $meetingId',
        );
        callback(data);
      } else {
        debugPrint(
          '[MEETING_KEYS] No callback registered for meeting: $meetingId',
        );
      }
    } catch (e) {
      debugPrint('[MEETING_KEYS] Error handling key response: $e');
    }
  }
}
