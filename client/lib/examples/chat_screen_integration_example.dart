import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/message_listener_service.dart';
import '../providers/notification_provider.dart';

/// Example: How to integrate global message listener in a chat screen
class ExampleChatScreenIntegration extends StatefulWidget {
  final String channelId; // or userId for 1:1 chats
  final bool isGroupChat;

  const ExampleChatScreenIntegration({
    Key? key,
    required this.channelId,
    this.isGroupChat = true,
  }) : super(key: key);

  @override
  State<ExampleChatScreenIntegration> createState() => _ExampleChatScreenIntegrationState();
}

class _ExampleChatScreenIntegrationState extends State<ExampleChatScreenIntegration> {
  List<Map<String, dynamic>> _messages = [];
  
  @override
  void initState() {
    super.initState();
    _loadMessages();
    _markAsRead();
    _listenToNewMessages(); // Optional: for real-time updates
  }

  @override
  void dispose() {
    // Cleanup optional listener
    MessageListenerService.instance.unregisterNotificationCallback(_onNewMessage);
    super.dispose();
  }

  /// Load messages from local storage
  Future<void> _loadMessages() async {
    // Load from decryptedGroupItemsStore or decryptedMessagesStore
    // Implementation depends on your storage layer
  }

  /// Mark this chat as read
  void _markAsRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<NotificationProvider>(context, listen: false)
          .markAsRead(widget.channelId);
    });
  }

  /// Optional: Listen to new messages for real-time updates
  void _listenToNewMessages() {
    MessageListenerService.instance.registerNotificationCallback(_onNewMessage);
  }

  /// Optional: Handle new message notification
  void _onNewMessage(MessageNotification notification) {
    // Only update if this is our chat
    final isOurChat = widget.isGroupChat
        ? notification.type == MessageType.group && notification.channelId == widget.channelId
        : notification.type == MessageType.direct && notification.senderId == widget.channelId;

    if (!isOurChat) return;

    // Update UI
    setState(() {
      if (!notification.encrypted && notification.message != null) {
        // Add decrypted message to list
        _messages.add({
          'itemId': notification.itemId,
          'sender': notification.senderId,
          'message': notification.message,
          'timestamp': notification.timestamp,
          'isOwn': false,
        });
      } else {
        // Reload all messages (in case decryption failed)
        _loadMessages();
      }
    });

    // Mark as read immediately (since screen is open)
    Provider.of<NotificationProvider>(context, listen: false)
        .markAsRead(widget.channelId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Chat'),
      ),
      body: ListView.builder(
        itemCount: _messages.length,
        itemBuilder: (context, index) {
          final message = _messages[index];
          return ListTile(
            title: Text(message['message']),
            subtitle: Text(message['timestamp']),
          );
        },
      ),
    );
  }
}

