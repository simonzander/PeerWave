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
import '../../services/api_service.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../models/file_message.dart';
import '../../extensions/snackbar_extensions.dart';
import '../../providers/unread_messages_provider.dart';

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

  @override
  void initState() {
    super.initState();
    _initialize();
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    SignalService.instance.unregisterItemCallback('message', _handleNewMessage);
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
      _initialize(); // Reload
    }
  }

  /// Initialize the direct messages screen: verify Signal Protocol, then load messages
  Future<void> _initialize() async {
    // Verify own identity keys are available
    try {
      await SignalService.instance.identityStore.getIdentityKeyPair();
      debugPrint('[DIRECT_MESSAGES] Identity key pair verified');
    } catch (e) {
      debugPrint('[DIRECT_MESSAGES] Identity key pair check failed: $e');
      
      // Attempt to regenerate if missing
      debugPrint('[DIRECT_MESSAGES] Attempting to regenerate Signal Protocol...');
      try {
        await SignalService.instance.init();
        debugPrint('[DIRECT_MESSAGES] Signal Protocol regenerated successfully');
      } catch (regenerateError) {
        debugPrint('[DIRECT_MESSAGES] Failed to regenerate Signal Protocol: $regenerateError');
        
        // Show warning and set error state
        if (mounted) {
          context.showErrorSnackBar(
            'Signal Protocol initialization incomplete. Cannot send messages.',
            duration: const Duration(seconds: 5),
          );
        }
        
        setState(() {
          _error = 'Signal Protocol not initialized';
        });
        // Continue loading messages (can still receive)
      }
    }
    
    await _loadMessages();
    _setupMessageListener();
    _setupReceiptListeners();
    
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
          if (readByDeviceId != null && readByUserId != null) {
            _deleteMessageFromServer(itemId, receiverDeviceId: readByDeviceId, receiverUserId: readByUserId);
          } else {
            _deleteMessageFromServer(itemId);
          }
        } else {
          debugPrint('[DM_SCREEN] ⚠ Message not found in list for read receipt: $itemId');
        }
      });
    });
  }

  void _setupMessageListener() {
    SignalService.instance.registerItemCallback('message', _handleNewMessage);
  }

  void _handleNewMessage(dynamic item) {
    final itemType = item['type'];

    // ✅ WHITELIST: Only display allowed message types
    if (!DISPLAYABLE_MESSAGE_TYPES.contains(itemType)) {
      // Handle read_receipt system message
      if (itemType == 'read_receipt') {
        try {
          final receiptData = jsonDecode(item['message']);
          final referencedItemId = receiptData['itemId'];
          final readByDeviceId = receiptData['readByDeviceId'] as int?;
          final readByUserId = item['sender'];

          setState(() {
            final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == referencedItemId);
            if (msgIndex != -1) {
              _messages[msgIndex]['status'] = 'read';

              if (readByDeviceId != null && readByUserId != null) {
                _deleteMessageFromServer(
                  referencedItemId,
                  receiverDeviceId: readByDeviceId,
                  receiverUserId: readByUserId
                );
              } else {
                _deleteMessageFromServer(referencedItemId);
              }
            }
          });

          if (item['itemId'] != null) {
            _deleteMessageFromServer(item['itemId']);
          }
        } catch (e) {
          debugPrint('[DM_SCREEN] Error processing read_receipt: $e');
        }
      }
      // Don't display system messages in UI
      return;
    }

    // Check if message is relevant to this conversation
    final sender = item['sender'];
    final recipient = item['recipient'];
    final isFromTarget = sender == widget.recipientUuid;
    final isLocalSent = item['isLocalSent'] == true;

    final isRelevant = isFromTarget ||
                       (isLocalSent && recipient == widget.recipientUuid) ||
                       (recipient == widget.recipientUuid);

    if (isRelevant) {
      setState(() {
        final itemId = item['itemId'];
        final exists = _messages.any((msg) => msg['itemId'] == itemId);
        if (exists) return;

        final msg = {
          'itemId': item['itemId'],
          'sender': sender,
          'senderDeviceId': item['senderDeviceId'],
          'senderDisplayName': isLocalSent ? 'You' : widget.recipientDisplayName,
          'text': item['message'],
          'message': item['message'],
          'payload': item['payload'] ?? item['message'], // Add payload field for file messages
          'time': item['timestamp'] ?? DateTime.now().toIso8601String(),
          'isLocalSent': isLocalSent,
          // Status logic: 
          // - Local sent messages keep their status (sending/sent/delivered/read)
          // - Received messages have no status indicator
          'status': isLocalSent ? (item['status'] ?? 'sending') : null,
          'type': itemType, // Preserve message type (message or file)
        };
        _messages.add(msg);

        _messages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      });

      if (!isLocalSent && isFromTarget) {
        // Parse senderDeviceId as int (might be String from storage/socket)
        final senderDeviceId = item['senderDeviceId'] is int
            ? item['senderDeviceId'] as int
            : int.parse(item['senderDeviceId'].toString());
        _sendReadReceipt(item['itemId'], sender, senderDeviceId);
      }
    }
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

  Future<void> _deleteMessageFromServer(String itemId, {int? receiverDeviceId, String? receiverUserId}) async {
    try {
      String url = '${widget.host}/items/$itemId';
      final params = <String>[];

      if (receiverDeviceId != null) {
        params.add('deviceId=$receiverDeviceId');
      }
      if (receiverUserId != null) {
        params.add('receiverId=$receiverUserId');
      }

      if (params.isNotEmpty) {
        url += '?${params.join('&')}';
      }

      await ApiService.delete(url);
    } catch (e) {
      debugPrint('[DM_SCREEN] Error deleting message from server: $e');
    }
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
      ApiService.init();

      // Load messages from SQLite (both sent and received)
      final messageStore = await SqliteMessageStore.getInstance();
      final allMessages = await messageStore.getMessagesFromConversation(
        widget.recipientUuid,
        types: DISPLAYABLE_MESSAGE_TYPES.toList(), // ✅ Whitelist: Only load message & file types
      );
      
      // Separate into sent and received
      final sentMessages = allMessages
          .where((msg) => msg['direction'] == 'sent')
          .map((msg) => {
            'itemId': msg['itemId'],
            'message': msg['message'],
            'timestamp': msg['timestamp'],
            'type': msg['type'],
            'status': msg['status'] ?? 'sent', // Use status from SQLite
            'metadata': msg['metadata'], // ✅ Preserve metadata for image/voice
          })
          .toList();
      
      final receivedMessages = allMessages
          .where((msg) => msg['direction'] == 'received')
          .map((msg) => {
            'itemId': msg['itemId'],
            'message': msg['message'],
            'timestamp': msg['timestamp'],
            'sender': msg['sender'],
            'type': msg['type'],
            'metadata': msg['metadata'], // ✅ Preserve metadata for image/voice
          })
          .toList();
      
      debugPrint('[DM_SCREEN] Loaded ${sentMessages.length} sent + ${receivedMessages.length} received messages from SQLite');

      // Load new messages from server
      final resp = await ApiService.get('${widget.host}/direct/messages/${widget.recipientUuid}');
      
      if (resp.statusCode == 200) {
        resp.data.sort((a, b) {
          final timeA = DateTime.tryParse(a['timestamp'] ?? a['createdAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['timestamp'] ?? b['createdAt'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });

        final decryptedMessages = <Map<String, dynamic>>[];

        for (int i = 0; i < resp.data.length; i++) {
          final msg = resp.data[i];
          final msgType = msg['type'];

          // Skip system messages (senderKeyDistribution, senderKeyRequest)
          if (msgType == 'senderKeyDistribution' || msgType == 'senderKeyRequest') {
            debugPrint('[DM_SCREEN] Skipping system message type: $msgType');
            continue;
          }

          if (msgType == 'read_receipt') {
            try {
              // Parse deviceSender as int (server returns String from SQLite INTEGER)
              final deviceSender = msg['deviceSender'] is int
                  ? msg['deviceSender'] as int
                  : int.parse(msg['deviceSender'].toString());
              
              final item = {
                'itemId': msg['itemId'],
                'sender': msg['sender'],
                'senderDeviceId': deviceSender,
                'payload': msg['payload'],
                'cipherType': msg['cipherType'],
              };

              final decrypted = await SignalService.instance.decryptItemFromData(item);
              if (decrypted.isNotEmpty) {
                final receiptData = jsonDecode(decrypted);
                final referencedItemId = receiptData['itemId'];
                final readByDeviceId = receiptData['readByDeviceId'] as int?;
                final readByUserId = msg['sender'];

                final msgIndex = _messages.indexWhere((m) => m['itemId'] == referencedItemId);
                if (msgIndex != -1) {
                  _messages[msgIndex]['status'] = 'read';
                  
                  // Update status in SQLite
                  try {
                    final messageStore = await SqliteMessageStore.getInstance();
                    await messageStore.markAsRead(referencedItemId);
                  } catch (e) {
                    debugPrint('[DM_SCREEN] ⚠️ Error updating read status in SQLite: $e');
                  }

                  if (readByDeviceId != null && readByUserId != null) {
                    await _deleteMessageFromServer(
                      referencedItemId,
                      receiverDeviceId: readByDeviceId,
                      receiverUserId: readByUserId
                    );
                  }
                }

                await _deleteMessageFromServer(msg['itemId']);
              }
            } catch (e) {
              debugPrint('[DM_SCREEN] Error processing read_receipt: $e');
            }
            continue;
          }

          // Parse deviceSender as int (server returns String from SQLite INTEGER)
          final deviceSender = msg['deviceSender'] is int
              ? msg['deviceSender'] as int
              : int.parse(msg['deviceSender'].toString());

          final item = {
            'itemId': msg['itemId'],
            'sender': msg['sender'],
            'senderDeviceId': deviceSender,
            'payload': msg['payload'],
            'cipherType': msg['cipherType'],
          };

          final decrypted = await SignalService.instance.decryptItemFromData(item);

          if (decrypted.isEmpty) continue;

          final decryptedMsg = {
            'itemId': msg['itemId'],
            'sender': msg['sender'],
            'senderDeviceId': deviceSender,
            'text': decrypted,
            'message': decrypted,
            'payload': decrypted, // Add payload field for file messages
            'time': msg['time'] ?? msg['timestamp'] ?? msg['createdAt'] ?? DateTime.now().toIso8601String(),
            'senderDisplayName': widget.recipientDisplayName,
            'type': msgType, // Preserve message type (message or file)
          };

          decryptedMessages.add(decryptedMsg);

          if (msg['sender'] == widget.recipientUuid) {
            // Parse deviceSender as int (IndexedDB might return String)
            final deviceSender = msg['deviceSender'] is int
                ? msg['deviceSender'] as int
                : int.parse(msg['deviceSender'].toString());
            await _sendReadReceipt(msg['itemId'], msg['sender'], deviceSender);
          }
        }

        // Merge all messages
        final allMessages = <Map<String, dynamic>>[];

        for (var sentMsg in sentMessages) {
          final message = sentMsg['message'] ?? '';
          if (message.toString().startsWith('{"itemId":')) continue;

          // Filter displayable message types
          final msgType = sentMsg['type'] ?? 'message';
          if (!DISPLAYABLE_MESSAGE_TYPES.contains(msgType)) {
            debugPrint('[DM_SCREEN] Skipping sent system message type: $msgType');
            continue;
          }

          allMessages.add({
            'itemId': sentMsg['itemId'],
            'sender': SignalService.instance.currentUserId,
            'senderDisplayName': 'You',
            'text': message,
            'message': message,
            'payload': message, // Add payload field for file messages
            'time': sentMsg['timestamp'],
            'isLocalSent': true,
            'status': sentMsg['status'] ?? 'sending',
            'type': msgType, // Preserve message type
            'metadata': sentMsg['metadata'], // ✅ Preserve metadata for image/voice
          });
        }

        for (var receivedMsg in receivedMessages) {
          // Filter displayable message types
          final msgType = receivedMsg['type'] ?? 'message';
          if (!DISPLAYABLE_MESSAGE_TYPES.contains(msgType)) {
            debugPrint('[DM_SCREEN] Skipping received system message type: $msgType');
            continue;
          }

          allMessages.add({
            'itemId': receivedMsg['itemId'],
            'sender': receivedMsg['sender'],
            'senderDisplayName': widget.recipientDisplayName,
            'text': receivedMsg['message'],
            'message': receivedMsg['message'],
            'payload': receivedMsg['message'], // Add payload field for file messages
            'time': receivedMsg['timestamp'] ?? receivedMsg['decryptedAt'],
            'isLocalSent': false,
            'type': msgType, // Preserve message type
            'metadata': receivedMsg['metadata'], // ✅ Preserve metadata for image/voice
          });
        }

        for (var msg in decryptedMessages) {
          final itemId = msg['itemId'];
          final exists = allMessages.any((m) => m['itemId'] == itemId);
          
          // Filter out system messages
          final msgType = msg['type'] ?? 'message';
          if (!DISPLAYABLE_MESSAGE_TYPES.contains(msgType)) {
            debugPrint('[DM_SCREEN] Skipping decrypted system message type: $msgType');
            continue;
          }
          
          if (!exists) {
            allMessages.add(msg);
          }
        }

        allMessages.sort((a, b) {
          final timeA = DateTime.tryParse(a['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['time'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });

        // Apply pagination: load last 20 messages, or next 20 older messages
        final totalMessages = allMessages.length;
        final List<Map<String, dynamic>> paginatedMessages;
        
        if (loadMore) {
          // Load 20 more older messages
          final newOffset = _messageOffset + 20;
          final startIndex = totalMessages - newOffset - 20;
          final endIndex = totalMessages - newOffset;
          
          if (startIndex < 0) {
            // No more messages to load
            paginatedMessages = allMessages.sublist(0, endIndex > 0 ? endIndex : 0);
            _hasMoreMessages = false;
          } else {
            paginatedMessages = allMessages.sublist(startIndex, endIndex);
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
          paginatedMessages = allMessages.sublist(startIndex);
          
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
      setState(() {
        _error = 'Error: $e';
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

    // Check Signal Protocol initialization
    if (_error != null && _error!.contains('Signal Protocol not initialized')) {
      if (mounted) {
        context.showErrorSnackBar(
          'Cannot send message: Signal Protocol not initialized. Please refresh the page.',
          duration: const Duration(seconds: 5),
        );
      }
      return;
    }

    // Check recipient PreKeys
    try {
      final hasPreKeys = await SignalService.instance.hasPreKeysForRecipient(
        widget.recipientUuid
      );
      
      if (hasPreKeys == false) {
        if (mounted) {
          context.showErrorSnackBar(
            'Cannot send message: ${widget.recipientDisplayName} has no PreKeys available.',
            duration: const Duration(seconds: 5),
          );
        }
        return;
      }
    } catch (e) {
      debugPrint('[DM] PreKey check failed: $e');
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

