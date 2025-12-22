import 'dart:async';
import 'package:flutter/foundation.dart';
import 'storage_interface.dart';
import 'chunking_service.dart';
import 'encryption_service.dart';

/// Download Manager with Pause/Resume Support
///
/// Features:
/// - Multi-chunk parallel downloads
/// - Pause/Resume functionality
/// - Progress tracking per file and chunk
/// - Automatic retry on failure
/// - Multi-source downloads (multiple seeders)
/// - Bandwidth throttling (optional)
class DownloadManager extends ChangeNotifier {
  final FileStorageInterface storage;
  final ChunkingService chunkingService;
  final EncryptionService encryptionService;

  // Active downloads: fileId -> DownloadTask
  final Map<String, DownloadTask> _downloads = {};

  // Download queue (pending downloads)
  final List<String> _queue = [];

  // Max parallel downloads
  int maxParallelDownloads = 3;

  // Max parallel chunks per file
  int maxParallelChunks = 4;

  // Retry settings
  int maxRetries = 3;
  Duration retryDelay = const Duration(seconds: 5);

  DownloadManager({
    required this.storage,
    required this.chunkingService,
    required this.encryptionService,
  });

  /// Start a new download
  ///
  /// Returns download task or null if already downloading
  Future<DownloadTask?> startDownload({
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required Uint8List fileKey,
    required Map<String, List<int>> seederChunks, // userId -> available chunks
    List<String>? sharedWith, // ✅ NEW: Add sharedWith parameter
  }) async {
    // Check if already downloading
    if (_downloads.containsKey(fileId)) {
      return _downloads[fileId];
    }

    // Save file metadata
    await storage.saveFileMetadata({
      'fileId': fileId,
      'fileName': fileName,
      'mimeType': mimeType,
      'fileSize': fileSize,
      'checksum': checksum,
      'chunkCount': chunkCount,
      'status': 'downloading',
      'isSeeder': false,
      'createdAt': DateTime.now().toIso8601String(),
      'lastActivity': DateTime.now().toIso8601String(),
      'sharedWith': sharedWith ?? [], // ✅ NEW: Save sharedWith
    });

    // Save encryption key
    await storage.saveFileKey(fileId, fileKey);

    // Create download task
    final task = DownloadTask(
      fileId: fileId,
      fileName: fileName,
      fileSize: fileSize,
      checksum: checksum,
      chunkCount: chunkCount,
      seederChunks: seederChunks,
    );

    _downloads[fileId] = task;

    // Check which chunks we already have (resume)
    final availableChunks = await storage.getAvailableChunks(fileId);
    task.completedChunks.addAll(availableChunks);
    task.downloadedChunks = availableChunks.length;

    // Start download if under parallel limit
    if (_activeDownloadCount() < maxParallelDownloads) {
      _startDownloadTask(fileId);
    } else {
      // Add to queue
      _queue.add(fileId);
      task.status = DownloadStatus.queued;
    }

    notifyListeners();
    return task;
  }

  /// Pause a download
  Future<void> pauseDownload(String fileId) async {
    final task = _downloads[fileId];
    if (task == null || task.status != DownloadStatus.downloading) {
      return;
    }

    task.status = DownloadStatus.paused;
    task._cancelToken?.cancel();

    // Update metadata
    await storage.updateFileMetadata(fileId, {
      'status': 'paused',
      'lastActivity': DateTime.now().toIso8601String(),
    });

    notifyListeners();
  }

  /// Resume a paused download
  Future<void> resumeDownload(String fileId) async {
    final task = _downloads[fileId];
    if (task == null || task.status != DownloadStatus.paused) {
      return;
    }

    if (_activeDownloadCount() < maxParallelDownloads) {
      _startDownloadTask(fileId);
    } else {
      // Add to queue
      _queue.add(fileId);
      task.status = DownloadStatus.queued;
    }

    notifyListeners();
  }

  /// Cancel a download and delete partial data
  Future<void> cancelDownload(String fileId) async {
    final task = _downloads[fileId];
    if (task == null) return;

    task.status = DownloadStatus.cancelled;
    task._cancelToken?.cancel();

    // Remove from queue
    _queue.remove(fileId);

    // Delete file data
    await storage.deleteFile(fileId);

    _downloads.remove(fileId);
    notifyListeners();
  }

  /// Get download progress for a file
  DownloadTask? getDownload(String fileId) {
    return _downloads[fileId];
  }

  /// Get all active downloads
  List<DownloadTask> getAllDownloads() {
    return _downloads.values.toList();
  }

  /// Update seeder availability (when new seeders join)
  void updateSeeders(String fileId, Map<String, List<int>> seederChunks) {
    final task = _downloads[fileId];
    if (task != null) {
      task.seederChunks = seederChunks;
      notifyListeners();
    }
  }

