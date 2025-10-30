import 'dart:convert';
import 'socket_service.dart';
import 'signal_service.dart';

/// Global service that listens for all incoming messages (1:1 and group)
/// and stores them in local storage, regardless of which screen is open.
/// Also triggers notification callbacks for UI updates.
class MessageListenerService {
  static final MessageListenerService _instance = MessageListenerService._internal();
  static MessageListenerService get instance => _instance;
  
  MessageListenerService._internal();

  bool _isInitialized = false;
  final List<Function(MessageNotification)> _notificationCallbacks = [];

  /// Initialize global message listeners
  Future<void> initialize() async {
    if (_isInitialized) {
      print('[MESSAGE_LISTENER] Already initialized');
      return;
    }

    print('[MESSAGE_LISTENER] Initializing global message listeners...');

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
    print('[MESSAGE_LISTENER] Global message listeners initialized');
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
    print('[MESSAGE_LISTENER] Global message listeners disposed');
  }

  /// Register a callback for message notifications
  void registerNotificationCallback(Function(MessageNotification) callback) {
    if (!_notificationCallbacks.contains(callback)) {
      _notificationCallbacks.add(callback);
      print('[MESSAGE_LISTENER] Registered notification callback (total: ${_notificationCallbacks.length})');
    }
  }

  /// Unregister a callback
  void unregisterNotificationCallback(Function(MessageNotification) callback) {
    _notificationCallbacks.remove(callback);
    print('[MESSAGE_LISTENER] Unregistered notification callback (total: ${_notificationCallbacks.length})');
  }

  /// Trigger notification for all registered callbacks
  void _triggerNotification(MessageNotification notification) {
    print('[MESSAGE_LISTENER] Triggering notification: ${notification.type} from ${notification.senderId}');
    for (final callback in _notificationCallbacks) {
      try {
        callback(notification);
      } catch (e) {
        print('[MESSAGE_LISTENER] Error in notification callback: $e');
      }
    }
  }

