import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/meeting.dart';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'meeting_service.dart';
import 'sound_service.dart';
import 'signal_service.dart';
import 'presence_service.dart';

/// Call service - handles instant call creation and notifications
///
/// Use HTTP routes for:
/// - Creating instant calls (POST /api/calls/instant)
/// - Same endpoints as meetings (calls are meetings with is_instant_call=true)
/// - Pre-call validation (GET /api/presence/bulk for online status)
///
/// Use Socket.IO for real-time notifications:
/// - call:notify (emit) - Send ringtone notification to recipients
/// - call:incoming (listen) - Receive incoming call notification
/// - call:ringing (listen) - Caller sees who is ringing
/// - call:accept (emit) - Notify acceptance
/// - call:decline (emit) - Notify decline
/// - call:accepted (listen) - Receive acceptance notification
/// - call:declined (listen) - Receive decline notification
class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  final _socketService = SocketService();
  final _meetingService = MeetingService();
  final _soundService = SoundService.instance;

  // Stream controllers for call events
  final _incomingCallController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _callRingingController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _callAcceptedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _callDeclinedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _callEndedController = StreamController<String>.broadcast();

  // Public streams
  Stream<Map<String, dynamic>> get onIncomingCall =>
      _incomingCallController.stream;
  Stream<Map<String, dynamic>> get onCallRinging =>
      _callRingingController.stream;
  Stream<Map<String, dynamic>> get onCallAccepted =>
      _callAcceptedController.stream;
  Stream<Map<String, dynamic>> get onCallDeclined =>
      _callDeclinedController.stream;
  Stream<String> get onCallEnded => _callEndedController.stream;

  bool _listenersRegistered = false;

  /// Initialize Socket.IO listeners for call notifications
  void initializeListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    // Register Signal callback for call notifications (from any sender)
    // Backend sends call data via Signal protocol (encrypted)
    SignalService.instance.registerItemCallback('call_notification', (data) {
      debugPrint('[CALL SERVICE] Received call_notification via Signal: $data');
      try {
        // Data structure: {type, payload, sender, itemId}
        // payload is a JSON string that needs to be parsed
        final itemData = data as Map<String, dynamic>;
        final payloadStr = itemData['payload'] as String;
        final callData = jsonDecode(payloadStr) as Map<String, dynamic>;

        // Extract call information (already decrypted)
        final String meetingId = callData['meetingId'] as String;
        final String? channelId = callData['channelId'] as String?;
        final String? channelName = callData['channelName'] as String?;
        final String? callerName = callData['callerName'] as String?;
        final String? callerId = callData['callerId'] as String?;
        final String? callerAvatar = callData['callerAvatar'] as String?;
        final bool isDirectCall = callData['isDirectCall'] as bool? ?? false;

        debugPrint(
          '[CALL SERVICE] Incoming call - meetingId: $meetingId, '
          'channel: ${channelName ?? 'Direct Call'}, caller: $callerName',
        );

        // Play ringtone
        _soundService.playRingtone();

        // Add to stream
        _incomingCallController.add({
          'meetingId': meetingId,
          'channelId': channelId,
          'channelName': channelName,
          'callerName': callerName,
          'callerId': callerId,
          'callerAvatar': callerAvatar,
          'isDirectCall': isDirectCall,
        });
      } catch (e, stackTrace) {
        debugPrint('[CALL SERVICE] Error parsing call notification: $e');
        debugPrint('[CALL SERVICE] Stack trace: $stackTrace');
        // Still notify UI with error state
        _incomingCallController.add({
          'error': true,
          'message': 'Failed to parse call data',
        });
      }
    });

    _socketService.registerListener('call:ringing', (data) {
      debugPrint('[CALL SERVICE] Received call:ringing: $data');
      try {
        _callRingingController.add(data as Map<String, dynamic>);
      } catch (e) {
        debugPrint('[CALL SERVICE] Error parsing call:ringing: $e');
      }
    });

    _socketService.registerListener('call:accepted', (data) {
      debugPrint('[CALL SERVICE] Received call:accepted: $data');
      try {
        final acceptData = data as Map<String, dynamic>;

        // Stop ringtone when call is accepted (could be on another device)
        _soundService.stopRingtone();

        // Notify stream (will dismiss overlay on other devices)
        _callAcceptedController.add(acceptData);
      } catch (e) {
        debugPrint('[CALL SERVICE] Error parsing call:accepted: $e');
      }
    });

    _socketService.registerListener('call:declined', (data) {
      debugPrint('[CALL SERVICE] Received call:declined: $data');
      try {
        // Stop ringtone when call is declined
        _soundService.stopRingtone();

        _callDeclinedController.add(data as Map<String, dynamic>);
      } catch (e) {
        debugPrint('[CALL SERVICE] Error parsing call:declined: $e');
      }
    });

    _socketService.registerListener('call:ended', (data) {
      debugPrint('[CALL SERVICE] Received call:ended: $data');
      try {
        final meetingId =
            (data as Map<String, dynamic>)['meeting_id'] as String;

        // Stop ringtone when call ends
        _soundService.stopRingtone();

        _callEndedController.add(meetingId);
      } catch (e) {
        debugPrint('[CALL SERVICE] Error parsing call:ended: $e');
      }
    });

    debugPrint('[CALL SERVICE] Socket.IO listeners initialized');
  }

  /// Dispose resources
  void dispose() {
    _incomingCallController.close();
    _callRingingController.close();
    _callAcceptedController.close();
    _callDeclinedController.close();
    _callEndedController.close();
  }

  // ============================================================================
  // HTTP API Methods
  // ============================================================================

  /// Create an instant call (uses meetings API with is_instant_call=true)
  Future<Meeting> createCall({
    String? title,
    String? sourceChannelId,
    String? sourceUserId,
    bool allowExternal = false,
    bool voiceOnly = false,
  }) async {
    final now = DateTime.now();
    final endTime = now.add(const Duration(hours: 24));

    final response = await ApiService.post(
      '/api/calls/instant',
      data: {
        'title': title ?? 'Instant Call',
        'start_time': now.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'source_channel_id': sourceChannelId,
        'source_user_id': sourceUserId,
        'allow_external': allowExternal,
        'voice_only': voiceOnly,
      },
    );

    return Meeting.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get active calls (instant meetings with is_instant_call=true)
  Future<List<Meeting>> getActiveCalls() async {
    return await _meetingService.getMeetings(
      status: 'in_progress',
      isInstantCall: true,
    );
  }

  /// Start instant call from channel
  /// Returns meeting ID for joining LiveKit room
  /// Validates that at least one member is online before creating call
  Future<String> startChannelCall({
    required String channelId,
    required String channelName,
  }) async {
    debugPrint(
      '[CALL SERVICE] Starting channel call: $channelName ($channelId)',
    );

    // Pre-call validation: Check if any members are online
    // Get online members via API (server already has this logic)
    try {
      final response = await ApiService.get(
        '/api/channels/$channelId/online-members',
      );
      final data = response.data as Map<String, dynamic>;
      final List<dynamic> onlineMembers =
          data['online_members'] as List<dynamic>;

      if (onlineMembers.isEmpty) {
        throw Exception('No channel members are currently online');
      }

      debugPrint('[CALL SERVICE] Found ${onlineMembers.length} online members');
    } catch (e) {
      debugPrint('[CALL SERVICE] Error checking online members: $e');
      throw Exception('Failed to verify online members');
    }

    final meeting = await createCall(
      title: '$channelName Call',
      sourceChannelId: channelId,
      allowExternal: false, // No external guests for instant calls
      voiceOnly: false,
    );

    return meeting.meetingId;
  }

  /// Start 1:1 instant call
  /// Returns meeting ID for joining LiveKit room
  /// Validates that recipient is online before creating call
  Future<String> startDirectCall({
    required String userId,
    required String userName,
  }) async {
    debugPrint('[CALL SERVICE] Starting 1:1 call with $userName ($userId)');

    // Pre-call validation: Check if recipient is online
    debugPrint(
      '[CALL SERVICE] Pre-call check: Verifying $userName ($userId) is online',
    );
    final presenceService = PresenceService();
    final isOnline = await presenceService.isUserOnline(userId);
    debugPrint('[CALL SERVICE] Pre-call check result: isOnline=$isOnline');

    if (!isOnline) {
      debugPrint(
        '[CALL SERVICE] ERROR: $userName is offline, cannot start call',
      );
      throw Exception('$userName is currently offline');
    }

    debugPrint('[CALL SERVICE] Recipient is online, creating call');

    final meeting = await createCall(
      title: '1:1 Call with $userName',
      sourceUserId: userId,
      allowExternal: false,
      voiceOnly: false,
    );

    // Immediately notify the single recipient
    notifyRecipients(meeting.meetingId, [userId]);

    return meeting.meetingId;
  }

  /// Notify online channel members after initiator joins LiveKit room
  /// Called AFTER successful join to avoid notifying if join fails
  /// Returns list of invited user IDs
  Future<List<String>> notifyChannelMembers({
    required String meetingId,
    required String channelId,
  }) async {
    try {
      debugPrint(
        '[CALL SERVICE] Getting online members for channel $channelId',
      );

      // Get online members from server
      final response = await ApiService.get(
        '/api/channels/$channelId/online-members',
      );
      final onlineMembers = (response.data['online_members'] as List)
          .map((m) => m['user_id'] as String)
          .toList();

      debugPrint('[CALL SERVICE] Found ${onlineMembers.length} online members');

      if (onlineMembers.isNotEmpty) {
        // Send call:notify event to all online members
        notifyRecipients(meetingId, onlineMembers);
      }

      return onlineMembers;
    } catch (e) {
      debugPrint('[CALL SERVICE] Error notifying channel members: $e');
      rethrow;
    }
  }

  // ============================================================================
  // Socket.IO Methods (for real-time notifications)
  // ============================================================================

  /// Send call notification to recipients (triggers ringtone on their devices)
  void notifyRecipients(String meetingId, List<String> recipientIds) {
    _socketService.emit('call:notify', {
      'meeting_id': meetingId,
      'recipient_ids': recipientIds,
    });
    debugPrint(
      '[CALL SERVICE] Sent call:notify for meeting $meetingId to ${recipientIds.length} recipients',
    );
  }

  /// Accept an incoming call (notifies caller)
  void acceptCall(String meetingId) {
    _socketService.emit('call:accept', {'meeting_id': meetingId});

    // Stop ringtone
    _soundService.stopRingtone();

    debugPrint('[CALL SERVICE] Accepted call: $meetingId');
  }

  /// Decline an incoming call (notifies caller)
  void declineCall(String meetingId, {String reason = 'declined'}) {
    _socketService.emit('call:decline', {
      'meeting_id': meetingId,
      'reason': reason,
    });

    // Stop ringtone
    _soundService.stopRingtone();

    debugPrint('[CALL SERVICE] Declined call: $meetingId (reason: $reason)');
  }

  /// Stop ringtone manually (e.g., when navigating away from call screen)
  void stopRingtone() {
    _soundService.stopRingtone();
  }
}
