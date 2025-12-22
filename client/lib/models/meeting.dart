/// Meeting model
/// Represents a scheduled meeting or instant call
class Meeting {
  final String meetingId;
  final String title;
  final String? description;
  final String createdBy;
  final DateTime? scheduledStart;
  final DateTime? scheduledEnd;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String status; // 'scheduled', 'in_progress', 'completed', 'cancelled'
  final bool isInstantCall;
  final String? channelId;
  final String? livekitRoom;
  final bool livekitRoomActive;
  final bool allowExternal;
  final String? invitationToken;
  final DateTime? invitationExpiresAt;
  final bool voiceOnly;
  final bool muteOnJoin;
  final int? maxParticipants;
  final int? participantCount; // Number of participants who have joined
  final List<String> invitedParticipants;
  final MeetingRsvpSummary? rsvpSummary;
  final Map<String, String>? invitedRsvpStatuses;
  final DateTime createdAt;
  final DateTime updatedAt;

  Meeting({
    required this.meetingId,
    required this.title,
    this.description,
    required this.createdBy,
    this.scheduledStart,
    this.scheduledEnd,
    this.startedAt,
    this.endedAt,
    required this.status,
    required this.isInstantCall,
    this.channelId,
    this.livekitRoom,
    this.livekitRoomActive = false,
    required this.allowExternal,
    this.invitationToken,
    this.invitationExpiresAt,
    required this.voiceOnly,
    required this.muteOnJoin,
    this.maxParticipants,
    this.participantCount,
    this.invitedParticipants = const [],
    this.rsvpSummary,
    this.invitedRsvpStatuses,
    required this.createdAt,
    required this.updatedAt,
  });

  static List<String> _parseInvitedParticipants(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return raw
          .map((e) => e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList();
    }
    return const [];
  }

