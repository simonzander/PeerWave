import 'dart:async';
import 'package:flutter/foundation.dart';

/// Transfer direction
enum TransferDirection {
  upload,
  download,
}

/// Active transfer information
class ActiveTransfer {
  final String fileId;
  final String fileName;
  final String peerId;
  final TransferDirection direction;
  final int bytesTransferred;
  final int totalBytes;
  final DateTime startTime;
  DateTime lastUpdate;
  double currentSpeed; // bytes per second
  
  ActiveTransfer({
    required this.fileId,
    required this.fileName,
    required this.peerId,
    required this.direction,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.startTime,
    DateTime? lastUpdate,
    this.currentSpeed = 0.0,
  }) : lastUpdate = lastUpdate ?? DateTime.now();
  
  double get progress => totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;
}

/// File-level transfer statistics
class FileTransferStats {
  final String fileId;
  final String fileName;
  
  // Upload stats
  int uploadBytesTransferred = 0;
  double uploadSpeed = 0.0; // bytes/sec
  Set<String> activeUploaders = {}; // peerIds currently downloading from us
  
  // Download stats
  int downloadBytesTransferred = 0;
  double downloadSpeed = 0.0; // bytes/sec
  Set<String> activeSeeders = {}; // peerIds we're downloading from
  
  FileTransferStats({
    required this.fileId,
    required this.fileName,
  });
}

/// Speed data point for graphing
class SpeedDataPoint {
  final DateTime timestamp;
  final double uploadSpeed; // bytes/sec
  final double downloadSpeed; // bytes/sec
  
  SpeedDataPoint({
    required this.timestamp,
    required this.uploadSpeed,
    required this.downloadSpeed,
  });
}

/// Provider for tracking file transfer statistics
class FileTransferStatsProvider extends ChangeNotifier {
  // Per-file statistics: fileId -> FileTransferStats
  final Map<String, FileTransferStats> _fileStats = {};
  
  // Active transfers: transferKey (fileId:peerId:direction) -> ActiveTransfer
  final Map<String, ActiveTransfer> _activeTransfers = {};
  
  // Speed history for graphs (last 60 data points = 60 seconds at 1Hz)
  final List<SpeedDataPoint> _speedHistory = [];
  static const int maxHistoryPoints = 60;
  
  // Global totals
  double _totalUploadSpeed = 0.0;
  double _totalDownloadSpeed = 0.0;
  
  // Timer for periodic speed calculation
  Timer? _updateTimer;
  
  // Byte counters for speed calculation
  final Map<String, int> _lastUploadBytes = {};
  final Map<String, int> _lastDownloadBytes = {};
  DateTime _lastUpdateTime = DateTime.now();
  
  FileTransferStatsProvider() {
    _startPeriodicUpdates();
  }
  
  // ============================================
  // GETTERS
  // ============================================
  
  /// Get all file statistics
  Map<String, FileTransferStats> get fileStats => Map.unmodifiable(_fileStats);
  
  /// Get statistics for a specific file
  FileTransferStats? getFileStats(String fileId) => _fileStats[fileId];
  
  /// Get all active transfers
  List<ActiveTransfer> get activeTransfers => _activeTransfers.values.toList();
  
  /// Get active uploads
  List<ActiveTransfer> get activeUploads => 
      _activeTransfers.values.where((t) => t.direction == TransferDirection.upload).toList();
  
  /// Get active downloads
  List<ActiveTransfer> get activeDownloads => 
      _activeTransfers.values.where((t) => t.direction == TransferDirection.download).toList();
  
  /// Global upload speed (bytes/sec)
  double get totalUploadSpeed => _totalUploadSpeed;
  
  /// Global download speed (bytes/sec)
  double get totalDownloadSpeed => _totalDownloadSpeed;
  
  /// Check if any uploads are active
  bool get isUploading => activeUploads.isNotEmpty;
  
  /// Check if any downloads are active
  bool get isDownloading => activeDownloads.isNotEmpty;
  
  /// Get speed history for graphs
  List<SpeedDataPoint> get speedHistory => List.unmodifiable(_speedHistory);
  
  // ============================================
  // UPDATE METHODS
  // ============================================
  
  /// Record upload progress
  void recordUpload({
    required String fileId,
    required String fileName,
    required String peerId,
    required int bytesTransferred,
    required int totalBytes,
  }) {
    final key = '$fileId:$peerId:upload';
    
    // Update or create active transfer
    if (_activeTransfers.containsKey(key)) {
      _activeTransfers[key]!.lastUpdate = DateTime.now();
    } else {
      _activeTransfers[key] = ActiveTransfer(
        fileId: fileId,
        fileName: fileName,
        peerId: peerId,
        direction: TransferDirection.upload,
        bytesTransferred: bytesTransferred,
        totalBytes: totalBytes,
        startTime: DateTime.now(),
      );
    }
    
    // Update file stats
    _fileStats.putIfAbsent(
      fileId,
      () => FileTransferStats(fileId: fileId, fileName: fileName),
    );
    _fileStats[fileId]!.uploadBytesTransferred = bytesTransferred;
    _fileStats[fileId]!.activeUploaders.add(peerId);
    
    notifyListeners();
  }
  
