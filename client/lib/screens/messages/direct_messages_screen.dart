// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../widgets/message_list.dart';
import '../../widgets/enhanced_message_input.dart';
import '../../widgets/user_avatar.dart';
import '../../services/socket_service_native.dart'
    if (dart.library.html) '../../services/socket_service.dart';
import '../../services/offline_message_queue.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/storage/sqlite_recent_conversations_store.dart';
import '../../services/starred_conversations_service.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../services/event_bus.dart';
import '../../services/active_conversation_service.dart';
import '../../models/file_message.dart';
import '../../extensions/snackbar_extensions.dart';
import '../../providers/unread_messages_provider.dart';
import '../../views/video_conference_prejoin_view.dart';
import '../../views/video_conference_view.dart';
import '../../widgets/animated_widgets.dart';
import '../../services/api_service.dart';
import '../../services/server_settings_service.dart';
import '../../services/device_identity_service.dart';
import '../../services/user_profile_service.dart';
import '../report_abuse_screen.dart';

/// Whitelist of message types that should be displayed in UI
const Set<String> displayableMessageTypes = {
  'message',
  'file',
  'image',
  'voice',
  'system:session_reset', // Show session recovery notifications
};

/// Screen for Direct Messages (1:1 Signal chats)
class DirectMessagesScreen extends StatefulWidget {
  final String recipientUuid;
  final String recipientDisplayName;
  final String?
  scrollToMessageId; // Optional: message to scroll to after loading

