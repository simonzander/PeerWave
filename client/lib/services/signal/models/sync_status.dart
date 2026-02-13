/// Message synchronization status tracking
///
/// Tracks progress of message sync operations for UI display.
/// Used during offline message recovery and background sync.
class SyncStatus {
  final String syncId;
  final SyncType type;
  final int totalItems;
  final int syncedItems;
  final int failedItems;
  final DateTime startedAt;
  final DateTime? completedAt;
  final SyncState state;
  final String? errorMessage;
  final Map<String, dynamic>? metadata;

  SyncStatus({
    required this.syncId,
    required this.type,
    required this.totalItems,
    this.syncedItems = 0,
    this.failedItems = 0,
    DateTime? startedAt,
    this.completedAt,
    this.state = SyncState.inProgress,
    this.errorMessage,
    this.metadata,
  }) : startedAt = startedAt ?? DateTime.now();

  /// Calculate sync progress percentage (0-100)
  double get progress {
    if (totalItems == 0) return 100.0;
    return ((syncedItems / totalItems) * 100).clamp(0.0, 100.0);
  }

  /// Get remaining items to sync
  int get remainingItems =>
      (totalItems - syncedItems - failedItems).clamp(0, totalItems);

  /// Check if sync is complete
  bool get isComplete => state == SyncState.completed;

  /// Check if sync has errors
  bool get hasErrors => failedItems > 0 || state == SyncState.failed;

  /// Get sync duration
  Duration get duration {
    final endTime = completedAt ?? DateTime.now();
    return endTime.difference(startedAt);
  }

  /// Create from storage data
  factory SyncStatus.fromJson(Map<String, dynamic> json) {
    return SyncStatus(
      syncId: json['syncId'] as String,
      type: _typeFromString(json['type'] as String),
      totalItems: json['totalItems'] as int,
      syncedItems: json['syncedItems'] as int? ?? 0,
      failedItems: json['failedItems'] as int? ?? 0,
      startedAt: DateTime.parse(json['startedAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      state: _stateFromString(json['state'] as String),
      errorMessage: json['errorMessage'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'syncId': syncId,
      'type': type.toString().split('.').last,
      'totalItems': totalItems,
      'syncedItems': syncedItems,
      'failedItems': failedItems,
      'startedAt': startedAt.toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
      'state': state.toString().split('.').last,
      if (errorMessage != null) 'errorMessage': errorMessage,
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// Create a copy with updated fields
  SyncStatus copyWith({
    String? syncId,
    SyncType? type,
    int? totalItems,
    int? syncedItems,
    int? failedItems,
    DateTime? startedAt,
    DateTime? completedAt,
    SyncState? state,
    String? errorMessage,
    Map<String, dynamic>? metadata,
  }) {
    return SyncStatus(
      syncId: syncId ?? this.syncId,
      type: type ?? this.type,
      totalItems: totalItems ?? this.totalItems,
      syncedItems: syncedItems ?? this.syncedItems,
      failedItems: failedItems ?? this.failedItems,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      state: state ?? this.state,
      errorMessage: errorMessage ?? this.errorMessage,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Increment synced count
  SyncStatus incrementSynced() {
    return copyWith(syncedItems: syncedItems + 1);
  }

  /// Increment failed count
  SyncStatus incrementFailed() {
    return copyWith(failedItems: failedItems + 1);
  }

  /// Mark sync as complete
  SyncStatus markComplete() {
    return copyWith(state: SyncState.completed, completedAt: DateTime.now());
  }

  /// Mark sync as failed
  SyncStatus markFailed(String error) {
    return copyWith(
      state: SyncState.failed,
      errorMessage: error,
      completedAt: DateTime.now(),
    );
  }

  static SyncType _typeFromString(String type) {
    switch (type) {
      case 'pendingMessages':
        return SyncType.pendingMessages;
      case 'offlineQueue':
        return SyncType.offlineQueue;
      case 'backgroundRefresh':
        return SyncType.backgroundRefresh;
      case 'keySync':
        return SyncType.keySync;
      default:
        return SyncType.pendingMessages;
    }
  }

  static SyncState _stateFromString(String state) {
    switch (state) {
      case 'inProgress':
        return SyncState.inProgress;
      case 'completed':
        return SyncState.completed;
      case 'failed':
        return SyncState.failed;
      case 'cancelled':
        return SyncState.cancelled;
      default:
        return SyncState.inProgress;
    }
  }

  @override
  String toString() {
    return 'SyncStatus(syncId: $syncId, type: $type, '
        'progress: ${progress.toStringAsFixed(1)}%, state: $state)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncStatus && other.syncId == syncId;
  }

  @override
  int get hashCode => syncId.hashCode;
}

/// Type of sync operation
enum SyncType {
  /// Syncing pending messages from server
  pendingMessages,

  /// Processing offline message queue
  offlineQueue,

  /// Background refresh of messages
  backgroundRefresh,

  /// Syncing encryption keys
  keySync,
}

/// State of sync operation
enum SyncState {
  /// Sync is currently in progress
  inProgress,

  /// Sync completed successfully
  completed,

  /// Sync failed with errors
  failed,

  /// Sync was cancelled by user
  cancelled,
}
