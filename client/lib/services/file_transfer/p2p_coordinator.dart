import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'webrtc_service.dart';
import 'download_manager.dart';
import 'storage_interface.dart';
import 'encryption_service.dart';

/// P2P Coordinator - Manages multi-source downloads
/// 
/// Coordinates WebRTC connections to multiple seeders and
/// distributes chunk requests across them for optimal download speed
class P2PCoordinator extends ChangeNotifier {
  final WebRTCFileService webrtcService;
  final DownloadManager downloadManager;
  final FileStorageInterface storage;
  final EncryptionService encryptionService;
  
  // Active connections per file: fileId -> Set<peerId>
  final Map<String, Set<String>> _fileConnections = {};
  
  // Chunk requests in progress: fileId -> Map<chunkIndex, peerId>
  final Map<String, Map<int, String>> _activeChunkRequests = {};
  
  // Seeder availability: fileId -> Map<peerId, List<chunkIndices>>
  final Map<String, Map<String, List<int>>> _seederAvailability = {};
  
  // Request queue: fileId -> List<chunkIndex>
  final Map<String, List<int>> _chunkQueue = {};
  
  // Connection limits
  int maxConnectionsPerFile = 4;
  int maxParallelChunksPerConnection = 2;
  
  P2PCoordinator({
    required this.webrtcService,
    required this.downloadManager,
    required this.storage,
    required this.encryptionService,
  }) {
    _setupWebRTCCallbacks();
  }
  
  /// Start downloading a file from available seeders
  Future<void> startDownload({
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required Uint8List fileKey,
    required Map<String, List<int>> seederChunks, // peerId -> chunks
  }) async {
    debugPrint('[P2P] Starting download: $fileName ($fileId)');
    debugPrint('[P2P] Available seeders: ${seederChunks.length}');
    
    // Store seeder availability
    _seederAvailability[fileId] = seederChunks;
    
    // Initialize file connections
    _fileConnections[fileId] = {};
    _activeChunkRequests[fileId] = {};
    
    // Start download in DownloadManager
    await downloadManager.startDownload(
      fileId: fileId,
      fileName: fileName,
      mimeType: mimeType,
      fileSize: fileSize,
      checksum: checksum,
      chunkCount: chunkCount,
      fileKey: fileKey,
      seederChunks: seederChunks,
    );
    
    // Build chunk queue (missing chunks)
    await _buildChunkQueue(fileId, chunkCount);
    
    // Connect to seeders
    await _connectToSeeders(fileId);
    
    notifyListeners();
  }
  
  /// Pause download (close connections but keep state)
  Future<void> pauseDownload(String fileId) async {
    debugPrint('[P2P] Pausing download: $fileId');
    
    // Disconnect all connections for this file
    final connections = _fileConnections[fileId] ?? {};
    for (final peerId in connections) {
      await webrtcService.closePeerConnection(peerId);
    }
    
    _fileConnections[fileId]?.clear();
    _activeChunkRequests[fileId]?.clear();
    
    await downloadManager.pauseDownload(fileId);
    notifyListeners();
  }
  
  /// Resume download (reconnect to seeders)
  Future<void> resumeDownload(String fileId) async {
    debugPrint('[P2P] Resuming download: $fileId');
    
    await downloadManager.resumeDownload(fileId);
    
    // Rebuild queue (in case new chunks were added while paused)
    final task = downloadManager.getDownload(fileId);
    if (task != null) {
      await _buildChunkQueue(fileId, task.chunkCount);
      await _connectToSeeders(fileId);
    }
    
    notifyListeners();
  }
  
  /// Cancel download and cleanup
  Future<void> cancelDownload(String fileId) async {
    debugPrint('[P2P] Cancelling download: $fileId');
    
    // Disconnect all connections
    final connections = _fileConnections[fileId] ?? {};
    for (final peerId in connections) {
      await webrtcService.closePeerConnection(peerId);
    }
    
    // Cleanup state
    _fileConnections.remove(fileId);
    _activeChunkRequests.remove(fileId);
    _seederAvailability.remove(fileId);
    _chunkQueue.remove(fileId);
    
    await downloadManager.cancelDownload(fileId);
    notifyListeners();
  }
  
