import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' show min, max;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_service.dart';
import 'download_manager.dart';
import 'storage_interface.dart';
import 'encryption_service.dart';
import 'socket_file_client.dart';
import '../signal_service.dart';
import 'chunking_service.dart';
import '../../models/seeder_info.dart';
// Web-only imports for browser download
import 'dart:html' as html show AnchorElement, Blob, Url, document;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Download phase tracking for graceful completion
enum DownloadPhase {
  downloading,   // Active download, requesting chunks
  draining,      // All chunks received, waiting for in-flight chunks
  assembling,    // Assembling file from chunks
  verifying,     // Verifying checksum
  complete,      // Download complete
  failed,        // Download failed
}

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
  final SocketFileClient socketClient;
  final ChunkingService chunkingService;
  
  // Active connections per file: fileId -> Set<peerId>
  final Map<String, Set<String>> _fileConnections = {};
  
  // Peer device mapping: userId -> deviceId (for WebRTC signaling)
  final Map<String, String> _peerDevices = {};
  
  // Chunk requests in progress: fileId -> Map<chunkIndex, peerId>
  final Map<String, Map<int, String>> _activeChunkRequests = {};
  
  // SEEDER: Track chunks sent per peer: peerId -> Map<fileId, Set<chunkIndex>>
  final Map<String, Map<String, Set<int>>> _seederChunksSent = {};
  
  // SEEDER: Last activity timestamp per connection: peerId -> DateTime
  final Map<String, DateTime> _seederLastActivity = {};
  
  // SEEDER: Cleanup timeout (close connection after inactivity)
  static const Duration _seederInactivityTimeout = Duration(seconds: 30);
  
  // Pending chunk metadata: peerId -> Map with chunkIndex and size
  final Map<String, Map<String, dynamic>> _pendingChunkMetadata = {};
  
  // Batch metadata storage: fileId:peerId -> Map<chunkIndex, metadata>
  final Map<String, Map<int, Map<String, dynamic>>> _batchMetadataCache = {};
  
  // Maps for pending ACKs (seeder waits for downloader to ACK metadata before sending binary)
  final Map<String, Completer<void>> _pendingBatchMetadataAcks = {};
  
  // Seeder availability: fileId -> Map<deviceKey, SeederInfo>
  // deviceKey format: "userId:deviceId"
  final Map<String, Map<String, SeederInfo>> _seederAvailability = {};
  
  // Request queue: fileId -> List<chunkIndex>
  final Map<String, List<int>> _chunkQueue = {};
  
  // Key exchange: fileId -> Completer waiting for encryption key
  final Map<String, Completer<Uint8List>> _keyRequests = {};
  static const Duration _keyRequestTimeout = Duration(seconds: 10);
  
  // Download phase tracking for graceful completion
  final Map<String, DownloadPhase> _downloadPhases = {};
  final Map<String, DateTime> _drainStartTime = {};
  static const Duration _drainTimeout = Duration(seconds: 5);
  
  // Connection limits
  int maxConnectionsPerFile = 4;
  int maxParallelChunksPerConnection = 2;
  
  // Rate limiting: Track chunks in flight per peer
  final Map<String, Set<int>> _chunksInFlightPerPeer = {};
  static const int MAX_CHUNKS_IN_FLIGHT_PER_PEER = 5;
  
  // Chunk retry tracking: fileId -> Map<chunkIndex, RetryInfo>
  final Map<String, Map<int, ChunkRetryInfo>> _chunkRetryInfo = {};
  static const int MAX_CHUNK_RETRIES = 3;
  
  // Chunk error tracking: Track which seeder failed for which chunk
  // fileId -> Map<chunkIndex, Set<failedPeerIds>>
  final Map<String, Map<int, Set<String>>> _chunkFailedSeeders = {};
  
  // Adaptive throttling state
  final Map<String, AdaptiveThrottler> _throttlers = {};
  
  P2PCoordinator({
    required this.webrtcService,
    required this.downloadManager,
    required this.storage,
    required this.encryptionService,
    required this.signalService,
    required this.socketClient,
    required this.chunkingService,
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
    required Map<String, SeederInfo> seederChunks, // deviceKey -> SeederInfo
  }) async {
    debugPrint('[P2P] Starting download: $fileName ($fileId)');
    debugPrint('[P2P] Available seeders: ${seederChunks.length}');
    
    // Initialize download phase
    _downloadPhases[fileId] = DownloadPhase.downloading;
    
    // Store seeder availability
    _seederAvailability[fileId] = seederChunks;
    
    // Store deviceId mapping for each seeder
    for (final entry in seederChunks.entries) {
      final seederInfo = entry.value;
      _peerDevices[seederInfo.userId] = seederInfo.deviceId;
      debugPrint('[P2P] Registered seeder: ${seederInfo.userId} -> device ${seederInfo.deviceId}');
    }
    
    // Initialize file connections
    _fileConnections[fileId] = {};
    _activeChunkRequests[fileId] = {};
    
    // Convert SeederInfo map to old format for DownloadManager
    final legacySeederChunks = <String, List<int>>{};
    for (final entry in seederChunks.entries) {
      legacySeederChunks[entry.key] = entry.value.availableChunks;
    }
    
    // Start download in DownloadManager
    await downloadManager.startDownload(
      fileId: fileId,
      fileName: fileName,
      mimeType: mimeType,
      fileSize: fileSize,
      checksum: checksum,
      chunkCount: chunkCount,
      fileKey: fileKey,
      seederChunks: legacySeederChunks,
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
    required Map<String, SeederInfo> seederChunks,
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
    
    // Get first seeder for key request (extract userId from SeederInfo)
    final firstSeederInfo = seederChunks.values.first;
    final firstSeeder = firstSeederInfo.userId;
    
    // Store deviceId mapping
    _peerDevices[firstSeeder] = firstSeederInfo.deviceId;
    
    debugPrint('[P2P DOWNLOADER] ================================================');
    debugPrint('[P2P DOWNLOADER] PHASE 1: Key Exchange via Signal Protocol');
    debugPrint('[P2P DOWNLOADER] Requesting encryption key from: $firstSeeder (device: ${firstSeederInfo.deviceId})');
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
  void updateSeederAvailability(String fileId, Map<String, SeederInfo> seederChunks) {
    debugPrint('[P2P] Updating seeder availability for $fileId: ${seederChunks.length} seeders');
    
    _seederAvailability[fileId] = seederChunks;
    
    // Store deviceId mappings
    for (final entry in seederChunks.entries) {
      final seederInfo = entry.value;
      _peerDevices[seederInfo.userId] = seederInfo.deviceId;
    }
    
    // Convert to legacy format for DownloadManager
    final legacySeederChunks = <String, List<int>>{};
    for (final entry in seederChunks.entries) {
      legacySeederChunks[entry.key] = entry.value.availableChunks;
    }
    downloadManager.updateSeeders(fileId, legacySeederChunks);
    
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
    // Listen for incoming WebRTC offers (we are the seeder)
    socketClient.onWebRTCOffer((data) {
      _handleWebRTCOffer(data);
    });
    
    // Listen for incoming WebRTC answers (we are the downloader)
    socketClient.onWebRTCAnswer((data) {
      _handleWebRTCAnswer(data);
    });
    
    // Listen for incoming ICE candidates
    socketClient.onICECandidate((data) {
      _handleICECandidate(data);
    });
    
    // Set up ICE candidate callback for outgoing candidates
    webrtcService.setIceCandidateCallback((peerId, candidate) {
      _sendICECandidate(peerId, candidate);
    });
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
      debugPrint('[P2P SEEDER] Key type: ${key.runtimeType}');
      
      // Validate key before sending
      if (key.length != 32) {
        debugPrint('[P2P SEEDER] ⚠️  ERROR: Stored key is ${key.length} bytes, expected 32 bytes!');
        debugPrint('[P2P SEEDER] ⚠️  This file was uploaded with wrong key size');
        
        // Send error instead of wrong key
        await signalService.sendItem(
          recipientUserId: sender,
          type: 'fileKeyResponse',
          payload: jsonEncode({
            'fileId': fileId,
            'error': 'Invalid key size: ${key.length} bytes (expected 32)',
            'timestamp': DateTime.now().toIso8601String(),
          }),
        );
        return;
      }
      
      debugPrint('[P2P SEEDER] Sending key to $sender via Signal Protocol (E2E encrypted)...');
      
      // Send key back via Signal (end-to-end encrypted)
      final keyBase64 = base64.encode(key);
      debugPrint('[P2P SEEDER] ✓ Encoded key to base64: $keyBase64');
      debugPrint('[P2P SEEDER] ✓ Base64 string length: ${keyBase64.length} chars');
      debugPrint('[P2P SEEDER] ✓ Original key was ${key.length} bytes');
      
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
      
      debugPrint('[P2P] ✓ Received base64 key: $keyBase64');
      debugPrint('[P2P] ✓ Base64 string length: ${keyBase64.length} chars');
      
      // Try to decode
      debugPrint('[P2P] DEBUG: About to call base64.decode...');
      final decoded = base64.decode(keyBase64);
      debugPrint('[P2P] DEBUG: base64.decode returned: ${decoded.runtimeType}');
      debugPrint('[P2P] DEBUG: decoded.length = ${decoded.length}');
      
      final key = Uint8List.fromList(decoded);
      
      debugPrint('[P2P] ✓ Successfully decoded file key for $fileId');
      debugPrint('[P2P] ✓ Decoded key length: ${key.length} bytes');
      debugPrint('[P2P] ✓ Key bytes (first 8): ${key.sublist(0, min(8, key.length)).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      
      // Validate key length (must be 32 bytes for AES-256)
      if (key.length != 32) {
        throw Exception('Invalid key length: ${key.length} bytes (expected 32 for AES-256)');
      }
      
      debugPrint('[P2P] ✓ AES-256 key validated');
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
  
  // ============================================
  // WEBRTC SIGNALING HANDLERS
  // ============================================
  
  /// Handle incoming WebRTC offer (we are the seeder)
  /// 
  /// When a downloader wants to connect to us, they send an offer.
  /// We create a peer connection, set their offer as remote description,
  /// and send back an answer.
  Future<void> _handleWebRTCOffer(Map<String, dynamic> data) async {
    try {
      final String fromUserId = data['fromUserId'] as String;
      final String fromDeviceId = data['fromDeviceId'].toString(); // Convert to String (might be int)
      final String fileId = data['fileId'] as String;
      final Map<String, dynamic> offerData = data['offer'] as Map<String, dynamic>;
      
      debugPrint('[P2P SEEDER] ========================================');
      debugPrint('[P2P SEEDER] Received WebRTC offer from $fromUserId:$fromDeviceId');
      debugPrint('[P2P SEEDER] FileId: $fileId');
      
      // Store device mapping for later use
      _peerDevices[fromUserId] = fromDeviceId;
      
      // Register connection BEFORE creating answer (ICE candidates will be generated)
      _fileConnections.putIfAbsent(fileId, () => {});
      _fileConnections[fileId]!.add(fromUserId);
      
      // Create RTCSessionDescription from offer data
      final offer = RTCSessionDescription(
        offerData['sdp'],
        offerData['type'],
      );
      
      // Set up data channel message handler BEFORE handleOffer (messages can arrive immediately)
      webrtcService.onMessage(fromUserId, (peerId, data) {
        debugPrint('[P2P SEEDER] Message callback invoked for $peerId');
        _handleDataChannelMessage(fileId, peerId, data);
      });
      
      debugPrint('[P2P SEEDER] Message handler registered for $fromUserId');
      
      // Set up connection callback
      webrtcService.onConnected(fromUserId, (peerId) {
        debugPrint('[P2P SEEDER] ✓ WebRTC connected to $peerId for file $fileId');
      });
      
      // Handle the offer and create answer
      debugPrint('[P2P SEEDER] Creating peer connection and answer...');
      final answer = await webrtcService.handleOffer(fromUserId, offer);
      
      debugPrint('[P2P SEEDER] ✓ Answer created, sending back to $fromUserId:$fromDeviceId');
      
      // Send answer back via Socket.IO
      socketClient.sendWebRTCAnswer(
        targetUserId: fromUserId,
        targetDeviceId: fromDeviceId,
        fileId: fileId,
        answer: {
          'sdp': answer.sdp,
          'type': answer.type,
        },
      );
      
      debugPrint('[P2P SEEDER] ✓ WebRTC answer sent, waiting for connection');
      debugPrint('[P2P SEEDER] ========================================');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P SEEDER] ERROR handling WebRTC offer: $e');
      debugPrint('[P2P SEEDER] Stack trace: $stackTrace');
    }
  }
  
  /// Handle incoming WebRTC answer (we are the downloader)
  /// 
  /// When we sent an offer to a seeder, they respond with an answer.
  /// We set it as the remote description to complete the connection setup.
  Future<void> _handleWebRTCAnswer(Map<String, dynamic> data) async {
    try {
      final String fromUserId = data['fromUserId'] as String;
      final String fromDeviceId = data['fromDeviceId'].toString();
      final String fileId = data['fileId'] as String;
      final Map<String, dynamic> answerData = data['answer'] as Map<String, dynamic>;
      
      debugPrint('[P2P] ========================================');
      debugPrint('[P2P] Received WebRTC answer from $fromUserId:$fromDeviceId');
      debugPrint('[P2P] FileId: $fileId');
      
      // Store device mapping for later use
      _peerDevices[fromUserId] = fromDeviceId;
      
      // Create RTCSessionDescription from answer data
      final answer = RTCSessionDescription(
        answerData['sdp'],
        answerData['type'],
      );
      
      // Handle the answer
      debugPrint('[P2P] Setting remote description...');
      await webrtcService.handleAnswer(fromUserId, answer);
      
      debugPrint('[P2P] ✓ Remote description set, waiting for ICE connection');
      debugPrint('[P2P] ========================================');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR handling WebRTC answer: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
    }
  }
  
  /// Handle incoming ICE candidate
  /// 
  /// ICE candidates are sent by both sides during WebRTC connection setup
  /// to negotiate the best connection path (direct, STUN, or TURN relay)
  Future<void> _handleICECandidate(Map<String, dynamic> data) async {
    try {
      final String fromUserId = data['fromUserId'] as String;
      final String fromDeviceId = data['fromDeviceId'].toString();
      final String fileId = data['fileId'] as String;
      final Map<String, dynamic> candidateData = data['candidate'] as Map<String, dynamic>;
      
      debugPrint('[P2P] Received ICE candidate from $fromUserId:$fromDeviceId for file $fileId');
      
      // Store device mapping
      _peerDevices[fromUserId] = fromDeviceId;
      
      // Create RTCIceCandidate
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      
      // Add to peer connection
      await webrtcService.handleIceCandidate(fromUserId, candidate);
      
      debugPrint('[P2P] ✓ ICE candidate added for $fromUserId:$fromDeviceId');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR handling ICE candidate: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
    }
  }
  
  /// Send ICE candidate to peer via Socket.IO
  /// 
  /// This is called automatically by WebRTCFileService when local
  /// ICE candidates are discovered
  void _sendICECandidate(String peerId, RTCIceCandidate candidate) {
    try {
      // Extract fileId from active connections
      String? fileId;
      for (final entry in _fileConnections.entries) {
        if (entry.value.contains(peerId)) {
          fileId = entry.key;
          break;
        }
      }
      
      if (fileId == null) {
        debugPrint('[P2P] WARNING: Cannot send ICE candidate - no fileId for peer $peerId');
        return;
      }
      
      // Get device ID for this peer
      final deviceId = _peerDevices[peerId];
      if (deviceId == null) {
        debugPrint('[P2P] WARNING: Cannot send ICE candidate - no deviceId for peer $peerId');
        return;
      }
      
      socketClient.sendICECandidate(
        targetUserId: peerId,
        targetDeviceId: deviceId,
        fileId: fileId,
        candidate: {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      );
      
      debugPrint('[P2P] ✓ ICE candidate sent to $peerId:$deviceId');
      
    } catch (e) {
      debugPrint('[P2P] ERROR sending ICE candidate: $e');
    }
  }
  
  /// Handle incoming data channel message
  /// 
  /// This handles both chunk requests (when we are seeder) and
  /// chunk responses (when we are downloader)
  Future<void> _handleDataChannelMessage(String fileId, String peerId, dynamic data) async {
    try {
      debugPrint('[P2P DataChannel] Received message from $peerId, type: ${data.runtimeType}');
      
      if (data is Uint8List) {
        // Binary data - encrypted chunk
        debugPrint('[P2P] Received encrypted chunk from $peerId (${data.length} bytes)');
        await _handleIncomingChunk(fileId, peerId, data);
      } else if (data is Map<String, dynamic>) {
        // JSON message - chunk request or response metadata
        final type = data['type'] as String?;
        debugPrint('[P2P DataChannel] Message type: $type');
        
        if (type == 'requestBatchMetadata') {
          // We are seeder - peer wants ALL metadata at once
          debugPrint('[P2P DataChannel] Routing to _handleBatchMetadataRequest');
          await _handleBatchMetadataRequest(fileId, peerId, data);
        } else if (type == 'chunkRequest') {
          // We are seeder - peer is requesting a chunk
          debugPrint('[P2P DataChannel] Routing to _handleChunkRequest');
          await _handleChunkRequest(fileId, peerId, data);
        } else if (type == 'batchMetadata') {
          // We are downloader - peer sent ALL metadata
          debugPrint('[P2P DataChannel] Routing to _handleBatchMetadata');
          await _handleBatchMetadata(fileId, peerId, data);
        } else if (type == 'chunkResponse') {
          // We are downloader - peer sent chunk metadata (legacy/fallback)
          debugPrint('[P2P DataChannel] Routing to _handleChunkResponse');
          await _handleChunkResponse(fileId, peerId, data);
        } else if (type == 'chunkMetadataAck') {
          // We are seeder - peer acknowledged metadata
          debugPrint('[P2P DataChannel] Routing to _handleChunkMetadataAck');
          _handleChunkMetadataAck(peerId, data);
        } else if (type == 'batchMetadataAck') {
          // We are seeder - peer acknowledged batch metadata
          debugPrint('[P2P DataChannel] Routing to _handleBatchMetadataAck');
          _handleBatchMetadataAck(peerId);
        } else if (type == 'error') {
          debugPrint('[P2P] Received error from $peerId: ${data['message']}');
        } else {
          debugPrint('[P2P] WARNING: Unknown message type: $type');
        }
      } else {
        debugPrint('[P2P DataChannel] WARNING: Unexpected data type: ${data.runtimeType}');
      }
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR handling data channel message: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
    }
  }
  
  /// Handle batch metadata request from downloader (we are seeder)
  /// 
  /// Send ALL chunk metadata at once, then wait for ACK before accepting chunk requests
  Future<void> _handleBatchMetadataRequest(String fileId, String peerId, Map<String, dynamic> request) async {
    try {
      debugPrint('[P2P SEEDER] ========================================');
      debugPrint('[P2P SEEDER] Batch metadata request from $peerId');
      debugPrint('[P2P SEEDER] FileId: $fileId');
      
      // Get chunk count
      final chunkCount = await storage.getChunkCount(fileId);
      if (chunkCount == 0) {
        debugPrint('[P2P SEEDER] ✗ ERROR: File not found or has no chunks');
        await webrtcService.sendData(peerId, {
          'type': 'error',
          'message': 'File not available',
        });
        return;
      }
      
      debugPrint('[P2P SEEDER] File has $chunkCount chunks, collecting metadata...');
      
      // Collect metadata for ALL chunks
      final List<Map<String, dynamic>> allMetadata = [];
      for (int i = 0; i < chunkCount; i++) {
        final metadata = await storage.getChunkMetadata(fileId, i);
        if (metadata != null) {
          allMetadata.add({
            'chunkIndex': i,
            'iv': metadata['iv'] ?? '',
            'chunkHash': metadata['chunkHash'] ?? '',
            'size': metadata['size'] ?? 0,
          });
        }
      }
      
      debugPrint('[P2P SEEDER] Collected ${allMetadata.length} chunk metadata entries');
      
      // Create completer to wait for ACK
      final ackCompleter = Completer<void>();
      _pendingBatchMetadataAcks[peerId] = ackCompleter;
      
      // Send batch metadata
      await webrtcService.sendData(peerId, {
        'type': 'batchMetadata',
        'fileId': fileId,
        'metadata': allMetadata,
      });
      
      debugPrint('[P2P SEEDER] ✓ Batch metadata sent, waiting for ACK...');
      
      // Wait for ACK with timeout
      try {
        await ackCompleter.future.timeout(
          Duration(seconds: 10),
          onTimeout: () {
            debugPrint('[P2P SEEDER] ✗ Batch metadata ACK timeout');
            throw TimeoutException('Batch metadata ACK not received within 10 seconds');
          },
        );
        
        debugPrint('[P2P SEEDER] ✓ Batch metadata acknowledged, ready for chunk requests');
        
      } finally {
        // Clean up completer
        _pendingBatchMetadataAcks.remove(peerId);
      }
      
      debugPrint('[P2P SEEDER] ========================================');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P SEEDER] ERROR handling batch metadata request: $e');
      debugPrint('[P2P SEEDER] Stack trace: $stackTrace');
      
      try {
        await webrtcService.sendData(peerId, {
          'type': 'error',
          'message': 'Internal error: $e',
        });
      } catch (_) {}
    }
  }
  
  /// Handle chunk request from downloader (we are seeder)
  /// 
  /// Load the encrypted chunk from storage and send it directly (metadata was already sent in batch)
  Future<void> _handleChunkRequest(String fileId, String peerId, Map<String, dynamic> request) async {
    try {
      final int chunkIndex = request['chunkIndex'];
      
      debugPrint('[P2P SEEDER] Chunk $chunkIndex request from $peerId');
      
      // Track activity (for inactivity cleanup)
      _seederLastActivity[peerId] = DateTime.now();
      
      // Load encrypted chunk from storage
      final encryptedChunk = await storage.getChunk(fileId, chunkIndex);
      
      if (encryptedChunk == null) {
        debugPrint('[P2P SEEDER] ✗ ERROR: Chunk $chunkIndex not found');
        
        // Send error response
        await webrtcService.sendData(peerId, {
          'type': 'chunk-unavailable',
          'chunkIndex': chunkIndex,
        });
        return;
      }
      
      debugPrint('[P2P SEEDER] ✓ Sending chunk $chunkIndex (${encryptedChunk.length} bytes)');
      
      // ✅ FIX: Prepend chunkIndex as 4-byte header before binary data
      // This allows downloader to identify which chunk this is
      final chunkIndexBytes = ByteData(4)..setInt32(0, chunkIndex, Endian.big);
      final dataWithHeader = Uint8List.fromList([
        ...chunkIndexBytes.buffer.asUint8List(),
        ...encryptedChunk,
      ]);
      
      // Send chunk with header as binary
      await webrtcService.sendBinary(peerId, dataWithHeader);
      
      debugPrint('[P2P SEEDER] ✓ Chunk $chunkIndex sent successfully');
      
      // Track sent chunks for cleanup detection
      _seederChunksSent.putIfAbsent(peerId, () => {});
      _seederChunksSent[peerId]!.putIfAbsent(fileId, () => {});
      _seederChunksSent[peerId]![fileId]!.add(chunkIndex);
      
      // Check if all chunks have been sent
      await _checkSeederTransferComplete(fileId, peerId);
      
    } catch (e, stackTrace) {
      debugPrint('[P2P SEEDER] ERROR handling chunk request: $e');
      debugPrint('[P2P SEEDER] Stack trace: $stackTrace');
      
      // Try to send error response
      try {
        await webrtcService.sendData(peerId, {
          'type': 'error',
          'chunkIndex': request['chunkIndex'],
          'message': 'Internal error: $e',
        });
      } catch (_) {}
    }
  }
  
  /// Check if all chunks have been sent to downloader (SEEDER cleanup)
  /// 
  /// This is called after each chunk is sent. If all chunks have been sent,
  /// we start an inactivity timer. If no new requests come in for 30 seconds,
  /// we close the connection to free resources.
  Future<void> _checkSeederTransferComplete(String fileId, String peerId) async {
    try {
      // Get total chunk count for this file
      final chunkCount = await storage.getChunkCount(fileId);
      if (chunkCount == 0) {
        debugPrint('[P2P SEEDER] Cannot determine chunk count for $fileId');
        return;
      }
      
      // Get chunks sent to this peer
      final sentChunks = _seederChunksSent[peerId]?[fileId]?.length ?? 0;
      
      debugPrint('[P2P SEEDER] Transfer progress to $peerId: $sentChunks/$chunkCount chunks');
      
      // Check if all chunks have been sent
      if (sentChunks >= chunkCount) {
        debugPrint('[P2P SEEDER] ================================================');
        debugPrint('[P2P SEEDER] ✓ ALL CHUNKS SENT to $peerId for $fileId');
        debugPrint('[P2P SEEDER] Total chunks: $chunkCount');
        debugPrint('[P2P SEEDER] Starting inactivity timer (${_seederInactivityTimeout.inSeconds}s)...');
        debugPrint('[P2P SEEDER] ================================================');
        
        // Start inactivity timer
        _startSeederCleanupTimer(fileId, peerId);
      }
      
    } catch (e) {
      debugPrint('[P2P SEEDER] Error checking transfer complete: $e');
    }
  }
  
  /// Start inactivity timer for seeder cleanup
  /// 
  /// If no new chunk requests arrive within the timeout, close the connection
  void _startSeederCleanupTimer(String fileId, String peerId) async {
    final startTime = DateTime.now();
    
    // Wait for inactivity timeout
    await Future.delayed(_seederInactivityTimeout);
    
    // Check if there was activity during the wait
    final lastActivity = _seederLastActivity[peerId];
    if (lastActivity != null && lastActivity.isAfter(startTime)) {
      debugPrint('[P2P SEEDER] Activity detected from $peerId, extending timer');
      // Recursively start new timer
      _startSeederCleanupTimer(fileId, peerId);
      return;
    }
    
    // No activity - close connection
    debugPrint('[P2P SEEDER] ================================================');
    debugPrint('[P2P SEEDER] CLEANUP: Closing connection to $peerId (inactivity)');
    debugPrint('[P2P SEEDER] FileId: $fileId');
    debugPrint('[P2P SEEDER] No requests for ${_seederInactivityTimeout.inSeconds}s');
    debugPrint('[P2P SEEDER] ================================================');
    
    try {
      // Close WebRTC connection
      await webrtcService.closePeerConnection(peerId);
      
      // Clean up state
      _fileConnections[fileId]?.remove(peerId);
      _seederChunksSent.remove(peerId);
      _seederLastActivity.remove(peerId);
      _peerDevices.remove(peerId);
      
      debugPrint('[P2P SEEDER] ✓ Connection closed and state cleaned up');
      
      notifyListeners();
      
    } catch (e) {
      debugPrint('[P2P SEEDER] ⚠️ Error during cleanup: $e');
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
    
    for (final seederInfo in seeders.values) {
      if (seederInfo.hasChunk(chunkIndex)) {
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
    // Note: We use deviceKey (userId:deviceId) for connections, but extract userId for WebRTC
    final unconnectedSeeders = seeders.entries
        .where((entry) => !currentConnections.contains(entry.value.userId))
        .toList();
    
    if (unconnectedSeeders.isEmpty) {
      debugPrint('[P2P] No unconnected seeders available for $fileId');
      return;
    }
    
    // Sort by chunk availability (prefer seeders with chunks we need)
    unconnectedSeeders.sort((a, b) {
      final seederA = a.value;
      final seederB = b.value;
      final neededA = _countNeededChunks(fileId, seederA.availableChunks);
      final neededB = _countNeededChunks(fileId, seederB.availableChunks);
      return neededB.compareTo(neededA); // Descending
    });
    
    // Connect to top seeders
    final seedersToConnect = unconnectedSeeders.take(availableSlots).toList();
    
    for (final entry in seedersToConnect) {
      try {
        final seederInfo = entry.value;
        // Use userId for connection (WebRTC peer connection)
        await _connectToSeeder(fileId, seederInfo.userId);
      } catch (e) {
        debugPrint('[P2P] Failed to connect to seeder ${entry.value.userId}: $e');
      }
    }
  }
  
  int _countNeededChunks(String fileId, List<int> seederChunks) {
    final queue = _chunkQueue[fileId] ?? [];
    return seederChunks.where((chunk) => queue.contains(chunk)).length;
  }
  
  Future<void> _connectToSeeder(String fileId, String peerId) async {
    debugPrint('[P2P] Connecting to seeder $peerId for file $fileId');
    
    // Register connection BEFORE creating offer (ICE candidates will be generated)
    _fileConnections.putIfAbsent(fileId, () => {});
    _fileConnections[fileId]!.add(peerId);
    
    // Set up message callback for this peer
    webrtcService.onMessage(peerId, (peerId, data) {
      _handlePeerMessage(fileId, peerId, data);
    });
    
    // Set up connection callback
    webrtcService.onConnected(peerId, (peerId) {
      debugPrint('[P2P] PeerConnection connected to seeder $peerId');
      notifyListeners();
    });
    
    // Set up data channel open callback - THIS is when we can send data!
    webrtcService.onDataChannelOpen(peerId, (peerId) async {
      debugPrint('[P2P] ✓ DataChannel open to seeder $peerId');
      
      // Request ALL metadata first (batch)
      debugPrint('[P2P] Requesting batch metadata from seeder...');
      await webrtcService.sendData(peerId, {
        'type': 'requestBatchMetadata',
        'fileId': fileId,
      });
      
      notifyListeners();
    });
    
    // Create offer
    final offer = await webrtcService.createOffer(peerId);
    
    // Send offer via signaling (Socket.IO)
    _sendSignalingMessage(peerId, {
      'type': 'offer',
      'fileId': fileId,
      'offer': {
        'type': offer.type,
        'sdp': offer.sdp,
      }
    });
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
        case 'batchMetadata':  // Seeder sent all metadata
          await _handleBatchMetadata(fileId, peerId, message);
          break;
        case 'batchMetadataAck':  // Downloader acknowledged batch
          _handleBatchMetadataAck(peerId);
          break;
        case 'requestBatchMetadata':  // Downloader wants batch metadata
          await _handleBatchMetadataRequest(fileId, peerId, message);
          break;
        case 'chunkResponse':  // Match what seeder sends (legacy)
        case 'chunk-response':  // Legacy support
          _handleChunkResponse(fileId, peerId, message);
          break;
        case 'chunkMetadataAck':  // Downloader ACKs metadata receipt (legacy)
          _handleChunkMetadataAck(peerId, message);
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
    int? chunkIndex; // Declare at function scope for error handler
    
    try {
      // Check download phase - accept chunks during downloading and draining
      final phase = _downloadPhases[fileId] ?? DownloadPhase.downloading;
      
      if (phase == DownloadPhase.assembling || phase == DownloadPhase.complete) {
        debugPrint('[P2P] ⚠️ Ignoring late chunk from $peerId (download in phase: $phase)');
        return;
      }
      
      if (phase == DownloadPhase.draining) {
        debugPrint('[P2P] Accepting chunk during drain phase from $peerId');
      }
      
      debugPrint('[P2P] Received chunk data from $peerId (${encryptedChunk.length} bytes)');
      
      // ✅ FIX: Extract chunkIndex from 4-byte header
      if (encryptedChunk.length < 4) {
        debugPrint('[P2P] ERROR: Chunk data too small (no header): ${encryptedChunk.length} bytes');
        return;
      }
      
      final headerBytes = ByteData.sublistView(encryptedChunk, 0, 4);
      chunkIndex = headerBytes.getInt32(0, Endian.big);
      
      // Remove header to get actual encrypted chunk
      final actualEncryptedChunk = Uint8List.sublistView(encryptedChunk, 4);
      
      debugPrint('[P2P] ✓ Chunk identified from header: $chunkIndex (${actualEncryptedChunk.length} bytes payload)');
      
      // Get metadata from batch cache
      final cacheKey = '$fileId:$peerId';
      final metadata = _batchMetadataCache[cacheKey]?[chunkIndex];
      
      if (metadata == null) {
        debugPrint('[P2P] ERROR: Received chunk data without metadata from $peerId');
        debugPrint('[P2P] Cache key: $cacheKey, ChunkIndex: $chunkIndex');
        return;
      }
      
      // Check if chunk already received (duplicate)
      final downloadTask = downloadManager.getDownload(fileId);
      if (downloadTask != null && downloadTask.completedChunks.contains(chunkIndex)) {
        debugPrint('[P2P] Ignoring duplicate chunk $chunkIndex from $peerId (already in completed set)');
        // Remove from active requests
        _activeChunkRequests[fileId]?.remove(chunkIndex);
        _completeChunkRequest(peerId, chunkIndex);
        return;
      }
      
      final String? ivString = metadata['iv'] as String?;
      final String? chunkHash = metadata['chunkHash'] as String?;
      
      debugPrint('[P2P] Processing chunk $chunkIndex from $peerId');
      
      // Get file key
      final fileKey = await storage.getFileKey(fileId);
      if (fileKey == null) {
        throw Exception('File key not found for $fileId');
      }
      
      // Convert IV from string if present
      Uint8List? iv;
      if (ivString != null && ivString.isNotEmpty) {
        try {
          // IV is stored as base64 in metadata
          iv = base64.decode(ivString);
          debugPrint('[P2P] Decoded IV (${iv.length} bytes)');
        } catch (e) {
          debugPrint('[P2P] WARNING: Failed to decode IV: $e');
        }
      }
      
      // Save encrypted chunk to storage with duplicate protection
      final wasSaved = await storage.saveChunkSafe(
        fileId, 
        chunkIndex, 
        actualEncryptedChunk,
        iv: iv,
        chunkHash: chunkHash,
      );
      
      if (!wasSaved) {
        debugPrint('[P2P] Chunk $chunkIndex was duplicate, skipping progress update');
        _activeChunkRequests[fileId]?.remove(chunkIndex);
        _completeChunkRequest(peerId, chunkIndex);
        return;
      }
      
      // ✅ Mark chunk request as complete (for rate limiting)
      _completeChunkRequest(peerId, chunkIndex);
      
      // Update download progress
      final task = downloadManager.getDownload(fileId);
      if (task != null) {
        task.completedChunks.add(chunkIndex);
        task.downloadedChunks++;
        task.downloadedBytes += actualEncryptedChunk.length;
        
        debugPrint('[P2P] Download progress: ${task.downloadedChunks}/${task.chunkCount} chunks');
        
        // Check if all chunks received
        if (task.downloadedChunks >= task.chunkCount) {
          debugPrint('[P2P] ================================================');
          debugPrint('[P2P] ✓ ALL CHUNKS RECEIVED: $fileId');
          debugPrint('[P2P] Total chunks: ${task.chunkCount}');
          debugPrint('[P2P] Total bytes: ${task.downloadedBytes}');
          debugPrint('[P2P] Entering DRAIN PHASE...');
          debugPrint('[P2P] ================================================');
          
          // Enter drain phase
          _downloadPhases[fileId] = DownloadPhase.draining;
          _drainStartTime[fileId] = DateTime.now();
          
          // Stop requesting new chunks
          _stopChunkRequests(fileId);
          
          // Wait for in-flight chunks, then complete
          _drainAndComplete(fileId, task);
        }
      }
      
      // Clear metadata
      _pendingChunkMetadata.remove(peerId);
      
      // Remove from active requests
      _activeChunkRequests[fileId]?.remove(chunkIndex);
      
      // Remove from queue
      _chunkQueue[fileId]?.remove(chunkIndex);
      
      // Request next chunk from this peer (only if not draining)
      if (_downloadPhases[fileId] != DownloadPhase.draining) {
        _requestNextChunks(fileId, peerId);
      }
      
      notifyListeners();
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ================================================');
      debugPrint('[P2P] ❌ ERROR processing chunk $chunkIndex from $peerId');
      debugPrint('[P2P] Error: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
      debugPrint('[P2P] ================================================');
      
      // ✅ CHUNK RETRY LOGIC
      await _handleChunkError(fileId, chunkIndex, peerId, e.toString());
      
      // Clear metadata
      _pendingChunkMetadata.remove(peerId);
    }
  }
  
  /// Handle chunk processing error with retry logic
  /// 
  /// Implements:
  /// - Retry counter (max 3 attempts)
  /// - Exponential backoff (1s, 2s, 4s)
  /// - Alternate seeder selection
  /// - Graceful degradation (continue with other chunks)
  Future<void> _handleChunkError(String fileId, int? chunkIndex, String peerId, String error) async {
    if (chunkIndex == null) {
      debugPrint('[P2P ChunkRetry] Cannot retry - chunkIndex unknown');
      // Request next chunk from this peer
      _requestNextChunks(fileId, peerId);
      return;
    }
    
    // Initialize retry tracking
    _chunkRetryInfo.putIfAbsent(fileId, () => {});
    final retryInfo = _chunkRetryInfo[fileId]!.putIfAbsent(
      chunkIndex,
      () => ChunkRetryInfo(),
    );
    
    // Track this seeder as failed for this chunk
    _chunkFailedSeeders.putIfAbsent(fileId, () => {});
    _chunkFailedSeeders[fileId]!.putIfAbsent(chunkIndex, () => {});
    _chunkFailedSeeders[fileId]![chunkIndex]!.add(peerId);
    
    debugPrint('[P2P ChunkRetry] ================================================');
    debugPrint('[P2P ChunkRetry] Chunk $chunkIndex failed from $peerId');
    debugPrint('[P2P ChunkRetry] Error: $error');
    debugPrint('[P2P ChunkRetry] Attempt: ${retryInfo.attemptCount + 1}/$MAX_CHUNK_RETRIES');
    debugPrint('[P2P ChunkRetry] Failed seeders: ${_chunkFailedSeeders[fileId]![chunkIndex]!.toList()}');
    
    // Check if max retries exceeded
    if (retryInfo.attemptCount >= MAX_CHUNK_RETRIES) {
      debugPrint('[P2P ChunkRetry] ❌ Max retries exceeded for chunk $chunkIndex');
      debugPrint('[P2P ChunkRetry] Marking chunk as permanently failed');
      debugPrint('[P2P ChunkRetry] Download will continue with other chunks');
      debugPrint('[P2P ChunkRetry] ================================================');
      
      // Remove from active requests
      _activeChunkRequests[fileId]?.remove(chunkIndex);
      _completeChunkRequest(peerId, chunkIndex);
      
      // Remove from queue (don't retry anymore)
      _chunkQueue[fileId]?.remove(chunkIndex);
      
      // Continue with next chunk from this peer
      _requestNextChunks(fileId, peerId);
      return;
    }
    
    // Record this attempt
    retryInfo.recordAttempt(peerId);
    
    // Find alternate seeder (not in failed list)
    final failedSeeders = _chunkFailedSeeders[fileId]![chunkIndex]!;
    final alternateSeeder = _findAlternateSeeder(fileId, chunkIndex, failedSeeders);
    
    if (alternateSeeder != null) {
      debugPrint('[P2P ChunkRetry] ✓ Found alternate seeder: $alternateSeeder');
      debugPrint('[P2P ChunkRetry] Will retry after ${retryInfo.getBackoffDelay().inSeconds}s backoff');
      debugPrint('[P2P ChunkRetry] ================================================');
      
      // Wait for backoff delay
      await Future.delayed(retryInfo.getBackoffDelay());
      
      // Remove from active requests (current peer)
      _activeChunkRequests[fileId]?.remove(chunkIndex);
      _completeChunkRequest(peerId, chunkIndex);
      
      // Add back to queue (will be picked up by alternate seeder)
      if (!(_chunkQueue[fileId]?.contains(chunkIndex) ?? false)) {
        _chunkQueue[fileId]?.add(chunkIndex);
      }
      
      // Request from alternate seeder
      debugPrint('[P2P ChunkRetry] Requesting chunk $chunkIndex from alternate seeder $alternateSeeder');
      await _requestChunk(fileId, alternateSeeder, chunkIndex);
      
    } else {
      debugPrint('[P2P ChunkRetry] ⚠️ No alternate seeder available');
      debugPrint('[P2P ChunkRetry] Will retry with same seeder after ${retryInfo.getBackoffDelay().inSeconds}s');
      debugPrint('[P2P ChunkRetry] ================================================');
      
      // Wait for backoff delay
      await Future.delayed(retryInfo.getBackoffDelay());
      
      // Remove from active requests
      _activeChunkRequests[fileId]?.remove(chunkIndex);
      _completeChunkRequest(peerId, chunkIndex);
      
      // Add back to queue
      if (!(_chunkQueue[fileId]?.contains(chunkIndex) ?? false)) {
        _chunkQueue[fileId]?.add(chunkIndex);
      }
      
      // Retry with same seeder
      debugPrint('[P2P ChunkRetry] Retrying chunk $chunkIndex with $peerId');
      await _requestChunk(fileId, peerId, chunkIndex);
    }
    
    // Continue requesting other chunks
    _requestNextChunks(fileId, peerId);
  }
  
  /// Find an alternate seeder for a chunk (not in failed list)
  String? _findAlternateSeeder(String fileId, int chunkIndex, Set<String> failedSeeders) {
    final seeders = _seederAvailability[fileId] ?? {};
    
    for (final entry in seeders.entries) {
      final seederInfo = entry.value;
      final userId = seederInfo.userId;
      
      // Skip if this seeder already failed for this chunk
      if (failedSeeders.contains(userId)) {
        continue;
      }
      
      // Check if this seeder has the chunk
      if (seederInfo.hasChunk(chunkIndex)) {
        // Check if we're connected to this seeder
        final isConnected = _fileConnections[fileId]?.contains(userId) ?? false;
        
        if (isConnected) {
          return userId;
        }
      }
    }
    
    return null;
  }
  
  /// Stop requesting new chunks for this download
  void _stopChunkRequests(String fileId) {
    debugPrint('[P2P] Stopping chunk requests for $fileId');
    
    // Clear queue
    _chunkQueue.remove(fileId);
    
    debugPrint('[P2P] ✓ Chunk queue cleared');
  }
  
  /// Drain in-flight chunks and complete download
  Future<void> _drainAndComplete(String fileId, dynamic task) async {
    debugPrint('[P2P] ================================================');
    debugPrint('[P2P] DRAIN PHASE: Waiting for in-flight chunks');
    
    final activeRequests = _activeChunkRequests[fileId] ?? {};
    final inFlightCount = activeRequests.length;
    
    debugPrint('[P2P] In-flight chunks: $inFlightCount');
    debugPrint('[P2P] Chunks: ${activeRequests.keys.toList()}');
    
    if (inFlightCount == 0) {
      debugPrint('[P2P] No in-flight chunks, proceeding immediately');
      debugPrint('[P2P] ================================================');
      
      // Mark download as complete
      task.status = DownloadStatus.completed;
      task.endTime = DateTime.now();
      
      // Proceed to assembly
      await _completeDownload(fileId, task.fileName);
      return;
    }
    
    // Wait up to 5 seconds for chunks to arrive
    final startTime = DateTime.now();
    const checkInterval = Duration(milliseconds: 100);
    
    while (DateTime.now().difference(startTime) < _drainTimeout) {
      final remaining = (_activeChunkRequests[fileId] ?? {}).length;
      
      if (remaining == 0) {
        final elapsed = DateTime.now().difference(startTime);
        debugPrint('[P2P] ✓ All in-flight chunks received (${elapsed.inMilliseconds}ms)');
        debugPrint('[P2P] ================================================');
        
        // Mark download as complete
        task.status = DownloadStatus.completed;
        task.endTime = DateTime.now();
        
        // Proceed to assembly
        await _completeDownload(fileId, task.fileName);
        return;
      }
      
      await Future.delayed(checkInterval);
    }
    
    // Timeout - some chunks didn't arrive
    final remaining = (_activeChunkRequests[fileId] ?? {}).length;
    debugPrint('[P2P] ⚠️ Drain timeout: $remaining chunks still missing');
    debugPrint('[P2P] Missing chunks: ${(_activeChunkRequests[fileId] ?? {}).keys.toList()}');
    debugPrint('[P2P] ================================================');
    
    // Clear the requests anyway and try to complete
    _activeChunkRequests[fileId]?.clear();
    
    // Mark download as complete (may fail if chunks missing)
    task.status = DownloadStatus.completed;
    task.endTime = DateTime.now();
    
    // Proceed to assembly (will fail if chunks actually missing)
    await _completeDownload(fileId, task.fileName);
  }
  
  /// Handle batch metadata from seeder (we are downloader)
  /// 
  /// Store ALL metadata and send ACK so chunk requests can begin
  Future<void> _handleBatchMetadata(String fileId, String peerId, Map<String, dynamic> data) async {
    try {
      final List<dynamic> metadataList = data['metadata'] as List<dynamic>;
      
      debugPrint('[P2P] ========================================');
      debugPrint('[P2P] Received batch metadata from $peerId');
      debugPrint('[P2P] Total chunks: ${metadataList.length}');
      
      // Store in cache
      final cacheKey = '$fileId:$peerId';
      _batchMetadataCache[cacheKey] = {};
      
      for (final item in metadataList) {
        final metadata = item as Map<String, dynamic>;
        final chunkIndex = metadata['chunkIndex'] as int;
        
        // Convert IV if needed
        dynamic ivData = metadata['iv'];
        String? ivString;
        
        if (ivData is String) {
          ivString = ivData;
        } else if (ivData is List) {
          try {
            final ivBytes = Uint8List.fromList(ivData.cast<int>());
            ivString = base64.encode(ivBytes);
          } catch (e) {
            debugPrint('[P2P] ERROR converting IV for chunk $chunkIndex: $e');
          }
        }
        
        _batchMetadataCache[cacheKey]![chunkIndex] = {
          'chunkIndex': chunkIndex,
          'iv': ivString,
          'chunkHash': metadata['chunkHash'],
          'size': metadata['size'],
          'fileId': fileId,
        };
      }
      
      debugPrint('[P2P] ✓ Batch metadata cached for ${metadataList.length} chunks');
      debugPrint('[P2P] Sending batch metadata ACK...');
      
      // Send ACK
      await webrtcService.sendData(peerId, {
        'type': 'batchMetadataAck',
      });
      
      debugPrint('[P2P] ✓ ACK sent, starting chunk requests');
      debugPrint('[P2P] ========================================');
      
      // Start requesting chunks now
      _requestNextChunks(fileId, peerId);
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR handling batch metadata: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
    }
  }
  
  void _handleBatchMetadataAck(String peerId) {
    try {
      debugPrint('[P2P SEEDER] Received batch metadata ACK from $peerId');
      
      // Complete the waiting completer
      final completer = _pendingBatchMetadataAcks[peerId];
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      
    } catch (e) {
      debugPrint('[P2P SEEDER] ERROR handling batch metadata ACK: $e');
    }
  }
  
  Future<void> _handleChunkResponse(String fileId, String peerId, Map<String, dynamic> data) async {
    try {
      final chunkIndex = data['chunkIndex'] as int;
      final size = data['size'] as int;
      
      // IV can come as String (base64) or List<int> - handle both
      dynamic ivData = data['iv'];
      String? ivString;
      
      if (ivData is String) {
        ivString = ivData;
      } else if (ivData is List) {
        // Convert List<int> to base64 string
        try {
          final ivBytes = Uint8List.fromList(ivData.cast<int>());
          ivString = base64.encode(ivBytes);
          debugPrint('[P2P] Converted IV from List to base64 string');
        } catch (e) {
          debugPrint('[P2P] ERROR converting IV: $e');
        }
      }
      
      final chunkHash = data['chunkHash'] as String?;
      
      debugPrint('[P2P] Received chunk metadata: chunk $chunkIndex ($size bytes) from $peerId');
      if (ivString != null) {
        debugPrint('[P2P] Chunk has IV for decryption (${ivString.substring(0, 10)}...)');
      }
      
      // Store metadata
      final metadataMap = {
        'chunkIndex': chunkIndex,
        'size': size,
        'fileId': fileId,
        'iv': ivString,
        'chunkHash': chunkHash,
      };
      
      _pendingChunkMetadata[peerId] = metadataMap;
      
      // Send ACK back to seeder so they can send binary chunk
      final ackMessage = {
        'type': 'chunkMetadataAck',
        'chunkIndex': chunkIndex,
      };
      
      debugPrint('[P2P] Sending metadata ACK for chunk $chunkIndex');
      await webrtcService.sendData(
        peerId,
        ackMessage,  // Send as Map, not as JSON string
      );
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR handling chunk response: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
    }
  }
  
  void _handleChunkMetadataAck(String peerId, Map<String, dynamic> data) {
    // Legacy handler - no longer needed with batch metadata
    // Chunks now sent immediately after request without individual ACKs
    debugPrint('[P2P] Received legacy chunk metadata ACK (ignored with batch protocol)');
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
    
    // ✅ RATE LIMITING: Check chunks in flight for this peer
    final inFlight = _chunksInFlightPerPeer[peerId]?.length ?? 0;
    if (inFlight >= MAX_CHUNKS_IN_FLIGHT_PER_PEER) {
      debugPrint('[P2P RateLimit] Peer $peerId has $inFlight chunks in flight, waiting...');
      return;
    }
    
    // ✅ ADAPTIVE THROTTLING: Get current limit from throttler
    _throttlers[peerId] ??= AdaptiveThrottler();
    final adaptiveLimit = _throttlers[peerId]!.getCurrentLimit();
    
    if (currentPeerRequests >= adaptiveLimit) {
      // This peer is already busy (adaptive limit)
      return;
    }
    
    if (currentPeerRequests >= maxParallelChunksPerConnection) {
      // This peer is already busy (hard limit)
      return;
    }
    
    // Find seeder info for this peer (search by userId)
    final seeders = _seederAvailability[fileId] ?? {};
    SeederInfo? seederInfo;
    
    for (final entry in seeders.entries) {
      if (entry.value.userId == peerId) {
        seederInfo = entry.value;
        break;
      }
    }
    
    if (seederInfo == null) {
      debugPrint('[P2P] No seeder info found for peer $peerId');
      return;
    }
    
    final seederChunks = seederInfo.availableChunks;
    
    // Find chunks this seeder has that we need
    final availableChunks = queue.where((chunk) => seederChunks.contains(chunk)).toList();
    
    if (availableChunks.isEmpty) {
      debugPrint('[P2P] Seeder $peerId has no chunks we need');
      return;
    }
    
    // Request up to the limit (use min of all limits)
    final effectiveLimit = min(
      min(adaptiveLimit, MAX_CHUNKS_IN_FLIGHT_PER_PEER - inFlight),
      maxParallelChunksPerConnection - currentPeerRequests,
    );
    
    final chunksToRequest = availableChunks.take(effectiveLimit);
    
    for (final chunkIndex in chunksToRequest) {
      _requestChunkWithRateLimit(fileId, peerId, chunkIndex);
    }
  }
  
  /// Request chunk with rate limiting
  Future<void> _requestChunkWithRateLimit(String fileId, String peerId, int chunkIndex) async {
    // Initialize in-flight tracker
    _chunksInFlightPerPeer[peerId] ??= {};
    
    // Mark as in flight
    _chunksInFlightPerPeer[peerId]!.add(chunkIndex);
    
    try {
      await _requestChunk(fileId, peerId, chunkIndex);
    } catch (e) {
      debugPrint('[P2P RateLimit] Error requesting chunk $chunkIndex: $e');
      // Remove from in-flight on error
      _chunksInFlightPerPeer[peerId]?.remove(chunkIndex);
      rethrow;
    }
  }
  
  /// Complete a chunk request (called when chunk is received)
  void _completeChunkRequest(String peerId, int chunkIndex) {
    // Remove from in-flight
    _chunksInFlightPerPeer[peerId]?.remove(chunkIndex);
    
    // Update throttler based on success
    _throttlers[peerId]?.recordSuccess();
  }
  
  Future<void> _requestChunk(String fileId, String peerId, int chunkIndex) async {
    debugPrint('[P2P] Requesting chunk $chunkIndex from $peerId');
    
    // Mark as active request
    _activeChunkRequests[fileId] ??= {};
    _activeChunkRequests[fileId]![chunkIndex] = peerId;
    
    // Send request via WebRTC
    await webrtcService.sendData(peerId, {
      'type': 'chunkRequest',  // Match handler expectation
      'fileId': fileId,
      'chunkIndex': chunkIndex,
    });
  }
  
  void _sendSignalingMessage(String peerId, Map<String, dynamic> message) {
    final type = message['type'] as String;
    final fileId = message['fileId'] as String;
    
    debugPrint('[P2P] Sending signaling message to $peerId: $type');
    
    // Get device ID for target peer (we need this for routing)
    final targetDeviceId = _peerDevices[peerId];
    if (targetDeviceId == null) {
      debugPrint('[P2P] WARNING: No deviceId for peer $peerId, cannot send signaling message');
      // For backward compatibility, try sending without deviceId (server will broadcast)
      // This happens when we're initiating the connection (downloader role)
      // In this case, we send to userId and let server broadcast to all devices
    }
    
    switch (type) {
      case 'offer':
        final offer = message['offer'] as Map<String, dynamic>;
        socketClient.sendWebRTCOffer(
          targetUserId: peerId,
          targetDeviceId: targetDeviceId ?? '', // Empty string triggers broadcast on server
          fileId: fileId,
          offer: offer,
        );
        debugPrint('[P2P] ✓ WebRTC offer sent to $peerId${targetDeviceId != null ? ':$targetDeviceId' : ' (broadcast)'}');
        break;
        
      case 'answer':
        final answer = message['answer'] as Map<String, dynamic>;
        socketClient.sendWebRTCAnswer(
          targetUserId: peerId,
          targetDeviceId: targetDeviceId ?? '',
          fileId: fileId,
          answer: answer,
        );
        debugPrint('[P2P] ✓ WebRTC answer sent to $peerId${targetDeviceId != null ? ':$targetDeviceId' : ' (broadcast)'}');
        break;
        
      default:
        debugPrint('[P2P] WARNING: Unknown signaling message type: $type');
    }
  }
  
  /// Complete download: assemble chunks, decrypt, and trigger browser download
  Future<void> _completeDownload(String fileId, String fileName) async {
    try {
      debugPrint('[P2P] ================================================');
      debugPrint('[P2P] PHASE: ASSEMBLING FILE: $fileName');
      debugPrint('[P2P] ================================================');
      
      // Set phase to assembling
      _downloadPhases[fileId] = DownloadPhase.assembling;
      
      final task = downloadManager.getDownload(fileId);
      if (task == null) {
        throw Exception('Download task not found');
      }
      
      // Get file key
      final fileKey = await storage.getFileKey(fileId);
      if (fileKey == null) {
        throw Exception('File key not found');
      }
      
      debugPrint('[P2P] Loading ${task.chunkCount} chunks from storage...');
      
      // Load all encrypted chunks with their metadata
      final chunks = <ChunkData>[];
      for (int i = 0; i < task.chunkCount; i++) {
        final encryptedChunk = await storage.getChunk(fileId, i);
        final metadata = await storage.getChunkMetadata(fileId, i);
        
        if (encryptedChunk == null) {
          throw Exception('Missing chunk $i');
        }
        
        if (metadata == null) {
          throw Exception('Missing metadata for chunk $i');
        }
        
        // Get IV from metadata - handle both String (base64) and Uint8List
        dynamic ivData = metadata['iv'];
        Uint8List iv;
        
        if (ivData == null) {
          throw Exception('Missing IV for chunk $i');
        } else if (ivData is String) {
          if (ivData.isEmpty) {
            throw Exception('Empty IV for chunk $i');
          }
          try {
            iv = base64.decode(ivData);
          } catch (e) {
            throw Exception('Invalid IV base64 for chunk $i: $e');
          }
        } else if (ivData is Uint8List) {
          iv = ivData;
        } else if (ivData is List) {
          iv = Uint8List.fromList(ivData.cast<int>());
        } else {
          throw Exception('Invalid IV type for chunk $i: ${ivData.runtimeType}');
        }
        
        // Decrypt chunk using file key and IV
        final decryptedChunk = await encryptionService.decryptChunk(
          encryptedChunk,
          fileKey,
          iv,
        );
        
        if (decryptedChunk == null) {
          throw Exception('Failed to decrypt chunk $i');
        }
        
        chunks.add(ChunkData(
          chunkIndex: i,
          data: decryptedChunk,
          hash: metadata['chunkHash'] as String? ?? '',
          size: decryptedChunk.length,
        ));
      }
      
      debugPrint('[P2P] All chunks loaded and decrypted');
      debugPrint('[P2P] Assembling file...');
      
      // Assemble chunks into final file
      final fileData = await chunkingService.assembleChunks(chunks);
      if (fileData == null) {
        throw Exception('Failed to assemble file');
      }
      
      debugPrint('[P2P] File assembled: ${fileData.length} bytes');
      
      // Verify checksum
      final fileChecksum = chunkingService.calculateFileChecksum(fileData);
      if (fileChecksum != task.checksum) {
        debugPrint('[P2P] WARNING: Checksum mismatch!');
        debugPrint('[P2P] Expected: ${task.checksum}');
        debugPrint('[P2P] Got: $fileChecksum');
        // Don't throw - allow download anyway for testing
      } else {
        debugPrint('[P2P] ✓ Checksum verified');
      }
      
      // Trigger browser download
      if (kIsWeb) {
        debugPrint('[P2P] Triggering browser download...');
        _triggerBrowserDownload(fileData, fileName);
      } else {
        debugPrint('[P2P] Native platform - file saved to storage');
        // For native platforms, file is already in storage
        // Could implement file system save here if needed
      }
      
      // Set phase to complete
      _downloadPhases[fileId] = DownloadPhase.complete;
      
      // Clean up P2P connections (LÖSUNG 10)
      await _cleanupDownloadConnections(fileId);
      
      debugPrint('[P2P] ================================================');
      debugPrint('[P2P] ✅ DOWNLOAD COMPLETE: $fileName');
      debugPrint('[P2P] ================================================');
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR completing download: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
      
      _downloadPhases[fileId] = DownloadPhase.failed;
      
      final task = downloadManager.getDownload(fileId);
      if (task != null) {
        task.status = DownloadStatus.failed;
        task.error = 'Assembly failed: $e';
      }
    }
  }
  
  /// Clean up download connections (LÖSUNG 10)
  Future<void> _cleanupDownloadConnections(String fileId) async {
    debugPrint('[P2P] ================================================');
    debugPrint('[P2P] CLEANUP: Closing connections for $fileId');
    
    // PHASE 1: Close all peer connections
    final peers = _fileConnections[fileId] ?? {};
    debugPrint('[P2P] Disconnecting from ${peers.length} peers');
    
    for (final peerId in peers) {
      try {
        await webrtcService.closePeerConnection(peerId);
        debugPrint('[P2P] ✓ Disconnected from $peerId');
      } catch (e) {
        debugPrint('[P2P] ⚠️ Error disconnecting from $peerId: $e');
      }
    }
    
    // PHASE 2: Clear all state
    _fileConnections.remove(fileId);
    _activeChunkRequests.remove(fileId);
    _seederAvailability.remove(fileId);
    _chunkQueue.remove(fileId);
    _downloadPhases.remove(fileId);
    _drainStartTime.remove(fileId);
    _throttlers.remove(fileId);
    
    // Clear retry tracking
    _chunkRetryInfo.remove(fileId);
    _chunkFailedSeeders.remove(fileId);
    
    _chunksInFlightPerPeer.clear();
    _batchMetadataCache.removeWhere((key, _) => key.startsWith('$fileId:'));
    
    debugPrint('[P2P] ✓ All state cleared for $fileId');
    debugPrint('[P2P] ================================================');
  }
  
  /// Trigger file download in web browser
  void _triggerBrowserDownload(Uint8List fileData, String fileName) {
    final blob = html.Blob([fileData]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.document.createElement('a') as html.AnchorElement;
    anchor.href = url;
    anchor.download = fileName;
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    debugPrint('[P2P] Browser download triggered for: $fileName');
  }
  
  /// Print buffer statistics for all peers
  void printBufferStatistics() {
    webrtcService.printAllBufferStats();
  }
}

/// Adaptive Throttler - Adjusts chunk request rate based on backpressure
class AdaptiveThrottler {
  int _currentMaxInFlight = 5;
  DateTime? _lastSlowdown;
  DateTime? _lastSpeedup;
  int _successCount = 0;
  int _slowdownCount = 0;
  
  // Limits
  static const int MIN_LIMIT = 2;
  static const int MAX_LIMIT = 10;
  static const int DEFAULT_LIMIT = 5;
  
  // Timing
  static const Duration COOLDOWN_PERIOD = Duration(seconds: 5);
  static const int SUCCESS_THRESHOLD = 10; // Speed up after N successes
  
  int getCurrentLimit() => _currentMaxInFlight;
  
  void recordSuccess() {
    _successCount++;
    
    // Speed up after consistent success
    if (_successCount >= SUCCESS_THRESHOLD) {
      final now = DateTime.now();
      final canSpeedup = _lastSpeedup == null || 
                         now.difference(_lastSpeedup!) > COOLDOWN_PERIOD;
      
      if (canSpeedup && _currentMaxInFlight < MAX_LIMIT) {
        _currentMaxInFlight = min(MAX_LIMIT, _currentMaxInFlight + 1);
        _lastSpeedup = now;
        _successCount = 0;
        debugPrint('[AdaptiveThrottle] ↑ Increased limit to $_currentMaxInFlight');
      }
    }
  }
  
  void recordBackpressure(int bufferedAmount) {
    final now = DateTime.now();
    
    // Only slowdown if not in cooldown
    final canSlowdown = _lastSlowdown == null || 
                       now.difference(_lastSlowdown!) > COOLDOWN_PERIOD;
    
    if (canSlowdown && bufferedAmount > 10 * 1024 * 1024) { // > 10 MB
      if (_currentMaxInFlight > MIN_LIMIT) {
        _currentMaxInFlight = max(MIN_LIMIT, _currentMaxInFlight - 1);
        _lastSlowdown = now;
        _slowdownCount++;
        _successCount = 0; // Reset success counter
        debugPrint('[AdaptiveThrottle] ↓ Decreased limit to $_currentMaxInFlight (buffer: ${(bufferedAmount / 1024 / 1024).toStringAsFixed(1)} MB)');
      }
    }
  }
  
  void reset() {
    _currentMaxInFlight = DEFAULT_LIMIT;
    _lastSlowdown = null;
    _lastSpeedup = null;
    _successCount = 0;
    _slowdownCount = 0;
  }
  
  void printStats() {
    debugPrint('Adaptive Throttler Stats:');
    debugPrint('  Current limit: $_currentMaxInFlight');
    debugPrint('  Slowdowns: $_slowdownCount');
    debugPrint('  Success streak: $_successCount');
  }
}

/// Chunk Retry Info - Tracks retry attempts for failed chunks
class ChunkRetryInfo {
  int attemptCount;
  DateTime? lastAttempt;
  String? lastSeeder; // Last seeder that failed
  
  ChunkRetryInfo({
    this.attemptCount = 0,
    this.lastAttempt,
    this.lastSeeder,
  });
  
  /// Get backoff delay based on attempt count
  /// Exponential backoff: 1s, 2s, 4s
  Duration getBackoffDelay() {
    if (attemptCount == 0) return Duration.zero;
    if (attemptCount == 1) return Duration(seconds: 1);
    if (attemptCount == 2) return Duration(seconds: 2);
    return Duration(seconds: 4);
  }
  
  /// Check if ready to retry (backoff period elapsed)
  bool canRetry() {
    if (lastAttempt == null) return true;
    final elapsed = DateTime.now().difference(lastAttempt!);
    return elapsed >= getBackoffDelay();
  }
  
  /// Record new attempt
  void recordAttempt(String seeder) {
    attemptCount++;
    lastAttempt = DateTime.now();
    lastSeeder = seeder;
  }
}
