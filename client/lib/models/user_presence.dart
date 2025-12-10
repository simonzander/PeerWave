/// User presence model
/// Tracks online/offline status of users
class UserPresence {
  final String userId;
  final DateTime lastHeartbeat;
  final DateTime createdAt;
  final DateTime updatedAt;

  UserPresence({
    required this.userId,
    required this.lastHeartbeat,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserPresence.fromJson(Map<String, dynamic> json) {
    return UserPresence(
      userId: json['user_id'] as String,
      lastHeartbeat: DateTime.parse(json['last_heartbeat'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'last_heartbeat': lastHeartbeat.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  /// Returns true if user is considered online (heartbeat within last 90 seconds)
  bool get isOnline {
    final now = DateTime.now();
    final diff = now.difference(lastHeartbeat);
    return diff.inSeconds <= 90;
  }

  /// Returns the last seen time for display
  String get lastSeenDisplay {
    if (isOnline) return 'Online';
    
    final now = DateTime.now();
    final diff = now.difference(lastHeartbeat);
    
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return 'Offline';
  }

  UserPresence copyWith({
    String? userId,
    DateTime? lastHeartbeat,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return UserPresence(
      userId: userId ?? this.userId,
      lastHeartbeat: lastHeartbeat ?? this.lastHeartbeat,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() {
    return 'UserPresence(userId: $userId, isOnline: $isOnline, lastHeartbeat: $lastHeartbeat)';
  }
}