  /// Update seeder availability (when new seeders join or chunks change)
  void updateSeederAvailability(String fileId, Map<String, List<int>> seederChunks) {
    debugPrint('[P2P] Updating seeder availability for $fileId: ${seederChunks.length} seeders');
    
    _seederAvailability[fileId] = seederChunks;
    downloadManager.updateSeeders(fileId, seederChunks);
    
    // Try to connect to new seeders if we have capacity
    _connectToSeeders(fileId);
    
    notifyListeners();
  }
  
  /// Get connection status for a file
  Map<String, dynamic> getConnectionStatus(String fileId) {
    final connections = _fileConnections[fileId] ?? {};
    final activeRequests = _activeChunkRequests[fileId] ?? {};
    final queueLength = _chunkQueue[fileId]?.length ?? 0;
    
    return {
      'connectedSeeders': connections.length,
      'activeRequests': activeRequests.length,
      'queuedChunks': queueLength,
      'connectedPeers': connections.toList(),
    };
  }
  
  // ============================================
  // PRIVATE METHODS
  // ============================================
  
  void _setupWebRTCCallbacks() {
    // WebRTC message handling will be set up per connection
  }
  
  Future<void> _buildChunkQueue(String fileId, int chunkCount) async {
    final availableChunks = await storage.getAvailableChunks(fileId);
    final missingChunks = <int>[];
    
    for (int i = 0; i < chunkCount; i++) {
      if (!availableChunks.contains(i)) {
        missingChunks.add(i);
      }
    }
    
    // Use rarest-first strategy: chunks available from fewer seeders first
    missingChunks.sort((a, b) {
      final rarityA = _getChunkRarity(fileId, a);
      final rarityB = _getChunkRarity(fileId, b);
      return rarityA.compareTo(rarityB);
    });
    
    _chunkQueue[fileId] = missingChunks;
    debugPrint('[P2P] Built chunk queue for $fileId: ${missingChunks.length} missing chunks');
  }
  
  int _getChunkRarity(String fileId, int chunkIndex) {
    final seeders = _seederAvailability[fileId] ?? {};
    int count = 0;
    
    for (final chunks in seeders.values) {
      if (chunks.contains(chunkIndex)) {
        count++;
      }
    }
    
    return count;
  }
  
  Future<void> _connectToSeeders(String fileId) async {
    final seeders = _seederAvailability[fileId] ?? {};
    final currentConnections = _fileConnections[fileId] ?? {};
    
    // How many more connections can we make?
    final availableSlots = maxConnectionsPerFile - currentConnections.length;
    if (availableSlots <= 0) return;
    
    // Select seeders to connect to (prioritize those with rare chunks)
    final unconnectedSeeders = seeders.keys
        .where((peerId) => !currentConnections.contains(peerId))
        .toList();
    
    if (unconnectedSeeders.isEmpty) {
      debugPrint('[P2P] No unconnected seeders available for $fileId');
      return;
    }
    
    // Sort by chunk availability (prefer seeders with chunks we need)
    unconnectedSeeders.sort((a, b) {
      final chunksA = seeders[a] ?? [];
      final chunksB = seeders[b] ?? [];
      final neededA = _countNeededChunks(fileId, chunksA);
      final neededB = _countNeededChunks(fileId, chunksB);
      return neededB.compareTo(neededA); // Descending
    });
    
    // Connect to top seeders
    final seedersToConnect = unconnectedSeeders.take(availableSlots).toList();
    
    for (final peerId in seedersToConnect) {
      try {
        await _connectToSeeder(fileId, peerId);
      } catch (e) {
        debugPrint('[P2P] Failed to connect to seeder $peerId: $e');
      }
    }
  }
  
