import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../widgets/message_list.dart';
import '../../widgets/enhanced_message_input.dart';
import '../../widgets/user_avatar.dart';
import '../../services/signal_service.dart';
import '../../services/socket_service.dart';
import '../../services/offline_message_queue.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../models/file_message.dart';
import '../../extensions/snackbar_extensions.dart';
import '../../providers/unread_messages_provider.dart';
import '../../widgets/people_context_panel.dart';
import '../../services/recent_conversations_service.dart';
import 'package:intl/intl.dart';

/// Whitelist of message types that should be displayed in UI
const Set<String> DISPLAYABLE_MESSAGE_TYPES = {'message', 'file', 'image', 'voice'};

/// Screen for Direct Messages (1:1 Signal chats)
class DirectMessagesScreen extends StatefulWidget {
  final String host;
  final String recipientUuid;
  final String recipientDisplayName;

  const DirectMessagesScreen({
    super.key,
    required this.host,
    required this.recipientUuid,
    required this.recipientDisplayName,
  });

  @override
  State<DirectMessagesScreen> createState() => _DirectMessagesScreenState();
}

class _DirectMessagesScreenState extends State<DirectMessagesScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String? _error;
  int _messageOffset = 0;
  bool _hasMoreMessages = true;
  bool _loadingMore = false;
  final ScrollController _scrollController = ScrollController();
  
  // Context panel state
  List<Map<String, dynamic>> _recentPeople = [];
  bool _isLoadingRecentPeople = false;
  int _recentPeopleLimit = 10;
  bool _hasMoreRecentPeople = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    
    // ✅ Unregister specific callbacks for this conversation
    for (final type in DISPLAYABLE_MESSAGE_TYPES) {
      SignalService.instance.unregisterReceiveItem(
        type,
        widget.recipientUuid,
        _handleNewMessageFromCallback,
      );
    }
    
    debugPrint('[DM_SCREEN] Unregistered all receiveItem callbacks');
    
    SignalService.instance.clearDeliveryCallbacks();
    SignalService.instance.clearReadCallbacks();
    super.dispose();
  }

  @override
  void didUpdateWidget(DirectMessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload messages when recipient changes
    if (oldWidget.recipientUuid != widget.recipientUuid) {
      debugPrint('[DIRECT_MESSAGES] Recipient changed from ${oldWidget.recipientUuid} to ${widget.recipientUuid}');
      _messages = []; // Clear old messages
      _messageOffset = 0;
      _hasMoreMessages = true;
      
      // Clear unread count for new conversation
      try {
        final unreadProvider = context.read<UnreadMessagesProvider>();
        unreadProvider.markDirectMessageAsRead(widget.recipientUuid);
        debugPrint('[DM_SCREEN] ✓ Cleared unread count for new conversation ${widget.recipientUuid}');
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error clearing unread count: $e');
      }
      
      _initialize(); // Reload
    }
  }

  /// Initialize the direct messages screen
  Future<void> _initialize() async {
    await _loadMessages();
    await _loadRecentPeople(); // Load recent people for context panel
    _setupReceiveItemCallbacks(); // ✅ Register granular callbacks
    _setupReceiptListeners();
    
    // ✅ Clear unread count for this conversation
    if (mounted) {
      try {
        final unreadProvider = context.read<UnreadMessagesProvider>();
        unreadProvider.markDirectMessageAsRead(widget.recipientUuid);
        debugPrint('[DM_SCREEN] ✓ Cleared unread count for ${widget.recipientUuid}');
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error clearing unread count: $e');
      }
    }
    
    // Scroll to bottom after initial load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _setupReceiptListeners() {
    // Listen for delivery receipts
    SignalService.instance.onDeliveryReceipt((itemId) async {
      if (!mounted) return;
      
      debugPrint('[DM_SCREEN] Delivery receipt received for itemId: $itemId');
      
      // Update status in SQLite
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.markAsDelivered(itemId);
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error updating status in SQLite: $e');
      }
      
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          debugPrint('[DM_SCREEN] ✓ Updated message status to delivered: $itemId');
          _messages[msgIndex]['status'] = 'delivered';
        } else {
          debugPrint('[DM_SCREEN] ⚠ Message not found in list for delivery receipt: $itemId');
        }
      });
    });

    // Listen for read receipts
    SignalService.instance.onReadReceipt((receiptInfo) async {
      final itemId = receiptInfo['itemId'] as String;
      final readByDeviceId = receiptInfo['readByDeviceId'] as int?;
      final readByUserId = receiptInfo['readByUserId'] as String?;

      if (!mounted) return;

      debugPrint('[DM_SCREEN] Read receipt received for itemId: $itemId from user: $readByUserId, device: $readByDeviceId');

      // Update status in SQLite
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.markAsRead(itemId);
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error updating status in SQLite: $e');
      }

      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          debugPrint('[DM_SCREEN] ✓ Updated message status to read: $itemId');
          _messages[msgIndex]['status'] = 'read';

          // Delete message from server after read confirmation
          SignalService.instance.deleteItemFromServer(itemId);
        } else {
          debugPrint('[DM_SCREEN] ⚠ Message not found in list for read receipt: $itemId');
        }
      });
    });
  }

  /// ✅ NEW: Setup granular callbacks for this specific conversation
  void _setupReceiveItemCallbacks() {
    // Register callback for each displayable message type
    for (final type in DISPLAYABLE_MESSAGE_TYPES) {
      SignalService.instance.registerReceiveItem(
        type,
        widget.recipientUuid,
        _handleNewMessageFromCallback,
      );
    }
    
    debugPrint('[DM_SCREEN] Registered receiveItem callbacks for ${DISPLAYABLE_MESSAGE_TYPES.length} types');
  }

  /// ✅ NEW: Handle incoming messages from SignalService callbacks
  void _handleNewMessageFromCallback(Map<String, dynamic> item) {
    if (!mounted) return;
    
    debugPrint('[DM_SCREEN] New message received via callback: ${item['itemId']}');
    
    // Message is already stored in SQLite by SignalService
    // Only update UI
    setState(() {
      final itemId = item['itemId'];
      final exists = _messages.any((msg) => msg['itemId'] == itemId);
      
      if (!exists) {
        final isLocalSent = item['isLocalSent'] == true;
        
        // Add message to local list
        _messages.add({
          'itemId': item['itemId'],
          'sender': item['sender'],
          'senderDeviceId': item['senderDeviceId'],
          'senderDisplayName': isLocalSent ? 'You' : widget.recipientDisplayName,
          'text': item['message'],
          'message': item['message'],
          'payload': item['message'],
          'time': item['timestamp'] ?? DateTime.now().toIso8601String(),
          'isLocalSent': isLocalSent,
          'status': isLocalSent ? (item['status'] ?? 'sending') : null,
          'type': item['type'],
          'metadata': item['metadata'],
        });
        
        // Sort by time
        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
        
        debugPrint('[DM_SCREEN] ✓ Message added to UI list');
      } else {
        // Message already in list - check if this is a status update
        if (item['status'] != null) {
          final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
          if (msgIndex != -1) {
            _messages[msgIndex]['status'] = item['status'];
            debugPrint('[DM_SCREEN] ✓ Updated message status: ${item['status']}');
          }
        } else {
          debugPrint('[DM_SCREEN] ⚠ Message already in list (duplicate prevention)');
        }
      }
    });
    
    // Send read receipt if this is a received message
    final isLocalSent = item['isLocalSent'] == true;
    if (!isLocalSent && item['sender'] == widget.recipientUuid) {
      final senderDeviceId = item['senderDeviceId'] is int
          ? item['senderDeviceId'] as int
          : int.parse(item['senderDeviceId'].toString());
      _sendReadReceipt(item['itemId'], item['sender'], senderDeviceId);
    }
    
    // Auto-scroll to new message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendReadReceipt(String itemId, String sender, int senderDeviceId) async {
    try {
      // Check if we already sent a read receipt for this message
      final messageStore = await SqliteMessageStore.getInstance();
      final alreadySent = await messageStore.hasReadReceiptBeenSent(itemId);
      
      if (alreadySent) {
        debugPrint('[DM_SCREEN] Read receipt already sent for itemId: $itemId, skipping');
        return;
      }
      
      final myDeviceId = SignalService.instance.currentDeviceId;

      await SignalService.instance.sendItem(
        recipientUserId: sender,
        type: "read_receipt",
        payload: jsonEncode({
          'itemId': itemId,
          'readByDeviceId': myDeviceId,
        }),
      );
      
      // Mark that we sent the read receipt
      await messageStore.markReadReceiptSent(itemId);
      debugPrint('[DM_SCREEN] ✓ Read receipt sent and marked for itemId: $itemId');
      
      // Mark this conversation as read in the unread provider
      try {
        final provider = Provider.of<UnreadMessagesProvider>(context, listen: false);
        provider.markDirectMessageAsRead(sender);
      } catch (e) {
        debugPrint('[DM_SCREEN] Error updating unread badge: $e');
      }
    } catch (e) {
      debugPrint('[DM_SCREEN] Error sending read receipt: $e');
    }
  }

  /// Load recent conversation partners for context panel
  Future<void> _loadRecentPeople() async {
    if (_isLoadingRecentPeople) return;
    
    setState(() {
      _isLoadingRecentPeople = true;
    });

    try {
      // Load from RecentConversationsService with SQLite + profiles
      final allConversations = await RecentConversationsService.getRecentConversations();
      
      // Apply limit
      final conversations = allConversations.take(_recentPeopleLimit).toList();
      
      // Load last messages from SQLite
      final messageStore = await SqliteMessageStore.getInstance();
      final List<Map<String, dynamic>> peopleWithMessages = [];
      
      for (final conv in conversations) {
        final userId = conv['uuid'] as String;
        
        // Get last message
        final messages = await messageStore.getMessagesFromConversation(
          userId,
          limit: 1,
          offset: 0,
          types: ['message', 'file', 'image', 'voice'],
        );
        
        String? lastMessage;
        String? lastMessageTime;
        
        if (messages.isNotEmpty) {
          final msg = messages.first;
          final messageText = msg['message'] as String?;
          final messageType = msg['type'] as String?;
          
          // Format message preview
          if (messageType == 'file') {
            lastMessage = '📎 File';
          } else if (messageType == 'image') {
            lastMessage = '🖼️ Image';
          } else if (messageType == 'voice') {
            lastMessage = '🎤 Voice';
          } else {
            lastMessage = messageText;
          }
          
          // Truncate if too long
          if (lastMessage != null && lastMessage.length > 40) {
            lastMessage = '${lastMessage.substring(0, 40)}...';
          }
          
          // Format timestamp
          lastMessageTime = _formatMessageTime(msg['timestamp'] as String?);
        }
        
        peopleWithMessages.add({
          'uuid': userId,
          'displayName': conv['displayName'],
          'username': userId, // Use userId as username fallback
          'profilePicture': conv['picture'],
          'lastMessage': lastMessage,
          'lastMessageTime': lastMessageTime,
        });
      }
      
      setState(() {
        _recentPeople = peopleWithMessages;
        _isLoadingRecentPeople = false;
        _hasMoreRecentPeople = allConversations.length > _recentPeopleLimit;
      });
      
    } catch (e) {
      debugPrint('[DM_SCREEN] Error loading recent people: $e');
      setState(() {
        _isLoadingRecentPeople = false;
      });
    }
  }

  /// Format message timestamp
  String _formatMessageTime(String? timestamp) {
    if (timestamp == null) return '';
    
    try {
      final messageTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(messageTime);
      
      if (difference.inMinutes < 1) {
        return 'now';
      } else if (difference.inMinutes < 60) {
        return '${difference.inMinutes}m';
      } else if (difference.inHours < 24) {
        return '${difference.inHours}h';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d';
      } else {
        return DateFormat('MMM d').format(messageTime);
      }
    } catch (e) {
      return '';
    }
  }

  /// Load more recent people (incremental)
  Future<void> _loadMoreRecentPeople() async {
    if (_isLoadingRecentPeople || !_hasMoreRecentPeople) return;
    
    setState(() {
      _recentPeopleLimit += 10;
    });
    
    await _loadRecentPeople();
  }

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
      // ✅ EINZIGE Datenquelle: SQLite
      final messageStore = await SqliteMessageStore.getInstance();
      
      // Load messages with pagination
      final messages = await messageStore.getMessagesFromConversation(
        widget.recipientUuid,
        limit: 20,
        offset: loadMore ? _messageOffset : 0,
        types: DISPLAYABLE_MESSAGE_TYPES.toList(),
      );
      
      debugPrint('[DM_SCREEN] Loaded ${messages.length} messages from SQLite (offset: ${loadMore ? _messageOffset : 0})');
      
      // Transform to UI format
      final uiMessages = messages.map((msg) {
        final isLocalSent = msg['direction'] == 'sent';
        return {
          'itemId': msg['item_id'],
          'sender': isLocalSent ? SignalService.instance.currentUserId : msg['sender'],
          'senderDeviceId': msg['sender_device_id'],
          'senderDisplayName': isLocalSent ? 'You' : widget.recipientDisplayName,
          'text': msg['message'],
          'message': msg['message'],
          'payload': msg['message'],
          'time': msg['timestamp'],
          'isLocalSent': isLocalSent,
          'status': isLocalSent ? (msg['status'] ?? 'sent') : null,
          'type': msg['type'],
          'metadata': msg['metadata'],
        };
      }).toList();
      
      // Reverse messages since DB returns DESC (newest first), but UI needs ASC (oldest first)
      final reversedMessages = uiMessages.reversed.toList();
      
      setState(() {
        if (loadMore) {
          // Prepend older messages (already in correct order after reversal)
          _messages.insertAll(0, reversedMessages);
          _messageOffset += messages.length;
        } else {
          // Initial load
          _messages = reversedMessages;
          _messageOffset = messages.length;
        }
        _hasMoreMessages = messages.length == 20;
        _loading = false;
        _loadingMore = false;
      });
      
      debugPrint('[DM_SCREEN] ✓ Messages loaded successfully');
      
    } catch (e, stackTrace) {
      debugPrint('[DM_SCREEN] ❌ Error loading messages: $e');
      debugPrint('[DM_SCREEN] Stack trace: $stackTrace');
      
      setState(() {
        _error = 'Error loading messages: $e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// Enhanced message sending with support for multiple message types
  Future<void> _sendMessageEnhanced(
    String content, {
    String? type,
    Map<String, dynamic>? metadata,
  }) async {
    final messageType = type ?? 'message';
    
    if (content.trim().isEmpty) return;

    // Validate size for base64 content (image, voice)
    if (messageType == 'image' || messageType == 'voice') {
      final sizeBytes = content.length * 0.75; // Base64 to bytes approximation
      if (sizeBytes > 2 * 1024 * 1024) {
        if (mounted) {
          context.showErrorSnackBar(
            'Content too large (max 2MB)',
            duration: const Duration(seconds: 3),
          );
        }
        return;
      }
    }

    final itemId = Uuid().v4();
    final timestamp = DateTime.now().toIso8601String();

    // Add to UI immediately for text and displayable types
    if (messageType == 'message' || messageType == 'image' || messageType == 'voice') {
      setState(() {
        _messages.add({
          'itemId': itemId,
          'sender': SignalService.instance.currentUserId,
          'senderDeviceId': SignalService.instance.currentDeviceId,
          'senderDisplayName': 'You',
          'text': messageType == 'message' ? content : '[${messageType.toUpperCase()}]',
          'message': content,
          'payload': content,
          'time': timestamp,
          'isLocalSent': true,
          'status': 'sending',
          'type': messageType,
          'metadata': metadata,
        });
      });
    }

    // Check connection
    if (!SocketService().isConnected) {
      await OfflineMessageQueue.instance.enqueue(
        QueuedMessage(
          itemId: itemId,
          type: 'direct',
          text: content,
          timestamp: timestamp,
          metadata: {
            'recipientId': widget.recipientUuid,
            'recipientName': widget.recipientDisplayName,
            'messageType': messageType,
            ...?metadata,
          },
        ),
      );
      
      if (mounted) {
        context.showErrorSnackBar(
          'Not connected. Message queued.',
          duration: const Duration(seconds: 3),
        );
      }
      
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'pending';
        }
      });
      return;
    }

    try {
      // Send main message
      await SignalService.instance.sendItem(
        recipientUserId: widget.recipientUuid,
        type: messageType,
        payload: content,
        itemId: itemId,
        metadata: metadata,
      );
      
      // Send notification messages for mentions
      if (metadata != null && metadata['mentions'] != null) {
        final mentions = metadata['mentions'] as List;
        for (final mention in mentions) {
          try {
            await SignalService.instance.sendItem(
              recipientUserId: mention['userId'] as String,
              type: 'notification',
              payload: jsonEncode({
                'mentionedBy': SignalService.instance.currentUserId,
                'mentionedByName': 'You',
                'message': content,
                'conversationId': widget.recipientUuid,
                'conversationName': widget.recipientDisplayName,
              }),
            );
            debugPrint('[DM] Sent mention notification to ${mention['userId']}');
          } catch (e) {
            debugPrint('[DM] Failed to send mention notification: $e');
          }
        }
      }
      
      // Update status
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'sent';
          debugPrint('[DM_SCREEN] ✓ ${messageType} message sent: $itemId');
        }
      });
    } catch (e) {
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'failed';
        }
      });
      
      if (mounted) {
        context.showErrorSnackBar(
          'Failed to send ${messageType}: ${e.toString()}',
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
        title: Row(
          children: [
            SmallUserAvatar(
              userId: widget.recipientUuid,
              displayName: widget.recipientDisplayName,
            ),
            const SizedBox(width: 12),
            Text(widget.recipientDisplayName),
          ],
        ),
        backgroundColor: colorScheme.surfaceContainerHighest,
        foregroundColor: colorScheme.onSurface,
        elevation: 1,
      ),
      backgroundColor: colorScheme.surface,
      body: Row(
        children: [
          // Context panel (recent conversations) - LEFT SIDE
          PeopleContextPanel(
            host: widget.host,
            recentPeople: _recentPeople,
            favoritePeople: const [], // No favorites for now
            onPersonTap: (uuid, displayName) {
              // Navigate to different conversation
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (context) => DirectMessagesScreen(
                    host: widget.host,
                    recipientUuid: uuid,
                    recipientDisplayName: displayName,
                  ),
                ),
              );
            },
            isLoading: _isLoadingRecentPeople,
            onLoadMore: _loadMoreRecentPeople,
            hasMore: _hasMoreRecentPeople,
          ),
          
          // Main chat area - RIGHT SIDE
          Expanded(
            child: Column(
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
                EnhancedMessageInput(
                  onSendMessage: (message, {type, metadata}) {
                    _sendMessageEnhanced(message, type: type, metadata: metadata);
                  },
                  onFileShare: (itemId) {
                    // Handle P2P file share completion
                    debugPrint('[DM_SCREEN] File shared: $itemId');
                  },
                  availableUsers: [
                    {
                      'userId': widget.recipientUuid,
                      'displayName': widget.recipientDisplayName,
                      'atName': widget.recipientDisplayName.toLowerCase().replaceAll(' ', ''),
                    }
                  ],
                  isGroupChat: false,
                  recipientUserId: widget.recipientUuid, // For P2P file sharing
                ),
              ],
            ),
          ),
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

  /// Handle file download request from FileMessageWidget
  Future<void> _handleFileDownload(dynamic fileMessageDynamic) async {
    try {
      // Cast to FileMessage
      final FileMessage fileMessage = fileMessageDynamic as FileMessage;
      
      debugPrint('[DIRECT_MSG] ================================================');
      debugPrint('[DIRECT_MSG] File download requested');
      debugPrint('[DIRECT_MSG] File ID: ${fileMessage.fileId}');
      debugPrint('[DIRECT_MSG] File Name: ${fileMessage.fileName}');
      debugPrint('[DIRECT_MSG] File Size: ${fileMessage.fileSizeFormatted}');
      debugPrint('[DIRECT_MSG] ================================================');
      
      // Show snackbar
      if (mounted) {
        context.showSuccessSnackBar(
          'Starting download: ${fileMessage.fileName}...',
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
      debugPrint('[DIRECT_MSG] Fetching file info and seeders...');
      // Fetch file info for validation and to get sharedWith list
      final fileInfo = await socketClient.getFileInfo(fileMessage.fileId);
      final seederChunks = await socketClient.getAvailableChunks(fileMessage.fileId);
      
      if (seederChunks.isEmpty) {
        throw Exception('No seeders available for this file');
      }
      
      debugPrint('[DIRECT_MSG] Found ${seederChunks.length} seeders');
      
      // Register as leecher
      await socketClient.registerLeecher(fileMessage.fileId);
      
      // 2. Decode the encrypted file key (base64 → Uint8List)
      debugPrint('[DIRECT_MSG] Decoding file encryption key...');
      final Uint8List fileKey = base64Decode(fileMessage.encryptedFileKey);
      debugPrint('[DIRECT_MSG] File key decoded: ${fileKey.length} bytes');
      
      // 3. Start P2P download with the file key
      debugPrint('[DIRECT_MSG] Starting P2P download...');
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
      
      debugPrint('[DIRECT_MSG] Download started successfully!');
      
      // Show success feedback
      if (mounted) {
        final colorScheme = Theme.of(context).colorScheme;
        context.showSuccessSnackBar(
          'Download started: ${fileMessage.fileName}',
          action: SnackBarAction(
            label: 'View',
            textColor: colorScheme.onPrimaryContainer,
            onPressed: () {
              // TODO: Navigate to downloads screen
              debugPrint('[DIRECT_MSG] Navigate to downloads screen');
            },
          ),
        );
      }
      
    } catch (e, stackTrace) {
      debugPrint('[DIRECT_MSG] ❌ Download failed: $e');
      debugPrint('[DIRECT_MSG] Stack trace: $stackTrace');
      
      if (mounted) {
        context.showErrorSnackBar(
          'Download failed: $e',
          duration: const Duration(seconds: 5),
        );
      }
    }
  }
}