  /// Record download progress
  void recordDownload({
    required String fileId,
    required String fileName,
    required String peerId,
    required int bytesTransferred,
    required int totalBytes,
  }) {
    final key = '$fileId:$peerId:download';
    
    // Update or create active transfer
    if (_activeTransfers.containsKey(key)) {
      _activeTransfers[key]!.lastUpdate = DateTime.now();
    } else {
      _activeTransfers[key] = ActiveTransfer(
        fileId: fileId,
        fileName: fileName,
        peerId: peerId,
        direction: TransferDirection.download,
        bytesTransferred: bytesTransferred,
        totalBytes: totalBytes,
        startTime: DateTime.now(),
      );
    }
    
    // Update file stats
    _fileStats.putIfAbsent(
      fileId,
      () => FileTransferStats(fileId: fileId, fileName: fileName),
    );
    _fileStats[fileId]!.downloadBytesTransferred = bytesTransferred;
    _fileStats[fileId]!.activeSeeders.add(peerId);
    
    notifyListeners();
  }
  
  /// Mark transfer as completed
  void completeTransfer({
    required String fileId,
    required String peerId,
    required TransferDirection direction,
  }) {
    final key = '$fileId:$peerId:${direction.name}';
    _activeTransfers.remove(key);
    
    if (_fileStats.containsKey(fileId)) {
      if (direction == TransferDirection.upload) {
        _fileStats[fileId]!.activeUploaders.remove(peerId);
      } else {
        _fileStats[fileId]!.activeSeeders.remove(peerId);
      }
      
      // Clean up if no active transfers for this file
      if (_fileStats[fileId]!.activeUploaders.isEmpty &&
          _fileStats[fileId]!.activeSeeders.isEmpty) {
        _fileStats.remove(fileId);
      }
    }
    
    notifyListeners();
  }
  
  /// Clear all statistics
  void clearAll() {
    _fileStats.clear();
    _activeTransfers.clear();
    _speedHistory.clear();
    _totalUploadSpeed = 0.0;
    _totalDownloadSpeed = 0.0;
    notifyListeners();
  }
  
  // ============================================
  // PRIVATE METHODS
  // ============================================
  
  /// Start periodic speed calculations (every second)
  void _startPeriodicUpdates() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _calculateSpeeds();
    });
  }
  
  /// Calculate upload/download speeds
  void _calculateSpeeds() {
    final now = DateTime.now();
    final timeDelta = now.difference(_lastUpdateTime).inMilliseconds / 1000.0;
    
    if (timeDelta < 0.1) return; // Skip if too fast
    
    // Calculate upload speed
    int currentUploadBytes = 0;
    for (final stats in _fileStats.values) {
      currentUploadBytes += stats.uploadBytesTransferred;
    }
    
    final uploadBytesDelta = currentUploadBytes - (_lastUploadBytes['total'] ?? 0);
    _totalUploadSpeed = timeDelta > 0 ? uploadBytesDelta / timeDelta : 0.0;
    _lastUploadBytes['total'] = currentUploadBytes;
    
    // Calculate download speed
    int currentDownloadBytes = 0;
    for (final stats in _fileStats.values) {
      currentDownloadBytes += stats.downloadBytesTransferred;
    }
    
    final downloadBytesDelta = currentDownloadBytes - (_lastDownloadBytes['total'] ?? 0);
    _totalDownloadSpeed = timeDelta > 0 ? downloadBytesDelta / timeDelta : 0.0;
    _lastDownloadBytes['total'] = currentDownloadBytes;
    
    // Update per-file speeds
    for (final stats in _fileStats.values) {
      stats.uploadSpeed = _totalUploadSpeed; // Simplified for now
      stats.downloadSpeed = _totalDownloadSpeed;
    }
    
    // Add to history
    _speedHistory.add(SpeedDataPoint(
      timestamp: now,
      uploadSpeed: _totalUploadSpeed,
      downloadSpeed: _totalDownloadSpeed,
    ));
    
    // Trim history
    if (_speedHistory.length > maxHistoryPoints) {
      _speedHistory.removeAt(0);
    }
    
    _lastUpdateTime = now;
    
    // Clean up stale transfers (no activity for 5 seconds)
    final staleKeys = <String>[];
    for (final entry in _activeTransfers.entries) {
      if (now.difference(entry.value.lastUpdate).inSeconds > 5) {
        staleKeys.add(entry.key);
      }
    }
    for (final key in staleKeys) {
      _activeTransfers.remove(key);
    }
    
    notifyListeners();
  }
  
  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }
  
  // ============================================
  // UTILITY METHODS
  // ============================================
  
  /// Format bytes to human-readable string
  static String formatBytes(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  
  /// Format speed to human-readable string
  static String formatSpeed(double bytesPerSecond) {
    return '${formatBytes(bytesPerSecond)}/s';
  }
}