  int _countNeededChunks(String fileId, List<int> seederChunks) {
    final queue = _chunkQueue[fileId] ?? [];
    return seederChunks.where((chunk) => queue.contains(chunk)).length;
  }
  
  Future<void> _connectToSeeder(String fileId, String peerId) async {
    debugPrint('[P2P] Connecting to seeder $peerId for file $fileId');
    
    // Set up message callback for this peer
    webrtcService.onMessage(peerId, (peerId, data) {
      _handlePeerMessage(fileId, peerId, data);
    });
    
    // Set up connection callback
    webrtcService.onConnected(peerId, (peerId) {
      debugPrint('[P2P] Connected to seeder $peerId');
      _fileConnections[fileId]?.add(peerId);
      
      // Start requesting chunks
      _requestNextChunks(fileId, peerId);
      
      notifyListeners();
    });
    
    // Create offer
    final offer = await webrtcService.createOffer(peerId);
    
    // Send offer via signaling (Socket.IO)
    // NOTE: This needs to be implemented - sending via Socket.IO
    _sendSignalingMessage(peerId, {
      'type': 'offer',
      'fileId': fileId,
      'offer': {
        'type': offer.type,
        'sdp': offer.sdp,
      }
    });
    
    _fileConnections[fileId]?.add(peerId);
  }
  
  void _handlePeerMessage(String fileId, String peerId, dynamic data) {
    if (data is Uint8List) {
      // Binary data - incoming chunk
      _handleIncomingChunk(fileId, peerId, data);
    } else if (data is Map) {
      // JSON message - cast to proper type
      final message = Map<String, dynamic>.from(data);
      final type = message['type'] as String?;
      
      switch (type) {
        case 'chunk-response':
          _handleChunkResponse(fileId, peerId, message);
          break;
        case 'chunk-unavailable':
          _handleChunkUnavailable(fileId, peerId, message);
          break;
        default:
          debugPrint('[P2P] Unknown message type from $peerId: $type');
      }
    }
  }
  
  Future<void> _handleIncomingChunk(String fileId, String peerId, Uint8List encryptedChunk) async {
    // This is the actual encrypted chunk data
    // We need to know which chunk this is - should be in _activeChunkRequests
    
    // For now, we'll handle chunk metadata in _handleChunkResponse
    debugPrint('[P2P] Received chunk data from $peerId (${encryptedChunk.length} bytes)');
  }
  
  Future<void> _handleChunkResponse(String fileId, String peerId, Map<String, dynamic> data) async {
    final chunkIndex = data['chunkIndex'] as int;
    final chunkHash = data['chunkHash'] as String;
    final iv = data['iv'] as String; // base64
    final encryptedData = data['data'] as String; // base64
    
    debugPrint('[P2P] Received chunk $chunkIndex from $peerId');
    
    try {
      // Decode encrypted data
      final encryptedChunk = Uint8List.fromList(
        base64Decode(encryptedData),
      );
      
      final ivBytes = Uint8List.fromList(
        base64Decode(iv),
      );
      
      // Get file key
      final fileKey = await storage.getFileKey(fileId);
      if (fileKey == null) {
        throw Exception('File key not found');
      }
      
      // Decrypt chunk
      final decryptedChunk = await encryptionService.decryptChunk(
        encryptedChunk,
        fileKey,
        ivBytes,
      );
      
      if (decryptedChunk == null) {
        throw Exception('Decryption failed for chunk $chunkIndex');
      }
      
      // Verify hash
      final actualHash = encryptionService.calculateHash(decryptedChunk);
      if (actualHash != chunkHash) {
        throw Exception('Chunk hash mismatch for chunk $chunkIndex');
      }
      
      // Save chunk
      await storage.saveChunk(
        fileId,
        chunkIndex,
        encryptedChunk,
        iv: ivBytes,
        chunkHash: chunkHash,
      );
      
      // Update download progress
      final task = downloadManager.getDownload(fileId);
      if (task != null) {
        task.completedChunks.add(chunkIndex);
        task.downloadedChunks++;
        task.downloadedBytes += decryptedChunk.length;
      }
      
      // Remove from active requests
      _activeChunkRequests[fileId]?.remove(chunkIndex);
      
      // Remove from queue
      _chunkQueue[fileId]?.remove(chunkIndex);
      
      // Request next chunk from this peer
      _requestNextChunks(fileId, peerId);
      
      notifyListeners();
      
    } catch (e) {
      debugPrint('[P2P] Error processing chunk $chunkIndex from $peerId: $e');
      
      // Mark request as failed - will retry
      _activeChunkRequests[fileId]?.remove(chunkIndex);
      
      // Add chunk back to queue for retry
      if (!(_chunkQueue[fileId]?.contains(chunkIndex) ?? false)) {
        _chunkQueue[fileId]?.add(chunkIndex);
      }
      
      // Request next chunk
      _requestNextChunks(fileId, peerId);
    }
  }
  