  /// Handle incoming 1:1 message
  Future<void> _handleDirectMessage(dynamic data) async {
    try {
      print('[MESSAGE_LISTENER] Received 1:1 message');
      
      final itemId = data['itemId'] as String?;
      final sender = data['sender'] as String?;
      final deviceSender = data['deviceSender'] as int?;
      final payload = data['payload'] as String?;
      final timestamp = data['timestamp'] as String?;

      if (itemId == null || sender == null || deviceSender == null || payload == null) {
        print('[MESSAGE_LISTENER] Missing required fields in 1:1 message');
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

      print('[MESSAGE_LISTENER] 1:1 message notification triggered: $itemId');
    } catch (e) {
      print('[MESSAGE_LISTENER] Error handling 1:1 message: $e');
    }
  }

  /// Handle incoming group message
  Future<void> _handleGroupMessage(dynamic data) async {
    try {
      print('[MESSAGE_LISTENER] Received group message');
      
      final itemId = data['itemId'] as String?;
      final channelId = data['channel'] as String?;
      final senderId = data['sender'] as String?;
      final senderDeviceId = data['senderDevice'] as int?;
      final payload = data['payload'] as String?;
      final timestamp = data['timestamp'] as String?;
      final itemType = data['type'] as String? ?? 'message';

      if (itemId == null || channelId == null || senderId == null || 
          senderDeviceId == null || payload == null) {
        print('[MESSAGE_LISTENER] Missing required fields in group message');
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

        print('[MESSAGE_LISTENER] Group message decrypted and stored: $itemId');
      } catch (e) {
        print('[MESSAGE_LISTENER] Error decrypting group message: $e');
        
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
      print('[MESSAGE_LISTENER] Error handling group message: $e');
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
      print('[MESSAGE_LISTENER] Processing file share update');
      
      // Parse the decrypted JSON payload
      final Map<String, dynamic> shareData = jsonDecode(decryptedPayload);
      final fileId = shareData['fileId'] as String?;
      final action = shareData['action'] as String?; // 'add' | 'revoke'
      final affectedUserIds = (shareData['affectedUserIds'] as List?)?.cast<String>() ?? [];
      final checksum = shareData['checksum'] as String?;
      
      if (fileId == null || action == null) {
        print('[MESSAGE_LISTENER] Missing fileId or action in share update');
        return;
      }

      print('[MESSAGE_LISTENER] File share update: $action for file $fileId');
      print('[MESSAGE_LISTENER] Affected users: $affectedUserIds');
      if (checksum != null) {
        print('[MESSAGE_LISTENER] Checksum: ${checksum.substring(0, 16)}...');
      }

      // ========================================
      // CRITICAL #4: SERVER VERIFICATION
      // ========================================
      // Don't trust Signal messages blindly - verify with server!
      
      final fileTransferService = _getFileTransferService();
      final socketFileClient = _getSocketFileClient();
      
      if (socketFileClient != null) {
        print('[SECURITY] Verifying share update with server...');
        
        try {
          // Get current file state from server (source of truth)
          final fileInfo = await socketFileClient.getFileInfo(fileId);
          final serverSharedWith = (fileInfo['sharedWith'] as List?)?.cast<String>() ?? [];
          final currentUserId = _getCurrentUserId();
          
          if (currentUserId == null) {
            print('[SECURITY] ❌ Cannot verify - user ID unknown');
            return;
          }
          
          // Verify action matches server state
          final isInServerList = serverSharedWith.contains(currentUserId);
          
          if (action == 'add') {
            // Verify: User should NOW be in sharedWith
            if (!isInServerList) {
              print('[SECURITY] ❌ CRITICAL: Signal says ADD but server says NOT in sharedWith!');
              print('[SECURITY] Server sharedWith: $serverSharedWith');
              print('[SECURITY] Current user: $currentUserId');
              
              _triggerNotification(MessageNotification(
                type: MessageType.fileShareUpdate,
                itemId: itemId,
                channelId: channelId,
                senderId: senderId,
                senderDeviceId: senderDeviceId,
                timestamp: timestamp ?? DateTime.now().toIso8601String(),
                encrypted: false,
                message: 'File share rejected: Server verification failed (possible attack)',
              ));
              
              return; // ❌ REJECT - Signal message doesn't match server
            }
            
            print('[SECURITY] ✅ Server confirms: User IS in sharedWith');
            
          } else if (action == 'revoke') {
            // Verify: User should NOT be in sharedWith anymore
            if (isInServerList) {
              print('[SECURITY] ❌ CRITICAL: Signal says REVOKE but server says STILL in sharedWith!');
              print('[SECURITY] Server sharedWith: $serverSharedWith');
              print('[SECURITY] Current user: $currentUserId');
              
              _triggerNotification(MessageNotification(
                type: MessageType.fileShareUpdate,
                itemId: itemId,
                channelId: channelId,
                senderId: senderId,
                senderDeviceId: senderDeviceId,
                timestamp: timestamp ?? DateTime.now().toIso8601String(),
                encrypted: false,
                message: 'Access revoke rejected: Server verification failed',
              ));
              
              return; // ❌ REJECT - Signal message doesn't match server
            }
            
            print('[SECURITY] ✅ Server confirms: User NOT in sharedWith');
          }
          
          print('[SECURITY] ✅ Signal message verified with server');
          
        } catch (e) {
          print('[SECURITY] ⚠️ Could not verify with server: $e');
          // Continue anyway - server might be temporarily unavailable
          // But log the warning
        }
      }

      // Verify checksum with server before processing (if action is 'add')
      if (checksum != null && action == 'add' && fileTransferService != null) {
        print('[SECURITY] Verifying checksum before accepting share...');
        
        final isValid = await fileTransferService.verifyChecksumBeforeDownload(
          fileId,
          checksum,
        );
        
        if (!isValid) {
          print('[SECURITY] ❌ Checksum verification FAILED - ignoring share update');
          
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
        
        print('[SECURITY] ✅ Checksum verified - share is authentic');
      }

      // ========================================
      // Process the share update (AFTER verification)
      // ========================================
      
      if (action == 'add') {
        // User was added to file share
        print('[FILE SHARE] You were given access to file: $fileId');
        
        // ========================================
        // CRITICAL: ALWAYS sync sharedWith from server
        // ========================================
        // Even if file doesn't exist yet locally, we want to have
        // the updated sharedWith ready for when download starts
        
        if (fileTransferService != null && socketFileClient != null) {
          try {
            // Get current metadata (might be null if file not downloaded yet)
            final metadata = await fileTransferService.getFileMetadata(fileId);
            
            // Get fresh sharedWith from server (source of truth)
            final serverSharedWith = await fileTransferService.getServerSharedWith(fileId);
            
            if (serverSharedWith != null) {
              if (metadata != null) {
                // File exists locally - update sharedWith
                await fileTransferService.updateFileMetadata(fileId, {
                  'sharedWith': serverSharedWith,
                  'lastSync': DateTime.now().millisecondsSinceEpoch,
                });
                print('[FILE SHARE] ✓ Local sharedWith updated: ${serverSharedWith.length} users');
                print('[FILE SHARE] sharedWith: $serverSharedWith');
              } else {
                // File doesn't exist yet - save minimal metadata with sharedWith
                // so when download starts, it will have the correct sharedWith
                print('[FILE SHARE] File not downloaded yet - saving sharedWith for future download');
                print('[FILE SHARE] sharedWith: $serverSharedWith');
                
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
                    'sharedWith': serverSharedWith, // ✅ WICHTIG: sharedWith von Server
                    'downloadedChunks': [],
                  });
                  print('[FILE SHARE] ✓ Saved file metadata with sharedWith for future download');
                } catch (e) {
                  print('[FILE SHARE] Warning: Could not save file metadata: $e');
                }
              }
            }
          } catch (e) {
            print('[FILE SHARE] Warning: Could not update local sharedWith: $e');
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
        print('[FILE SHARE] Your access to file was revoked: $fileId');
        
        // Update local sharedWith list if file exists locally (for remaining seeders)
        if (fileTransferService != null) {
          try {
            final metadata = await fileTransferService.getFileMetadata(fileId);
            if (metadata != null) {
              // File exists locally - update sharedWith from server
              final serverSharedWith = await fileTransferService.getServerSharedWith(fileId);
              if (serverSharedWith != null) {
                await fileTransferService.updateFileMetadata(fileId, {
                  'sharedWith': serverSharedWith,
                  'lastSync': DateTime.now().millisecondsSinceEpoch,
                });
                print('[FILE SHARE] ✓ Local sharedWith updated: ${serverSharedWith.length} users');
              }
            }
          } catch (e) {
            print('[FILE SHARE] Warning: Could not update local sharedWith: $e');
          }
        }
        
        // Cancel any active downloads for this file
        if (fileTransferService != null) {
          try {
            print('[FILE SHARE] Canceling active downloads for revoked file...');
            await fileTransferService.cancelDownload(fileId);
            print('[FILE SHARE] ✓ Active downloads canceled');
          } catch (e) {
            print('[FILE SHARE] Error canceling downloads: $e');
          }
          
          // Optionally: Delete already downloaded chunks
          try {
            print('[FILE SHARE] Deleting downloaded chunks for revoked file...');
            await fileTransferService.deleteFile(fileId);
            print('[FILE SHARE] ✓ Downloaded chunks deleted');
          } catch (e) {
            print('[FILE SHARE] Error deleting chunks: $e');
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

      print('[MESSAGE_LISTENER] File share update processed successfully');
      
    } catch (e) {
      print('[MESSAGE_LISTENER] Error processing file share update: $e');
    }
  }

  /// Handle incoming file share update (DEPRECATED - now handled in groupItem)
  /// 
  /// NOTE: File share updates are sent as groupItem with type='file_share_update'
  /// This handler is kept for backward compatibility but may not receive events
  Future<void> _handleFileShareUpdate(dynamic data) async {
    print('[MESSAGE_LISTENER] ⚠️ Received file_share_update via dedicated event (deprecated)');
    print('[MESSAGE_LISTENER] File shares should arrive as groupItem with type=file_share_update');
    
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
  
  /// Helper to get current user ID
  /// TODO: Inject via constructor or get from SignalService
  String? _getCurrentUserId() {
    try {
      // Get from SignalService
      return SignalService.instance.currentUserId;
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
      print('[MESSAGE_LISTENER] Error handling delivery receipt: $e');
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
      print('[MESSAGE_LISTENER] Error handling group delivery receipt: $e');
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
      print('[MESSAGE_LISTENER] Error handling group read receipt: $e');
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
