/// External participant session model
/// Represents a guest user session for external meeting participants
class ExternalSession {
  final String sessionId;
  final String meetingId;
  final String displayName;
  final String admissionStatus; // 'waiting', 'admitted', 'declined'
  final String? admittedBy;
  final DateTime? admittedAt;
  final String? e2eeIdentityKey;
  final String? e2eeSignedPreKey;
  final String? e2eePreKeySignature;
  final DateTime expiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  ExternalSession({
    required this.sessionId,
    required this.meetingId,
    required this.displayName,
    required this.admissionStatus,
    this.admittedBy,
    this.admittedAt,
    this.e2eeIdentityKey,
    this.e2eeSignedPreKey,
    this.e2eePreKeySignature,
    required this.expiresAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ExternalSession.fromJson(Map<String, dynamic> json) {
    return ExternalSession(
      sessionId: json['session_id'] as String? ?? '',
      meetingId: json['meeting_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? 'Guest',
      admissionStatus: json['admission_status'] as String? ?? 'waiting',
      admittedBy: json['admitted_by'] as String?,
      admittedAt: json['admitted_at'] != null
          ? DateTime.tryParse(json['admitted_at'] as String)
          : null,
      e2eeIdentityKey: json['e2ee_identity_key'] as String?,
      e2eeSignedPreKey: json['e2ee_signed_pre_key'] as String?,
      e2eePreKeySignature: json['e2ee_pre_key_signature'] as String?,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String) ??
                DateTime.now().add(const Duration(hours: 24))
          : DateTime.now().add(const Duration(hours: 24)),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'meeting_id': meetingId,
      'display_name': displayName,
      'admission_status': admissionStatus,
      'admitted_by': admittedBy,
      'admitted_at': admittedAt?.toIso8601String(),
      'e2ee_identity_key': e2eeIdentityKey,
      'e2ee_signed_pre_key': e2eeSignedPreKey,
      'e2ee_pre_key_signature': e2eePreKeySignature,
      'expires_at': expiresAt.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  ExternalSession copyWith({
    String? sessionId,
    String? meetingId,
    String? displayName,
    String? admissionStatus,
    String? admittedBy,
    DateTime? admittedAt,
    String? e2eeIdentityKey,
    String? e2eeSignedPreKey,
    String? e2eePreKeySignature,
    DateTime? expiresAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ExternalSession(
      sessionId: sessionId ?? this.sessionId,
      meetingId: meetingId ?? this.meetingId,
      displayName: displayName ?? this.displayName,
      admissionStatus: admissionStatus ?? this.admissionStatus,
      admittedBy: admittedBy ?? this.admittedBy,
      admittedAt: admittedAt ?? this.admittedAt,
      e2eeIdentityKey: e2eeIdentityKey ?? this.e2eeIdentityKey,
      e2eeSignedPreKey: e2eeSignedPreKey ?? this.e2eeSignedPreKey,
      e2eePreKeySignature: e2eePreKeySignature ?? this.e2eePreKeySignature,
      expiresAt: expiresAt ?? this.expiresAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  bool get isWaiting => admissionStatus == 'waiting';
  bool get isAdmitted => admissionStatus == 'admitted';
  bool get isDeclined => admissionStatus == 'declined';

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get hasE2EE =>
      e2eeIdentityKey != null &&
      e2eeSignedPreKey != null &&
      e2eePreKeySignature != null;

  @override
  String toString() {
    return 'ExternalSession(id: $sessionId, displayName: $displayName, status: $admissionStatus)';
  }
}
