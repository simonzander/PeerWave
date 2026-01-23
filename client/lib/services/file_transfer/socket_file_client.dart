import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/seeder_info.dart';
import '../socket_service.dart'
    if (dart.library.io) '../socket_service_native.dart';

/// Socket.IO Client for P2P File Sharing
///
/// Wraps P2P-specific Socket.IO events and provides
/// a clean interface for file announcements, discovery, and signaling
///
/// Uses SocketService() directly to always use the active server connection
class SocketFileClient {
  // Event listeners
  final Map<String, List<Function>> _eventListeners = {};

  SocketFileClient() {
    _setupEventListeners();
  }

  /// Get current socket from SocketService (always uses active server)
  dynamic get _socket => SocketService().socket;

  // ============================================
  // FILE ANNOUNCEMENT & DISCOVERY
  // ============================================

  /// Announce a file to the network (fileName is NOT sent for privacy)
  Future<Map<String, dynamic>> announceFile({
    required String fileId,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required List<int> availableChunks,
    List<String>? sharedWith, // ← Optional share list
  }) async {
    // Check socket connection
    final socket = _socket;
    if (socket == null) {
      final isConnected = SocketService().isConnected;
      throw Exception(
        'Socket not connected (isConnected: $isConnected). Please check your internet connection and try again.',
      );
    }

    final completer = Completer<Map<String, dynamic>>();

    // Add timeout to prevent hanging
    Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.completeError('Announce timeout after 30 seconds');
      }
    });

    socket.emitWithAck(
      'announceFile',
      {
        'fileId': fileId,
        'mimeType': mimeType,
        'fileSize': fileSize,
        'checksum': checksum,
        'chunkCount': chunkCount,
        'availableChunks': availableChunks,
        'sharedWith': sharedWith, // ← NEU
      },
      ack: (data) {
        if (!completer.isCompleted) {
          if (data['success'] == true) {
            final chunkQuality = data['chunkQuality'] ?? 0;
            debugPrint(
              '[FILE CLIENT] ✓ File announced with quality: $chunkQuality%',
            );
            completer.complete(data);
          } else {
            completer.completeError(data['error'] ?? 'Unknown error');
          }
        }
      },
    );

    return completer.future;
  }

  /// Unannounce a file (stop seeding)
  Future<bool> unannounceFile(String fileId) async {
    final completer = Completer<bool>();

    _socket?.emitWithAck(
      'unannounceFile',
      {'fileId': fileId},
      ack: (data) {
        completer.complete(data['success'] == true);
      },
    );

    return completer.future;
  }

  /// Update available chunks for a file
  Future<bool> updateAvailableChunks(
    String fileId,
    List<int> availableChunks,
  ) async {
    final completer = Completer<bool>();

    _socket?.emitWithAck(
      'updateAvailableChunks',
      {'fileId': fileId, 'availableChunks': availableChunks},
      ack: (data) {
        completer.complete(data['success'] == true);
      },
    );

    return completer.future;
  }

  /// Get file information and seeders
  Future<Map<String, dynamic>> getFileInfo(String fileId) async {
    if (_socket == null) {
      throw Exception('Socket not connected');
    }

    final completer = Completer<Map<String, dynamic>>();

    Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        completer.completeError('Get file info timeout after 15 seconds');
      }
    });

    _socket?.emitWithAck(
      'getFileInfo',
      {'fileId': fileId},
      ack: (data) {
        if (!completer.isCompleted) {
          if (data['success'] == true) {
            completer.complete(data['fileInfo']);
          } else {
            completer.completeError(data['error'] ?? 'File not found');
          }
        }
      },
    );

    return completer.future;
  }

  /// Register as downloading a file (leecher)
  Future<bool> registerLeecher(String fileId) async {
    final completer = Completer<bool>();

    _socket?.emitWithAck(
      'registerLeecher',
      {'fileId': fileId},
      ack: (data) {
        completer.complete(data['success'] == true);
      },
    );

    return completer.future;
  }

  /// Unregister as downloading a file
  Future<bool> unregisterLeecher(String fileId) async {
    final completer = Completer<bool>();

    _socket?.emitWithAck(
      'unregisterLeecher',
      {'fileId': fileId},
      ack: (data) {
        completer.complete(data['success'] == true);
      },
    );

    return completer.future;
  }

  /// Get current sharedWith list from server (for sync before reannouncement)
  Future<List<String>?> getSharedWith(String fileId) async {
    if (_socket == null) {
      return null;
    }

    final completer = Completer<List<String>?>();

    Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        completer.complete(null); // Return null on timeout
      }
    });

    _socket?.emitWithAck(
      'file:get-sharedWith',
      {'fileId': fileId},
      ack: (data) {
        if (!completer.isCompleted) {
          if (data['success'] == true && data['sharedWith'] != null) {
            final sharedWith = (data['sharedWith'] as List).cast<String>();
            completer.complete(sharedWith);
          } else {
            completer.complete(null);
          }
        }
      },
    );

    return completer.future;
  }

  /// Update file share - add or revoke users (NEW SECURE VERSION)
  ///
  /// Permission Model:
  /// - Creator can add/revoke anyone
  /// - Any seeder can add users (but not revoke)
  ///
  /// Rate Limited: Max 10 operations per minute
  /// Size Limited: Max 1000 users in sharedWith
  Future<Map<String, dynamic>> updateFileShare({
    required String fileId,
    required String action, // 'add' | 'revoke'
    required List<String> userIds,
  }) async {
    // Check socket connection
    final socketService = SocketService();
    final socket = socketService.socket;
    final isConnected = socketService.isConnected;

    debugPrint(
      '[FILE CLIENT] updateFileShare check: socket=${socket != null}, '
      'socket.connected=${socket?.connected}, isConnected=$isConnected',
    );

    if (socket == null) {
      throw Exception(
        'Socket not connected (socket=null, isConnected: $isConnected). '
        'Please check your internet connection and try again.',
      );
    }

    final completer = Completer<Map<String, dynamic>>();

    debugPrint(
      '[FILE CLIENT] Updating file share: $action ${userIds.length} users for $fileId',
    );

    // Add timeout to prevent hanging
    Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.completeError('Share update timeout after 30 seconds');
      }
    });

    socket.emitWithAck(
      'updateFileShare',
      {'fileId': fileId, 'action': action, 'userIds': userIds},
      ack: (data) {
        if (!completer.isCompleted) {
          if (data['success'] == true) {
            final successCount = data['successCount'] ?? 0;
            final failCount = data['failCount'] ?? 0;
            final totalUsers = data['totalUsers'] ?? 0;

            debugPrint(
              '[FILE CLIENT] ✓ Share updated: $successCount succeeded, $failCount failed, total: $totalUsers',
            );
            completer.complete(data);
          } else {
            debugPrint('[FILE CLIENT] ✗ Share update failed: ${data['error']}');
            completer.completeError(data['error'] ?? 'Share update failed');
          }
        }
      },
    );

    return completer.future;
  }

  /// Search for files by name or checksum
  Future<List<Map<String, dynamic>>> searchFiles(String query) async {
    final completer = Completer<List<Map<String, dynamic>>>();

    _socket?.emitWithAck(
      'searchFiles',
      {'query': query},
      ack: (data) {
        if (data['success'] == true) {
          final results = (data['results'] as List)
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
          completer.complete(results);
        } else {
          completer.completeError(data['error'] ?? 'Search failed');
        }
      },
    );

    return completer.future;
  }

  /// Get all active files (with seeders)
  Future<List<Map<String, dynamic>>> getActiveFiles() async {
    final completer = Completer<List<Map<String, dynamic>>>();

    _socket?.emitWithAck(
      'getActiveFiles',
      null,
      ack: (data) {
        if (data['success'] == true) {
          final files = (data['files'] as List)
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
          completer.complete(files);
        } else {
          completer.completeError(data['error'] ?? 'Failed to get files');
        }
      },
    );

    return completer.future;
  }

  /// Get available chunks from seeders
  /// Returns `Map<String, SeederInfo>` where key is deviceKey (userId:deviceId)
  Future<Map<String, SeederInfo>> getAvailableChunks(String fileId) async {
    if (_socket == null) {
      throw Exception('Socket not connected');
    }

    final completer = Completer<Map<String, SeederInfo>>();

    Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        completer.completeError(
          'Get available chunks timeout after 15 seconds',
        );
      }
    });

    _socket?.emitWithAck(
      'getAvailableChunks',
      {'fileId': fileId},
      ack: (data) {
        if (!completer.isCompleted) {
          if (data['success'] == true) {
            final seeders = <String, SeederInfo>{};
            final rawChunks = data['chunks'] as Map;

            for (final entry in rawChunks.entries) {
              try {
                // Parse userId:deviceId from key
                final deviceKey = entry.key as String;
                final chunks = List<int>.from(entry.value);

                // Create SeederInfo from deviceKey
                final seederInfo = SeederInfo.fromDeviceKey(deviceKey, chunks);
                seeders[deviceKey] = seederInfo;

                debugPrint(
                  '[SOCKET FILE] Seeder: ${seederInfo.userId}:${seederInfo.deviceId} has ${chunks.length} chunks',
                );
              } catch (e) {
                debugPrint(
                  '[SOCKET FILE] Warning: Failed to parse seeder entry ${entry.key}: $e',
                );
              }
            }

            completer.complete(seeders);
          } else {
            completer.completeError(data['error'] ?? 'Failed to get chunks');
          }
        }
      },
    );

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
    _socket?.emit('file:webrtc-offer', {
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
    _socket?.emit('file:webrtc-answer', {
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
    _socket?.emit('file:webrtc-ice', {
      'targetUserId': targetUserId,
      'targetDeviceId': targetDeviceId,
      'fileId': fileId,
      'candidate': candidate,
    });
  }

  // ============================================
  // KEY EXCHANGE (via Socket.IO relay)
  // ============================================

  /// Request encryption key from seeder (via server relay)
  void sendKeyRequest({required String targetUserId, required String fileId}) {
    debugPrint(
      '[SOCKET FILE] Sending key request for $fileId to $targetUserId',
    );
    _socket?.emit('file:key-request', {
      'targetUserId': targetUserId,
      'fileId': fileId,
    });
  }

  /// Send encryption key response to downloader (via server relay)
  void sendKeyResponse({
    required String targetUserId,
    required String fileId,
    String? key, // base64-encoded encryption key
    String? error,
  }) {
    debugPrint(
      '[SOCKET FILE] Sending key response for $fileId to $targetUserId',
    );
    _socket?.emit('file:key-response', {
      'targetUserId': targetUserId,
      'fileId': fileId,
      'key': key,
      'error': error,
    });
  }

  /// Send chunk request to peer
  void sendChunkRequest({
    required String targetUserId,
    required String targetDeviceId,
    required String fileId,
    required int chunkIndex,
  }) {
    _socket?.emit('file:chunk-request', {
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
    _socket?.emit('file:chunk-response', {
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

  /// Listen for key requests from downloaders
  void onKeyRequest(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:key-request', callback);
  }

  /// Listen for key responses from seeders
  void onKeyResponse(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:key-response', callback);
  }

  /// Listen for chunk requests
  void onChunkRequest(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:chunk-request', callback);
  }

  /// Listen for chunk responses
  void onChunkResponse(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:chunk-response', callback);
  }

  /// Listen for file shared with you notifications
  void onFileSharedWithYou(Function(Map<String, dynamic>) callback) {
    _addEventListener('fileSharedWithYou', callback);
  }

  /// Listen for file access revoked notifications
  void onFileAccessRevoked(Function(Map<String, dynamic>) callback) {
    _addEventListener('fileAccessRevoked', callback);
  }

  /// Listen for sharedWith updates (democratic P2P sharing)
  void onSharedWithUpdated(Function(Map<String, dynamic>) callback) {
    _addEventListener('file:sharedWith-updated', callback);
  }

  // ============================================
  // PRIVATE METHODS
  // ============================================

  void _setupEventListeners() {
    // File announcements
    _socket?.on('fileAnnounced', (data) {
      final chunkQuality = data['chunkQuality'] ?? 0;
      debugPrint(
        '[FILE CLIENT] File announced: ${data['fileId']} - Quality: $chunkQuality%',
      );
      _notifyListeners('fileAnnounced', data);
    });

    _socket?.on('fileSeederUpdate', (data) {
      final chunkQuality = data['chunkQuality'] ?? 0;
      debugPrint(
        '[FILE CLIENT] Seeder update: ${data['fileId']} - Quality: $chunkQuality%',
      );
      _notifyListeners('fileSeederUpdate', data);
    });

    // Share notifications
    _socket?.on('fileSharedWithYou', (data) {
      debugPrint(
        '[FILE CLIENT] File shared with you: ${data['fileId']} from ${data['fromUserId']}',
      );
      _notifyListeners('fileSharedWithYou', data);
    });

    _socket?.on('fileAccessRevoked', (data) {
      debugPrint(
        '[FILE CLIENT] File access revoked: ${data['fileId']} by ${data['byUserId']}',
      );
      _notifyListeners('fileAccessRevoked', data);
    });

    // SharedWith updates (democratic P2P)
    _socket?.on('file:sharedWith-updated', (data) {
      debugPrint(
        '[FILE CLIENT] SharedWith updated: ${data['fileId']} - ${data['sharedWith']?.length ?? 0} users',
      );
      _notifyListeners('file:sharedWith-updated', data);
    });

    // WebRTC signaling
    _socket?.on('file:webrtc-offer', (data) {
      _notifyListeners('file:webrtc-offer', data);
    });

    _socket?.on('file:webrtc-answer', (data) {
      _notifyListeners('file:webrtc-answer', data);
    });

    _socket?.on('file:webrtc-ice', (data) {
      _notifyListeners('file:webrtc-ice', data);
    });

    // Key exchange
    _socket?.on('file:key-request', (data) {
      _notifyListeners('file:key-request', data);
    });

    _socket?.on('file:key-response', (data) {
      _notifyListeners('file:key-response', data);
    });

    // Chunk transfer
    _socket?.on('file:chunk-request', (data) {
      _notifyListeners('file:chunk-request', data);
    });

    _socket?.on('file:chunk-response', (data) {
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
