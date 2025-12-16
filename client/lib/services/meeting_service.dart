import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/meeting.dart';
import '../models/meeting_participant.dart';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';

/// Meeting service - handles HTTP API calls and Socket.IO real-time notifications
///
/// Use HTTP routes for:
/// - Creating meetings (POST /api/meetings)
/// - Updating meetings (PATCH /api/meetings/:id)
/// - Deleting meetings (DELETE /api/meetings/:id)
/// - Adding/removing participants
/// - Generating invitation links
///
/// Use Socket.IO listeners for real-time notifications:
/// - meeting:created
/// - meeting:updated
/// - meeting:started
/// - meeting:participant_joined
/// - meeting:participant_left
/// - meeting:first_participant_joined
class MeetingService {
  static final MeetingService _instance = MeetingService._internal();
  factory MeetingService() => _instance;
  MeetingService._internal();

  final _socketService = SocketService();

  // Stream controllers for real-time updates
  final _meetingCreatedController = StreamController<Meeting>.broadcast();
  final _meetingUpdatedController = StreamController<Meeting>.broadcast();
  final _meetingStartedController = StreamController<String>.broadcast();
  final _meetingCancelledController = StreamController<String>.broadcast();
  final _participantJoinedController =
      StreamController<MeetingParticipant>.broadcast();
  final _participantLeftController =
      StreamController<Map<String, String>>.broadcast();
  final _firstParticipantJoinedController =
      StreamController<String>.broadcast();

  // Public streams
  Stream<Meeting> get onMeetingCreated => _meetingCreatedController.stream;
  Stream<Meeting> get onMeetingUpdated => _meetingUpdatedController.stream;
  Stream<String> get onMeetingStarted => _meetingStartedController.stream;
  Stream<String> get onMeetingCancelled => _meetingCancelledController.stream;
  Stream<MeetingParticipant> get onParticipantJoined =>
      _participantJoinedController.stream;
  Stream<Map<String, String>> get onParticipantLeft =>
      _participantLeftController.stream;
  Stream<String> get onFirstParticipantJoined =>
      _firstParticipantJoinedController.stream;

  bool _listenersRegistered = false;

  /// Initialize Socket.IO listeners for real-time notifications
  void initializeListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    _socketService.registerListener('meeting:created', (data) {
      debugPrint('[MEETING SERVICE] Received meeting:created: $data');
      try {
        final meeting = Meeting.fromJson(data as Map<String, dynamic>);
        _meetingCreatedController.add(meeting);
      } catch (e) {
        debugPrint('[MEETING SERVICE] Error parsing meeting:created: $e');
      }
    });

    _socketService.registerListener('meeting:updated', (data) {
      debugPrint('[MEETING SERVICE] Received meeting:updated: $data');
      try {
        final meeting = Meeting.fromJson(data as Map<String, dynamic>);
        _meetingUpdatedController.add(meeting);
      } catch (e) {
        debugPrint('[MEETING SERVICE] Error parsing meeting:updated: $e');
      }
    });

    _socketService.registerListener('meeting:started', (data) {
      debugPrint('[MEETING SERVICE] Received meeting:started: $data');
      try {
        final meetingId =
            (data as Map<String, dynamic>)['meeting_id'] as String;
        _meetingStartedController.add(meetingId);
      } catch (e) {
        debugPrint('[MEETING SERVICE] Error parsing meeting:started: $e');
      }
    });

    _socketService.registerListener('meeting:cancelled', (data) {
      debugPrint('[MEETING SERVICE] Received meeting:cancelled: $data');
      try {
        final meetingId =
            (data as Map<String, dynamic>)['meeting_id'] as String;
        _meetingCancelledController.add(meetingId);
      } catch (e) {
        debugPrint('[MEETING SERVICE] Error parsing meeting:cancelled: $e');
      }
    });

    _socketService.registerListener('meeting:participant_joined', (data) {
      debugPrint(
        '[MEETING SERVICE] Received meeting:participant_joined: $data',
      );
      try {
        final participant = MeetingParticipant.fromJson(
          data as Map<String, dynamic>,
        );
        _participantJoinedController.add(participant);
      } catch (e) {
        debugPrint(
          '[MEETING SERVICE] Error parsing meeting:participant_joined: $e',
        );
      }
    });

    _socketService.registerListener('meeting:participant_left', (data) {
      debugPrint('[MEETING SERVICE] Received meeting:participant_left: $data');
      try {
        final map = data as Map<String, dynamic>;
        _participantLeftController.add({
          'meeting_id': map['meeting_id'] as String,
          'user_id': map['user_id'] as String,
        });
      } catch (e) {
        debugPrint(
          '[MEETING SERVICE] Error parsing meeting:participant_left: $e',
        );
      }
    });

    _socketService.registerListener('meeting:first_participant_joined', (data) {
      debugPrint(
        '[MEETING SERVICE] Received meeting:first_participant_joined: $data',
      );
      try {
        final meetingId =
            (data as Map<String, dynamic>)['meeting_id'] as String;
        _firstParticipantJoinedController.add(meetingId);
      } catch (e) {
        debugPrint(
          '[MEETING SERVICE] Error parsing meeting:first_participant_joined: $e',
        );
      }
    });

