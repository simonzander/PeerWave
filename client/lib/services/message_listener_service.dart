import 'package:flutter/foundation.dart' show debugPrint;
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'video_conference_service.dart';

// ============================================================================
// ⚠️ DEPRECATION NOTICE
// ============================================================================
// This service is DEPRECATED and conflicts with SignalClient's ListenerRegistry.
//
// PROBLEM:
// - SignalClient's GroupListeners already handles groupItem events
// - This creates duplicate listeners causing race conditions
// - Uses deprecated pattern instead of SignalClient architecture
//
// TODO - MIGRATION PLAN:
// 1. Move video E2EE handling → MessagingService.handleSystemMessage()
// 2. Move file share logic → MessagingService.handleSystemMessage()
// 3. Remove duplicate groupItem/receiveItem listeners
// 4. Use SignalClient.callbackManager for UI notifications
// 5. Delete this file once migration is complete
//
// CURRENT STATUS:
// - Still used by VideoConferenceService for E2EE key routing
// - Still used by NotificationProvider for UI updates
// - Still used by post_login_init_service.dart
// ============================================================================

/// Global service that listens for all incoming messages (1:1 and group)
/// and stores them in local storage, regardless of which screen is open.
/// Also triggers notification callbacks for UI updates.
class MessageListenerService {
  static final MessageListenerService _instance =
      MessageListenerService._internal();
  static MessageListenerService get instance => _instance;

  MessageListenerService._internal();

  bool _isInitialized = false;
  final List<Function(MessageNotification)> _notificationCallbacks = [];

  // VideoConferenceService instance for E2EE key distribution
  // ⚠️ DEPRECATED: Not used since message handlers were removed
  // VideoConferenceService registration is no longer needed
  // TODO: Remove this when VideoConferenceService migrates to SignalClient
  // VideoConferenceService? _videoConferenceService;

  /// Register VideoConferenceService for E2EE key handling
  /// ⚠️ DEPRECATED: No-op since message handlers removed
  void registerVideoConferenceService(VideoConferenceService service) {
    // _videoConferenceService = service;
    debugPrint(
      '[MESSAGE_LISTENER] ⚠️ VideoConferenceService registration is deprecated (no message handlers)',
    );
  }

  /// Unregister VideoConferenceService
  /// ⚠️ DEPRECATED: No-op since message handlers removed
  void unregisterVideoConferenceService() {
    // _videoConferenceService = null;
    debugPrint(
      '[MESSAGE_LISTENER] ⚠️ VideoConferenceService unregistration is deprecated',
    );
  }

  /// Initialize global message listeners
  ///
  /// ⚠️ DEPRECATED: Socket listeners removed - SignalClient handles them now
  /// This method is kept only for the notification callback system
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('[MESSAGE_LISTENER] Already initialized');
      return;
    }

    debugPrint(
      '[MESSAGE_LISTENER] Initializing notification callback system...',
    );

    // ⚠️ ALL SOCKET LISTENERS REMOVED
    // SignalClient's ListenerRegistry already handles:
    // - receiveItem (via MessageListeners)
    // - groupItem (via GroupListeners)
    // - deliveryReceipt (via MessageListeners)
    // - groupItemDelivered (via GroupListeners)
    // - groupItemReadUpdate (via GroupListeners)
    // - file_share_update (should be in MessagingService)
    //
    // This service now only manages:
    // - VideoConferenceService registration bridge
    // - UI notification callbacks
    //
    // TODO: Remove this service entirely once:
    // 1. VideoConferenceService migrated to use SignalClient callbacks
    // 2. NotificationProvider uses SignalClient.callbackManager directly

    _isInitialized = true;
    debugPrint(
      '[MESSAGE_LISTENER] ✓ Notification callback system ready (no socket listeners)',
    );
  }

  /// Cleanup listeners
  void dispose() {
    if (!_isInitialized) return;

    // Unregister all listeners for MessageListenerService
    SocketService.instance.unregisterAllForName('MessageListenerService');

    _notificationCallbacks.clear();
    _isInitialized = false;
    debugPrint('[MESSAGE_LISTENER] Global message listeners disposed');
  }

  /// Register a callback for message notifications
  ///
  /// ⚠️ NOTE: No messages will trigger callbacks since socket listeners removed
  /// SignalClient.callbackManager should be used instead
  void registerNotificationCallback(Function(MessageNotification) callback) {
    if (!_notificationCallbacks.contains(callback)) {
      _notificationCallbacks.add(callback);
      debugPrint(
        '[MESSAGE_LISTENER] Registered notification callback (total: ${_notificationCallbacks.length})',
      );
    }
  }

  /// Unregister a callback
  void unregisterNotificationCallback(Function(MessageNotification) callback) {
    _notificationCallbacks.remove(callback);
    debugPrint(
      '[MESSAGE_LISTENER] Unregistered notification callback (total: ${_notificationCallbacks.length})',
    );
  }
}

/// Type of message notification
enum MessageType {
  direct,
  group,
  fileShareUpdate, // ← NEW: File share add/revoke notifications
  deliveryReceipt,
  groupDeliveryReceipt,
  groupReadReceipt,
  system, // ← NEW: System notifications (identity key changes, etc.)
}

/// Message notification data
class MessageNotification {
  final MessageType type;
  final String itemId;
  final String? channelId;
  final String? senderId;
  final int? senderDeviceId;
  final String timestamp;
  final bool encrypted;
  final String? message;
  final int? deliveredCount;
  final int? readCount;
  final int? totalCount;
  final bool? allRead;
  final String? fileId; // ← NEW: For file share updates
  final String? fileAction; // ← NEW: 'add' | 'revoke'

  MessageNotification({
    required this.type,
    required this.itemId,
    this.channelId,
    this.senderId,
    this.senderDeviceId,
    required this.timestamp,
    this.encrypted = false,
    this.message,
    this.deliveredCount,
    this.readCount,
    this.totalCount,
    this.allRead,
    this.fileId, // ← NEW
    this.fileAction, // ← NEW
  });

  @override
  String toString() {
    return 'MessageNotification(type: $type, itemId: $itemId, channelId: $channelId, sender: $senderId, encrypted: $encrypted)';
  }
}
