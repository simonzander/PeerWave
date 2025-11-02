import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../services/api_service.dart';
import '../../services/signal_service.dart';
import '../../services/socket_service.dart';
import '../../services/offline_message_queue.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../models/role.dart';
import '../../models/file_message.dart';
import '../channel/channel_members_screen.dart';
import '../../views/video_conference_prejoin_view.dart';
import '../../views/video_conference_view.dart';

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

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  /// Initialize the group chat screen: wait for sender key setup, then load messages
  Future<void> _initialize() async {
    await _initializeGroupChannel();
    await _loadMessages();
    _setupMessageListener();
    
    // Send read receipts for any pending messages when screen becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendPendingReadReceipts();
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
        print('[SIGNAL_GROUP] Identity key pair verified');
      } catch (e) {
        print('[SIGNAL_GROUP] Identity key pair check failed: $e');
        hasIdentityKey = false;
      }
      
      // Attempt to regenerate if missing (instead of giving up)
      if (!hasIdentityKey) {
        print('[SIGNAL_GROUP] Attempting to regenerate Signal Protocol...');
        try {
          // Try to re-initialize Signal Protocol (this should generate keys)
          await signalService.init();
          print('[SIGNAL_GROUP] Signal Protocol regenerated successfully');
          hasIdentityKey = true;
        } catch (regenerateError) {
          print('[SIGNAL_GROUP] Failed to regenerate Signal Protocol: $regenerateError');
          // Show warning but don't block completely
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Signal Protocol initialization incomplete. Some features may not work.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 5),
              ),
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
        print('[SIGNAL_GROUP] Creating and uploading sender key for group ${widget.channelUuid}');
        
        // Create sender key
        await signalService.createGroupSenderKey(widget.channelUuid);
        
        // Upload to server via REST API (replaces 1:1 distribution)
        await signalService.uploadSenderKeyToServer(widget.channelUuid);
        
        print('[SIGNAL_GROUP] Sender key uploaded to server successfully');
      } else {
        print('[SIGNAL_GROUP] Sender key already exists');
      }
      
      // Load ALL sender keys for this channel from server (batch load)
      print('[SIGNAL_GROUP] Loading all sender keys for channel from server...');
      try {
        final result = await signalService.loadAllSenderKeysForChannel(widget.channelUuid);
        print('[SIGNAL_GROUP] All sender keys loaded successfully');
        
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
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot decrypt messages from: $memberList$remaining'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 8),
                action: SnackBarAction(
                  label: 'Retry',
                  textColor: Colors.white,
                  onPressed: () {
                    _initializeGroupChannel(); // Retry loading
                  },
                ),
              ),
            );
          }
        }
      } catch (loadError) {
        print('[SIGNAL_GROUP] Error loading sender keys: $loadError');
        // Show warning but don't block completely
        if (mounted) {
          final errorMsg = loadError.toString();
          if (errorMsg.contains('Failed to load') && errorMsg.contains('sender key')) {
            // Partial failure - some member keys missing
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(loadError.toString().replaceAll('Exception: ', '')),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 7),
              ),
            );
          } else if (errorMsg.contains('HTTP') || errorMsg.contains('server')) {
            // Server error
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to load member encryption keys. You may not be able to read all messages.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 7),
              ),
            );
          }
        }
        // Don't return - allow user to try sending/reading what they can
      }
      
    } catch (e) {
      print('[SIGNAL_GROUP] Error initializing group channel: $e');
      // Show error but don't block the UI completely
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize group chat: $e'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    SignalService.instance.unregisterItemCallback('groupItem', _handleGroupItem);
    SignalService.instance.unregisterItemCallback('groupItemReadUpdate', _handleReadReceipt);
    SocketService().unregisterListener('groupItemDelivered', _handleDeliveryReceipt);
    super.dispose();
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

      print('[SIGNAL_GROUP] Delivery receipt: message delivered to server, $recipientCount recipients');

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
      print('[SIGNAL_GROUP] Error handling delivery receipt: $e');
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

      print('[SIGNAL_GROUP] Read receipt: $readCount/$totalCount read, $deliveredCount delivered');

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
      print('[SIGNAL_GROUP] Error handling read receipt: $e');
    }
  }

  /// Handle incoming group items via Socket.IO (NEW API with auto-reload)
  Future<void> _handleGroupItem(dynamic data) async {
    try {
      final itemId = data['itemId'] as String;
      final channelId = data['channel'] as String;
      final senderId = data['sender'] as String;
      final senderDeviceId = data['senderDevice'] as int;
      final payload = data['payload'] as String;
      final timestamp = data['timestamp'] ?? DateTime.now().toIso8601String();
      final itemType = data['type'] as String? ?? 'message';
      
      // Filter out P2P file key exchange messages (they don't have channels)
      if (itemType == 'fileKeyRequest' || itemType == 'fileKeyResponse') {
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
      
      print('[SIGNAL_GROUP] Received groupItem via Socket.IO: $itemId');
      
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
        print('[SIGNAL_GROUP] Error decrypting groupItem (auto-reload failed): $e');
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
      
      // Add to UI
      setState(() {
        _messages.add({
          'itemId': itemId,
          'sender': senderId,
          'senderDisplayName': senderId, // TODO: Load actual display name
          'text': decrypted,
          'message': decrypted,
          'time': timestamp,
          'timestamp': timestamp,
          'status': 'received',
          'isOwn': false,
          'isLocalSent': false,
          'type': itemType,
        });
        
        // Sort by timestamp
        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      });
      
      print('[SIGNAL_GROUP] GroupItem decrypted and displayed successfully');
      
      // Send read receipt (only for others' messages)
      final isOwnMessage = senderId == signalService.currentUserId;
      if (!isOwnMessage) {
        _sendReadReceiptForMessage(itemId);
      }
    } catch (e) {
      print('[SIGNAL_GROUP] Error handling groupItem: $e');
    }
  }

  /// Send read receipt for a specific message (NEW API)
  void _sendReadReceiptForMessage(String itemId) {
    try {
      // NEW: Use markGroupItemAsRead from SignalService
      SignalService.instance.markGroupItemAsRead(itemId);
      _pendingReadReceipts.remove(itemId);
      print('[SIGNAL_GROUP] Sent read receipt for item: $itemId');
    } catch (e) {
      print('[SIGNAL_GROUP] Error sending read receipt: $e');
    }
  }

  /// Send read receipts for all pending messages (when screen becomes visible)
  void _sendPendingReadReceipts() {
    if (_pendingReadReceipts.isEmpty) return;
    
    print('[SIGNAL_GROUP] Sending ${_pendingReadReceipts.length} pending read receipts');
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

  Future<void> _loadMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      ApiService.init();
      final signalService = SignalService.instance;

      // NEW: Load sent group items from new store
      final sentGroupItems = await signalService.loadSentGroupItems(widget.channelUuid);

      // NEW: Load received/decrypted group items from new store
      final receivedGroupItems = await signalService.loadReceivedGroupItems(widget.channelUuid);

      // NEW: Load group items from server via REST API
      final resp = await ApiService.get('/api/group-items/${widget.channelUuid}?limit=100');
      
      if (resp.statusCode == 200) {
        final items = resp.data['items'] as List<dynamic>;
        final decryptedItems = <Map<String, dynamic>>[];

        for (final item in items) {
          try {
            final itemId = item['itemId'] as String;
            final senderId = item['sender'] as String;
            final senderDeviceId = item['senderDevice'] as int;
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
              print('[SIGNAL_GROUP] Error decrypting item $itemId: $e');
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
            
            decryptedItems.add({
              'itemId': itemId,
              'sender': senderId,
              'senderDisplayName': senderId, // TODO: Load actual display name
              'text': decrypted,
              'message': decrypted,
              'time': timestamp,
              'timestamp': timestamp,
              'status': 'received',
              'isOwn': false,
              'isLocalSent': false,
              'type': itemType,
            });
          } catch (e) {
            print('[SIGNAL_GROUP] Error processing group item: $e');
          }
        }

        // Combine sent and received items
        final allMessages = [
          ...sentGroupItems.map((m) => {
            ...m, 
            'isOwn': true,
            'isLocalSent': true,
            'senderDisplayName': 'You',
            'time': m['timestamp'],
            'text': m['message'],
          }),
          ...receivedGroupItems.map((m) => {
            ...m, 
            'isOwn': false,
            'isLocalSent': false,
            'senderDisplayName': m['sender'], // TODO: Load actual display name
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

        setState(() {
          _messages = sortedMessages;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load messages: ${resp.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      print('[SIGNAL_GROUP] Error loading messages: $e');
      setState(() {
        _error = 'Error: $e';
        _loading = false;
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot send message: Signal Protocol not initialized. Please refresh the page.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
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
        print('[SIGNAL_GROUP] Sender key missing, attempting to create...');
        try {
          await signalService.createGroupSenderKey(widget.channelUuid);
          await signalService.uploadSenderKeyToServer(widget.channelUuid);
          print('[SIGNAL_GROUP] Sender key created successfully');
        } catch (keyError) {
          // Show warning but allow retry
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Sender key creation failed. Retrying may work: $keyError'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 5),
              ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Not connected. Message queued and will be sent when reconnected.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
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

      print('[SIGNAL_GROUP] Message sent successfully: $itemId');

    } catch (e) {
      print('[SIGNAL_GROUP] Error sending message: $e');
      
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: errorColor,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('# ${widget.channelName}'),
        backgroundColor: Colors.grey[850],
        actions: [
          // Video Call Button - Navigate to PreJoin screen
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () async {
              // Open PreJoin screen for device selection and E2EE key exchange
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
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
                    MaterialPageRoute(
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
                MaterialPageRoute(
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
      backgroundColor: const Color(0xFF36393F),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_error!, style: const TextStyle(color: Colors.red)),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadMessages,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _messages.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[600]),
                                const SizedBox(height: 16),
                                Text(
                                  'No messages yet',
                                  style: TextStyle(color: Colors.grey[600], fontSize: 18),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Start the conversation!',
                                  style: TextStyle(color: Colors.grey[500], fontSize: 14),
                                ),
                              ],
                            ),
                          )
                        : MessageList(
                            messages: _messages,
                            onFileDownload: _handleFileDownload,
                          ),
          ),
          MessageInput(onSendMessage: _sendMessage),
        ],
      ),
    );
  }

  /// Handle file download request from FileMessageWidget
  Future<void> _handleFileDownload(dynamic fileMessageDynamic) async {
    try {
      // Cast to FileMessage
      final FileMessage fileMessage = fileMessageDynamic as FileMessage;
      
      print('[GROUP_CHAT] ================================================');
      print('[GROUP_CHAT] File download requested');
      print('[GROUP_CHAT] File ID: ${fileMessage.fileId}');
      print('[GROUP_CHAT] File Name: ${fileMessage.fileName}');
      print('[GROUP_CHAT] File Size: ${fileMessage.fileSizeFormatted}');
      print('[GROUP_CHAT] ================================================');
      
      // Show loading feedback
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Starting download: ${fileMessage.fileName}...'),
            backgroundColor: Colors.blue,
            duration: const Duration(seconds: 2),
          ),
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
      print('[GROUP_CHAT] Fetching file info and seeders...');
      // Fetch file info for validation and to get sharedWith list
      final fileInfo = await socketClient.getFileInfo(fileMessage.fileId);
      final seederChunks = await socketClient.getAvailableChunks(fileMessage.fileId);
      
      if (seederChunks.isEmpty) {
        throw Exception('No seeders available for this file');
      }
      
      print('[GROUP_CHAT] Found ${seederChunks.length} seeders');
      
      // Register as leecher
      await socketClient.registerLeecher(fileMessage.fileId);
      
      // 2. Decode the encrypted file key (base64 → Uint8List)
      print('[GROUP_CHAT] Decoding file encryption key...');
      final Uint8List fileKey = base64Decode(fileMessage.encryptedFileKey);
      print('[GROUP_CHAT] File key decoded: ${fileKey.length} bytes');
      
      // 3. Start P2P download with the file key
      print('[GROUP_CHAT] Starting P2P download...');
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
      
      print('[GROUP_CHAT] Download started successfully!');
      
      // Show success feedback
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download started: ${fileMessage.fileName}'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'View',
              textColor: Colors.white,
              onPressed: () {
                // TODO: Navigate to downloads screen
                print('[GROUP_CHAT] Navigate to downloads screen');
              },
            ),
          ),
        );
      }
      
    } catch (e, stackTrace) {
      print('[GROUP_CHAT] ❌ Download failed: $e');
      print('[GROUP_CHAT] Stack trace: $stackTrace');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