    debugPrint('[MEETING SERVICE] Socket.IO listeners initialized');
  }

  /// Dispose resources
  void dispose() {
    _meetingCreatedController.close();
    _meetingUpdatedController.close();
    _meetingStartedController.close();
    _meetingCancelledController.close();
    _participantJoinedController.close();
    _participantLeftController.close();
    _firstParticipantJoinedController.close();
  }

  // ============================================================================
  // HTTP API Methods
  // ============================================================================

  /// Create a new meeting
  Future<Meeting> createMeeting({
    required String title,
    String? description,
    required DateTime startTime,
    required DateTime endTime,
    bool allowExternal = false,
    bool voiceOnly = false,
    bool muteOnJoin = false,
    List<String>? participantIds,
    List<String>? emailInvitations,
  }) async {
    final response = await ApiService.post(
      '/api/meetings',
      data: {
        'title': title,
        'description': description,
        'start_time': startTime.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'allow_external': allowExternal,
        'voice_only': voiceOnly,
        'mute_on_join': muteOnJoin,
        'participant_ids': participantIds,
        'email_invitations': emailInvitations,
      },
    );

    return Meeting.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get all meetings
  Future<List<Meeting>> getMeetings({
    String? status,
    bool? isInstantCall,
    String? channelId,
  }) async {
    final queryParams = <String, dynamic>{};
    if (status != null) queryParams['status'] = status;
    if (isInstantCall != null) queryParams['is_instant_call'] = isInstantCall;
    if (channelId != null) queryParams['channel_id'] = channelId;

    final response = await ApiService.get(
      '/api/meetings',
      queryParameters: queryParams,
    );
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => Meeting.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get upcoming meetings
  Future<List<Meeting>> getUpcomingMeetings() async {
    final response = await ApiService.get('/api/meetings/upcoming');
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => Meeting.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get past meetings
  Future<List<Meeting>> getPastMeetings() async {
    final response = await ApiService.get('/api/meetings/past');
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => Meeting.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get user's meetings (where user is participant)
  Future<List<Meeting>> getMyMeetings() async {
    final response = await ApiService.get('/api/meetings/my');
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => Meeting.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get a specific meeting by ID
  Future<Meeting> getMeeting(String meetingId) async {
    final response = await ApiService.get('/api/meetings/$meetingId');
    return Meeting.fromJson(response.data as Map<String, dynamic>);
  }

  /// Update a meeting
  Future<Meeting> updateMeeting(
    String meetingId, {
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    bool? allowExternal,
    bool? voiceOnly,
    bool? muteOnJoin,
    int? maxParticipants,
  }) async {
    final updates = <String, dynamic>{};
    if (title != null) updates['title'] = title;
    if (description != null) updates['description'] = description;
    if (startTime != null) updates['start_time'] = startTime.toIso8601String();
    if (endTime != null) updates['end_time'] = endTime.toIso8601String();
    if (allowExternal != null) updates['allow_external'] = allowExternal;
    if (voiceOnly != null) updates['voice_only'] = voiceOnly;
    if (muteOnJoin != null) updates['mute_on_join'] = muteOnJoin;
    if (maxParticipants != null) updates['max_participants'] = maxParticipants;

    final response = await ApiService.patch(
      '/api/meetings/$meetingId',
      data: updates,
    );
    return Meeting.fromJson(response.data as Map<String, dynamic>);
  }

  /// Delete a meeting
  Future<void> deleteMeeting(String meetingId) async {
    await ApiService.delete('/api/meetings/$meetingId');
  }

  /// Get participants for a meeting
  Future<List<MeetingParticipant>> getParticipants(String meetingId) async {
    final response = await ApiService.get(
      '/api/meetings/$meetingId/participants',
    );
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map(
          (json) => MeetingParticipant.fromJson(json as Map<String, dynamic>),
        )
        .toList();
  }

  /// Add a participant to a meeting
  Future<MeetingParticipant> addParticipant(
    String meetingId,
    String userId, {
    String role = 'meeting_member',
  }) async {
    final response = await ApiService.post(
      '/api/meetings/$meetingId/participants',
      data: {'user_id': userId, 'role': role},
    );
    return MeetingParticipant.fromJson(response.data as Map<String, dynamic>);
  }

  /// Remove a participant from a meeting
  Future<void> removeParticipant(String meetingId, String userId) async {
    await ApiService.delete('/api/meetings/$meetingId/participants/$userId');
  }

  /// Update participant status
  Future<MeetingParticipant> updateParticipantStatus(
    String meetingId,
    String userId,
    String status,
  ) async {
    final response = await ApiService.post(
      '/api/meetings/$meetingId/participants/$userId',
      data: {'status': status},
    );
    return MeetingParticipant.fromJson(response.data as Map<String, dynamic>);
  }

  /// Generate invitation link for external participants
  Future<Map<String, dynamic>> generateInvitationLink(
    String meetingId, {
    int expiresInHours = 24,
  }) async {
    final response = await ApiService.post(
      '/api/meetings/$meetingId/generate-link',
      data: {'expires_in_hours': expiresInHours},
    );
    return response.data as Map<String, dynamic>;
  }

  // ============================================================================
  // Socket.IO Methods (for real-time notifications only)
  // ============================================================================

  /// Leave meeting (emit real-time notification to other participants)
  void leaveMeeting(String meetingId) {
    _socketService.emit('meeting:leave', {'meeting_id': meetingId});
  }
}
