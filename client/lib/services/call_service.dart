import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/meeting.dart';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'meeting_service.dart';
import 'sound_service.dart';

/// Call service - handles instant call creation and notifications
/// 
/// Use HTTP routes for:
/// - Creating instant calls (POST /api/calls)
/// - Same endpoints as meetings (calls are meetings with is_instant_call=true)
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
  final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  final _callRingingController = StreamController<Map<String, dynamic>>.broadcast();
  final _callAcceptedController = StreamController<Map<String, dynamic>>.broadcast();
  final _callDeclinedController = StreamController<Map<String, dynamic>>.broadcast();
  final _callEndedController = StreamController<String>.broadcast();

  // Public streams
  Stream<Map<String, dynamic>> get onIncomingCall => _incomingCallController.stream;
  Stream<Map<String, dynamic>> get onCallRinging => _callRingingController.stream;
  Stream<Map<String, dynamic>> get onCallAccepted => _callAcceptedController.stream;
  Stream<Map<String, dynamic>> get onCallDeclined => _callDeclinedController.stream;
  Stream<String> get onCallEnded => _callEndedController.stream;

  bool _listenersRegistered = false;

  /// Initialize Socket.IO listeners for call notifications
  void initializeListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    _socketService.registerListener('call:incoming', (data) {
      debugPrint('[CALL SERVICE] Received call:incoming: $data');
      try {
        final callData = data as Map<String, dynamic>;
        
        // Play ringtone for incoming call
        _soundService.playRingtone();
        
        _incomingCallController.add(callData);
      } catch (e) {
        debugPrint('[CALL SERVICE] Error parsing call:incoming: $e');
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
        // Stop ringtone when call is accepted
        _soundService.stopRingtone();
        
        _callAcceptedController.add(data as Map<String, dynamic>);
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
        final meetingId = (data as Map<String, dynamic>)['meeting_id'] as String;
        
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
    String? channelId,
    bool allowExternal = false,
    bool voiceOnly = false,
  }) async {
    final now = DateTime.now();
    final endTime = now.add(const Duration(hours: 24));

    final response = await ApiService.post('/api/calls', data: {
      'title': title ?? 'Instant Call',
      'start_time': now.toIso8601String(),
      'end_time': endTime.toIso8601String(),
      'is_instant_call': true,
      'channel_id': channelId,
      'allow_external': allowExternal,
      'voice_only': voiceOnly,
    });

    return Meeting.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get active calls (instant meetings with is_instant_call=true)
  Future<List<Meeting>> getActiveCalls() async {
    return await _meetingService.getMeetings(
      status: 'in_progress',
      isInstantCall: true,
    );
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
    debugPrint('[CALL SERVICE] Sent call:notify for meeting $meetingId to ${recipientIds.length} recipients');
  }

  /// Accept an incoming call (notifies caller)
  void acceptCall(String meetingId) {
    _socketService.emit('call:accept', {
      'meeting_id': meetingId,
    });
    
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
