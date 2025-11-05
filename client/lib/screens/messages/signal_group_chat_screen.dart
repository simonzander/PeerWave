import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../widgets/animated_widgets.dart';
import '../../services/api_service.dart';
import '../../services/signal_service.dart';
import '../../services/socket_service.dart';
import '../../services/offline_message_queue.dart';
import '../../services/user_profile_service.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../models/role.dart';
import '../../models/file_message.dart';
import '../../extensions/snackbar_extensions.dart';
import '../../providers/unread_messages_provider.dart';
import '../channel/channel_members_screen.dart';
import '../../views/video_conference_prejoin_view.dart';
import '../../views/video_conference_view.dart';

/// Whitelist of message types that should be displayed in UI
const Set<String> DISPLAYABLE_MESSAGE_TYPES = {'message', 'file'};

/// Screen for Signal Group Chats (encrypted group conversations)
class SignalGroupChatScreen extends StatefulWidget {
  final String host;
  final String channelUuid;
  final String channelName;

  const SignalGroupChatScreen({
    super.key,
    required this.host,
    required this.channelUuid,
    required this.channelName,
  });

  @override
  State<SignalGroupChatScreen> createState() => _SignalGroupChatScreenState();
}

class _SignalGroupChatScreenState extends State<SignalGroupChatScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String? _error;
  final Set<String> _pendingReadReceipts = {};  // Track messages waiting for read receipt
  int _messageOffset = 0;
  bool _hasMoreMessages = true;
  bool _loadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    SignalService.instance.unregisterItemCallback('groupItem', _handleGroupItem);
    SignalService.instance.unregisterItemCallback('groupItemReadUpdate', _handleReadReceipt);
    SocketService().unregisterListener('groupItemDelivered', _handleDeliveryReceipt);
    super.dispose();
  }

  @override
  void didUpdateWidget(SignalGroupChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload messages when channel changes
    if (oldWidget.channelUuid != widget.channelUuid) {
      debugPrint('[SIGNAL_GROUP] Channel changed from ${oldWidget.channelUuid} to ${widget.channelUuid}');
      _messages = []; // Clear old messages
      _messageOffset = 0;
      _hasMoreMessages = true;
      _initialize(); // Reload
    }
  }

  /// Initialize the group chat screen: wait for sender key setup, then load messages
  Future<void> _initialize() async {
    await _initializeGroupChannel();
    await _loadMessages();
    _setupMessageListener();
    
    // Send read receipts for any pending messages when screen becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendPendingReadReceipts();
      
      // Scroll to bottom after initial load
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// Initialize group channel: load all sender keys and upload our own
  /// Initialize group channel: load all sender keys and upload our own
  Future<void> _initializeGroupChannel() async {
    try {
      final signalService = SignalService.instance;
      
      // STEP 3: Robust identity key pair check with auto-regenerate attempt
      bool hasIdentityKey = false;
      try {
        await signalService.identityStore.getIdentityKeyPair();
        hasIdentityKey = true;
        debugPrint('[SIGNAL_GROUP] Identity key pair verified');
      } catch (e) {
        debugPrint('[SIGNAL_GROUP] Identity key pair check failed: $e');
        hasIdentityKey = false;
      }
      
      // Attempt to regenerate if missing (instead of giving up)
      if (!hasIdentityKey) {
        debugPrint('[SIGNAL_GROUP] Attempting to regenerate Signal Protocol...');
        try {
          // Try to re-initialize Signal Protocol (this should generate keys)
          await signalService.init();
          debugPrint('[SIGNAL_GROUP] Signal Protocol regenerated successfully');
          hasIdentityKey = true;
        } catch (regenerateError) {
          debugPrint('[SIGNAL_GROUP] Failed to regenerate Signal Protocol: $regenerateError');
          // Show warning but don't block completely
          if (mounted) {
            context.showCustomSnackBar(
              'Signal Protocol initialization incomplete. Some features may not work.',
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            );
          }
          // Continue anyway - let sendMessage handle the blocking if needed
          setState(() {
            _error = 'Signal Protocol not initialized';
          });
          return; // Exit initialization but don't crash
        }
      }
      
      // Create and upload our sender key if not already done
      final hasSenderKey = await signalService.hasSenderKey(
        widget.channelUuid,
        signalService.currentUserId ?? '',
        signalService.currentDeviceId ?? 0,
      );

      if (!hasSenderKey) {
        debugPrint('[SIGNAL_GROUP] Creating and uploading sender key for group ${widget.channelUuid}');
        
        // Create sender key
        await signalService.createGroupSenderKey(widget.channelUuid);
        
        // Upload to server via REST API (replaces 1:1 distribution)
        await signalService.uploadSenderKeyToServer(widget.channelUuid);
        
        debugPrint('[SIGNAL_GROUP] Sender key uploaded to server successfully');
      } else {
        debugPrint('[SIGNAL_GROUP] Sender key already exists');
      }
      
      // Load ALL sender keys for this channel from server (batch load)
      debugPrint('[SIGNAL_GROUP] Loading all sender keys for channel from server...');
      try {
        final result = await signalService.loadAllSenderKeysForChannel(widget.channelUuid);
        debugPrint('[SIGNAL_GROUP] All sender keys loaded successfully');
        
        // Store failed keys for later reference
        if (result['failedKeys'] != null && (result['failedKeys'] as List).isNotEmpty) {
          final failedKeys = result['failedKeys'] as List<Map<String, String>>;
          setState(() {
            _error = 'Some member keys failed to load';
          });
          
          // Show detailed warning about which members
          if (mounted) {
            final memberList = failedKeys.map((k) => '${k['userId']}').take(3).join(', ');
            final remaining = failedKeys.length > 3 ? ' and ${failedKeys.length - 3} more' : '';
            
            context.showCustomSnackBar(
              'Cannot decrypt messages from: $memberList$remaining',
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 8),
              action: SnackBarAction(
                label: 'Retry',
                textColor: Colors.white,
                onPressed: () {
                  _initializeGroupChannel(); // Retry loading
                },
              ),
            );
          }
        }
      } catch (loadError) {
        debugPrint('[SIGNAL_GROUP] Error loading sender keys: $loadError');
        // Show warning but don't block completely
        if (mounted) {
          final errorMsg = loadError.toString();
          if (errorMsg.contains('Failed to load') && errorMsg.contains('sender key')) {
            // Partial failure - some member keys missing
            context.showCustomSnackBar(
              loadError.toString().replaceAll('Exception: ', ''),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 7),
            );
          } else if (errorMsg.contains('HTTP') || errorMsg.contains('server')) {
            // Server error
            context.showCustomSnackBar(
              'Failed to load member encryption keys. You may not be able to read all messages.',
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 7),
            );
          }
        }
        // Don't return - allow user to try sending/reading what they can
      }
      
    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error initializing group channel: $e');
      // Show error but don't block the UI completely
      if (mounted) {
        context.showCustomSnackBar(
          'Failed to initialize group chat: $e',
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 5),
        );
      }
    }
  }

  void _setupMessageListener() {
    // NEW: Listen for groupItem events (replaces groupMessage)
    SignalService.instance.registerItemCallback('groupItem', _handleGroupItem);
    SignalService.instance.registerItemCallback('groupItemReadUpdate', _handleReadReceipt);
    SocketService().registerListener('groupItemDelivered', _handleDeliveryReceipt);
  }

  /// Handle delivery receipt from server
  void _handleDeliveryReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String;
      final recipientCount = data['recipientCount'] as int;

      debugPrint('[SIGNAL_GROUP] Delivery receipt: message delivered to server, $recipientCount recipients');

      // Update message status in UI
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'delivered';        // Graues Häkchen
          _messages[msgIndex]['deliveredCount'] = 0;          // Noch niemand empfangen
          _messages[msgIndex]['readCount'] = 0;               // Noch niemand gelesen
          _messages[msgIndex]['totalCount'] = recipientCount; // Gesamtzahl Empfänger
        }
      });
    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error handling delivery receipt: $e');
    }
  }

  /// Handle read receipt updates from other members
  void _handleReadReceipt(dynamic data) {
    try {
      final itemId = data['itemId'] as String;
      final readCount = data['readCount'] as int;
      final deliveredCount = data['deliveredCount'] as int;
      final totalCount = data['totalCount'] as int;
      final allRead = data['allRead'] as bool;

      debugPrint('[SIGNAL_GROUP] Read receipt: $readCount/$totalCount read, $deliveredCount delivered');

      // Update message status in UI
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['readCount'] = readCount;
          _messages[msgIndex]['deliveredCount'] = deliveredCount;
          _messages[msgIndex]['totalCount'] = totalCount;
          
          // Status-Logik:
          // - 'delivered' (graues Häkchen): Noch nicht alle haben gelesen
          // - 'read' (2 grüne Häkchen): Alle haben gelesen
          if (allRead) {
            _messages[msgIndex]['status'] = 'read';  // Alle haben gelesen
          } else {
            _messages[msgIndex]['status'] = 'delivered';  // Noch nicht alle
          }
        }
      });
    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error handling read receipt: $e');
    }
  }

  /// Handle incoming group items via Socket.IO (NEW API with auto-reload)
  Future<void> _handleGroupItem(dynamic data) async {
    try {
      final itemId = data['itemId'] as String;
      final channelId = data['channel'] as String;
      final senderId = data['sender'] as String;
      // Parse senderDeviceId as int (socket might send String)
      final senderDeviceId = data['senderDevice'] is int
          ? data['senderDevice'] as int
          : int.parse(data['senderDevice'].toString());
      final payload = data['payload'] as String;
      final timestamp = data['timestamp'] ?? DateTime.now().toIso8601String();
      final itemType = data['type'] as String? ?? 'message';
      
      // ✅ WHITELIST: Filter out system messages (only display 'message' and 'file')
      if (!DISPLAYABLE_MESSAGE_TYPES.contains(itemType)) {
        debugPrint('[SIGNAL_GROUP] Skipping system message type: $itemType');
        return;
      }
      
      // Verify this is for our channel
      if (channelId != widget.channelUuid) {
        return;
      }
      
      // Check if already exists
      if (_messages.any((m) => m['itemId'] == itemId)) {
        return;
      }
      
      debugPrint('[SIGNAL_GROUP] Received groupItem via Socket.IO: $itemId');
      
      final signalService = SignalService.instance;
      
      // Decrypt using NEW method with auto-reload on error
      String decrypted;
      try {
        decrypted = await signalService.decryptGroupItem(
          channelId: channelId,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          ciphertext: payload,
        );
      } catch (e) {
        debugPrint('[SIGNAL_GROUP] Error decrypting groupItem (auto-reload failed): $e');
        // Auto-reload already tried, message is unreadable
        return;
      }
      
      // Store decrypted in NEW store
      await signalService.decryptedGroupItemsStore.storeDecryptedGroupItem(
        itemId: itemId,
        channelId: channelId,
        sender: senderId,
        senderDevice: senderDeviceId,
        message: decrypted,
        timestamp: timestamp,
        type: itemType,
      );
      
      // Check if it's own message
      final isOwnMessage = senderId == signalService.currentUserId;
      
      // Add to UI
      setState(() {
        _messages.add({
          'itemId': itemId,
          'sender': senderId,
          'senderDisplayName': isOwnMessage ? 'You' : UserProfileService.instance.getDisplayName(senderId),
          'text': decrypted,
          'message': decrypted,
          'time': timestamp,
          'timestamp': timestamp,
          'status': 'received',
          'isOwn': isOwnMessage,
          'isLocalSent': isOwnMessage,
          'type': itemType,
        });
        
        // Sort by timestamp
        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      });
      
      debugPrint('[SIGNAL_GROUP] GroupItem decrypted and displayed successfully');
      
      // Send read receipt (only for others' messages)
      if (!isOwnMessage) {
        _sendReadReceiptForMessage(itemId);
      }
    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error handling groupItem: $e');
    }
  }

  /// Send read receipt for a specific message (NEW API)
  void _sendReadReceiptForMessage(String itemId) {
    try {
      // NEW: Use markGroupItemAsRead from SignalService
      SignalService.instance.markGroupItemAsRead(itemId);
      _pendingReadReceipts.remove(itemId);
      debugPrint('[SIGNAL_GROUP] Sent read receipt for item: $itemId');
      
      // Mark this channel as read in the unread provider
      try {
        final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
        provider.markChannelAsRead(widget.channelUuid);
      } catch (e) {
        debugPrint('[SIGNAL_GROUP] Error updating unread badge: $e');
      }
    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error sending read receipt: $e');
    }
  }

  /// Send read receipts for all pending messages (when screen becomes visible)
  void _sendPendingReadReceipts() {
    if (_pendingReadReceipts.isEmpty) return;
    
    debugPrint('[SIGNAL_GROUP] Sending ${_pendingReadReceipts.length} pending read receipts');
    final receiptsToSend = List<String>.from(_pendingReadReceipts);
    
    for (final itemId in receiptsToSend) {
      _sendReadReceiptForMessage(itemId);
    }
  }

  // ========================================
  // OLD METHODS REMOVED (No longer needed with GroupItem API)
  // - _handleSenderKeyDistribution: Keys now loaded via REST API
  // - _handleSenderKeyRequest: No more 1:1 key requests
  // - _handleSenderKeyRecreated: Keys managed server-side
  // - _requestSenderKey: Replaced by loadSenderKeyFromServer in SignalService
  // - _loadSenderKeyFromServer: Replaced by loadSenderKeyFromServer in SignalService
  // - _processPendingMessages: Auto-reload handles this in decryptGroupItem
  // - _handleNewMessage: Replaced by _handleGroupItem
  // ========================================

  Future<void> _loadMessages({bool loadMore = false}) async {
    if (loadMore) {
      if (_loadingMore || !_hasMoreMessages) return;
      setState(() {
        _loadingMore = true;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      ApiService.init();
      final signalService = SignalService.instance;

      // NEW: Load sent group items from new store
      final sentGroupItems = await signalService.loadSentGroupItems(widget.channelUuid);
      debugPrint('[SIGNAL_GROUP] Loaded ${sentGroupItems.length} sent items');
      for (final item in sentGroupItems) {
        debugPrint('[SIGNAL_GROUP] Sent item: itemId=${item['itemId']}, type=${item['type']}, message length=${(item['message'] as String?)?.length}');
      }

      // NEW: Load received/decrypted group items from new store
      final receivedGroupItems = await signalService.loadReceivedGroupItems(widget.channelUuid);
      debugPrint('[SIGNAL_GROUP] Loaded ${receivedGroupItems.length} received items');

      // NEW: Load group items from server via REST API
      final resp = await ApiService.get('/api/group-items/${widget.channelUuid}?limit=100');
      
      if (resp.statusCode == 200) {
        final items = resp.data['items'] as List<dynamic>;
        final decryptedItems = <Map<String, dynamic>>[];

        for (final item in items) {
          try {
            final itemId = item['itemId'] as String;
            final senderId = item['sender'] as String;
            // Parse senderDeviceId as int (REST API might return String)
            final senderDeviceId = item['senderDevice'] is int
                ? item['senderDevice'] as int
                : int.parse(item['senderDevice'].toString());
            final payload = item['payload'] as String;
            final timestamp = item['timestamp'] as String;
            final itemType = item['type'] as String? ?? 'message';
            
            // Check if already decrypted (in local store)
            final alreadyDecrypted = receivedGroupItems.any((m) => m['itemId'] == itemId);
            if (alreadyDecrypted) {
              continue; // Skip, already have it
            }
            
            // Check if it's our own message
            final isOwnMessage = senderId == signalService.currentUserId;
            if (isOwnMessage) {
              continue; // Skip, will be loaded from sentGroupItems
            }
            
            // Decrypt using NEW method with auto-reload
            String decrypted;
            try {
              decrypted = await signalService.decryptGroupItem(
                channelId: widget.channelUuid,
                senderId: senderId,
                senderDeviceId: senderDeviceId,
                ciphertext: payload,
              );
            } catch (e) {
              debugPrint('[SIGNAL_GROUP] Error decrypting item $itemId: $e');
              continue; // Skip unreadable messages
            }
            
            // Store in new store
            await signalService.decryptedGroupItemsStore.storeDecryptedGroupItem(
              itemId: itemId,
              channelId: widget.channelUuid,
              sender: senderId,
              senderDevice: senderDeviceId,
              message: decrypted,
              timestamp: timestamp,
              type: itemType,
            );
            
            // Check if it's own message (shouldn't happen due to earlier check, but for safety)
            final isItemOwnMessage = senderId == signalService.currentUserId;
            
            decryptedItems.add({
              'itemId': itemId,
              'sender': senderId,
              'senderDisplayName': isItemOwnMessage ? 'You' : UserProfileService.instance.getDisplayName(senderId),
              'text': decrypted,
              'message': decrypted,
              'time': timestamp,
              'timestamp': timestamp,
              'status': 'received',
              'isOwn': isItemOwnMessage,
              'isLocalSent': isItemOwnMessage,
              'type': itemType,
            });
          } catch (e) {
            debugPrint('[SIGNAL_GROUP] Error processing group item: $e');
          }
        }

        // Combine sent and received items
        final allMessages = [
          ...sentGroupItems.where((m) {
            final msgType = m['type'] ?? 'message';
            final isDisplayable = DISPLAYABLE_MESSAGE_TYPES.contains(msgType);
            if (!isDisplayable) {
              debugPrint('[SIGNAL_GROUP] Skipping sent system message type: $msgType');
            }
            return isDisplayable;
          }).map((m) => {
            ...m, 
            'isOwn': true,
            'isLocalSent': true,
            'senderDisplayName': 'You',
            'time': m['timestamp'],
            'text': m['message'],
          }),
          ...receivedGroupItems.where((m) {
            final msgType = m['type'] ?? 'message';
            final isDisplayable = DISPLAYABLE_MESSAGE_TYPES.contains(msgType);
            if (!isDisplayable) {
              debugPrint('[SIGNAL_GROUP] Skipping received system message type: $msgType');
            }
            return isDisplayable;
          }).map((m) => {
            ...m, 
            'isOwn': false,
            'isLocalSent': false,
            'senderDisplayName': () {
              final senderId = m['sender'];
              final isReceivedOwnMessage = senderId == signalService.currentUserId;
              final displayName = isReceivedOwnMessage ? 'You' : UserProfileService.instance.getDisplayName(senderId);
              debugPrint('[SIGNAL_GROUP] Mapping received message: senderId=$senderId, displayName=$displayName, type=${m['type']}');
              return displayName;
            }(),
            'time': m['timestamp'],
            'text': m['message'],
          }),
          ...decryptedItems,
        ];

        // Remove duplicates and sort
        final uniqueMessages = <String, Map<String, dynamic>>{};
        for (final msg in allMessages) {
          final itemId = msg['itemId'] as String?;
          if (itemId != null) {
            uniqueMessages[itemId] = msg;
          }
        }

        final sortedMessages = uniqueMessages.values.toList()
          ..sort((a, b) {
            final timeA = DateTime.tryParse(a['time'] ?? a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
            final timeB = DateTime.tryParse(b['time'] ?? b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
            return timeA.compareTo(timeB);
          });

        // Apply pagination: load last 20 messages, or next 20 older messages
        final totalMessages = sortedMessages.length;
        final List<Map<String, dynamic>> paginatedMessages;
        
        if (loadMore) {
          // Load 20 more older messages
          final newOffset = _messageOffset + 20;
          final startIndex = totalMessages - newOffset - 20;
          final endIndex = totalMessages - newOffset;
          
          if (startIndex < 0) {
            // No more messages to load
            paginatedMessages = sortedMessages.sublist(0, endIndex > 0 ? endIndex : 0);
            _hasMoreMessages = false;
          } else {
            paginatedMessages = sortedMessages.sublist(startIndex, endIndex);
          }
          
          // Prepend to existing messages
          setState(() {
            _messages.insertAll(0, paginatedMessages);
            _messageOffset = newOffset;
            _loadingMore = false;
          });
        } else {
          // Initial load: get last 20 messages
          final startIndex = totalMessages > 20 ? totalMessages - 20 : 0;
          paginatedMessages = sortedMessages.sublist(startIndex);
          
          setState(() {
            _messages = paginatedMessages;
            _messageOffset = 20;
            _hasMoreMessages = totalMessages > 20;
            _loading = false;
          });
        }
      } else {
        setState(() {
          _error = 'Failed to load messages: ${resp.statusCode}';
          _loading = false;
          _loadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error loading messages: $e');
      setState(() {
        _error = 'Error: $e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final itemId = const Uuid().v4();
    final timestamp = DateTime.now().toIso8601String();

    try {
      final signalService = SignalService.instance;
      
      // STEP 4: Check if Signal Protocol is initialized before sending
      if (_error != null && _error!.contains('Signal Protocol not initialized')) {
        if (mounted) {
          context.showCustomSnackBar(
            'Cannot send message: Signal Protocol not initialized. Please refresh the page.',
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          );
        }
        return; // ❌ BLOCK - Critical initialization error
      }
      
      // Check if sender key is available (should be from initialization)
      final hasSenderKey = await signalService.hasSenderKey(
        widget.channelUuid,
        signalService.currentUserId ?? '',
        signalService.currentDeviceId ?? 0,
      );
      
      if (!hasSenderKey) {
        // Attempt to create sender key on-the-fly (failsafe)
        debugPrint('[SIGNAL_GROUP] Sender key missing, attempting to create...');
        try {
          await signalService.createGroupSenderKey(widget.channelUuid);
          await signalService.uploadSenderKeyToServer(widget.channelUuid);
          debugPrint('[SIGNAL_GROUP] Sender key created successfully');
        } catch (keyError) {
          // Show warning but allow retry
          if (mounted) {
            context.showCustomSnackBar(
              'Sender key creation failed. Retrying may work: $keyError',
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            );
          }
          return; // Exit but allow user to retry
        }
      }
      
      // Add optimistic message to UI
      setState(() {
        _messages.add({
          'itemId': itemId,
          'sender': signalService.currentUserId,
          'senderDisplayName': 'You',
          'text': text,
          'message': text,
          'time': timestamp,
          'timestamp': timestamp,
          'status': 'sending',
          'isOwn': true,
          'isLocalSent': true,
          'readCount': 0,
          'deliveredCount': 0,
          'totalCount': 0,
        });
      });

      // CRITICAL: Check socket connection before sending
      if (!SocketService().isConnected) {
        // Add to offline queue
        await OfflineMessageQueue.instance.enqueue(
          QueuedMessage(
            itemId: itemId,
            type: 'group',
            text: text,
            timestamp: timestamp,
            metadata: {
              'channelId': widget.channelUuid,
              'channelName': widget.channelName,
            },
          ),
        );
        
        if (mounted) {
          context.showCustomSnackBar(
            'Not connected. Message queued and will be sent when reconnected.',
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          );
        }
        
        // Update message status to pending
        setState(() {
          final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
          if (msgIndex != -1) {
            _messages[msgIndex]['status'] = 'pending';
          }
        });
        return; // Exit but message stays in queue
      }

      // NEW: Send using sendGroupItem (simpler, no manual key checks)
      await signalService.sendGroupItem(
        channelId: widget.channelUuid,
        message: text,
        itemId: itemId,
        type: 'message',
      );

      // Update message status
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'sent';
        }
      });

      debugPrint('[SIGNAL_GROUP] Message sent successfully: $itemId');

    } catch (e) {
      debugPrint('[SIGNAL_GROUP] Error sending message: $e');
      
      // Update message status to error
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'error';
        }
      });

      // STEP 4: Better error messages based on error type
      String errorMessage = 'Failed to send message';
      Color errorColor = Colors.red;
      
      if (e.toString().contains('No sender key found')) {
        errorMessage = 'Sender key not available. Please try again.';
        errorColor = Colors.orange;
      } else if (e.toString().contains('User not authenticated')) {
        errorMessage = 'Session expired. Please refresh the page.';
        errorColor = Colors.red;
      } else if (e.toString().contains('Identity key')) {
        errorMessage = 'Encryption keys missing. Please refresh the page.';
        errorColor = Colors.red;
      } else if (e.toString().contains('Cannot create sender key')) {
        errorMessage = 'Signal keys missing. Please refresh the page.';
        errorColor = Colors.red;
      } else if (e.toString().contains('network') || e.toString().contains('connection')) {
        errorMessage = 'Network error. Please check your connection and retry.';
        errorColor = Colors.orange;
      } else {
        errorMessage = 'Failed to send message: ${e.toString()}';
      }

      if (mounted) {
        context.showCustomSnackBar(
          errorMessage,
          backgroundColor: errorColor,
          duration: const Duration(seconds: 5),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('# ${widget.channelName}'),
        backgroundColor: colorScheme.surfaceContainerHighest,
        foregroundColor: colorScheme.onSurface,
        elevation: 1,
        actions: [
          // Video Call Button - Navigate to PreJoin screen
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () async {
              // Open PreJoin screen for device selection and E2EE key exchange
              final result = await Navigator.push(
                context,
                SlidePageRoute(
                  builder: (context) => VideoConferencePreJoinView(
                    channelId: widget.channelUuid,
                    channelName: widget.channelName,
                    // No callback needed - will return via Navigator.pop
                  ),
                ),
              );
              
              // If user completed PreJoin, navigate to actual video conference
              if (result != null && result is Map && result['hasE2EEKey'] == true) {
                if (mounted) {
                  Navigator.push(
                    context,
                    SlidePageRoute(
                      builder: (context) => VideoConferenceView(
                        channelId: result['channelId'],
                        channelName: result['channelName'],
                        selectedCamera: result['selectedCamera'],
                        selectedMicrophone: result['selectedMicrophone'],
                      ),
                    ),
                  );
                }
              }
            },
            tooltip: 'Join Video Call',
          ),
          IconButton(
            icon: const Icon(Icons.people),
            onPressed: () {
              Navigator.push(
                context,
                SlidePageRoute(
                  builder: (context) => ChannelMembersScreen(
                    channelId: widget.channelUuid,
                    channelName: widget.channelName,
                    channelScope: RoleScope.channelSignal,
                  ),
                ),
              );
            },
            tooltip: 'Members',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // Navigate to group settings
            },
            tooltip: 'Settings',
          ),
        ],
      ),
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                      color: colorScheme.primary,
                    ),
                  )
                : _error != null
                    ? _buildErrorState()
                    : _messages.isEmpty
                        ? _buildEmptyState()
                        : Column(
                            children: [
                              if (_hasMoreMessages)
                                Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: _loadingMore
                                        ? const SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : ActionChip(
                                            avatar: const Icon(Icons.arrow_upward, size: 18),
                                            label: const Text('Load older messages'),
                                            onPressed: () => _loadMessages(loadMore: true),
                                            backgroundColor: colorScheme.surfaceContainerHighest,
                                          ),
                                  ),
                                ),
                              Expanded(
                                child: MessageList(
                                  key: ValueKey(_messages.length),
                                  messages: _messages,
                                  onFileDownload: _handleFileDownload,
                                  scrollController: _scrollController,
                                ),
                              ),
                            ],
                          ),
          ),
          MessageInput(onSendMessage: _sendMessage),
        ],
      ),
    );
  }

  /// Build error state widget
  Widget _buildErrorState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadMessages,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build empty state widget
  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start the conversation!',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Handle file download request from FileMessageWidget
  Future<void> _handleFileDownload(dynamic fileMessageDynamic) async {
    try {
      // Cast to FileMessage
      final FileMessage fileMessage = fileMessageDynamic as FileMessage;
      
      debugPrint('[GROUP_CHAT] ================================================');
      debugPrint('[GROUP_CHAT] File download requested');
      debugPrint('[GROUP_CHAT] File ID: ${fileMessage.fileId}');
      debugPrint('[GROUP_CHAT] File Name: ${fileMessage.fileName}');
      debugPrint('[GROUP_CHAT] File Size: ${fileMessage.fileSizeFormatted}');
      debugPrint('[GROUP_CHAT] ================================================');
      
      // Show snackbar
      if (mounted) {
        context.showCustomSnackBar(
          'Starting download: ${fileMessage.fileName}...',
          backgroundColor: Colors.blue,
          duration: const Duration(seconds: 2),
        );
      }
      
      // Get P2P Coordinator
      final p2pCoordinator = Provider.of<P2PCoordinator?>(context, listen: false);
      if (p2pCoordinator == null) {
        throw Exception('P2P Coordinator not initialized');
      }
      
      // Get Socket File Client
      final socketService = SocketService();
      if (socketService.socket == null) {
        throw Exception('Socket not connected');
      }
      final socketClient = SocketFileClient(socket: socketService.socket!);
      
      // 1. Fetch file info and seeder chunks from server
      debugPrint('[GROUP_CHAT] Fetching file info and seeders...');
      // Fetch file info for validation and to get sharedWith list
      final fileInfo = await socketClient.getFileInfo(fileMessage.fileId);
      final seederChunks = await socketClient.getAvailableChunks(fileMessage.fileId);
      
      if (seederChunks.isEmpty) {
        throw Exception('No seeders available for this file');
      }
      
      debugPrint('[GROUP_CHAT] Found ${seederChunks.length} seeders');
      
      // Register as leecher
      await socketClient.registerLeecher(fileMessage.fileId);
      
      // 2. Decode the encrypted file key (base64 → Uint8List)
      debugPrint('[GROUP_CHAT] Decoding file encryption key...');
      final Uint8List fileKey = base64Decode(fileMessage.encryptedFileKey);
      debugPrint('[GROUP_CHAT] File key decoded: ${fileKey.length} bytes');
      
      // 3. Start P2P download with the file key
      debugPrint('[GROUP_CHAT] Starting P2P download...');
      await p2pCoordinator.startDownload(
        fileId: fileMessage.fileId,
        fileName: fileMessage.fileName,
        mimeType: fileMessage.mimeType,
        fileSize: fileMessage.fileSize,
        checksum: fileMessage.checksum,
        chunkCount: fileMessage.chunkCount,
        fileKey: fileKey,
        seederChunks: seederChunks,
        sharedWith: (fileInfo['sharedWith'] as List?)?.cast<String>(), // ✅ NEW: Pass sharedWith from fileInfo
      );
      
      debugPrint('[GROUP_CHAT] Download started successfully!');
      
      // Show success feedback
      if (mounted) {
        context.showCustomSnackBar(
          'Download started: ${fileMessage.fileName}',
          backgroundColor: Colors.green,
          action: SnackBarAction(
            label: 'View',
            textColor: Colors.white,
            onPressed: () {
              // TODO: Navigate to downloads screen
              debugPrint('[GROUP_CHAT] Navigate to downloads screen');
            },
          ),
        );
      }
      
    } catch (e, stackTrace) {
      debugPrint('[GROUP_CHAT] ❌ Download failed: $e');
      debugPrint('[GROUP_CHAT] Stack trace: $stackTrace');
      
      if (mounted) {
        context.showCustomSnackBar(
          'Download failed: $e',
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        );
      }
    }
  }
}

