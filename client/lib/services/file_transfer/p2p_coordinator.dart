import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'webrtc_service.dart';
import 'download_manager.dart';
import 'storage_interface.dart';
import 'encryption_service.dart';
import '../signal_service.dart';

/// P2P Coordinator - Manages multi-source downloads
/// 
/// Coordinates WebRTC connections to multiple seeders and
/// distributes chunk requests across them for optimal download speed
class P2PCoordinator extends ChangeNotifier {
  final WebRTCFileService webrtcService;
  final DownloadManager downloadManager;
  final FileStorageInterface storage;
  final EncryptionService encryptionService;
  final SignalService signalService;
  
  // Active connections per file: fileId -> Set<peerId>
  final Map<String, Set<String>> _fileConnections = {};
  
  // Chunk requests in progress: fileId -> Map<chunkIndex, peerId>
  final Map<String, Map<int, String>> _activeChunkRequests = {};
  
  // Seeder availability: fileId -> Map<peerId, List<chunkIndices>>
  final Map<String, Map<String, List<int>>> _seederAvailability = {};
  
  // Request queue: fileId -> List<chunkIndex>
  final Map<String, List<int>> _chunkQueue = {};
  
  // Key exchange: fileId -> Completer waiting for encryption key
  final Map<String, Completer<Uint8List>> _keyRequests = {};
  static const Duration _keyRequestTimeout = Duration(seconds: 10);
  
  // Connection limits
  int maxConnectionsPerFile = 4;
  int maxParallelChunksPerConnection = 2;
  
  P2PCoordinator({
    required this.webrtcService,
    required this.downloadManager,
    required this.storage,
    required this.encryptionService,
    required this.signalService,
  }) {
    _setupWebRTCCallbacks();
    _setupSignalCallbacks();
  }
  
  /// Start downloading a file from available seeders (requires file key)
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
  
