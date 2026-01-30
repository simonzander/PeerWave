import 'package:flutter/foundation.dart';

/// Observable state for background message synchronization
///
/// Tracks progress of:
/// - Pending message fetching from server
/// - Offline queue processing
/// - Batch message processing
///
/// Usage:
/// ```dart
/// final syncState = SyncState.instance;
/// syncState.addListener(() {
///   print('Syncing: ${syncState.isSyncing}');
///   print('Progress: ${syncState.processed}/${syncState.total}');
/// });
/// ```
class SyncState extends ChangeNotifier {
  static final SyncState instance = SyncState._();
  SyncState._();

  bool _isSyncing = false;
  int _totalMessages = 0;
  int _processedMessages = 0;
  String _statusText = 'Not syncing';
  SyncType? _syncType;
  DateTime? _lastSyncTime;
  String? _errorMessage;

  // Getters
  bool get isSyncing => _isSyncing;
  int get total => _totalMessages;
  int get processed => _processedMessages;
  String get statusText => _statusText;
  SyncType? get syncType => _syncType;
  DateTime? get lastSyncTime => _lastSyncTime;
  String? get errorMessage => _errorMessage;

  double get percentage {
    if (_totalMessages == 0) return 0.0;
    return (_processedMessages / _totalMessages * 100).clamp(0.0, 100.0);
  }

  int get remaining =>
      (_totalMessages - _processedMessages).clamp(0, _totalMessages);

  /// Start syncing
  void startSync({
    required int totalMessages,
    required SyncType syncType,
    String? statusText,
  }) {
    _isSyncing = true;
    _totalMessages = totalMessages;
    _processedMessages = 0;
    _syncType = syncType;
    _statusText = statusText ?? 'Syncing $totalMessages messages...';
    _errorMessage = null;
    notifyListeners();
  }

  /// Update sync progress
  void updateProgress(int processed, {String? statusText}) {
    _processedMessages = processed;
    if (statusText != null) {
      _statusText = statusText;
    }
    notifyListeners();
  }

  /// Increment processed count
  void incrementProcessed({String? statusText}) {
    _processedMessages++;
    if (statusText != null) {
      _statusText = statusText;
    }
    notifyListeners();
  }

  /// Complete sync
  void completeSync() {
    _isSyncing = false;
    _lastSyncTime = DateTime.now();
    _statusText = 'Sync complete';
    _syncType = null;
    notifyListeners();
  }

  /// Mark sync error
  void setError(String error) {
    _isSyncing = false;
    _errorMessage = error;
    _statusText = 'Sync error: $error';
    notifyListeners();
  }

  /// Reset sync state
  void reset() {
    _isSyncing = false;
    _totalMessages = 0;
    _processedMessages = 0;
    _statusText = 'Not syncing';
    _syncType = null;
    _errorMessage = null;
    // Keep lastSyncTime for reference
    notifyListeners();
  }

  /// Get human-readable status
  String get syncDescription {
    if (_isSyncing) {
      return '$statusText ($_processedMessages/$_totalMessages)';
    }
    if (_errorMessage != null) {
      return 'Error: $_errorMessage';
    }
    if (_lastSyncTime != null) {
      final duration = DateTime.now().difference(_lastSyncTime!);
      if (duration.inMinutes < 1) {
        return 'Synced just now';
      } else if (duration.inHours < 1) {
        return 'Synced ${duration.inMinutes}m ago';
      } else {
        return 'Synced ${duration.inHours}h ago';
      }
    }
    return 'Not synced yet';
  }
}

/// Type of sync operation
enum SyncType {
  /// Fetching pending messages from server
  pendingMessages,

  /// Processing offline message queue
  offlineQueue,

  /// Batch message processing
  batch,

  /// Background refresh
  backgroundRefresh,
}