  // ============================================
  // PRIVATE METHODS
  // ============================================

  int _activeDownloadCount() {
    return _downloads.values
        .where((t) => t.status == DownloadStatus.downloading)
        .length;
  }

  void _startDownloadTask(String fileId) async {
    final task = _downloads[fileId];
    if (task == null) return;

    task.status = DownloadStatus.downloading;
    task._cancelToken = _CancelToken();
    task.startTime = DateTime.now();

    await storage.updateFileMetadata(fileId, {
      'status': 'downloading',
      'lastActivity': DateTime.now().toIso8601String(),
    });

    notifyListeners();

    try {
      // Download all missing chunks
      await _downloadChunks(fileId, task);

      // Verify and assemble file
      await _verifyAndComplete(fileId, task);
    } catch (e) {
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      notifyListeners();
    }

    // Start next queued download
    _startNextInQueue();
  }

  Future<void> _downloadChunks(String fileId, DownloadTask task) async {
    final missingChunks = <int>[];

    // Find which chunks we need
    for (int i = 0; i < task.chunkCount; i++) {
      if (!task.completedChunks.contains(i)) {
        missingChunks.add(i);
      }
    }

    if (missingChunks.isEmpty) {
      // Already have all chunks (resume case)
      return;
    }

    // Download chunks in batches (parallel)
    for (int i = 0; i < missingChunks.length; i += maxParallelChunks) {
      if (task._cancelToken?.isCancelled ?? false) {
        throw Exception('Download cancelled');
      }

      final batch = missingChunks.skip(i).take(maxParallelChunks).toList();

      // Download batch in parallel
      await Future.wait(
        batch.map((chunkIndex) => _downloadChunk(fileId, chunkIndex, task)),
      );

      notifyListeners();
    }
  }

  Future<void> _downloadChunk(
    String fileId,
    int chunkIndex,
    DownloadTask task,
  ) async {
    int retries = 0;

    while (retries < maxRetries) {
      if (task._cancelToken?.isCancelled ?? false) {
        throw Exception('Download cancelled');
      }

      try {
        // Find a seeder with this chunk
        final seeder = _findSeederForChunk(task.seederChunks, chunkIndex);
        if (seeder == null) {
          throw Exception('No seeder available for chunk $chunkIndex');
        }

        // Request chunk from seeder (via WebRTC or similar)
        // NOTE: This is a placeholder - actual implementation needs WebRTC DataChannel
        final encryptedChunk = await _requestChunkFromPeer(
          seeder,
          fileId,
          chunkIndex,
        );

        if (encryptedChunk == null) {
          throw Exception('Failed to receive chunk $chunkIndex from $seeder');
        }

        // Get encryption key
        final fileKey = await storage.getFileKey(fileId);
        if (fileKey == null) {
          throw Exception('File key not found');
        }

        // Get chunk metadata (contains IV)
        final metadata = await storage.getChunkMetadata(fileId, chunkIndex);
        if (metadata == null) {
          throw Exception('Chunk metadata not found');
        }

        final iv = Uint8List.fromList(
          (metadata['iv'] as String).codeUnits,
        ); // Simplified - should use base64

        // Decrypt chunk
        final decryptedChunk = await encryptionService.decryptChunk(
          encryptedChunk,
          fileKey,
          iv,
        );

        if (decryptedChunk == null) {
          throw Exception('Failed to decrypt chunk $chunkIndex');
        }

        // Verify chunk hash
        final chunkHash = chunkingService.calculateFileChecksum(decryptedChunk);
        if (chunkHash != metadata['chunkHash']) {
          throw Exception('Chunk hash mismatch for chunk $chunkIndex');
        }

        // Save chunk
        await storage.saveChunk(
          fileId,
          chunkIndex,
          encryptedChunk,
          iv: iv,
          chunkHash: chunkHash,
        );

        // Update progress
        task.completedChunks.add(chunkIndex);
        task.downloadedChunks++;
        task.downloadedBytes += decryptedChunk.length;

        return; // Success
      } catch (e) {
        retries++;
        if (retries >= maxRetries) {
          throw Exception(
            'Failed to download chunk $chunkIndex after $maxRetries attempts: $e',
          );
        }

        // Wait before retry
        await Future.delayed(retryDelay);
      }
    }
  }

  String? _findSeederForChunk(
    Map<String, List<int>> seederChunks,
    int chunkIndex,
  ) {
    // Find seeder with this chunk (prefer seeders with fewer connections)
    for (final entry in seederChunks.entries) {
      if (entry.value.contains(chunkIndex)) {
        return entry.key;
      }
    }
    return null;
  }

