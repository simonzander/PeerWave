import 'package:flutter/material.dart';
import 'dart:async';
import '../services/socket_service.dart' if (dart.library.io) '../services/socket_service_native.dart';
import '../services/user_profile_service.dart';

/// Activities Context Panel - Notification List
/// 
/// Shows real-time notifications from Signal Protocol messages
/// Similar to Facebook notifications - displays activity feed
class ActivitiesContextPanel extends StatefulWidget {
  final String host;
  final Function(String type, Map<String, dynamic> data)? onNotificationTap;
  
  const ActivitiesContextPanel({
    super.key,
    required this.host,
    this.onNotificationTap,
  });

  @override
  State<ActivitiesContextPanel> createState() => _ActivitiesContextPanelState();
}

class _ActivitiesContextPanelState extends State<ActivitiesContextPanel> {
  final List<NotificationItem> _notifications = [];
  StreamSubscription? _socketSubscription;
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _initializeNotifications();
    _listenToSocketEvents();
  }
  
  @override
  void dispose() {
    _socketSubscription?.cancel();
    super.dispose();
  }
  
  Future<void> _initializeNotifications() async {
    // Load initial notifications from storage or API
    // For now, just set loading to false
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  void _listenToSocketEvents() {
    final socketService = SocketService();
    if (socketService.socket == null) {
      debugPrint('[ACTIVITIES_PANEL] Socket not connected');
      return;
    }
    
    // Listen to various Signal Protocol message types
    final socket = socketService.socket!;
    
    // New message notification
    socket.on('signal:message', (data) {
      _handleNotification(
        type: NotificationType.message,
        title: 'New message',
        message: data['preview'] ?? 'You have a new message',
        sender: data['sender'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
    
    // New group message
    socket.on('signal:groupMessage', (data) {
      _handleNotification(
        type: NotificationType.groupMessage,
        title: 'New group message',
        message: data['preview'] ?? 'Message in ${data['channelName'] ?? 'group'}',
        sender: data['sender'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
    
    // File share notification
    socket.on('signal:fileShared', (data) {
      _handleNotification(
        type: NotificationType.fileShared,
        title: 'File shared',
        message: '${data['fileName'] ?? 'A file'} was shared with you',
        sender: data['sender'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
    
    // Channel invitation
    socket.on('signal:channelInvite', (data) {
      _handleNotification(
        type: NotificationType.channelInvite,
        title: 'Channel invitation',
        message: 'You were invited to ${data['channelName'] ?? 'a channel'}',
        sender: data['inviter'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
    
    // Call notification
    socket.on('signal:call', (data) {
      _handleNotification(
        type: NotificationType.call,
        title: 'Incoming call',
        message: 'Video call',
        sender: data['caller'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
    
    // Mention notification
    socket.on('signal:mention', (data) {
      _handleNotification(
        type: NotificationType.mention,
        title: 'You were mentioned',
        message: data['preview'] ?? 'Someone mentioned you',
        sender: data['sender'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
    
    // Reaction notification
    socket.on('signal:reaction', (data) {
      _handleNotification(
        type: NotificationType.reaction,
        title: 'New reaction',
        message: '${data['reaction'] ?? '👍'} to your message',
        sender: data['sender'],
        timestamp: DateTime.now(),
        data: data,
      );
    });
  }
  
  void _handleNotification({
    required NotificationType type,
    required String title,
    required String message,
    String? sender,
    required DateTime timestamp,
    required dynamic data,
  }) {
    if (!mounted) return;
    
    final notification = NotificationItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: type,
      title: title,
      message: message,
      senderUuid: sender,
      timestamp: timestamp,
      isRead: false,
      data: data,
    );
    
    setState(() {
      _notifications.insert(0, notification);
      // Keep only last 100 notifications
      if (_notifications.length > 100) {
        _notifications.removeRange(100, _notifications.length);
      }
    });
  }
  
  void _markAsRead(String id) {
    setState(() {
      final index = _notifications.indexWhere((n) => n.id == id);
      if (index != -1) {
        _notifications[index] = _notifications[index].copyWith(isRead: true);
      }
    });
  }
  
  void _clearAll() {
    setState(() {
      _notifications.clear();
    });
  }
  
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.notifications,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Notifications',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_notifications.isNotEmpty)
                TextButton(
                  onPressed: _clearAll,
                  child: const Text('Clear all'),
                ),
            ],
          ),
        ),
        
        // Notifications list
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _notifications.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      itemCount: _notifications.length,
                      itemBuilder: (context, index) {
                        return _buildNotificationItem(_notifications[index]);
                      },
                    ),
        ),
      ],
    );
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.notifications_none,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'No notifications',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'You\'re all caught up!',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildNotificationItem(NotificationItem notification) {
    final colorScheme = Theme.of(context).colorScheme;
    final userProfileService = UserProfileService.instance;
    
    // Load sender profile if not cached
    if (notification.senderUuid != null && 
        !userProfileService.isProfileCached(notification.senderUuid!)) {
      userProfileService.loadProfiles([notification.senderUuid!]);
    }
    
    final senderName = notification.senderUuid != null
        ? userProfileService.getDisplayName(notification.senderUuid!)
        : null;
    final senderPicture = notification.senderUuid != null
        ? userProfileService.getPicture(notification.senderUuid!)
        : null;
    
    return InkWell(
      onTap: () {
        _markAsRead(notification.id);
        if (widget.onNotificationTap != null) {
          widget.onNotificationTap!(
            notification.type.name,
            notification.data,
          );
        }
      },
      child: Container(
        color: notification.isRead ? null : colorScheme.primaryContainer.withValues(alpha: 0.1),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar or icon
            _buildNotificationIcon(notification, senderPicture),
            const SizedBox(width: 12),
            
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title with sender name
                  Row(
                    children: [
                      if (senderName != null) ...[
                        Text(
                          senderName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          notification.title,
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  
                  // Message
                  Text(
                    notification.message,
                    style: const TextStyle(fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  
                  // Timestamp
                  Text(
                    _formatTimestamp(notification.timestamp),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            
            // Unread indicator
            if (!notification.isRead)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(left: 8, top: 4),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildNotificationIcon(NotificationItem notification, String? senderPicture) {
    final colorScheme = Theme.of(context).colorScheme;
    
    // Show sender picture if available
    if (senderPicture != null && senderPicture.isNotEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundImage: NetworkImage('${widget.host}$senderPicture'),
        onBackgroundImageError: (_, __) {},
      );
    }
    
    // Otherwise show icon based on notification type
    IconData icon;
    Color backgroundColor;
    Color iconColor;
    
    switch (notification.type) {
      case NotificationType.message:
        icon = Icons.message;
        backgroundColor = colorScheme.primaryContainer;
        iconColor = colorScheme.onPrimaryContainer;
        break;
      case NotificationType.groupMessage:
        icon = Icons.group;
        backgroundColor = colorScheme.secondaryContainer;
        iconColor = colorScheme.onSecondaryContainer;
        break;
      case NotificationType.fileShared:
        icon = Icons.folder;
        backgroundColor = colorScheme.tertiaryContainer;
        iconColor = colorScheme.onTertiaryContainer;
        break;
      case NotificationType.channelInvite:
        icon = Icons.group_add;
        backgroundColor = colorScheme.primaryContainer;
        iconColor = colorScheme.onPrimaryContainer;
        break;
      case NotificationType.call:
        icon = Icons.videocam;
        backgroundColor = Colors.green.withValues(alpha: 0.2);
        iconColor = Colors.green.shade700;
        break;
      case NotificationType.mention:
        icon = Icons.alternate_email;
        backgroundColor = colorScheme.tertiaryContainer;
        iconColor = colorScheme.onTertiaryContainer;
        break;
      case NotificationType.reaction:
        icon = Icons.favorite;
        backgroundColor = colorScheme.errorContainer;
        iconColor = colorScheme.onErrorContainer;
        break;
    }
    
    return CircleAvatar(
      radius: 20,
      backgroundColor: backgroundColor,
      child: Icon(icon, size: 20, color: iconColor),
    );
  }
  
  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);
    
    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
    }
  }
}

/// Notification Item Model
class NotificationItem {
  final String id;
  final NotificationType type;
  final String title;
  final String message;
  final String? senderUuid;
  final DateTime timestamp;
  final bool isRead;
  final dynamic data;
  
  NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    this.senderUuid,
    required this.timestamp,
    required this.isRead,
    required this.data,
  });
  
  NotificationItem copyWith({
    String? id,
    NotificationType? type,
    String? title,
    String? message,
    String? senderUuid,
    DateTime? timestamp,
    bool? isRead,
    dynamic data,
  }) {
    return NotificationItem(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      message: message ?? this.message,
      senderUuid: senderUuid ?? this.senderUuid,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      data: data ?? this.data,
    );
  }
}

/// Notification Types
enum NotificationType {
  message,
  groupMessage,
  fileShared,
  channelInvite,
  call,
  mention,
  reaction,
}
