import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'event_bus.dart';
import 'notification_service.dart' as desktop;
import 'notification_service_android.dart';
import 'user_profile_service.dart';
import 'active_conversation_service.dart';

/// Listens to EventBus events and triggers appropriate notifications
///
/// This service bridges the EventBus (central event system) with:
/// - NotificationService (system notifications + sounds for messages)
/// - SoundService (subtle sounds for video conference events)
class NotificationListenerService {
  static final NotificationListenerService _instance =
      NotificationListenerService._internal();
  static NotificationListenerService get instance => _instance;

  NotificationListenerService._internal();

  bool _isInitialized = false;
  StreamSubscription<Map<String, dynamic>>? _newMessageSub;
  StreamSubscription<Map<String, dynamic>>? _newNotificationSub;

  // Deduplication: Track recently shown notifications by itemId
  // Prevents duplicate notifications when user has multiple devices online
  final Map<String, DateTime> _recentNotifications = {};
  static const Duration _deduplicationWindow = Duration(seconds: 5);

  /// Get the platform-specific notification service
  dynamic get _notificationService {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return NotificationServiceAndroid.instance;
    } else {
      return desktop.NotificationService.instance;
    }
  }

  /// Initialize and start listening to EventBus events
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('[NotificationListener] Already initialized');
      return;
    }

    debugPrint('[NotificationListener] Initializing...');

    // Listen for new messages (direct & group)
    _newMessageSub = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newMessage)
        .listen(_handleNewMessage);

    // Listen for activity notifications
    _newNotificationSub = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newNotification)
        .listen(_handleNewNotification);

    _isInitialized = true;
    debugPrint(
      '[NotificationListener] ✓ Initialized and listening to EventBus',
    );
  }

  /// Handle new message events (1:1 and group messages)
  String? _getServerId(Map<String, dynamic> data) {
    final rawServerId = data['serverId'] ?? data['_serverId'];
    if (rawServerId is String && rawServerId.isNotEmpty) {
      return rawServerId;
    }

    if (kIsWeb) {
      return 'web';
    }

    return null;
  }

  bool _isDuplicateNotification(String? itemId, String? serverId) {
    if (itemId == null || itemId.isEmpty) return false;

    final key = serverId == null || serverId.isEmpty
        ? itemId
        : '$serverId:$itemId';
    final now = DateTime.now();

    _recentNotifications.removeWhere(
      (storedKey, time) => now.difference(time) > _deduplicationWindow,
    );

    if (_recentNotifications.containsKey(key)) {
      return true;
    }

    _recentNotifications[key] = now;
    return false;
  }

  void _handleNewMessage(Map<String, dynamic> data) {
    try {
      debugPrint('[NotificationListener] 📬 New message event received');
      debugPrint('[NotificationListener] Data: $data');

      final type = data['type'] as String?;
      final sender = (data['senderId'] ?? data['sender'])?.toString();
      final message = data['message'] as String?;
      final channel = (data['channelId'] ?? data['channel'])?.toString();
      final itemId = data['itemId'] as String?;
      final serverId = _getServerId(data);

      final currentUserId = UserProfileService.instance.currentUserUuid;
      final isOwnMessage =
          data['isOwnMessage'] as bool? ??
          (currentUserId != null && sender == currentUserId);

      // Don't show notifications for own messages
      if (isOwnMessage) {
        debugPrint('[NotificationListener] Skipping own message');
        return;
      }

      // Deduplication: Skip if we've shown this notification recently
      // This prevents duplicate notifications when user has multiple devices online
      if (_isDuplicateNotification(itemId, serverId)) {
        debugPrint(
          '[NotificationListener] ⏭️ Skipping duplicate notification (itemId: $itemId, serverId: $serverId)',
        );
        return;
      }

      // Only show notifications for actual content (not system messages)
      if (type != 'message' &&
          type != 'file' &&
          type != 'voice' &&
          type != 'image') {
        debugPrint(
          '[NotificationListener] Skipping non-content message type: $type',
        );
        return;
      }

      // Get sender display name
      final senderId = sender ?? 'Unknown';
      final senderName =
          UserProfileService.instance.getDisplayName(senderId) ?? senderId;

      // Get appropriate message preview based on type
      String messagePreview;
      switch (type) {
        case 'voice':
          messagePreview = 'Voice message';
          break;
        case 'image':
          messagePreview = 'Image';
          break;
        case 'file':
          messagePreview = 'File';
          break;
        case 'message':
        default:
          messagePreview = message ?? 'New message';
      }

      if (channel != null) {
        // Group message
        _showGroupMessageNotification(
          channelId: channel,
          senderName: senderName,
          message: messagePreview,
          messageType: type,
        );
      } else {
        // Direct message
        _showDirectMessageNotification(
          senderId: senderId,
          senderName: senderName,
          message: messagePreview,
          messageType: type,
        );
      }
    } catch (e) {
      debugPrint('[NotificationListener] ❌ Error handling new message: $e');
    }
  }

  /// Handle activity notification events (mentions, reactions, etc.)
  void _handleNewNotification(Map<String, dynamic> data) {
    try {
      debugPrint('[NotificationListener] 🔔 New notification event received');

      final type = data['type'] as String?;
      final sender = (data['senderId'] ?? data['sender'])?.toString();
      final message = data['message'] as String?;
      final itemId = data['itemId'] as String?;
      final serverId = _getServerId(data);

      final currentUserId = UserProfileService.instance.currentUserUuid;
      final isOwnMessage =
          data['isOwnMessage'] as bool? ??
          (currentUserId != null && sender == currentUserId);

      // Don't show notifications for own actions
      if (isOwnMessage) {
        return;
      }

      // Deduplication: Skip if we've shown this notification recently
      if (_isDuplicateNotification(itemId, serverId)) {
        debugPrint(
          '[NotificationListener] ⏭️ Skipping duplicate activity notification (itemId: $itemId, serverId: $serverId)',
        );
        return;
      }

      // Get sender display name
      final senderId = sender ?? 'Unknown';
      final senderName =
          UserProfileService.instance.getDisplayName(senderId) ?? senderId;

      String title = '';
      String body = message ?? '';

      switch (type) {
        case 'mention':
          title = '$senderName mentioned you';
          break;
        case 'emote':
          title = '$senderName reacted';
          break;
        case 'missingcall':
          title = 'Missed call from $senderName';
          break;
        case 'addtochannel':
          title = '$senderName added you to a channel';
          break;
        case 'removefromchannel':
          title = '$senderName removed you from a channel';
          break;
        case 'permissionchange':
          title = 'Permissions changed by $senderName';
          break;
        default:
          title = 'Notification from $senderName';
      }

      _notificationService.notifyGeneral(
        title: title,
        message: body,
        identifier: 'notification_${data['itemId']}',
      );
    } catch (e) {
      debugPrint('[NotificationListener] ❌ Error handling notification: $e');
    }
  }

  /// Show notification for direct message
  void _showDirectMessageNotification({
    required String senderId,
    required String senderName,
    required String message,
    String? messageType,
  }) {
    // Check if this conversation is currently open - suppress notification if so
    if (ActiveConversationService.instance
        .shouldSuppressDirectMessageNotification(senderId)) {
      debugPrint(
        '[NotificationListener] ⏭️ Suppressing DM notification - conversation is open',
      );
      return;
    }

    debugPrint(
      '[NotificationListener] 💬 Showing 1:1 notification (type: $messageType)',
    );
    _notificationService.notifyNewDirectMessage(
      senderName: senderName,
      messagePreview: message,
      senderId: senderId,
      messageType: messageType,
    );
  }

  /// Show notification for group message
  void _showGroupMessageNotification({
    required String channelId,
    required String senderName,
    required String message,
    String? messageType,
  }) {
    // Check if this channel is currently open - suppress notification if so
    if (ActiveConversationService.instance.shouldSuppressGroupNotification(
      channelId,
    )) {
      debugPrint(
        '[NotificationListener] ⏭️ Suppressing group notification - channel is open',
      );
      return;
    }

    debugPrint(
      '[NotificationListener] 💬 Showing group notification (type: $messageType)',
    );

    // TODO: Fetch actual channel name from service
    final channelName = channelId; // Fallback to ID for now

    _notificationService.notifyNewGroupMessage(
      channelName: channelName,
      senderName: senderName,
      messagePreview: message,
      channelId: channelId,
      messageType: messageType,
    );
  }

  /// Dispose and clean up subscriptions
  void dispose() {
    debugPrint('[NotificationListener] Disposing...');
    _newMessageSub?.cancel();
    _newNotificationSub?.cancel();
    _newMessageSub = null;
    _newNotificationSub = null;
    _isInitialized = false;
    debugPrint('[NotificationListener] ✓ Disposed');
  }
}
