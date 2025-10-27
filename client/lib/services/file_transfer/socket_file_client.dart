import 'dart:async';
import 'package:flutter/foundation.dart';

/// Socket.IO Client for P2P File Sharing
/// 
/// Wraps P2P-specific Socket.IO events and provides
/// a clean interface for file announcements, discovery, and signaling
class SocketFileClient {
  // This should be the existing Socket.IO connection from your app
  final dynamic socket; // socket_io_client.Socket
  
  // Event listeners
  final Map<String, List<Function>> _eventListeners = {};
  
  SocketFileClient({required this.socket}) {
    _setupEventListeners();
  }
  
  // ============================================
  // FILE ANNOUNCEMENT & DISCOVERY
  // ============================================
  
  /// Announce a file to the network
  Future<Map<String, dynamic>> announceFile({
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required List<int> availableChunks,
  }) async {
    final completer = Completer<Map<String, dynamic>>();
    
    socket.emitWithAck('announceFile', {
      'fileId': fileId,
      'fileName': fileName,
      'mimeType': mimeType,
      'fileSize': fileSize,
      'checksum': checksum,
      'chunkCount': chunkCount,
      'availableChunks': availableChunks,
    }, ack: (data) {
      if (data['success'] == true) {
        completer.complete(data);
      } else {
        completer.completeError(data['error'] ?? 'Unknown error');
      }
    });
    
    return completer.future;
  }
  
  /// Unannounce a file (stop seeding)
  Future<bool> unannounceFile(String fileId) async {
    final completer = Completer<bool>();
    
    socket.emitWithAck('unannounceFile', {
      'fileId': fileId,
    }, ack: (data) {
      completer.complete(data['success'] == true);
    });
    
    return completer.future;
  }
  
  /// Update available chunks for a file
  Future<bool> updateAvailableChunks(String fileId, List<int> availableChunks) async {
    final completer = Completer<bool>();
    
    socket.emitWithAck('updateAvailableChunks', {
      'fileId': fileId,
      'availableChunks': availableChunks,
    }, ack: (data) {
      completer.complete(data['success'] == true);
    });
    
    return completer.future;
  }
  
  /// Get file information and seeders
  Future<Map<String, dynamic>> getFileInfo(String fileId) async {
    final completer = Completer<Map<String, dynamic>>();
    
    socket.emitWithAck('getFileInfo', {
      'fileId': fileId,
    }, ack: (data) {
      if (data['success'] == true) {
        completer.complete(data['fileInfo']);
      } else {
        completer.completeError(data['error'] ?? 'File not found');
      }
    });
    
    return completer.future;
  }
  
  /// Register as downloading a file (leecher)
  Future<bool> registerLeecher(String fileId) async {
    final completer = Completer<bool>();
    
    socket.emitWithAck('registerLeecher', {
      'fileId': fileId,
    }, ack: (data) {
      completer.complete(data['success'] == true);
    });
    
    return completer.future;
  }
  
  /// Unregister as downloading a file
  Future<bool> unregisterLeecher(String fileId) async {
    final completer = Completer<bool>();
    
    socket.emitWithAck('unregisterLeecher', {
      'fileId': fileId,
    }, ack: (data) {
      completer.complete(data['success'] == true);
    });
    
    return completer.future;
  }
  
  /// Search for files by name or checksum
  Future<List<Map<String, dynamic>>> searchFiles(String query) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    
    socket.emitWithAck('searchFiles', {
      'query': query,
    }, ack: (data) {
      if (data['success'] == true) {
        final results = (data['results'] as List)
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        completer.complete(results);
      } else {
        completer.completeError(data['error'] ?? 'Search failed');
      }
    });
    
