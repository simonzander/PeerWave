import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/external_session.dart';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'user_profile_service.dart';

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
  static final ExternalParticipantService _instance =
      ExternalParticipantService._internal();
  factory ExternalParticipantService() => _instance;
  ExternalParticipantService._internal();

  final _socketService = SocketService();

  // Stream controllers
  final _guestWaitingController = StreamController<ExternalSession>.broadcast();
  final _guestAdmittedController =
      StreamController<ExternalSession>.broadcast();
  final _guestDeclinedController =
      StreamController<ExternalSession>.broadcast();
  final _guestAdmissionRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _guestE2EEKeyRequestController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Public streams
  Stream<ExternalSession> get onGuestWaiting => _guestWaitingController.stream;
  Stream<ExternalSession> get onGuestAdmitted =>
      _guestAdmittedController.stream;
  Stream<ExternalSession> get onGuestDeclined =>
      _guestDeclinedController.stream;
  Stream<Map<String, dynamic>> get onGuestAdmissionRequest =>
      _guestAdmissionRequestController.stream;
  Stream<Map<String, dynamic>> get onGuestE2EEKeyRequest =>
      _guestE2EEKeyRequestController.stream;

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
        debugPrint(
          '[EXTERNAL SERVICE] Error parsing meeting:guest_waiting: $e',
        );
      }
    });

    _socketService.registerListener('meeting:guest_admitted', (data) {
      debugPrint('[EXTERNAL SERVICE] Received meeting:guest_admitted: $data');
      try {
        final session = ExternalSession.fromJson(data as Map<String, dynamic>);
        _guestAdmittedController.add(session);
      } catch (e) {
        debugPrint(
          '[EXTERNAL SERVICE] Error parsing meeting:guest_admitted: $e',
        );
      }
    });

    _socketService.registerListener('meeting:guest_declined', (data) {
      debugPrint('[EXTERNAL SERVICE] Received meeting:guest_declined: $data');
      try {
        final session = ExternalSession.fromJson(data as Map<String, dynamic>);
        _guestDeclinedController.add(session);
      } catch (e) {
        debugPrint(
          '[EXTERNAL SERVICE] Error parsing meeting:guest_declined: $e',
        );
      }
    });

    _socketService.registerListener('meeting:guest_admission_request', (data) {
      debugPrint(
        '[EXTERNAL SERVICE] Received meeting:guest_admission_request: $data',
      );
      try {
        _guestAdmissionRequestController.add(data as Map<String, dynamic>);
      } catch (e) {
        debugPrint(
          '[EXTERNAL SERVICE] Error parsing meeting:guest_admission_request: $e',
        );
      }
    });

    debugPrint('[EXTERNAL SERVICE] Socket.IO listeners initialized');
    debugPrint(
      '[EXTERNAL SERVICE] Note: DEPRECATED plaintext listeners are disabled - use Signal Protocol',
    );
  }

  /// DEPRECATED: Register meeting-specific E2EE key request listener - DO NOT USE
  /// This uses insecure plaintext Socket.IO events. Use Signal Protocol instead.
  @Deprecated('Use Signal Protocol encrypted message handlers instead')
  void registerMeetingE2EEListener(String meetingId) {
    debugPrint(
      '[EXTERNAL SERVICE] ⚠️ DEPRECATED: registerMeetingE2EEListener called - this is insecure!',
    );
    debugPrint(
      '[EXTERNAL SERVICE] ⚠️ Use Signal Protocol guest:meeting_e2ee_key_request handler instead',
    );
    // COMMENTED OUT - DO NOT USE PLAINTEXT KEY EXCHANGE
    // final eventName = 'guest:request_e2ee_key:$meetingId';
    //
    // debugPrint('[EXTERNAL SERVICE] 🎧 Registering listener for $eventName');
    // debugPrint('[EXTERNAL SERVICE] Socket connected: ${_socketService.isConnected}');
    //
    // _socketService.registerListener(eventName, (data) {
    //   debugPrint('[EXTERNAL SERVICE] 🔔 Received $eventName: $data');
    //   try {
    //     _guestE2EEKeyRequestController.add(data as Map<String, dynamic>);
    //   } catch (e) {
    //     debugPrint('[EXTERNAL SERVICE] Error parsing $eventName: $e');
    //   }
    // });
    //
    // debugPrint('[EXTERNAL SERVICE] ✅ Listener registered for $eventName');
  }

  /// DEPRECATED: Unregister meeting-specific E2EE key request listener - DO NOT USE
  @Deprecated('Use Signal Protocol encrypted message handlers instead')
  void unregisterMeetingE2EEListener(String meetingId) {
    debugPrint(
      '[EXTERNAL SERVICE] ⚠️ DEPRECATED: unregisterMeetingE2EEListener called',
    );
    // COMMENTED OUT - NO LONGER NEEDED
    // final eventName = 'guest:request_e2ee_key:$meetingId';
    // debugPrint('[EXTERNAL SERVICE] Meeting E2EE listener for $eventName will be cleaned up on disconnect');
  }

  /// Dispose resources
  void dispose() {
    _guestWaitingController.close();
    _guestAdmittedController.close();
    _guestDeclinedController.close();
    _guestAdmissionRequestController.close();
    _guestE2EEKeyRequestController.close();
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
    String? identityKeyPublic,
    dynamic signedPreKey,
    List? preKeys,
  }) async {
    final response = await ApiService.post(
      '/api/meetings/external/register',
      data: {
        'invitation_token': invitationToken,
        'display_name': displayName,
        if (identityKeyPublic != null) 'identity_key_public': identityKeyPublic,
        if (signedPreKey != null) 'signed_pre_key': signedPreKey,
        if (preKeys != null) 'pre_keys': preKeys,
      },
    );

    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Update E2EE keys for external session (called after initial join)
  Future<ExternalSession> updateE2EEKeys({
    required String sessionId,
    required String e2eeIdentityKey,
    required String e2eeSignedPreKey,
    required String e2eePreKeySignature,
  }) async {
    final response = await ApiService.post(
      '/api/external/$sessionId/keys',
      data: {
        'e2ee_identity_key': e2eeIdentityKey,
        'e2ee_signed_pre_key': e2eeSignedPreKey,
        'e2ee_pre_key_signature': e2eePreKeySignature,
      },
    );

    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Check session status (for guests to poll while waiting)
  Future<ExternalSession> getSessionStatus(String sessionId) async {
    final response = await ApiService.get(
      '/api/meetings/external/session/$sessionId',
    );
    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  // ============================================================================
  // HTTP API Methods - Admission Control (Authenticated)
  // ============================================================================

  /// Get waiting guests for a meeting (authenticated endpoint)
  Future<List<ExternalSession>> getWaitingGuests(String meetingId) async {
    final response = await ApiService.get(
      '/api/meetings/$meetingId/external/waiting',
    );
    final List<dynamic> data = response.data['waiting'] as List<dynamic>? ?? [];
    return data
        .map((json) => ExternalSession.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Admit a guest to the meeting (authenticated endpoint)
  Future<ExternalSession> admitGuest(
    String sessionId, {
    String? meetingId,
  }) async {
    // We need meetingId - try to get it from the session if not provided
    final session = meetingId != null
        ? null
        : await getSessionStatus(sessionId);
    final mId = meetingId ?? session?.meetingId ?? '';
    final currentUserId = UserProfileService.instance.currentUserUuid ?? '';

    final response = await ApiService.post(
      '/api/meetings/$mId/external/$sessionId/admit',
      data: {'admitted_by': currentUserId},
    );
    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Decline a guest (authenticated endpoint)
  Future<ExternalSession> declineGuest(
    String sessionId, {
    String? meetingId,
    String reason = 'declined',
  }) async {
    // We need meetingId - try to get it from the session if not provided
    final session = meetingId != null
        ? null
        : await getSessionStatus(sessionId);
    final mId = meetingId ?? session?.meetingId ?? '';
    final currentUserId = UserProfileService.instance.currentUserUuid ?? '';

    final response = await ApiService.post(
      '/api/meetings/$mId/external/$sessionId/decline',
      data: {'declined_by': currentUserId, 'reason': reason},
    );
    return ExternalSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get all external sessions for a meeting (authenticated endpoint)
  Future<List<ExternalSession>> getMeetingSessions(String meetingId) async {
    final response = await ApiService.get(
      '/api/meetings/$meetingId/external-sessions',
    );
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

  // ============================================================================
  // Pre-Key Management (Guest Flow)
  // ============================================================================

  /// Get remaining pre-key count for external session
  Future<Map<String, dynamic>> getRemainingPreKeys(String sessionId) async {
    final response = await ApiService.get(
      '/api/meetings/external/session/$sessionId/prekeys',
    );
    return response.data as Map<String, dynamic>;
  }

  /// Replenish one-time pre-keys for external session
  ///
  /// Called by guest when pre-key count drops below threshold (< 10)
  Future<Map<String, dynamic>> replenishPreKeys({
    required String sessionId,
    required List<Map<String, dynamic>> preKeys,
  }) async {
    final response = await ApiService.post(
      '/api/meetings/external/session/$sessionId/prekeys',
      data: {'pre_keys': preKeys},
    );
    return response.data as Map<String, dynamic>;
  }

  /// Consume a pre-key (authenticated endpoint - called by server users)
  ///
  /// Used when establishing Signal session with guest
  Future<Map<String, dynamic>> consumePreKey({
    required String sessionId,
    required int preKeyId,
  }) async {
    final response = await ApiService.post(
      '/api/meetings/external/session/$sessionId/consume-prekey',
      data: {'pre_key_id': preKeyId},
    );
    return response.data as Map<String, dynamic>;
  }

  /// Get E2EE keys for establishing Signal session with guest (authenticated)
  ///
  /// Returns identity key, signed pre-key, and one available one-time pre-key
  Future<Map<String, dynamic>> getKeysForSession(String sessionId) async {
    final response = await ApiService.get(
      '/api/meetings/external/keys/$sessionId',
    );
    return response.data as Map<String, dynamic>;
  }
}
