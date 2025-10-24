import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../services/api_service.dart';
import '../../services/signal_service.dart';
import '../../services/socket_service.dart';
import '../../models/role.dart';
import '../channel/channel_members_screen.dart';

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
    _initializeGroupChannel();
    _loadMessages();
    _setupMessageListener();
    
    // Send read receipts for any pending messages when screen becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendPendingReadReceipts();
    });
  }

  /// Initialize group channel: load all sender keys and upload our own
  Future<void> _initializeGroupChannel() async {
    try {
      final signalService = SignalService.instance;
      
      // Force identity key pair generation if not exists
      try {
        await signalService.identityStore.getIdentityKeyPair();
        print('[SIGNAL_GROUP] Identity key pair verified');
      } catch (e) {
        print('[SIGNAL_GROUP] Error: Identity key pair not available: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Signal Protocol initialization failed. Please try reloading the page.'),
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
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
      await signalService.loadAllSenderKeysForChannel(widget.channelUuid);
      print('[SIGNAL_GROUP] All sender keys loaded successfully');
      
    } catch (e) {
      print('[SIGNAL_GROUP] Error initializing group channel: $e');
      // Don't block the UI if initialization fails
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

      print('[SIGNAL_GROUP] Delivery receipt: message sent to $recipientCount devices');

      // Update message status in UI
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'delivered';
          _messages[msgIndex]['deliveredCount'] = 0; // Will be updated as devices receive
          _messages[msgIndex]['readCount'] = 0;
          _messages[msgIndex]['totalCount'] = recipientCount;
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
          _messages[msgIndex]['status'] = allRead ? 'read' : 'delivered';
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
          'message': decrypted,
          'timestamp': timestamp,
          'status': 'received',
          'isOwn': false,
          'type': itemType,
        });
        
        // Sort by timestamp
        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
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
              'message': decrypted,
              'timestamp': timestamp,
              'status': 'received',
              'isOwn': false,
              'type': itemType,
            });
          } catch (e) {
            print('[SIGNAL_GROUP] Error processing group item: $e');
          }
        }

        // Combine sent and received items
        final allMessages = [
          ...sentGroupItems.map((m) => {...m, 'isOwn': true}),
          ...receivedGroupItems.map((m) => {...m, 'isOwn': false}),
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
            final timeA = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
            final timeB = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
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
      
      // Add optimistic message to UI
      setState(() {
        _messages.add({
          'itemId': itemId,
          'message': text,
          'timestamp': timestamp,
          'status': 'sending',
          'isOwn': true,
        });
      });

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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send message: ${e.toString()}'),
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
                        : MessageList(messages: _messages),
          ),
          MessageInput(onSendMessage: _sendMessage),
        ],
      ),
    );
  }
}
