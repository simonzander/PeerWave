/// Signal Protocol session metadata
///
/// Tracks session state and statistics for debugging and monitoring.
/// Used to identify stale sessions that need refreshing.
class SessionInfo {
  final String userId;
  final int deviceId;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final int messagesSent;
  final int messagesReceived;
  final SessionState state;
  final String? lastError;

  SessionInfo({
    required this.userId,
    required this.deviceId,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    this.messagesSent = 0,
    this.messagesReceived = 0,
    this.state = SessionState.active,
    this.lastError,
  }) : createdAt = createdAt ?? DateTime.now(),
       lastUsedAt = lastUsedAt ?? DateTime.now();

  /// Get session identifier
  String get sessionId => '$userId:$deviceId';

  /// Check if session is stale (not used recently)
  bool get isStale {
    final daysSinceLastUse = DateTime.now().difference(lastUsedAt).inDays;
    return daysSinceLastUse > 30;
  }

  /// Check if session is active and healthy
  bool get isHealthy => state == SessionState.active && lastError == null;

  /// Create from storage data
  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastUsedAt: DateTime.parse(json['lastUsedAt'] as String),
      messagesSent: json['messagesSent'] as int? ?? 0,
      messagesReceived: json['messagesReceived'] as int? ?? 0,
      state: _stateFromString(json['state'] as String?),
      lastError: json['lastError'] as String?,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'deviceId': deviceId,
      'createdAt': createdAt.toIso8601String(),
      'lastUsedAt': lastUsedAt.toIso8601String(),
      'messagesSent': messagesSent,
      'messagesReceived': messagesReceived,
      'state': state.toString().split('.').last,
      if (lastError != null) 'lastError': lastError,
    };
  }

  /// Create a copy with updated fields
  SessionInfo copyWith({
    String? userId,
    int? deviceId,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    int? messagesSent,
    int? messagesReceived,
    SessionState? state,
    String? lastError,
  }) {
    return SessionInfo(
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt ?? this.createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      messagesSent: messagesSent ?? this.messagesSent,
      messagesReceived: messagesReceived ?? this.messagesReceived,
      state: state ?? this.state,
      lastError: lastError ?? this.lastError,
    );
  }

  /// Update last used timestamp
  SessionInfo markUsed() {
    return copyWith(lastUsedAt: DateTime.now());
  }

  /// Increment message counters
  SessionInfo incrementSent() {
    return copyWith(messagesSent: messagesSent + 1, lastUsedAt: DateTime.now());
  }

  SessionInfo incrementReceived() {
    return copyWith(
      messagesReceived: messagesReceived + 1,
      lastUsedAt: DateTime.now(),
    );
  }

  static SessionState _stateFromString(String? state) {
    switch (state) {
      case 'active':
        return SessionState.active;
      case 'stale':
        return SessionState.stale;
      case 'corrupted':
        return SessionState.corrupted;
      case 'deleted':
        return SessionState.deleted;
      default:
        return SessionState.active;
    }
  }

  @override
  String toString() {
    return 'SessionInfo(sessionId: $sessionId, state: $state, '
        'messages: $messagesSent sent / $messagesReceived received)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionInfo && other.sessionId == sessionId;
  }

  @override
  int get hashCode => sessionId.hashCode;
}

/// Session state
enum SessionState {
  /// Session is active and usable
  active,

  /// Session hasn't been used recently
  stale,

  /// Session is corrupted and needs rebuilding
  corrupted,

  /// Session was deleted
  deleted,
}