  /// Start downloading with automatic key request from seeder
  /// 
  /// This method implements the complete P2P download flow:
  /// 
  /// Phase 1: Key Exchange (Signal Protocol - E2E encrypted)
  /// 1. Request encryption key from seeder via Signal Protocol
  /// 2. Wait for encrypted key response
  /// 
  /// Phase 2: Download Setup (with received key)
  /// 3. Initialize download manager with key
  /// 4. Build chunk queue
  /// 
  /// Phase 3: WebRTC Connection (Socket.IO signaling)
  /// 5. Connect to seeders via WebRTC (offer/answer/ICE via Socket.IO)
  /// 
  /// Phase 4: Data Transfer (WebRTC Data Channel)
  /// 6. Receive encrypted chunks via WebRTC
  /// 7. Decrypt chunks with key from Phase 1
  Future<void> startDownloadWithKeyRequest({
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required Map<String, List<int>> seederChunks,
  }) async {
    debugPrint('[P2P DOWNLOADER] ================================================');
    debugPrint('[P2P DOWNLOADER] Starting P2P download: $fileName');
    debugPrint('[P2P DOWNLOADER] File ID: $fileId');
    debugPrint('[P2P DOWNLOADER] File size: $fileSize bytes');
    debugPrint('[P2P DOWNLOADER] Chunks: $chunkCount');
    debugPrint('[P2P DOWNLOADER] Available seeders: ${seederChunks.length}');
    debugPrint('[P2P DOWNLOADER] ================================================');
    
    if (seederChunks.isEmpty) {
      throw Exception('No seeders available');
    }
    
    // Store seeder availability (needed for connection)
    _seederAvailability[fileId] = seederChunks;
    _fileConnections[fileId] = {};
    
    // Get first seeder for key request
    final firstSeeder = seederChunks.keys.first;
    
    debugPrint('[P2P DOWNLOADER] ================================================');
    debugPrint('[P2P DOWNLOADER] PHASE 1: Key Exchange via Signal Protocol');
    debugPrint('[P2P DOWNLOADER] Requesting encryption key from: $firstSeeder');
    debugPrint('[P2P DOWNLOADER] ================================================');
    
    // PHASE 1: Request the file key via Signal Protocol (E2E encrypted)
    // This is blocking - we MUST have the key before proceeding
    final fileKey = await requestFileKey(fileId, firstSeeder);
    
    debugPrint('[P2P DOWNLOADER] ================================================');
    debugPrint('[P2P DOWNLOADER] ✓ PHASE 1 COMPLETE: Key received (${fileKey.length} bytes)');
    debugPrint('[P2P DOWNLOADER] ================================================');
    
    debugPrint('[P2P DOWNLOADER] ================================================');
    debugPrint('[P2P DOWNLOADER] PHASE 2: Download Setup');
    debugPrint('[P2P DOWNLOADER] Initializing download manager with encryption key...');
    debugPrint('[P2P DOWNLOADER] ================================================');
    
    // PHASE 2 & 3: Start the actual download with the received key
    // This will:
    // - Initialize download manager (Phase 2)
    // - Build chunk queue (Phase 2)
    // - Establish WebRTC connections via Socket.IO signaling (Phase 3)
    // - Start chunk transfer via WebRTC Data Channel (Phase 4)
    await startDownload(
      fileId: fileId,
      fileName: fileName,
      mimeType: mimeType,
      fileSize: fileSize,
      checksum: checksum,
      chunkCount: chunkCount,
      fileKey: fileKey,
      seederChunks: seederChunks,
    );
    
    debugPrint('[P2P DOWNLOADER] ================================================');
    debugPrint('[P2P DOWNLOADER] ✓ Download started successfully');
    debugPrint('[P2P DOWNLOADER] ✓ WebRTC connections will now transfer chunks');
    debugPrint('[P2P DOWNLOADER] ✓ Chunks will be decrypted with the received key');
    debugPrint('[P2P DOWNLOADER] ================================================');
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
  
  /// Request file encryption key from a seeder
  /// 
  /// Sends key request via Signal Protocol (end-to-end encrypted) - most secure option
  /// 
  /// Flow:
  /// 1. Register completer for this fileId
  /// 2. Send fileKeyRequest via Signal Protocol (E2E encrypted)
  /// 3. Seeder receives request via _handleKeyRequest callback
  /// 4. Seeder sends fileKeyResponse via Signal Protocol
  /// 5. We receive response via _handleKeyResponse callback
  /// 6. Completer is completed with the key
  Future<Uint8List> requestFileKey(String fileId, String peerId) async {
    debugPrint('[P2P] Requesting file key for $fileId from $peerId via Signal');
    debugPrint('[P2P] Current pending requests: ${_keyRequests.keys.toList()}');
    
    // Check if there's already a pending request for this file
    if (_keyRequests.containsKey(fileId)) {
      debugPrint('[P2P] WARNING: Already have a pending key request for $fileId, waiting for existing one');
      return await _keyRequests[fileId]!.future;
    }
    
    // Create and register completer FIRST, before any async operations
    final completer = Completer<Uint8List>();
    _keyRequests[fileId] = completer;
    
    debugPrint('[P2P] Registered key request for $fileId, pending requests now: ${_keyRequests.keys.toList()}');
    
    try {
      // Send key request via Signal Protocol (end-to-end encrypted)
      // Uses Item model with type 'fileKeyRequest'
      // The seeder will receive this via their _handleKeyRequest callback
      await signalService.sendItem(
        recipientUserId: peerId,
        type: 'fileKeyRequest',
        payload: jsonEncode({
          'fileId': fileId,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      debugPrint('[P2P] Key request sent via Signal Protocol, waiting for response...');
      
      // Wait for response with timeout
      // Response will arrive via _handleKeyResponse callback which completes the completer
      final key = await completer.future.timeout(
        _keyRequestTimeout,
        onTimeout: () {
          debugPrint('[P2P] KEY REQUEST TIMEOUT after ${_keyRequestTimeout.inSeconds}s for $fileId');
          _keyRequests.remove(fileId);
          throw TimeoutException('Key request timed out after ${_keyRequestTimeout.inSeconds}s');
        },
      );
      
      _keyRequests.remove(fileId);
      debugPrint('[P2P] Received file key for $fileId (${key.length} bytes)');
      debugPrint('[P2P] Key can now be used to decrypt chunks received via WebRTC');
      return key;
      
    } catch (e) {
      _keyRequests.remove(fileId);
      debugPrint('[P2P] Key request failed: $e');
      rethrow;
    }
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
  
  void _setupSignalCallbacks() {
    // Register callback for incoming file key requests
    signalService.registerItemCallback('fileKeyRequest', (dynamic item) {
      _handleKeyRequest(Map<String, dynamic>.from(item));
    });
    
    // Register callback for incoming file key responses
    signalService.registerItemCallback('fileKeyResponse', (dynamic item) {
      _handleKeyResponse(Map<String, dynamic>.from(item));
    });
  }
  
  /// Handle incoming key request (we are the seeder)
  /// 
  /// This is called when someone wants to download a file from us
  /// We send them the encryption key via Signal Protocol (E2E encrypted)
  Future<void> _handleKeyRequest(Map<String, dynamic> item) async {
    try {
      final String sender = item['sender'];
      final String message = item['message'];
      final Map<String, dynamic> request = jsonDecode(message);
      final String fileId = request['fileId'];
      
      debugPrint('[P2P SEEDER] ========================================');
      debugPrint('[P2P SEEDER] Received key request for file: $fileId');
      debugPrint('[P2P SEEDER] Requester: $sender');
      debugPrint('[P2P SEEDER] Looking up encryption key in storage...');
      
      // Get the encryption key from storage
      final key = await storage.getFileKey(fileId);
      
      if (key == null) {
        debugPrint('[P2P SEEDER] ✗ ERROR: No encryption key found for $fileId');
        debugPrint('[P2P SEEDER] This file might not be shared or not fully downloaded');
        
        // Send error response via Signal
        await signalService.sendItem(
          recipientUserId: sender,
          type: 'fileKeyResponse',
          payload: jsonEncode({
            'fileId': fileId,
            'error': 'Key not found',
            'timestamp': DateTime.now().toIso8601String(),
          }),
        );
        
        debugPrint('[P2P SEEDER] ✗ Sent error response to $sender');
        debugPrint('[P2P SEEDER] ========================================');
        return;
      }
      
      debugPrint('[P2P SEEDER] ✓ Found encryption key (${key.length} bytes)');
      debugPrint('[P2P SEEDER] Sending key to $sender via Signal Protocol (E2E encrypted)...');
      
      // Send key back via Signal (end-to-end encrypted)
      final keyBase64 = base64Encode(key);
      await signalService.sendItem(
        recipientUserId: sender,
        type: 'fileKeyResponse',
        payload: jsonEncode({
          'fileId': fileId,
          'key': keyBase64,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      
      debugPrint('[P2P SEEDER] ✓ Successfully sent encrypted key to $sender');
      debugPrint('[P2P SEEDER] ✓ Downloader can now decrypt chunks via WebRTC');
      debugPrint('[P2P SEEDER] ========================================');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P SEEDER] ERROR handling key request: $e');
      debugPrint('[P2P SEEDER] Stack trace: $stackTrace');
      
      // Try to send error response
      try {
        final sender = item['sender'];
        final fileId = jsonDecode(item['message'])['fileId'];
        await signalService.sendItem(
          recipientUserId: sender,
          type: 'fileKeyResponse',
          payload: jsonEncode({
            'fileId': fileId,
            'error': 'Internal error: $e',
            'timestamp': DateTime.now().toIso8601String(),
          }),
        );
      } catch (_) {
        debugPrint('[P2P SEEDER] Could not send error response');
      }
    }
  }
  
  /// Handle incoming key response (we requested the key)
  /// 
  /// This is called when we receive a 'fileKeyResponse' item via Signal Protocol
  /// The key is E2E encrypted and only we can decrypt it
  void _handleKeyResponse(Map<String, dynamic> item) {
    try {
      final String sender = item['sender'];
      final String message = item['message'];
      
      debugPrint('[P2P] ========================================');
      debugPrint('[P2P] Received key response from $sender');
      debugPrint('[P2P] Raw message: $message');
      
      final Map<String, dynamic> response = jsonDecode(message);
      final String fileId = response['fileId'];
      
      debugPrint('[P2P] Parsed key response for fileId: $fileId');
      debugPrint('[P2P] Current pending requests: ${_keyRequests.keys.toList()}');
      
      // Check if we have a pending request for this file
      final completer = _keyRequests[fileId];
      
      if (completer == null) {
        debugPrint('[P2P] WARNING: Received key response but no pending request for $fileId');
        debugPrint('[P2P] This might mean the request timed out or was cancelled');
        return;
      }
      
      if (completer.isCompleted) {
        debugPrint('[P2P] WARNING: Received key response but completer already completed for $fileId');
        return;
      }
      
      // Check for errors from seeder
      if (response['error'] != null) {
        final error = response['error'];
        debugPrint('[P2P] ⚠️  Key request failed from $sender: $error');
        debugPrint('[P2P] ⚠️  This is normal if multiple seeders exist - waiting for other seeders...');
        // Don't complete with error - another seeder might have the key
        // The timeout will handle the case where NO seeder has the key
        return;
      }
      
      // Decode the base64 key
      final String keyBase64 = response['key'];
      final key = Uint8List.fromList(base64Decode(keyBase64));
      
      debugPrint('[P2P] ✓ Successfully received file key for $fileId');
      debugPrint('[P2P] ✓ Key length: ${key.length} bytes');
      debugPrint('[P2P] ✓ Completing key request');
      
      // Complete the completer - this unblocks requestFileKey()
      completer.complete(key);
      _keyRequests.remove(fileId);
      
      debugPrint('[P2P] ✓ Key request completed for $fileId');
      debugPrint('[P2P] ✓ Download can now proceed with WebRTC setup');
      debugPrint('[P2P] ========================================');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR handling key response: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
      
      // Try to extract fileId and complete with error
      try {
        final fileId = item['message'] != null ? 
          (jsonDecode(item['message'])['fileId'] as String?) : null;
        if (fileId != null) {
          final completer = _keyRequests[fileId];
          if (completer != null && !completer.isCompleted) {
            completer.completeError(e);
            _keyRequests.remove(fileId);
          }
        }
      } catch (_) {
        debugPrint('[P2P] Could not extract fileId from error response');
      }
    }
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
  
  void _handlePeerMessage(String fileId, String peerId, dynamic data) async {
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