  void _handleChunkUnavailable(String fileId, String peerId, Map<String, dynamic> data) {
    final chunkIndex = data['chunkIndex'] as int;
    
    debugPrint('[P2P] Chunk $chunkIndex unavailable from $peerId');
    
    // Remove from active requests
    _activeChunkRequests[fileId]?.remove(chunkIndex);
    
    // Add back to queue (will be requested from another seeder)
    if (!(_chunkQueue[fileId]?.contains(chunkIndex) ?? false)) {
      _chunkQueue[fileId]?.add(chunkIndex);
    }
    
    // Request next chunk from this peer
    _requestNextChunks(fileId, peerId);
  }
  
  void _requestNextChunks(String fileId, String peerId) {
    final queue = _chunkQueue[fileId];
    if (queue == null || queue.isEmpty) {
      debugPrint('[P2P] No more chunks to request for $fileId');
      return;
    }
    
    final activeRequests = _activeChunkRequests[fileId] ?? {};
    final currentPeerRequests = activeRequests.values.where((p) => p == peerId).length;
    
    if (currentPeerRequests >= maxParallelChunksPerConnection) {
      // This peer is already busy
      return;
    }
    
    final seederChunks = _seederAvailability[fileId]?[peerId] ?? [];
    
    // Find chunks this seeder has that we need
    final availableChunks = queue.where((chunk) => seederChunks.contains(chunk)).toList();
    
    if (availableChunks.isEmpty) {
      debugPrint('[P2P] Seeder $peerId has no chunks we need');
      return;
    }
    
    // Request up to the limit
    final chunksToRequest = availableChunks.take(maxParallelChunksPerConnection - currentPeerRequests);
    
    for (final chunkIndex in chunksToRequest) {
      _requestChunk(fileId, peerId, chunkIndex);
    }
  }
  
  void _requestChunk(String fileId, String peerId, int chunkIndex) {
    debugPrint('[P2P] Requesting chunk $chunkIndex from $peerId');
    
    // Mark as active request
    _activeChunkRequests[fileId] ??= {};
    _activeChunkRequests[fileId]![chunkIndex] = peerId;
    
    // Send request via WebRTC
    webrtcService.sendData(peerId, {
      'type': 'chunk-request',
      'fileId': fileId,
      'chunkIndex': chunkIndex,
    });
  }
  
  void _sendSignalingMessage(String peerId, Map<String, dynamic> message) {
    // TODO: Implement Socket.IO signaling
    // This should send the message via Socket.IO to the peer
    debugPrint('[P2P] Signaling message to $peerId: ${message['type']}');
  }
}

// Helper for base64 decoding
Uint8List base64Decode(String str) {
  return Uint8List.fromList(str.codeUnits);
}
