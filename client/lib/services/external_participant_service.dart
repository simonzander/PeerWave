import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/external_session.dart';
import 'api_service.dart';
import 'socket_service.dart';

/// External participant service - manages guest access to meetings
/// 
/// Features:
/// - Join meeting flow for external guests (unauthenticated)
/// - Admission control (admit/decline guests)
/// - E2EE key exchange for external participants
/// - Session management (24-hour expiration)
/// 
/// Use HTTP routes for:
/// - POST /api/external/join - Guest joins meeting with token
/// - POST /api/external/:sessionId/admit - Admit guest
/// - POST /api/external/:sessionId/decline - Decline guest
/// - POST /api/external/:sessionId/keys - Submit E2EE keys
/// 
/// Use Socket.IO for real-time notifications:
/// - meeting:guest_waiting (listen) - Guest is waiting for admission
/// - meeting:guest_admitted (listen) - Guest was admitted
/// - meeting:guest_declined (listen) - Guest was declined
class ExternalParticipantService {
  static final ExternalParticipantService _instance = ExternalParticipantService._internal();
  factory ExternalParticipantService() => _instance;
  ExternalParticipantService._internal();

  final _socketService = SocketService();

  // Stream controllers
  final _guestWaitingController = StreamController<ExternalSession>.broadcast();
  final _guestAdmittedController = StreamController<ExternalSession>.broadcast();
  final _guestDeclinedController = StreamController<ExternalSession>.broadcast();

  // Public streams
  Stream<ExternalSession> get onGuestWaiting => _guestWaitingController.stream;
  Stream<ExternalSession> get onGuestAdmitted => _guestAdmittedController.stream;
  Stream<ExternalSession> get onGuestDeclined => _guestDeclinedController.stream;

  bool _listenersRegistered = false;

  /// Initialize Socket.IO listeners for guest events
  void initializeListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    _socketService.registerListener('meeting:guest_waiting', (data) {
      debugPrint('[EXTERNAL SERVICE] Received meeting:guest_waiting: $data');
      try {
        final session = ExternalSession.fromJson(data as Map<String, dynamic>);
        _guestWaitingController.add(session);
      } catch (e) {
        debugPrint('[EXTERNAL SERVICE] Error parsing meeting:guest_waiting: $e');
      }
    });

    _socketService.registerListener('meeting:guest_admitted', (data) {
      debugPrint('[EXTERNAL SERVICE] Received meeting:guest_admitted: $data');
      try {
        final session = ExternalSession.fromJson(data as Map<String, dynamic>);
        _guestAdmittedController.add(session);
      } catch (e) {
        debugPrint('[EXTERNAL SERVICE] Error parsing meeting:guest_admitted: $e');
      }
    });

    _socketService.registerListener('meeting:guest_declined', (data) {
      debugPrint('[EXTERNAL SERVICE] Received meeting:guest_declined: $data');
      try {
        final session = ExternalSession.fromJson(data as Map<String, dynamic>);
        _guestDeclinedController.add(session);
      } catch (e) {
        debugPrint('[EXTERNAL SERVICE] Error parsing meeting:guest_declined: $e');
      }
    });

    debugPrint('[EXTERNAL SERVICE] Socket.IO listeners initialized');
  }

  /// Dispose resources
  void dispose() {
    _guestWaitingController.close();
    _guestAdmittedController.close();
    _guestDeclinedController.close();
  }

  // ============================================================================
  // HTTP API Methods - Guest Flow (Unauthenticated)
  // ============================================================================

  /// Join a meeting as an external guest (unauthenticated endpoint)
  /// 
  /// This is called by guests who have an invitation link
  /// Returns session information including admission status
  Future<ExternalSession> joinMeeting({
    required String invitationToken,
    required String displayName,
    String? e2eeIdentityKey,
    String? e2eeSignedPreKey,
    String? e2eePreKeySignature,
  }) async {
    final response = await ApiService.post('/api/external/join', data: {
      'invitation_token': invitationToken,
      'display_name': displayName,
      'e2ee_identity_key': e2eeIdentityKey,
      'e2ee_signed_pre_key': e2eeSignedPreKey,
      'e2ee_pre_key_signature': e2eePreKeySignature,
    });

    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Update E2EE keys for external session (called after initial join)
  Future<ExternalSession> updateE2EEKeys({
    required String sessionId,
    required String e2eeIdentityKey,
    required String e2eeSignedPreKey,
    required String e2eePreKeySignature,
  }) async {
    final response = await ApiService.post('/api/external/$sessionId/keys', data: {
      'e2ee_identity_key': e2eeIdentityKey,
      'e2ee_signed_pre_key': e2eeSignedPreKey,
      'e2ee_pre_key_signature': e2eePreKeySignature,
    });

    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Check session status (for guests to poll while waiting)
  Future<ExternalSession> getSessionStatus(String sessionId) async {
    final response = await ApiService.get('/api/external/$sessionId');
    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  // ============================================================================
  // HTTP API Methods - Admission Control (Authenticated)
  // ============================================================================

  /// Get waiting guests for a meeting (authenticated endpoint)
  Future<List<ExternalSession>> getWaitingGuests(String meetingId) async {
    final response = await ApiService.get('/api/external/waiting/$meetingId');
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => ExternalSession.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Admit a guest to the meeting (authenticated endpoint)
  Future<ExternalSession> admitGuest(String sessionId) async {
    final response = await ApiService.post('/api/external/$sessionId/admit', data: {});
    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Decline a guest (authenticated endpoint)
  Future<ExternalSession> declineGuest(
    String sessionId, {
    String reason = 'declined',
  }) async {
    final response = await ApiService.post('/api/external/$sessionId/decline', data: {
      'reason': reason,
    });
    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get all external sessions for a meeting (authenticated endpoint)
  Future<List<ExternalSession>> getMeetingSessions(String meetingId) async {
    final response = await ApiService.get('/api/meetings/$meetingId/external-sessions');
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => ExternalSession.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Revoke an external session (authenticated endpoint)
  /// 
  /// This removes the session and prevents the guest from rejoining
  Future<void> revokeSession(String sessionId) async {
    await ApiService.delete('/api/external/$sessionId');
  }
}