  const DirectMessagesScreen({
    super.key,
    required this.recipientUuid,
    required this.recipientDisplayName,
    this.scrollToMessageId,
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
  String? _highlightedMessageId; // For highlighting target message

  // Block status tracking
  bool _isBlocked = false;
  String? _blockDirection; // 'you_blocked' or 'they_blocked'

  void _scrollToBottom({required bool force}) {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || !mounted) return;
      if (!force) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        final currentScroll = _scrollController.position.pixels;
        const threshold = 200.0;
        if (maxScroll - currentScroll > threshold) {
          return;
        }
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  bool _isNearBottom() {
    if (!mounted || !_scrollController.hasClients) return false;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    const threshold = 200.0;
    return maxScroll - currentScroll <= threshold;
  }

  @override
  void initState() {
    super.initState();

    // Set this conversation as active to suppress notifications
    ActiveConversationService.instance.setActiveDirectMessage(
      widget.recipientUuid,
    );

    _initialize();
    _checkBlockStatus();
  }

  @override
  void dispose() {
    _scrollController.dispose();

    // Clear active conversation to re-enable notifications
    ActiveConversationService.instance.clearActiveConversation();

    // ✅ Unregister specific callbacks for this conversation
    // Note: SignalClient disposal is handled by ServerSettingsService
    // Callbacks will be cleaned up when the client is disposed

    super.dispose();
  }

  @override
  void didUpdateWidget(DirectMessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload messages when recipient changes
    if (oldWidget.recipientUuid != widget.recipientUuid) {
      debugPrint(
        '[DIRECT_MESSAGES] Recipient changed from ${oldWidget.recipientUuid} to ${widget.recipientUuid}',
      );

      // Update active conversation tracking
      ActiveConversationService.instance.setActiveDirectMessage(
        widget.recipientUuid,
      );

      _messages = []; // Clear old messages
      _messageOffset = 0;
      _hasMoreMessages = true;

      // Clear unread count for new conversation
      try {
        final unreadProvider = context.read<UnreadMessagesProvider>();
        unreadProvider.markDirectMessageAsRead(widget.recipientUuid);
        debugPrint(
          '[DM_SCREEN] ✓ Cleared unread count for new conversation ${widget.recipientUuid}',
        );
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error clearing unread count: $e');
      }

      _initialize(); // Reload
    }
  }

  /// Initialize the direct messages screen
  Future<void> _initialize() async {
    // Step 1: Load messages from database
    await _loadMessages();

    // Step 2: Setup live message listeners
    _setupMessageListeners(); // EventBus for new messages
    _setupReceiptListeners(); // Delivery & read receipts
    _setupReactionListener(); // Reaction updates

    // Step 3: Clear unread count for this conversation
    if (mounted) {
      try {
        final unreadProvider = context.read<UnreadMessagesProvider>();
        unreadProvider.markDirectMessageAsRead(widget.recipientUuid);
        debugPrint('[DM_SCREEN] Cleared unread count');
      } catch (e) {
        debugPrint('[DM_SCREEN] Error clearing unread count: $e');
      }
    }

    // Step 4: Mark notifications as read
    await _markDMNotificationsAsRead();

    // Step 5: Send read receipts for all loaded messages that we haven't acknowledged yet
    await _sendReadReceiptsForLoadedMessages();

    // Step 6: Scroll to bottom or target message
    SchedulerBinding.instance.addPostFrameCallback((_) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          if (widget.scrollToMessageId != null) {
            _scrollToMessage(widget.scrollToMessageId!);
          } else {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        }
      });
    });
  }

  /// Check if user is blocked
  Future<void> _checkBlockStatus() async {
    try {
      final response = await ApiService.instance.get(
        '/api/check-blocked/${widget.recipientUuid}',
      );
      if (response.statusCode == 200 && mounted) {
        setState(() {
          _isBlocked = response.data['blocked'] ?? false;
          _blockDirection = response.data['direction'];
        });
      }
    } catch (e) {
      debugPrint('[DM_SCREEN] Failed to check block status: $e');
    }
  }

  /// Block user
  Future<void> _blockUser() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Block User'),
        content: Text(
          'Block ${widget.recipientDisplayName}? You won\'t be able to message each other.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Block'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final response = await ApiService.instance.post(
        '/api/block',
        data: {'blockedUuid': widget.recipientUuid},
      );

      if (response.statusCode == 200) {
        await _checkBlockStatus();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${widget.recipientDisplayName} has been blocked'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to block user: $e')));
      }
    }
  }

  /// Unblock user
  Future<void> _unblockUser() async {
    try {
      final response = await ApiService.instance.post(
        '/api/unblock',
        data: {'blockedUuid': widget.recipientUuid},
      );

      if (response.statusCode == 200) {
        await _checkBlockStatus();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${widget.recipientDisplayName} has been unblocked',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to unblock user: $e')));
      }
    }
  }

  /// Delete conversation
  Future<void> _deleteConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text(
          'Delete all messages with ${widget.recipientDisplayName}? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.deleteConversation(widget.recipientUuid);

      // Delete from recent conversations
      final conversationsStore =
          await SqliteRecentConversationsStore.getInstance();
      await conversationsStore.removeConversation(widget.recipientUuid);

      // Remove from starred if it was starred
      await StarredConversationsService.instance.unstarConversation(
        widget.recipientUuid,
      );

      // Emit event to update UI
      EventBus.instance.emit(AppEvent.conversationDeleted, <String, dynamic>{
        'userId': widget.recipientUuid,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Conversation with ${widget.recipientDisplayName} has been deleted',
            ),
          ),
        );

        // Navigate to messages list
        context.go('/app/messages');
      }
    } catch (e) {
      debugPrint('[DM_SCREEN] Failed to delete conversation: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete conversation: $e')),
        );
      }
    }
  }

  /// Show report abuse dialog
  Future<void> _showReportAbuseDialog() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReportAbuseScreen(
          reportedUuid: widget.recipientUuid,
          reportedDisplayName: widget.recipientDisplayName,
        ),
      ),
    );

    // If report was submitted, refresh block status
    if (result == true) {
      await _checkBlockStatus();
    }
  }

  /// Mark all notifications for this DM conversation as read
  Future<void> _markDMNotificationsAsRead() async {
    try {
      final unreadProvider = Provider.of<UnreadMessagesProvider>(
        context,
        listen: false,
      );
      final dmMessageStore = await SqliteMessageStore.getInstance();

      // Get unread notifications for this user
      final unreadNotifications = await dmMessageStore
          .getUnreadNotificationsForUser(widget.recipientUuid);

      if (unreadNotifications.isNotEmpty) {
        // Mark as read in storage
        for (final notification in unreadNotifications) {
          final itemId = notification['itemId'] as String?;
          if (itemId != null) {
            await dmMessageStore.markNotificationAsRead(itemId);
          }
        }

        // Update unread counter
        final itemIds = unreadNotifications
            .map((n) => n['itemId'] as String?)
            .where((id) => id != null)
            .cast<String>()
            .toList();

        if (itemIds.isNotEmpty) {
          unreadProvider.markMultipleActivityNotificationsAsRead(itemIds);
          debugPrint(
            '[DM_SCREEN] Marked ${itemIds.length} notifications as read for user ${widget.recipientUuid}',
          );
        }
      }
    } catch (e) {
      debugPrint('[DM_SCREEN] Error marking notifications as read: $e');
    }
  }

  void _setupReceiptListeners() async {
    final signalClient = await ServerSettingsService.instance
        .getOrCreateSignalClientWithStoredCredentials();

    // Listen for delivery receipts
    signalClient.onDeliveryReceipt((itemId) async {
      if (!mounted) return;

      debugPrint('[DM_SCREEN] Delivery receipt received for itemId: $itemId');

      // Update status in SQLite
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.markAsDelivered(itemId);
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error updating status in SQLite: $e');
      }

      // Schedule setState for next frame to avoid layout conflicts
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            final msgIndex = _messages.indexWhere(
              (msg) => msg['itemId'] == itemId,
            );
            if (msgIndex != -1) {
              debugPrint(
                '[DM_SCREEN] ✓ Updated message status to delivered: $itemId',
              );
              _messages[msgIndex]['status'] = 'delivered';
            } else {
              debugPrint(
                '[DM_SCREEN] ⚠ Message not found in list for delivery receipt: $itemId',
              );
            }
          });
        }
      });
    });

    // Listen for read receipts
    signalClient.onReadReceipt((receiptInfo) async {
      final itemId = receiptInfo['itemId'] as String;
      final readByDeviceId = receiptInfo['readByDeviceId'] as int?;
      final readByUserId = receiptInfo['readByUserId'] as String?;

      if (!mounted) return;

      debugPrint(
        '[DM_SCREEN] Read receipt received for itemId: $itemId from user: $readByUserId, device: $readByDeviceId',
      );

      // Update status in SQLite
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.markAsRead(itemId);
      } catch (e) {
        debugPrint('[DM_SCREEN] ⚠️ Error updating status in SQLite: $e');
      }

      // Schedule setState for next frame to avoid layout conflicts
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            final msgIndex = _messages.indexWhere(
              (msg) => msg['itemId'] == itemId,
            );
            if (msgIndex != -1) {
              debugPrint(
                '[DM_SCREEN] ✓ Updated message status to read: $itemId',
              );
              _messages[msgIndex]['status'] = 'read';

              // Delete message from server after read confirmation
              signalClient.deleteItemFromServer(itemId);
            } else {
              debugPrint(
                '[DM_SCREEN] ⚠ Message not found in list for read receipt: $itemId',
              );
            }
          });
        }
      });
    });
  }

  /// Listen for reaction updates from other users
  void _setupReactionListener() {
    EventBus.instance.on(AppEvent.reactionUpdated).listen((data) {
      if (!mounted) return;

      final dataMap = data as Map<String, dynamic>?;
      final messageId = dataMap?['messageId'] as String?;
      final reactions = dataMap?['reactions'] as Map<String, dynamic>?;

      debugPrint('[DM_SCREEN] 🎭 Reaction update event received:');
      debugPrint('[DM_SCREEN]   messageId: $messageId');
      debugPrint('[DM_SCREEN]   reactions: $reactions');

      // Update if the message is in this conversation
      if (messageId != null && reactions != null) {
        setState(() {
          final msgIndex = _messages.indexWhere(
            (m) => m['itemId'] == messageId,
          );
          debugPrint('[DM_SCREEN]   Found message at index: $msgIndex');
          if (msgIndex != -1) {
            // Update reactions in the message data
            final reactionsJson = jsonEncode(reactions);
            _messages[msgIndex]['reactions'] = reactionsJson;
            debugPrint(
              '[DM_SCREEN] ✓ Updated reactions for message $messageId: $reactionsJson',
            );
            debugPrint(
              '[DM_SCREEN]   Message now has reactions: ${_messages[msgIndex]['reactions']}',
            );
          } else {
            debugPrint(
              '[DM_SCREEN] ⚠️ Message $messageId not found in _messages list',
            );
          }
        });
      }
    });

    // Listen for conversation deletion
    EventBus.instance.on(AppEvent.conversationDeleted).listen((data) {
      if (!mounted) return;

      final dataMap = data as Map<String, dynamic>?;
      final userId = dataMap?['userId'] as String?;

      // If this conversation's messages were deleted, clear the UI
      if (userId == widget.recipientUuid) {
        debugPrint(
          '[DM_SCREEN] Messages deleted for this conversation, clearing UI',
        );
        setState(() {
          _messages.clear();
          _messageOffset = 0;
          _hasMoreMessages = false;
        });
      }
    });
  }

  /// Setup EventBus listener for new messages in this conversation
  void _setupMessageListeners() {
    EventBus.instance.on(AppEvent.newMessage).listen((data) {
      if (!mounted) return;

      final dataMap = data as Map<String, dynamic>?;
      if (dataMap == null) return;

      final senderId = dataMap['senderId'] as String?;
      final isOwnMessage = dataMap['isOwnMessage'] as bool? ?? false;

      // Only handle messages for this conversation
      // For own messages (multi-device sync), sender is us, but originalRecipient is conversation partner
      final isThisConversation = isOwnMessage
          ? (dataMap['originalRecipient'] == widget.recipientUuid)
          : (senderId == widget.recipientUuid);

      if (!isThisConversation) return;

      debugPrint(
        '[DM_SCREEN] New message in this conversation: ${dataMap['itemId']}',
      );

      _handleNewMessage(dataMap);
    });

    debugPrint('[DM_SCREEN] EventBus message listener registered');
  }

  /// Handle incoming message from EventBus
  void _handleNewMessage(Map<String, dynamic> item) {
    if (!mounted) return;

    final itemId = item['itemId'] as String?;
    if (itemId == null) return;

    final itemType = item['type'] as String? ?? 'message';
    if (!displayableMessageTypes.contains(itemType)) {
      debugPrint('[DM_SCREEN] Skipping non-displayable type: $itemType');
      return;
    }

    // Check if message already exists
    final exists = _messages.any((msg) => msg['itemId'] == itemId);
    if (exists) {
      debugPrint('[DM_SCREEN] Message already in list (duplicate)');
      return;
    }

    final isOwnMessage = item['isOwnMessage'] as bool? ?? false;
    final displayName = item['displayName'] as String? ?? 'Unknown';

    final newMessage = {
      'itemId': itemId,
      'sender': item['sender'] ?? item['senderId'],
      'senderDeviceId': item['senderDeviceId'],
      'senderDisplayName': isOwnMessage ? 'You' : displayName,
      'text': item['message'],
      'message': item['message'],
      'payload': item['message'],
      'time': item['timestamp'] ?? DateTime.now().toIso8601String(),
      'isLocalSent': isOwnMessage,
      'status': isOwnMessage ? (item['status'] ?? 'sent') : 'received',
      'type': itemType,
      'metadata': item['metadata'],
      'reactions': item['reactions'] ?? '{}',
      if (item['originalRecipient'] != null)
        'originalRecipient': item['originalRecipient'],
    };

    final shouldScroll = _isNearBottom();

    // Add message to UI
    setState(() {
      _messages.add(newMessage);
    });

    debugPrint('[DM_SCREEN] ✓ Message added to UI');

    // Clear unread badge immediately while this conversation is open
    if (!isOwnMessage && mounted) {
      try {
        final provider = Provider.of<UnreadMessagesProvider>(
          context,
          listen: false,
        );
        provider.markDirectMessageAsRead(widget.recipientUuid);
      } catch (e) {
        debugPrint('[DM_SCREEN] Error clearing unread badge: $e');
      }
    }

    _scrollToBottom(force: isOwnMessage || shouldScroll);

    // Send read receipt if this is a received message (not our own)
    if (!isOwnMessage) {
      final senderId = item['sender'] as String? ?? item['senderId'] as String?;
      final senderDeviceId = item['senderDeviceId'];

      if (senderId != null && senderDeviceId != null) {
        final deviceId = senderDeviceId is int
            ? senderDeviceId
            : int.tryParse(senderDeviceId.toString());
        if (deviceId != null) {
          _sendReadReceipt(
            itemId,
            senderId,
            deviceId,
            originalRecipient: item['originalRecipient'],
          );
        }
      }
    }
  }

  Future<void> _sendReadReceipt(
    String itemId,
    String sender,
    int senderDeviceId, {
    String? originalRecipient, // NEW: For multi-device support
  }) async {
    try {
      // Check if we already sent a read receipt for this message
      final messageStore = await SqliteMessageStore.getInstance();
      final alreadySent = await messageStore.hasReadReceiptBeenSent(itemId);

      if (alreadySent) {
        debugPrint(
          '[DM_SCREEN] Read receipt already sent for itemId: $itemId, skipping',
        );
        return;
      }

      final myDeviceId = DeviceIdentityService.instance.deviceId;
      final myUserId = UserProfileService.instance.currentUserUuid;

      // 🔑 MULTI-DEVICE FIX: Determine the correct recipient for the read receipt
      // If sender == myUserId, this is a multi-device sync message
      // In that case, send read receipt to originalRecipient (the actual conversation partner)
      // Otherwise, send to sender (normal received message)
      String readReceiptRecipient;
      if (sender == myUserId && originalRecipient != null) {
        // Multi-device sync: Send read receipt to the original conversation partner
        readReceiptRecipient = originalRecipient;
        debugPrint(
          '[DM_SCREEN] Multi-device message detected: sending read receipt to originalRecipient: $originalRecipient instead of sender: $sender',
        );
      } else {
        // Normal message: Send read receipt to sender
        readReceiptRecipient = sender;
        debugPrint(
          '[DM_SCREEN] Normal message: sending read receipt to sender: $sender',
        );
      }

      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();
      await signalClient.messagingService.send1to1Message(
        recipientUserId: readReceiptRecipient,
        type: "read_receipt",
        payload: jsonEncode({'itemId': itemId, 'readByDeviceId': myDeviceId}),
      );

      // Mark that we sent the read receipt
      await messageStore.markReadReceiptSent(itemId);
      debugPrint(
        '[DM_SCREEN] ✓ Read receipt sent to $readReceiptRecipient and marked for itemId: $itemId',
      );

      // Mark this conversation as read in the unread provider
      try {
        if (!mounted) return;
        final provider = Provider.of<UnreadMessagesProvider>(
          context,
          listen: false,
        );
        provider.markDirectMessageAsRead(sender);
      } catch (e) {
        debugPrint('[DM_SCREEN] Error updating unread badge: $e');
      }
    } catch (e) {
      debugPrint('[DM_SCREEN] Error sending read receipt: $e');
    }
  }

  /// Send read receipts for all loaded messages that haven't been marked as read
  Future<void> _sendReadReceiptsForLoadedMessages() async {
    try {
      debugPrint(
        '[DM_SCREEN] 🔍 Checking loaded messages for unsent read receipts...',
      );

      // Filter received messages (not sent by me) from this conversation
      final receivedMessages = _messages
          .where(
            (msg) =>
                msg['isLocalSent'] != true &&
                msg['sender'] == widget.recipientUuid,
          )
          .toList();

      debugPrint(
        '[DM_SCREEN] Found ${receivedMessages.length} received messages to check',
      );

      int sentCount = 0;
      for (final msg in receivedMessages) {
        final itemId = msg['itemId'] as String?;
        final sender = msg['sender'] as String?;
        final senderDeviceId = msg['senderDeviceId'];

        if (itemId == null || sender == null || senderDeviceId == null) {
          continue;
        }

        // Check if read receipt was already sent
        final messageStore = await SqliteMessageStore.getInstance();
        final alreadySent = await messageStore.hasReadReceiptBeenSent(itemId);

        if (!alreadySent) {
          // Send read receipt
          final deviceId = senderDeviceId is int
              ? senderDeviceId
              : int.parse(senderDeviceId.toString());
          final originalRecipient = msg['originalRecipient'] as String?;

          await _sendReadReceipt(
            itemId,
            sender,
            deviceId,
            originalRecipient: originalRecipient,
          );
          sentCount++;
        }
      }

      if (sentCount > 0) {
        debugPrint(
          '[DM_SCREEN] ✓ Sent $sentCount read receipts for previously loaded messages',
        );
      } else {
        debugPrint('[DM_SCREEN] ✓ All loaded messages already marked as read');
      }
    } catch (e) {
      debugPrint(
        '[DM_SCREEN] Error sending read receipts for loaded messages: $e',
      );
    }
  }

  /// Scroll to a specific message and highlight it
  Future<void> _scrollToMessage(String messageId) async {
    // Wait for widget tree to build
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted || !_scrollController.hasClients) return;

    // Find message index
    final messageIndex = _messages.indexWhere((m) => m['itemId'] == messageId);

    if (messageIndex == -1) {
      debugPrint('[DM_SCREEN] Message $messageId not found in list');
      return;
    }

    debugPrint('[DM_SCREEN] Scrolling to message at index $messageIndex');

    // Calculate approximate scroll position (assuming ~80px per message)
    final approximatePosition = messageIndex * 80.0;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final targetPosition = approximatePosition.clamp(0.0, maxScroll);

    // Scroll to position
    await _scrollController.animateTo(
      targetPosition,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );

    // Highlight the message
    setState(() {
      _highlightedMessageId = messageId;
    });

    // Remove highlight after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _highlightedMessageId = null;
        });
      }
    });
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
        types: displayableMessageTypes.toList(),
      );

      debugPrint(
        '[DM_SCREEN] Loaded ${messages.length} messages from SQLite (offset: ${loadMore ? _messageOffset : 0})',
      );

      // Transform to UI format
      final currentUserId = UserProfileService.instance.currentUserUuid;
      final uiMessages = messages.map((msg) {
        final isLocalSent = msg['direction'] == 'sent';
        return {
          'itemId': msg['item_id'],
          'sender': isLocalSent ? currentUserId : msg['sender'],
          'senderDeviceId': msg['sender_device_id'],
          'senderDisplayName': isLocalSent
              ? 'You'
              : widget.recipientDisplayName,
          'text': msg['message'],
          'message': msg['message'],
          'payload': msg['message'],
          'time': msg['timestamp'],
          'isLocalSent': isLocalSent,
          'status':
              msg['status'], // Include status for both sent and received messages
          'type': msg['type'],
          'metadata': msg['metadata'],
          'reactions': msg['reactions'] ?? '{}', // Include reactions
        };
      }).toList();

      // Reverse messages since DB returns DESC (newest first), but UI needs ASC (oldest first)
      final reversedMessages = uiMessages.reversed.toList();

      // Schedule setState for next frame to avoid layout conflicts during scroll
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
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
        }
      });

      debugPrint('[DM_SCREEN] ✓ Messages loaded successfully');
    } catch (e, stackTrace) {
      debugPrint('[DM_SCREEN] ❌ Error loading messages: $e');
      debugPrint('[DM_SCREEN] Stack trace: $stackTrace');

      // Schedule setState for next frame to avoid layout conflicts
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _error = 'Error loading messages: $e';
            _loading = false;
            _loadingMore = false;
          });
        }
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

    // Check if user is blocked
    if (_isBlocked) {
      if (mounted) {
        context.showErrorSnackBar(
          _blockDirection == 'you_blocked'
              ? 'You have blocked this user. Unblock to send messages.'
              : 'This user has blocked you. You cannot send messages.',
          duration: const Duration(seconds: 3),
        );
      }
      return;
    }

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
    if (messageType == 'message' ||
        messageType == 'image' ||
        messageType == 'voice') {
      setState(() {
        final currentUserId = UserProfileService.instance.currentUserUuid;
        final currentDeviceId = DeviceIdentityService.instance.deviceId;
        _messages.add({
          'itemId': itemId,
          'sender': currentUserId,
          'senderDeviceId': currentDeviceId,
          'senderDisplayName': 'You',
          'text': messageType == 'message'
              ? content
              : '[${messageType.toUpperCase()}]',
          'message': content,
          'payload': content,
          'time': timestamp,
          'isLocalSent': true,
          'status': 'sending',
          'type': messageType,
          'metadata': metadata,
        });
      });

      _scrollToBottom(force: true);
    }

    // Check connection
    final socketService = SocketService.instance;
    final socket = socketService.socket;
    final socketConnected = socketService.isConnected;
    debugPrint(
      '[DM_SCREEN] Socket check: service=$socketService, socket=$socket, socket?.connected=${socket?.connected}, isConnected=$socketConnected',
    );

    if (!socketConnected) {
      debugPrint('[DM_SCREEN] Not connected - queuing message');
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
      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();

      // Send main message
      await signalClient.messagingService.send1to1Message(
        recipientUserId: widget.recipientUuid,
        type: messageType,
        payload: content,
        itemId: itemId,
      );

      // Send mention notifications if message has mentions
      if (metadata != null &&
          metadata['mentions'] != null &&
          messageType == 'message') {
        final mentions = metadata['mentions'] as List;
        for (final mention in mentions) {
          try {
            final mentionItemId = const Uuid().v4();
            final currentUserId = UserProfileService.instance.currentUserUuid;
            final mentionPayload = {
              'messageId': itemId,
              'mentionedUserId': mention['userId'],
              'sender': currentUserId,
              'content': content.length > 50
                  ? '${content.substring(0, 50)}...'
                  : content,
            };

            await signalClient.messagingService.send1to1Message(
              itemId: mentionItemId,
              recipientUserId: mention['userId'] as String,
              type: 'mention',
              payload: jsonEncode(mentionPayload),
            );

            debugPrint(
              '[DM_SCREEN] Sent mention notification for ${mention['userId']}',
            );
          } catch (e) {
            debugPrint('[DM_SCREEN] Error sending mention notification: $e');
          }
        }
      }

      // Update status
      setState(() {
        final msgIndex = _messages.indexWhere((msg) => msg['itemId'] == itemId);
        if (msgIndex != -1) {
          _messages[msgIndex]['status'] = 'sent';
          debugPrint('[DM_SCREEN] ✓ $messageType message sent: $itemId');
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
          'Failed to send $messageType: ${e.toString()}',
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
        actions: [
          // Phone Call Button - Start instant 1:1 call
          IconButton(
            icon: const Icon(Icons.phone),
            tooltip: 'Start Call',
            onPressed: () async {
              // Check if user is blocked
              if (_isBlocked) {
                if (mounted) {
                  context.showErrorSnackBar(
                    _blockDirection == 'you_blocked'
                        ? 'You have blocked this user. Unblock to start a call.'
                        : 'This user has blocked you. You cannot start a call.',
                    duration: const Duration(seconds: 3),
                  );
                }
                return;
              }

              // For 1:1 calls, use a placeholder ID - actual call ID created in PreJoin
              // The channelId will be replaced with the real meeting ID after creation
              final placeholderCallId = 'call_pending_${widget.recipientUuid}';

              // Navigate to PreJoin for instant 1:1 call
              final result = await Navigator.push(
                context,
                SlidePageRoute(
                  builder: (context) => VideoConferencePreJoinView(
                    channelId: placeholderCallId, // Will be replaced in PreJoin
                    channelName: '1:1 Call with ${widget.recipientDisplayName}',
                    isInstantCall: true,
                    sourceUserId: widget.recipientUuid,
                    isInitiator: true,
                  ),
                ),
              );

              if (!mounted) return;

              // If user completed PreJoin, navigate to video conference
              if (result != null &&
                  result is Map &&
                  result['hasE2EEKey'] == true) {
                Navigator.push(
                  context,
                  SlidePageRoute(
                    builder: (context) => VideoConferenceView(
                      channelId: result['channelId'],
                      channelName: result['channelName'],
                      selectedCamera: result['selectedCamera'],
                      selectedMicrophone: result['selectedMicrophone'],
                      isInstantCall: result['isInstantCall'] == true,
                      isInitiator: result['isInitiator'] == true,
                      sourceChannelId: result['sourceChannelId'] as String?,
                      sourceUserId: result['sourceUserId'] as String?,
                    ),
                  ),
                );
              }
            },
          ),
          // Three-dot menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'report') {
                _showReportAbuseDialog();
              } else if (value == 'block') {
                _blockUser();
              } else if (value == 'unblock') {
                _unblockUser();
              } else if (value == 'delete') {
                _deleteConversation();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(Icons.report, color: Colors.red, size: 20),
                    SizedBox(width: 12),
                    Text('Report Abuse'),
                  ],
                ),
              ),
              if (!_isBlocked || _blockDirection == 'you_blocked')
                PopupMenuItem(
                  value: _isBlocked ? 'unblock' : 'block',
                  child: Row(
                    children: [
                      Icon(
                        _isBlocked ? Icons.check_circle : Icons.block,
                        color: _isBlocked ? Colors.green : Colors.orange,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(_isBlocked ? 'Unblock User' : 'Block User'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, color: Colors.red, size: 20),
                    SizedBox(width: 12),
                    Text('Delete Conversation'),
                  ],
                ),
              ),
            ],
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
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_hasMoreMessages)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: _loadingMore
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : ActionChip(
                                    avatar: Icon(
                                      Icons.arrow_upward,
                                      size: 18,
                                      color: colorScheme.onSurface,
                                    ),
                                    label: Text(
                                      'Load older messages',
                                      style: TextStyle(
                                        color: colorScheme.onSurface,
                                      ),
                                    ),
                                    onPressed: () =>
                                        _loadMessages(loadMore: true),
                                    backgroundColor:
                                        colorScheme.surfaceContainerHighest,
                                  ),
                          ),
                        ),
                      Expanded(
                        child: MessageList(
                          key: ValueKey(_messages.length),
                          messages: _messages,
                          onFileDownload: _handleFileDownload,
                          scrollController: _scrollController,
                          onReactionAdd: _isBlocked ? null : _addReaction,
                          onReactionRemove: _removeReaction,
                          currentUserId:
                              UserProfileService.instance.currentUserUuid ?? '',
                          highlightedMessageId: _highlightedMessageId,
                        ),
                      ),
                    ],
                  ),
          ),
          // Show block warning or message input
          _isBlocked
              ? _buildBlockedInputWarning()
              : EnhancedMessageInput(
                  onSendMessage: (message, {type, metadata}) {
                    _sendMessageEnhanced(
                      message,
                      type: type,
                      metadata: metadata,
                    );
                  },
                  onFileShare: (itemId) {
                    // Handle P2P file share completion
                    debugPrint('[DM_SCREEN] File shared: $itemId');
                  },
                  availableUsers: [
                    {
                      'userId': widget.recipientUuid,
                      'displayName': widget.recipientDisplayName,
                      'atName': widget.recipientDisplayName
                          .toLowerCase()
                          .replaceAll(' ', ''),
                    },
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
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
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

  /// Build blocked input warning
  Widget _buildBlockedInputWarning() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withOpacity(0.3),
        border: Border(
          top: BorderSide(color: colorScheme.error.withOpacity(0.3), width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.block, color: colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _blockDirection == 'you_blocked'
                  ? 'You have blocked this user. Unblock to send messages.'
                  : 'This user has blocked you. You cannot send messages.',
              style: TextStyle(color: colorScheme.error),
            ),
          ),
          if (_blockDirection == 'you_blocked')
            TextButton(onPressed: _unblockUser, child: const Text('Unblock')),
        ],
      ),
    );
  }

  // =========================================================================
  // EMOJI REACTIONS
  // =========================================================================

  /// Add emoji reaction to a message
  Future<void> _addReaction(String messageId, String emoji) async {
    // Check if user is blocked
    if (_isBlocked) {
      if (mounted) {
        context.showErrorSnackBar(
          _blockDirection == 'you_blocked'
              ? 'You have blocked this user. Unblock to add reactions.'
              : 'This user has blocked you. You cannot add reactions.',
          duration: const Duration(seconds: 3),
        );
      }
      return;
    }

    try {
      final itemId = const Uuid().v4();
      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();
      final currentUserId = UserProfileService.instance.currentUserUuid;

      if (currentUserId == null) {
        debugPrint('[DIRECT_MSG] ✗ Cannot add reaction: no current user ID');
        return;
      }

      // Create emote message payload (will be encrypted)
      final emotePayload = {
        'messageId': messageId,
        'emoji': emoji,
        'action': 'add',
        'sender': currentUserId,
      };

      // Encode as JSON (will be encrypted and decrypted by recipient)
      final payloadJson = jsonEncode(emotePayload);

      // Send via Signal Protocol
      await signalClient.messagingService.send1to1Message(
        itemId: itemId,
        recipientUserId: widget.recipientUuid,
        payload: payloadJson,
        type: 'emote',
      );

      // Update local database immediately
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.addReaction(messageId, emoji, currentUserId);

      // Update UI
      final reactions = await messageStore.getReactions(messageId);
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == messageId);
        if (msgIndex != -1) {
          _messages[msgIndex]['reactions'] = jsonEncode(reactions);
        }
      });

      debugPrint(
        '[DIRECT_MSG] ✓ Sent emote reaction: $emoji on message $messageId',
      );
    } catch (e) {
      debugPrint('[DIRECT_MSG] ✗ Error sending reaction: $e');
      if (mounted) {
        context.showCustomSnackBar(
          'Failed to add reaction: $e',
          backgroundColor: Colors.red,
        );
      }
    }
  }

  /// Remove emoji reaction from a message
  Future<void> _removeReaction(String messageId, String emoji) async {
    try {
      final itemId = const Uuid().v4();
      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();
      final currentUserId = UserProfileService.instance.currentUserUuid;

      if (currentUserId == null) {
        debugPrint('[DIRECT_MSG] ✗ Cannot remove reaction: no current user ID');
        return;
      }

      // Create emote message payload (will be encrypted)
      final emotePayload = {
        'messageId': messageId,
        'emoji': emoji,
        'action': 'remove',
        'sender': currentUserId,
      };

      // Encode as JSON (will be encrypted and decrypted by recipient)
      final payloadJson = jsonEncode(emotePayload);

      // Send via Signal Protocol
      await signalClient.messagingService.send1to1Message(
        itemId: itemId,
        recipientUserId: widget.recipientUuid,
        payload: payloadJson,
        type: 'emote',
      );

      // Update local database immediately
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.removeReaction(messageId, emoji, currentUserId);

      // Update UI
      final reactions = await messageStore.getReactions(messageId);
      setState(() {
        final msgIndex = _messages.indexWhere((m) => m['itemId'] == messageId);
        if (msgIndex != -1) {
          _messages[msgIndex]['reactions'] = jsonEncode(reactions);
        }
      });

      debugPrint(
        '[DIRECT_MSG] ✓ Removed emote reaction: $emoji from message $messageId',
      );
    } catch (e) {
      debugPrint('[DIRECT_MSG] ✗ Error removing reaction: $e');
    }
  }

  /// Handle file download request from FileMessageWidget
  Future<void> _handleFileDownload(dynamic fileMessageDynamic) async {
    try {
      // Cast to FileMessage
      final FileMessage fileMessage = fileMessageDynamic as FileMessage;

      debugPrint(
        '[DIRECT_MSG] ================================================',
      );
      debugPrint('[DIRECT_MSG] File download requested');
      debugPrint('[DIRECT_MSG] File ID: ${fileMessage.fileId}');
      debugPrint('[DIRECT_MSG] File Name: ${fileMessage.fileName}');
      debugPrint('[DIRECT_MSG] File Size: ${fileMessage.fileSizeFormatted}');
      debugPrint(
        '[DIRECT_MSG] ================================================',
      );

      // Show snackbar
      if (mounted) {
        context.showSuccessSnackBar(
          'Starting download: ${fileMessage.fileName}...',
          duration: const Duration(seconds: 2),
        );
      }

      // Get P2P Coordinator
      final p2pCoordinator = Provider.of<P2PCoordinator?>(
        context,
        listen: false,
      );
      if (p2pCoordinator == null) {
        throw Exception('P2P Coordinator not initialized');
      }

      // Get Socket File Client
      final socketService = SocketService.instance;
      if (socketService.socket == null) {
        throw Exception('Socket not connected');
      }
      final socketClient = SocketFileClient();

      // 1. Fetch file info and seeder chunks from server
      debugPrint('[DIRECT_MSG] Fetching file info and seeders...');
      // Fetch file info for validation and to get sharedWith list
      final fileInfo = await socketClient.getFileInfo(fileMessage.fileId);
      final seederChunks = await socketClient.getAvailableChunks(
        fileMessage.fileId,
      );

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
        sharedWith: (fileInfo['sharedWith'] as List?)
            ?.cast<String>(), // ✅ NEW: Pass sharedWith from fileInfo
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
