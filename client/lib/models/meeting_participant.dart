/// Meeting participant model
/// Represents a user participating in a meeting
class MeetingParticipant {
  final String participantId;
  final String meetingId;
  final String userId;
  final String role; // 'meeting_owner', 'meeting_manager', 'meeting_member'
  final String status; // 'invited', 'accepted', 'declined', 'attended', 'left'
  final DateTime? joinedAt;
  final DateTime? leftAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  MeetingParticipant({
    required this.participantId,
    required this.meetingId,
    required this.userId,
    required this.role,
    required this.status,
    this.joinedAt,
    this.leftAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MeetingParticipant.fromJson(Map<String, dynamic> json) {
    return MeetingParticipant(
      participantId: json['participant_id'] as String,
      meetingId: json['meeting_id'] as String,
      userId: json['user_id'] as String,
      role: json['role'] as String,
      status: json['status'] as String,
      joinedAt: json['joined_at'] != null
          ? DateTime.parse(json['joined_at'] as String)
          : null,
      leftAt: json['left_at'] != null
          ? DateTime.parse(json['left_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'participant_id': participantId,
      'meeting_id': meetingId,
      'user_id': userId,
      'role': role,
      'status': status,
      'joined_at': joinedAt?.toIso8601String(),
      'left_at': leftAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  MeetingParticipant copyWith({
    String? participantId,
    String? meetingId,
    String? userId,
    String? role,
    String? status,
    DateTime? joinedAt,
    DateTime? leftAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MeetingParticipant(
      participantId: participantId ?? this.participantId,
      meetingId: meetingId ?? this.meetingId,
      userId: userId ?? this.userId,
      role: role ?? this.role,
      status: status ?? this.status,
      joinedAt: joinedAt ?? this.joinedAt,
      leftAt: leftAt ?? this.leftAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get isOwner => role == 'meeting_owner';
  bool get isManager => role == 'meeting_manager';
  bool get isMember => role == 'meeting_member';
  
  bool get isInvited => status == 'invited';
  bool get hasAccepted => status == 'accepted';
  bool get hasDeclined => status == 'declined';
  bool get hasAttended => status == 'attended';
  bool get hasLeft => status == 'left';
  
  bool get isActive => hasAccepted || hasAttended;

  @override
  String toString() {
    return 'MeetingParticipant(id: $participantId, userId: $userId, role: $role, status: $status)';
  }
}