  factory Meeting.fromJson(Map<String, dynamic> json) {
    final scheduledStartRaw = json['scheduled_start'] ?? json['start_time'];
    final scheduledEndRaw = json['scheduled_end'] ?? json['end_time'];

    return Meeting(
      meetingId: json['meeting_id'] as String,
      title: json['title'] as String,
      description: json['description'] as String?,
      createdBy: json['created_by'] as String,
      scheduledStart: scheduledStartRaw != null
          ? DateTime.parse(scheduledStartRaw as String)
          : null,
      scheduledEnd: scheduledEndRaw != null
          ? DateTime.parse(scheduledEndRaw as String)
          : null,
      startedAt: json['started_at'] != null
          ? DateTime.parse(json['started_at'] as String)
          : null,
      endedAt: json['ended_at'] != null
          ? DateTime.parse(json['ended_at'] as String)
          : null,
      status: json['status'] as String,
      isInstantCall:
          json['is_instant_call'] == 1 || json['is_instant_call'] == true,
      channelId: json['channel_id'] as String?,
      livekitRoom: json['livekit_room'] as String?,
      livekitRoomActive:
          json['livekit_room_active'] == 1 ||
          json['livekit_room_active'] == true,
      allowExternal:
          json['allow_external'] == 1 || json['allow_external'] == true,
      invitationToken: json['invitation_token'] as String?,
      invitationExpiresAt: json['invitation_expires_at'] != null
          ? DateTime.parse(json['invitation_expires_at'] as String)
          : null,
      voiceOnly: json['voice_only'] == 1 || json['voice_only'] == true,
      muteOnJoin: json['mute_on_join'] == 1 || json['mute_on_join'] == true,
      maxParticipants: json['max_participants'] as int?,
      participantCount: json['participant_count'] as int?,
      invitedParticipants: _parseInvitedParticipants(
        json['invited_participants'],
      ),
      rsvpSummary: json['rsvp_summary'] is Map
          ? MeetingRsvpSummary.fromJson(
              (json['rsvp_summary'] as Map).cast<String, dynamic>(),
            )
          : null,
      invitedRsvpStatuses: json['invited_rsvp_statuses'] is Map
          ? (json['invited_rsvp_statuses'] as Map).map(
              (k, v) => MapEntry(
                k.toString().toLowerCase(),
                v.toString().toLowerCase(),
              ),
            )
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'meeting_id': meetingId,
      'title': title,
      'description': description,
      'created_by': createdBy,
      'scheduled_start': scheduledStart?.toIso8601String(),
      'scheduled_end': scheduledEnd?.toIso8601String(),
      'started_at': startedAt?.toIso8601String(),
      'ended_at': endedAt?.toIso8601String(),
      'status': status,
      'is_instant_call': isInstantCall,
      'channel_id': channelId,
      'livekit_room': livekitRoom,
      'livekit_room_active': livekitRoomActive,
      'allow_external': allowExternal,
      'invitation_token': invitationToken,
      'invitation_expires_at': invitationExpiresAt?.toIso8601String(),
      'voice_only': voiceOnly,
      'mute_on_join': muteOnJoin,
      'max_participants': maxParticipants,
      'participant_count': participantCount,
      'invited_participants': invitedParticipants,
      'rsvp_summary': rsvpSummary?.toJson(),
      'invited_rsvp_statuses': invitedRsvpStatuses,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Meeting copyWith({
    String? meetingId,
    String? title,
    String? description,
    String? createdBy,
    DateTime? scheduledStart,
    DateTime? scheduledEnd,
    DateTime? startedAt,
    DateTime? endedAt,
    String? status,
    bool? isInstantCall,
    String? channelId,
    String? livekitRoom,
    bool? livekitRoomActive,
    bool? allowExternal,
    String? invitationToken,
    DateTime? invitationExpiresAt,
    bool? voiceOnly,
    bool? muteOnJoin,
    int? maxParticipants,
    int? participantCount,
    List<String>? invitedParticipants,
    MeetingRsvpSummary? rsvpSummary,
    Map<String, String>? invitedRsvpStatuses,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Meeting(
      meetingId: meetingId ?? this.meetingId,
      title: title ?? this.title,
      description: description ?? this.description,
      createdBy: createdBy ?? this.createdBy,
      scheduledStart: scheduledStart ?? this.scheduledStart,
      scheduledEnd: scheduledEnd ?? this.scheduledEnd,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      status: status ?? this.status,
      isInstantCall: isInstantCall ?? this.isInstantCall,
      channelId: channelId ?? this.channelId,
      livekitRoom: livekitRoom ?? this.livekitRoom,
      livekitRoomActive: livekitRoomActive ?? this.livekitRoomActive,
      allowExternal: allowExternal ?? this.allowExternal,
      invitationToken: invitationToken ?? this.invitationToken,
      invitationExpiresAt: invitationExpiresAt ?? this.invitationExpiresAt,
      voiceOnly: voiceOnly ?? this.voiceOnly,
      muteOnJoin: muteOnJoin ?? this.muteOnJoin,
      maxParticipants: maxParticipants ?? this.maxParticipants,
      participantCount: participantCount ?? this.participantCount,
      invitedParticipants: invitedParticipants ?? this.invitedParticipants,
      rsvpSummary: rsvpSummary ?? this.rsvpSummary,
      invitedRsvpStatuses: invitedRsvpStatuses ?? this.invitedRsvpStatuses,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get isActive => status == 'in_progress';
  bool get isScheduled => status == 'scheduled';
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'cancelled';

  /// Returns true if meeting has started or will start soon (within 15 minutes)
  bool get isJoinable {
    if (isActive) return true;
    if (scheduledStart == null) return false;
    final now = DateTime.now();
    final diff = scheduledStart!.difference(now);
    return diff.inMinutes <= 15 && diff.inMinutes >= -5;
  }

  /// Returns time until meeting starts (for display)
  Duration? get timeUntilStart {
    if (scheduledStart == null) return null;
    return scheduledStart!.difference(DateTime.now());
  }

  @override
  String toString() {
    return 'Meeting(id: $meetingId, title: $title, status: $status, isInstantCall: $isInstantCall)';
  }
}

class MeetingRsvpSummary {
  final int invited;
  final int accepted;
  final int tentative;
  final int declined;

  const MeetingRsvpSummary({
    required this.invited,
    required this.accepted,
    required this.tentative,
    required this.declined,
  });

  factory MeetingRsvpSummary.fromJson(Map<String, dynamic> json) {
    return MeetingRsvpSummary(
      invited: (json['invited'] as num?)?.toInt() ?? 0,
      accepted: (json['accepted'] as num?)?.toInt() ?? 0,
      tentative: (json['tentative'] as num?)?.toInt() ?? 0,
      declined: (json['declined'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'invited': invited,
      'accepted': accepted,
      'tentative': tentative,
      'declined': declined,
    };
  }
}
