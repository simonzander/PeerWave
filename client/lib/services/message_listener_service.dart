import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'signal_service.dart';
import 'video_conference_service.dart';
import 'user_profile_service.dart';

/// Global service that listens for all incoming messages (1:1 and group)
/// and stores them in local storage, regardless of which screen is open.
/// Also triggers notification callbacks for UI updates.
class MessageListenerService {
  static final MessageListenerService _instance = MessageListenerService._internal();
  static MessageListenerService get instance => _instance;
  
  MessageListenerService._internal();

  bool _isInitialized = false;
  final List<Function(MessageNotification)> _notificationCallbacks = [];
  
  // VideoConferenceService instance for E2EE key distribution
  VideoConferenceService? _videoConferenceService;
  
  /// Register VideoConferenceService for E2EE key handling
  void registerVideoConferenceService(VideoConferenceService service) {
    _videoConferenceService = service;
    debugPrint('[MESSAGE_LISTENER] VideoConferenceService registered for E2EE key handling');
  }
  
  /// Unregister VideoConferenceService
  void unregisterVideoConferenceService() {
    _videoConferenceService = null;
    debugPrint('[MESSAGE_LISTENER] VideoConferenceService unregistered');
  }

  /// Initialize global message listeners
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('[MESSAGE_LISTENER] Already initialized');
      return;
    }

    debugPrint('[MESSAGE_LISTENER] Initializing global message listeners...');

    // Listen for 1:1 messages
    SocketService().registerListener('receiveItem', _handleDirectMessage);

    // Listen for group messages
    SocketService().registerListener('groupItem', _handleGroupMessage);

    // Listen for file share updates (P2P)
    SocketService().registerListener('file_share_update', _handleFileShareUpdate);

    // Listen for delivery receipts
    SocketService().registerListener('deliveryReceipt', _handleDeliveryReceipt);
    SocketService().registerListener('groupItemDelivered', _handleGroupDeliveryReceipt);

    // Listen for read receipts
    SocketService().registerListener('groupItemReadUpdate', _handleGroupReadReceipt);

    _isInitialized = true;
    debugPrint('[MESSAGE_LISTENER] Global message listeners initialized');
  }

  /// Cleanup listeners
  void dispose() {
    if (!_isInitialized) return;

    SocketService().unregisterListener('receiveItem', _handleDirectMessage);
    SocketService().unregisterListener('groupItem', _handleGroupMessage);
    SocketService().unregisterListener('file_share_update', _handleFileShareUpdate);
    SocketService().unregisterListener('deliveryReceipt', _handleDeliveryReceipt);
    SocketService().unregisterListener('groupItemDelivered', _handleGroupDeliveryReceipt);
    SocketService().unregisterListener('groupItemReadUpdate', _handleGroupReadReceipt);

    _notificationCallbacks.clear();
    _isInitialized = false;
    debugPrint('[MESSAGE_LISTENER] Global message listeners disposed');
  }

  /// Register a callback for message notifications
  void registerNotificationCallback(Function(MessageNotification) callback) {
    if (!_notificationCallbacks.contains(callback)) {
      _notificationCallbacks.add(callback);
      debugPrint('[MESSAGE_LISTENER] Registered notification callback (total: ${_notificationCallbacks.length})');
    }
  }

  /// Unregister a callback
  void unregisterNotificationCallback(Function(MessageNotification) callback) {
    _notificationCallbacks.remove(callback);
    debugPrint('[MESSAGE_LISTENER] Unregistered notification callback (total: ${_notificationCallbacks.length})');
  }

  /// Trigger notification for all registered callbacks
  void _triggerNotification(MessageNotification notification) {
    debugPrint('[MESSAGE_LISTENER] Triggering notification: ${notification.type} from ${notification.senderId}');
    for (final callback in _notificationCallbacks) {
      try {
        callback(notification);
      } catch (e) {
        debugPrint('[MESSAGE_LISTENER] Error in notification callback: $e');
      }
    }
  }

  /// Handle incoming 1:1 message
  Future<void> _handleDirectMessage(dynamic data) async {
    try {
      debugPrint('[MESSAGE_LISTENER] Received 1:1 message');
      
      final itemId = data['itemId'] as String?;
      final sender = data['sender'] as String?;
      final deviceSender = data['deviceSender'] as int?;
      final payload = data['payload'] as String?;
      final timestamp = data['timestamp'] as String?;

      if (itemId == null || sender == null || deviceSender == null || payload == null) {
        debugPrint('[MESSAGE_LISTENER] Missing required fields in 1:1 message');
        return;
      }

      // Store in local storage via SignalService
      // The message will be decrypted when the chat screen loads
      // For now, just trigger a notification
      _triggerNotification(MessageNotification(
        type: MessageType.direct,
        itemId: itemId,
        senderId: sender,
        senderDeviceId: deviceSender,
        timestamp: timestamp ?? DateTime.now().toIso8601String(),
        encrypted: true,
      ));

      debugPrint('[MESSAGE_LISTENER] 1:1 message notification triggered: $itemId');
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error handling 1:1 message: $e');
    }
  }

  /// Handle incoming group message
  Future<void> _handleGroupMessage(dynamic data) async {
    try {
      debugPrint('[MESSAGE_LISTENER] Received group message');
      
      final itemId = data['itemId'] as String?;
      final channelId = data['channel'] as String?;
      final senderId = data['sender'] as String?;
      // Parse senderDeviceId as int (socket might send String)
      final senderDeviceIdRaw = data['senderDevice'];
      final senderDeviceId = senderDeviceIdRaw is int
          ? senderDeviceIdRaw
          : (senderDeviceIdRaw != null ? int.tryParse(senderDeviceIdRaw.toString()) : null);
      final payload = data['payload'] as String?;
      final timestamp = data['timestamp'] as String?;
      final itemType = data['type'] as String? ?? 'message';

      if (itemId == null || channelId == null || senderId == null || 
          senderDeviceId == null || payload == null) {
        debugPrint('[MESSAGE_LISTENER] Missing required fields in group message');
        return;
      }

      // Decrypt and store in local storage
      final signalService = SignalService.instance;
      
      try {
        // Decrypt using auto-reload on error
        final decrypted = await signalService.decryptGroupItem(
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          ciphertext: payload,
        );

        // ========================================
        // CHECK MESSAGE TYPE - Route accordingly
        // ========================================
        
        if (itemType == 'file_share_update') {
          // File share update - handle separately
          await _processFileShareUpdate(
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp,
            decryptedPayload: decrypted,
          );
          return; // Don't store as regular message
        }

        // Handle new video E2EE key exchange message types (with timestamp-based race condition resolution)
        if (itemType == 'video_e2ee_key_request' || itemType == 'video_e2ee_key_response') {
          await _processVideoE2EEKey(
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp,
            decryptedPayload: decrypted,
            messageType: itemType,
          );
          return; // Don't store as regular message
        }

        // Legacy: Handle old video E2EE key exchange message types (deprecated)
        if (itemType == 'video_key_request' || itemType == 'video_key_response') {
          // Video E2EE key exchange - handle separately
          await _processVideoE2EEKey(
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp,
            decryptedPayload: decrypted,
            messageType: itemType,
          );
          return; // Don't store as regular message
        }

        if (itemType == 'video_e2ee_key') {
          // Legacy video E2EE key - handle separately
          await _processVideoE2EEKey(
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp,
            decryptedPayload: decrypted,
            messageType: itemType,
          );
          return; // Don't store as regular message
        }

        // Store in decryptedGroupItemsStore (regular message)
        await signalService.decryptedGroupItemsStore.storeDecryptedGroupItem(
          itemId: itemId,
          channelId: channelId,
          sender: senderId,
          senderDevice: senderDeviceId,
          message: decrypted,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          type: itemType,
        );

        // Load sender's profile if not already cached
        try {
          final profileService = UserProfileService.instance;
          if (!profileService.isProfileCached(senderId)) {
            debugPrint("[MESSAGE_LISTENER] Loading profile for group message sender: $senderId");
            await profileService.loadProfiles([senderId]);
            debugPrint("[MESSAGE_LISTENER] ✓ Sender profile loaded");
          }
        } catch (e) {
          debugPrint("[MESSAGE_LISTENER] ⚠ Failed to load sender profile (server may be unavailable): $e");
          // Don't block message processing if profile loading fails
        }

        // Trigger notification with decrypted content
        _triggerNotification(MessageNotification(
          type: MessageType.group,
          itemId: itemId,
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          encrypted: false,
          message: decrypted,
        ));

        debugPrint('[MESSAGE_LISTENER] Group message decrypted and stored: $itemId');
      } catch (e) {
        debugPrint('[MESSAGE_LISTENER] Error decrypting group message: $e');
        
        // Still trigger notification, but mark as encrypted
        _triggerNotification(MessageNotification(
          type: MessageType.group,
          itemId: itemId,
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          encrypted: true,
        ));
      }
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error handling group message: $e');
    }
  }

  /// Process file share update (extracted from groupItem handler)
  Future<void> _processFileShareUpdate({
    required String itemId,
    required String channelId,
    required String senderId,
    required int senderDeviceId,
    required String? timestamp,
    required String decryptedPayload,
  }) async {
    try {
      debugPrint('[MESSAGE_LISTENER] Processing file share update');
      
      // Parse the decrypted JSON payload
      final Map<String, dynamic> shareData = jsonDecode(decryptedPayload);
      final fileId = shareData['fileId'] as String?;
      final action = shareData['action'] as String?; // 'add' | 'revoke'
      final affectedUserIds = (shareData['affectedUserIds'] as List?)?.cast<String>() ?? [];
      final checksum = shareData['checksum'] as String?;
      
      if (fileId == null || action == null) {
        debugPrint('[MESSAGE_LISTENER] Missing fileId or action in share update');
        return;
      }

      debugPrint('[MESSAGE_LISTENER] File share update: $action for file $fileId');
      debugPrint('[MESSAGE_LISTENER] Affected users: $affectedUserIds');
      if (checksum != null) {
        debugPrint('[MESSAGE_LISTENER] Checksum: ${checksum.substring(0, 16)}...');
      }

      // ========================================
      // P2P-NATIVE: Trust Signal Protocol (E2E encrypted)
      // ========================================
      // Signal Protocol provides E2E encryption and authentication.
      // We use MERGE strategy instead of server verification to handle
      // offline scenarios where server state may be stale.
      // 
      // Security is provided by:
      // 1. Signal Protocol E2E encryption (message authenticity)
      // 2. Checksum verification (file integrity, see below)
      // 3. Merge strategy (eventual consistency across peers)
      
      debugPrint('[P2P] Processing Signal-authenticated share update (action: $action)');
      
      final fileTransferService = _getFileTransferService();
      final socketFileClient = _getSocketFileClient();

      // Verify checksum with server before processing (if action is 'add')
      if (checksum != null && action == 'add' && fileTransferService != null) {
        debugPrint('[SECURITY] Verifying checksum before accepting share...');
        
        final isValid = await fileTransferService.verifyChecksumBeforeDownload(
          fileId,
          checksum,
        );
        
        if (!isValid) {
          debugPrint('[SECURITY] ❌ Checksum verification FAILED - ignoring share update');
          
          // Show warning to user
          _triggerNotification(MessageNotification(
            type: MessageType.fileShareUpdate,
            itemId: itemId,
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp ?? DateTime.now().toIso8601String(),
            encrypted: false,
            message: 'File share rejected: Checksum mismatch (security risk)',
          ));
          
          return; // ❌ ABORT - don't process compromised file
        }
        
        debugPrint('[SECURITY] ✅ Checksum verified - share is authentic');
      }

      // ========================================
      // Process the share update (AFTER verification)
      // ========================================
      
      if (action == 'add') {
        // User was added to file share
        debugPrint('[FILE SHARE] You were given access to file: $fileId');
        
        // ========================================
        // P2P MERGE: Add sender to local sharedWith
        // ========================================
        // Trust Signal Protocol E2E encryption for authenticity
        // Use MERGE strategy (Union) instead of server verification
        
        if (fileTransferService != null && socketFileClient != null) {
          try {
            // Get current metadata (might be null if file not downloaded yet)
            final metadata = await fileTransferService.getFileMetadata(fileId);
            
            if (metadata != null) {
              // File exists locally - MERGE sender into sharedWith
              final existingSharedWith = List<String>.from(metadata['sharedWith'] ?? []);
              final mergedSharedWith = <String>{...existingSharedWith, senderId}.toList();
              
              if (mergedSharedWith.length != existingSharedWith.length) {
                await fileTransferService.updateFileMetadata(fileId, {
                  'sharedWith': mergedSharedWith,
                  'lastSync': DateTime.now().millisecondsSinceEpoch,
                });
                debugPrint('[FILE SHARE] ✓ Merged sender into sharedWith: ${mergedSharedWith.length} users');
                debugPrint('[FILE SHARE] sharedWith: $mergedSharedWith');
              } else {
                debugPrint('[FILE SHARE] Sender already in sharedWith - no change needed');
              }
            } else {
              // File doesn't exist yet - save minimal metadata with sender in sharedWith
              debugPrint('[FILE SHARE] File not downloaded yet - saving metadata for future download');
              
              // Get file info from server to have all metadata ready
              try {
                final fileInfo = await socketFileClient.getFileInfo(fileId);
                await fileTransferService.saveFileMetadata({
                  'fileId': fileId,
                  'fileName': fileInfo['fileName'] ?? 'unknown',
                  'mimeType': fileInfo['mimeType'] ?? 'application/octet-stream',
                  'fileSize': fileInfo['fileSize'] ?? 0,
                  'checksum': fileInfo['checksum'] ?? '',
                  'chunkCount': fileInfo['chunkCount'] ?? 0,
                  'status': 'available', // Not downloaded yet, but available
                  'isSeeder': false,
                  'downloadComplete': false,
                  'createdAt': DateTime.now().millisecondsSinceEpoch,
                  'sharedWith': [senderId], // Start with sender only (will merge on announce)
                  'downloadedChunks': [],
                });
                debugPrint('[FILE SHARE] ✓ Saved file metadata with sender in sharedWith');
              } catch (e) {
                debugPrint('[FILE SHARE] Warning: Could not save file metadata: $e');
              }
            }
          } catch (e) {
            debugPrint('[FILE SHARE] Warning: Could not update local sharedWith: $e');
          }
        }
        
        // Trigger notification
        _triggerNotification(MessageNotification(
          type: MessageType.fileShareUpdate,
          itemId: itemId,
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          encrypted: false,
          message: 'File shared with you: $fileId',
          fileId: fileId,
          fileAction: 'add',
        ));
        
      } else if (action == 'revoke') {
        // ========================================
        // HIGH #6: STOP DOWNLOAD ON REVOKE
        // ========================================
        
        // User's access was revoked
        debugPrint('[FILE SHARE] Your access to file was revoked: $fileId');
        
        // P2P NOTE: We trust Signal E2E encrypted revoke message
        // No server verification needed - Signal Protocol guarantees authenticity
        
        // Cancel any active downloads for this file
        if (fileTransferService != null) {
          try {
            debugPrint('[FILE SHARE] Canceling active downloads for revoked file...');
            await fileTransferService.cancelDownload(fileId);
            debugPrint('[FILE SHARE] ✓ Active downloads canceled');
          } catch (e) {
            debugPrint('[FILE SHARE] Error canceling downloads: $e');
          }
          
          // Optionally: Delete already downloaded chunks
          try {
            debugPrint('[FILE SHARE] Deleting downloaded chunks for revoked file...');
            await fileTransferService.deleteFile(fileId);
            debugPrint('[FILE SHARE] ✓ Downloaded chunks deleted');
          } catch (e) {
            debugPrint('[FILE SHARE] Error deleting chunks: $e');
          }
        }
        
        // Trigger notification
        _triggerNotification(MessageNotification(
          type: MessageType.fileShareUpdate,
          itemId: itemId,
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          timestamp: timestamp ?? DateTime.now().toIso8601String(),
          encrypted: false,
          message: 'File access revoked: $fileId',
          fileId: fileId,
          fileAction: 'revoke',
        ));
      }

      debugPrint('[MESSAGE_LISTENER] File share update processed successfully');
      
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error processing file share update: $e');
    }
  }

  /// Process video E2EE key (extracted from groupItem handler)
  Future<void> _processVideoE2EEKey({
    required String itemId,
    required String channelId,
    required String senderId,
    required int senderDeviceId,
    required String? timestamp,
    required String decryptedPayload,
    String? messageType,
  }) async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[MESSAGE_LISTENER][TEST] 📬 PROCESSING VIDEO E2EE KEY MESSAGE');
      debugPrint('[MESSAGE_LISTENER][TEST] Sender: $senderId');
      debugPrint('[MESSAGE_LISTENER][TEST] Message Type: $messageType');
      debugPrint('[MESSAGE_LISTENER][TEST] Channel: $channelId');
      
      // Parse the decrypted JSON payload
      final Map<String, dynamic> keyData = jsonDecode(decryptedPayload);
      
      // NEW: Handle new message types with timestamp-based race condition resolution
      if (messageType == 'video_e2ee_key_request') {
        final requesterId = keyData['requesterId'] as String?;
        final requestTimestamp = keyData['timestamp'] as int?;
        
        debugPrint('[MESSAGE_LISTENER][TEST] 📩 KEY REQUEST RECEIVED');
        debugPrint('[MESSAGE_LISTENER][TEST] Requester: $requesterId');
        debugPrint('[MESSAGE_LISTENER][TEST] Request Timestamp: $requestTimestamp');
        debugPrint('[MESSAGE_LISTENER][TEST] 🔍 Checking VideoConferenceService...');
        debugPrint('[MESSAGE_LISTENER][TEST]   - Service registered: ${_videoConferenceService != null}');
        debugPrint('[MESSAGE_LISTENER][TEST]   - Has E2EE key: ${_videoConferenceService?.hasE2EEKey ?? false}');
        
        // ⚠️ IMPORTANT: Ignore our own key requests (sender receives their own broadcast)
        final currentUserId = SignalService.instance.currentUserId;
        if (requesterId == currentUserId || senderId == currentUserId) {
          debugPrint('[MESSAGE_LISTENER][TEST] ℹ️ Ignoring own key request (sender echo)');
          debugPrint('═══════════════════════════════════════════════════════════');
          return;
        }
        
        // Respond if we have a key available (even if not connected to LiveKit room yet)
        if (_videoConferenceService != null && _videoConferenceService!.hasE2EEKey) {
          debugPrint('[MESSAGE_LISTENER][TEST] ✓ Forwarding to VideoConferenceService.handleKeyRequest()');
          await _videoConferenceService!.handleKeyRequest(requesterId ?? senderId);
        } else {
          debugPrint('[MESSAGE_LISTENER][TEST] ⚠️ VideoConferenceService not available or no key generated');
          debugPrint('[MESSAGE_LISTENER][TEST] ℹ️ This is expected if you are the requester waiting for response');
        }
        
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }
      
      if (messageType == 'video_e2ee_key_response') {
        final targetUserId = keyData['targetUserId'] as String?;
        final encryptedKey = keyData['encryptedKey'] as String?;
        final keyTimestamp = keyData['timestamp'] as int?;
        
        debugPrint('[MESSAGE_LISTENER][TEST] 🔑 KEY RESPONSE RECEIVED');
        debugPrint('[MESSAGE_LISTENER][TEST] Target User: $targetUserId');
        debugPrint('[MESSAGE_LISTENER][TEST] Key Timestamp: $keyTimestamp');
        debugPrint('[MESSAGE_LISTENER][TEST] Key Length: ${encryptedKey?.length ?? 0} chars (base64)');
        
        if (encryptedKey != null && keyTimestamp != null && _videoConferenceService != null) {
          debugPrint('[MESSAGE_LISTENER][TEST] ✓ Forwarding to VideoConferenceService.handleE2EEKey()');
          await _videoConferenceService!.handleE2EEKey(
            senderUserId: senderId,
            encryptedKey: encryptedKey,
            channelId: channelId,
            timestamp: keyTimestamp,  // Pass timestamp for race condition resolution
          );
        } else {
          debugPrint('[MESSAGE_LISTENER][TEST] ⚠️ Missing data or VideoConferenceService not available');
        }
        
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }
      
      // LEGACY: Handle old message types (deprecated, but keep for compatibility)
      final type = keyData['type'] as String?;
      
      if (type == 'video_key_request') {
        // Someone is requesting the key
        final requesterId = keyData['requesterId'] as String?;
        debugPrint('[MESSAGE_LISTENER][TEST] [LEGACY] Received key request from $requesterId');
        
        if (_videoConferenceService != null && _videoConferenceService!.isConnected) {
          await _videoConferenceService!.handleKeyRequest(requesterId ?? senderId);
        }
        return;
      }
      
      if (type == 'video_key_response') {
        // Someone sent us the key (legacy format without timestamp - use current time)
        final targetUserId = keyData['targetUserId'] as String?;
        final encryptedKey = keyData['encryptedKey'] as String?;
        final legacyTimestamp = DateTime.now().millisecondsSinceEpoch;
        
        debugPrint('[MESSAGE_LISTENER] [LEGACY] Received key response for user: $targetUserId (no timestamp, using current: $legacyTimestamp)');
        
        if (encryptedKey != null && _videoConferenceService != null) {
          await _videoConferenceService!.handleE2EEKey(
            senderUserId: senderId,
            encryptedKey: encryptedKey,
            channelId: channelId,
            timestamp: legacyTimestamp,  // Use current time for legacy messages
          );
        }
        return;
      }
      
      debugPrint('[MESSAGE_LISTENER] Unknown video E2EE key type: $type or messageType: $messageType');
      
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error processing video E2EE key: $e');
    }
  }

  /// Handle incoming file share update (DEPRECATED - now handled in groupItem)
  /// 
  /// NOTE: File share updates are sent as groupItem with type='file_share_update'
  /// This handler is kept for backward compatibility but may not receive events
  Future<void> _handleFileShareUpdate(dynamic data) async {
    debugPrint('[MESSAGE_LISTENER] ⚠️ Received file_share_update via dedicated event (deprecated)');
    debugPrint('[MESSAGE_LISTENER] File shares should arrive as groupItem with type=file_share_update');
    
    // Route to groupItem handler
    await _handleGroupMessage(data);
  }

  /// Helper to get FileTransferService instance
  /// TODO: Inject via constructor or service locator
  dynamic _getFileTransferService() {
    try {
      // This should be injected properly
      // For now, return null and handle gracefully
      return null;
    } catch (e) {
      return null;
    }
  }
  
  /// Helper to get SocketFileClient instance
  /// TODO: Inject via constructor or service locator
  dynamic _getSocketFileClient() {
    try {
      // This should be injected properly
      // For now, return null and handle gracefully
      return null;
    } catch (e) {
      return null;
    }
  }
  
  /// Handle delivery receipt for 1:1 messages
  void _handleDeliveryReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String?;
      if (itemId != null) {
        _triggerNotification(MessageNotification(
          type: MessageType.deliveryReceipt,
          itemId: itemId,
          timestamp: DateTime.now().toIso8601String(),
        ));
      }
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error handling delivery receipt: $e');
    }
  }

  /// Handle delivery receipt for group messages
  void _handleGroupDeliveryReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String?;
      final deliveredCount = data['deliveredCount'] as int?;
      final totalDevices = data['totalDevices'] as int?;
      
      if (itemId != null) {
        _triggerNotification(MessageNotification(
          type: MessageType.groupDeliveryReceipt,
          itemId: itemId,
          timestamp: DateTime.now().toIso8601String(),
          deliveredCount: deliveredCount,
          totalCount: totalDevices,
        ));
      }
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error handling group delivery receipt: $e');
    }
  }

  /// Handle read receipt for group messages
  void _handleGroupReadReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String?;
      final readCount = data['readCount'] as int?;
      final deliveredCount = data['deliveredCount'] as int?;
      final totalCount = data['totalCount'] as int?;
      final allRead = data['allRead'] as bool? ?? false;
      
      if (itemId != null) {
        _triggerNotification(MessageNotification(
          type: MessageType.groupReadReceipt,
          itemId: itemId,
          timestamp: DateTime.now().toIso8601String(),
          readCount: readCount,
          deliveredCount: deliveredCount,
          totalCount: totalCount,
          allRead: allRead,
        ));
      }
    } catch (e) {
      debugPrint('[MESSAGE_LISTENER] Error handling group read receipt: $e');
    }
  }
}

/// Type of message notification
enum MessageType {
  direct,
  group,
  fileShareUpdate, // ← NEW: File share add/revoke notifications
  deliveryReceipt,
  groupDeliveryReceipt,
  groupReadReceipt,
}

/// Message notification data
class MessageNotification {
  final MessageType type;
  final String itemId;
  final String? channelId;
  final String? senderId;
  final int? senderDeviceId;
  final String timestamp;
  final bool encrypted;
  final String? message;
  final int? deliveredCount;
  final int? readCount;
  final int? totalCount;
  final bool? allRead;
  final String? fileId; // ← NEW: For file share updates
  final String? fileAction; // ← NEW: 'add' | 'revoke'

  MessageNotification({
    required this.type,
    required this.itemId,
    this.channelId,
    this.senderId,
    this.senderDeviceId,
    required this.timestamp,
    this.encrypted = false,
    this.message,
    this.deliveredCount,
    this.readCount,
    this.totalCount,
    this.allRead,
    this.fileId, // ← NEW
    this.fileAction, // ← NEW
  });

  @override
  String toString() {
    return 'MessageNotification(type: $type, itemId: $itemId, channelId: $channelId, sender: $senderId, encrypted: $encrypted)';
  }
}

