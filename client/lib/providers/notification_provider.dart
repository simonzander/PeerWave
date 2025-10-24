import 'package:flutter/foundation.dart';
import '../services/message_listener_service.dart';
import '../services/recent_conversations_service.dart';

/// Provider for managing in-app notifications (badges, toast messages, etc.)
class NotificationProvider with ChangeNotifier {
  final Map<String, int> _unreadCounts = {}; // channelId/userId -> unread count
  final List<MessageNotification> _recentNotifications = [];
  final Map<String, DateTime> _lastMessageTimes = {}; // Track last message timestamp
  
  int get totalUnreadCount => _unreadCounts.values.fold(0, (sum, count) => sum + count);
  
  Map<String, int> get unreadCounts => Map.unmodifiable(_unreadCounts);
  List<MessageNotification> get recentNotifications => List.unmodifiable(_recentNotifications);
  Map<String, DateTime> get lastMessageTimes => Map.unmodifiable(_lastMessageTimes);

  NotificationProvider() {
    // Register for message notifications
    MessageListenerService.instance.registerNotificationCallback(_handleNotification);
  }

  @override
  void dispose() {
    MessageListenerService.instance.unregisterNotificationCallback(_handleNotification);
    super.dispose();
  }

  void _handleNotification(MessageNotification notification) {
    print('[NOTIFICATION_PROVIDER] Received notification: ${notification.type}');

    switch (notification.type) {
      case MessageType.direct:
        _handleDirectMessageNotification(notification);
        break;
      case MessageType.group:
        _handleGroupMessageNotification(notification);
        break;
      case MessageType.deliveryReceipt:
      case MessageType.groupDeliveryReceipt:
      case MessageType.groupReadReceipt:
        // Don't create notifications for receipts
        break;
    }
  }

  void _handleDirectMessageNotification(MessageNotification notification) {
    if (notification.senderId == null) return;

    // Add to recent notifications
    _recentNotifications.insert(0, notification);
    if (_recentNotifications.length > 50) {
      _recentNotifications.removeLast();
    }

    // Increment unread count for this user
    final key = notification.senderId!;
    _unreadCounts[key] = (_unreadCounts[key] ?? 0) + 1;
    
    // Update last message time
    _lastMessageTimes[key] = DateTime.parse(notification.timestamp);

    // Update recent conversations (async, don't await)
    RecentConversationsService.updateTimestamp(key).catchError((e) {
      print('[NOTIFICATION_PROVIDER] Error updating recent conversation: $e');
    });

    print('[NOTIFICATION_PROVIDER] 1:1 message from ${notification.senderId}, unread: ${_unreadCounts[key]}');
    notifyListeners();
  }

  void _handleGroupMessageNotification(MessageNotification notification) {
    if (notification.channelId == null) return;

    // Add to recent notifications
    _recentNotifications.insert(0, notification);
    if (_recentNotifications.length > 50) {
      _recentNotifications.removeLast();
    }

    // Increment unread count for this channel
    final key = notification.channelId!;
    _unreadCounts[key] = (_unreadCounts[key] ?? 0) + 1;
    
    // Update last message time
    _lastMessageTimes[key] = DateTime.parse(notification.timestamp);

    print('[NOTIFICATION_PROVIDER] Group message in ${notification.channelId}, unread: ${_unreadCounts[key]}');
    notifyListeners();
  }

  /// Mark all messages from a user/channel as read
  void markAsRead(String key) {
    if (_unreadCounts.containsKey(key)) {
      _unreadCounts[key] = 0;
      print('[NOTIFICATION_PROVIDER] Marked $key as read');
      notifyListeners();
    }
  }

  /// Get unread count for a specific user/channel
  int getUnreadCount(String key) {
    return _unreadCounts[key] ?? 0;
  }

  /// Clear all notifications
  void clearAll() {
    _unreadCounts.clear();
    _recentNotifications.clear();
    notifyListeners();
  }

  /// Remove a specific notification
  void removeNotification(MessageNotification notification) {
    _recentNotifications.remove(notification);
    notifyListeners();
  }

  /// Get notifications for a specific user/channel
  List<MessageNotification> getNotificationsFor(String key) {
    return _recentNotifications.where((n) {
      if (n.type == MessageType.direct) {
        return n.senderId == key;
      } else if (n.type == MessageType.group) {
        return n.channelId == key;
      }
      return false;
    }).toList();
  }
}