    return completer.future;
  }
  
  /// Get all active files (with seeders)
  Future<List<Map<String, dynamic>>> getActiveFiles() async {
    final completer = Completer<List<Map<String, dynamic>>>();
    
    socket.emitWithAck('getActiveFiles', null, ack: (data) {
      if (data['success'] == true) {
        final files = (data['files'] as List)
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        completer.complete(files);
      } else {
        completer.completeError(data['error'] ?? 'Failed to get files');
      }
    });
    
    return completer.future;
  }
  
  /// Get available chunks from seeders
  Future<Map<String, List<int>>> getAvailableChunks(String fileId) async {
    final completer = Completer<Map<String, List<int>>>();
    
    socket.emitWithAck('getAvailableChunks', {
      'fileId': fileId,
    }, ack: (data) {
      if (data['success'] == true) {
        final chunks = <String, List<int>>{};
        final rawChunks = data['chunks'] as Map;
        
        for (final entry in rawChunks.entries) {
          chunks[entry.key] = List<int>.from(entry.value);
        }
        
        completer.complete(chunks);
      } else {
        completer.completeError(data['error'] ?? 'Failed to get chunks');
      }
    });
    
    return completer.future;
  }
  
  // ============================================
  // WEBRTC SIGNALING
  // ============================================
  
  /// Send WebRTC offer to peer
  void sendWebRTCOffer({
    required String targetUserId,
    required String targetDeviceId,
    required String fileId,
    required Map<String, dynamic> offer,
  }) {
    socket.emit('file:webrtc-offer', {
      'targetUserId': targetUserId,
      'targetDeviceId': targetDeviceId,
      'fileId': fileId,
      'offer': offer,
    });
  }
  
  /// Send WebRTC answer to peer
  void sendWebRTCAnswer({
    required String targetUserId,
    required String targetDeviceId,
    required String fileId,
    required Map<String, dynamic> answer,
  }) {
    socket.emit('file:webrtc-answer', {
      'targetUserId': targetUserId,
      'targetDeviceId': targetDeviceId,
      'fileId': fileId,
      'answer': answer,
    });
  }
  
  /// Send ICE candidate to peer
  void sendICECandidate({
    required String targetUserId,
    required String targetDeviceId,
    required String fileId,
    required Map<String, dynamic> candidate,
  }) {
    socket.emit('file:webrtc-ice', {
      'targetUserId': targetUserId,
      'targetDeviceId': targetDeviceId,
      'fileId': fileId,
      'candidate': candidate,
    });
  }
  
  /// Send chunk request to peer
  void sendChunkRequest({
    required String targetUserId,
    required String targetDeviceId,
    required String fileId,
    required int chunkIndex,
  }) {
    socket.emit('file:chunk-request', {
      'targetUserId': targetUserId,
      'targetDeviceId': targetDeviceId,
      'fileId': fileId,
      'chunkIndex': chunkIndex,
    });
  }
  
  /// Send chunk response to peer
  void sendChunkResponse({
    required String targetUserId,
    required String targetDeviceId,
    required String fileId,
    required int chunkIndex,
    required String encryptedData, // base64
    required String iv, // base64
    required String chunkHash,
  }) {
    socket.emit('file:chunk-response', {
      'targetUserId': targetUserId,
      'targetDeviceId': targetDeviceId,
      'fileId': fileId,
      'chunkIndex': chunkIndex,
      'encryptedData': encryptedData,
      'iv': iv,
      'chunkHash': chunkHash,
    });
  }
  
  // ============================================
  // EVENT LISTENERS
  // ============================================
  
  /// Listen for new file announcements
  void onFileAnnounced(Function(Map<String, dynamic>) callback) {
    _addEventListener('fileAnnounced', callback);
  }
  
  /// Listen for seeder count updates
  void onFileSeederUpdate(Function(Map<String, dynamic>) callback) {
    _addEventListener('fileSeederUpdate', callback);
  }
  
  /// Listen for WebRTC offers
  void onWebRTCOffer(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:webrtc-offer', callback);
  }
  
  /// Listen for WebRTC answers
  void onWebRTCAnswer(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:webrtc-answer', callback);
  }
  
  /// Listen for ICE candidates
  void onICECandidate(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:webrtc-ice', callback);
  }
  
  /// Listen for chunk requests
  void onChunkRequest(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:chunk-request', callback);
  }
  
  /// Listen for chunk responses
  void onChunkResponse(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:chunk-response', callback);
  }
  
  // ============================================
  // PRIVATE METHODS
  // ============================================
  
  void _setupEventListeners() {
    // File announcements
    socket.on('fileAnnounced', (data) {
      _notifyListeners('fileAnnounced', data);
    });
    
    socket.on('fileSeederUpdate', (data) {
      _notifyListeners('fileSeederUpdate', data);
    });
    
    // WebRTC signaling
    socket.on('file:webrtc-offer', (data) {
      _notifyListeners('file:webrtc-offer', data);
    });
    
    socket.on('file:webrtc-answer', (data) {
      _notifyListeners('file:webrtc-answer', data);
    });
    
    socket.on('file:webrtc-ice', (data) {
      _notifyListeners('file:webrtc-ice', data);
    });
    
    // Chunk transfer
    socket.on('file:chunk-request', (data) {
      _notifyListeners('file:chunk-request', data);
    });
    
    socket.on('file:chunk-response', (data) {
      _notifyListeners('file:chunk-response', data);
    });
  }
  
  void _addEventListener(String event, Function callback) {
    _eventListeners.putIfAbsent(event, () => []);
    _eventListeners[event]!.add(callback);
  }
  
  void _notifyListeners(String event, dynamic data) {
    final listeners = _eventListeners[event];
    if (listeners != null) {
      for (final listener in listeners) {
        try {
          listener(data);
        } catch (e) {
          debugPrint('[SocketFileClient] Error in listener for $event: $e');
        }
      }
    }
  }
  
  /// Remove all event listeners
  void dispose() {
    _eventListeners.clear();
  }
}