  Future<Uint8List?> _requestChunkFromPeer(
    String peerId,
    String fileId,
    int chunkIndex,
  ) async {
    // TODO: Implement WebRTC DataChannel request
    // This should:
    // 1. Establish WebRTC connection to peer
    // 2. Send chunk request message
    // 3. Receive encrypted chunk data
    // 4. Return chunk data

    // Placeholder implementation
    throw UnimplementedError('WebRTC chunk transfer not implemented yet');
  }

  Future<void> _verifyAndComplete(String fileId, DownloadTask task) async {
    task.status = DownloadStatus.verifying;
    notifyListeners();

    // Get all chunks
    final chunks = <ChunkData>[];
    for (int i = 0; i < task.chunkCount; i++) {
      final encryptedChunk = await storage.getChunk(fileId, i);
      final metadata = await storage.getChunkMetadata(fileId, i);

      if (encryptedChunk == null || metadata == null) {
        throw Exception('Missing chunk $i');
      }

      // Get file key and decrypt
      final fileKey = await storage.getFileKey(fileId);
      if (fileKey == null) throw Exception('File key not found');

      final iv = Uint8List.fromList(
        (metadata['iv'] as String).codeUnits,
      ); // Simplified

      final decryptedChunk = await encryptionService.decryptChunk(
        encryptedChunk,
        fileKey,
        iv,
      );

      if (decryptedChunk == null) {
        throw Exception('Failed to decrypt chunk $i');
      }

      chunks.add(
        ChunkData(
          chunkIndex: i,
          data: decryptedChunk,
          hash: metadata['chunkHash'] as String,
          size: decryptedChunk.length,
        ),
      );
    }

    // Assemble file
    final fileData = await chunkingService.assembleChunks(chunks);
    if (fileData == null) {
      throw Exception('Failed to assemble file - hash verification failed');
    }

    // Verify final checksum
    final fileChecksum = chunkingService.calculateFileChecksum(fileData);
    if (fileChecksum != task.checksum) {
      throw Exception('File checksum mismatch');
    }

    // Update status
    task.status = DownloadStatus.completed;
    task.endTime = DateTime.now();

    // ========================================
    // FIX: Set status to 'seeding' not 'completed'
    // ========================================
    // After successful download, user becomes a seeder
    // Note: file_transfer_service.dart will handle the announce to network
    await storage.updateFileMetadata(fileId, {
      'status': 'seeding', // ✅ Changed from 'completed' to 'seeding'
      'isSeeder': true, // ✅ Mark as seeder
      'downloadComplete': true, // ✅ Mark download as complete
      'lastActivity': DateTime.now().toIso8601String(),
    });

    debugPrint('[DOWNLOAD] ✓ Download complete, status set to seeding');

    notifyListeners();
  }

  void _startNextInQueue() {
    if (_queue.isEmpty) return;
    if (_activeDownloadCount() >= maxParallelDownloads) return;

    final nextFileId = _queue.removeAt(0);
    _startDownloadTask(nextFileId);
  }
}

/// Download status enum
enum DownloadStatus {
  queued,
  downloading,
  paused,
  verifying,
  completed,
  failed,
  cancelled,
}

/// Download task tracking
class DownloadTask {
  final String fileId;
  final String fileName;
  final int fileSize;
  final String checksum;
  final int chunkCount;

  DownloadStatus status = DownloadStatus.queued;

  // Seeder availability: userId -> available chunks
  Map<String, List<int>> seederChunks;

  // Progress
  Set<int> completedChunks = {};
  int downloadedChunks = 0;
  int downloadedBytes = 0;

  // Timing
  DateTime? startTime;
  DateTime? endTime;

  // Error handling
  String? error;
  _CancelToken? _cancelToken;

  DownloadTask({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.checksum,
    required this.chunkCount,
    required this.seederChunks,
  });

  /// Progress percentage (0-100)
  double get progress =>
      chunkCount > 0 ? (downloadedChunks / chunkCount) * 100 : 0;

  /// Download speed (bytes per second)
  double get speed {
    if (startTime == null || status != DownloadStatus.downloading) return 0;
    final elapsed = DateTime.now().difference(startTime!).inSeconds;
    return elapsed > 0 ? downloadedBytes / elapsed : 0;
  }

  /// Estimated time remaining
  Duration? get estimatedTimeRemaining {
    if (speed == 0) return null;
    final remaining = fileSize - downloadedBytes;
    return Duration(seconds: (remaining / speed).ceil());
  }

  /// Human-readable status
  String get statusText {
    switch (status) {
      case DownloadStatus.queued:
        return 'Queued';
      case DownloadStatus.downloading:
        return 'Downloading';
      case DownloadStatus.paused:
        return 'Paused';
      case DownloadStatus.verifying:
        return 'Verifying';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.cancelled:
        return 'Cancelled';
    }
  }
}

/// Simple cancel token for interrupting downloads
class _CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}
