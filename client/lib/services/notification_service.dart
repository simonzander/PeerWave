import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:universal_html/html.dart' as html;
import 'preferences_service.dart';

/// Service for system notifications with sound
///
/// Used for important events that need user attention:
/// - New 1:1 message
/// - New group chat message
/// - New notification
/// - Incoming call
///
/// Shows both:
/// - System notification (Windows/macOS/Web)
/// - Plays notification sound
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  static NotificationService get instance => _instance;

  NotificationService._internal();

  final AudioPlayer _player = AudioPlayer();
  bool _enabled = true;
  bool _soundEnabled = true;
  bool _initialized = false;

  // Permission state
  bool _permissionGranted = false;

  // Notification preferences
  bool _directMessageNotificationsEnabled = true;
  bool _directMessageSoundsEnabled = true;
  bool _directMessagePreviewEnabled = true;
  bool _groupMessageNotificationsEnabled = true;
  bool _groupMessageSoundsEnabled = true;
  bool _groupMessagePreviewEnabled = true;
  bool _onlyMentionsInGroups = false;
  bool _mentionNotificationsEnabled = true;
  bool _reactionNotificationsEnabled = true;
  bool _missedCallNotificationsEnabled = true;
  bool _channelInviteNotificationsEnabled = true;
  bool _permissionChangeNotificationsEnabled = true;
  bool _dndEnabled = false;

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Load preferences
      await _loadPreferences();

      if (kIsWeb) {
        await _initializeWeb();
      } else {
        await _initializeDesktop();
      }
      _initialized = true;
      debugPrint('[NotificationService] ✓ Initialized successfully');
    } catch (e) {
      debugPrint('[NotificationService] ❌ Initialization error: $e');
    }
  }

  /// Load notification preferences from storage
  Future<void> _loadPreferences() async {
    final prefs = PreferencesService();
    _enabled = await prefs.loadNotificationsEnabled();
    _soundEnabled = await prefs.loadSoundsEnabled();
    _directMessageNotificationsEnabled = await prefs
        .loadDirectMessageNotificationsEnabled();
    _directMessageSoundsEnabled = await prefs.loadDirectMessageSoundsEnabled();
    _directMessagePreviewEnabled = await prefs
        .loadDirectMessagePreviewEnabled();
    _groupMessageNotificationsEnabled = await prefs
        .loadGroupMessageNotificationsEnabled();
    _groupMessageSoundsEnabled = await prefs.loadGroupMessageSoundsEnabled();
    _groupMessagePreviewEnabled = await prefs.loadGroupMessagePreviewEnabled();
    _onlyMentionsInGroups = await prefs.loadOnlyMentionsInGroups();
    _mentionNotificationsEnabled = await prefs
        .loadMentionNotificationsEnabled();
    _reactionNotificationsEnabled = await prefs
        .loadReactionNotificationsEnabled();
    _missedCallNotificationsEnabled = await prefs
        .loadMissedCallNotificationsEnabled();
    _channelInviteNotificationsEnabled = await prefs
        .loadChannelInviteNotificationsEnabled();
    _permissionChangeNotificationsEnabled = await prefs
        .loadPermissionChangeNotificationsEnabled();
    _dndEnabled = await prefs.loadDndEnabled();
    debugPrint('[NotificationService] Preferences loaded');
  }

  /// Initialize for web platform
  Future<void> _initializeWeb() async {
    // Check if Notification API is supported
    if (!html.Notification.supported) {
      debugPrint(
        '[NotificationService] ⚠️ Notifications not supported in this browser',
      );
      return;
    }

    // Check current permission
    final permission = html.Notification.permission;
    if (permission == 'granted') {
      _permissionGranted = true;
      debugPrint(
        '[NotificationService] ✓ Web notifications permission granted',
      );
    } else if (permission == 'default') {
      debugPrint(
        '[NotificationService] ℹ️ Web notifications permission not yet requested',
      );
    } else {
      debugPrint('[NotificationService] ❌ Web notifications permission denied');
    }
  }

  /// Initialize for desktop platform (Windows/macOS/Linux)
  Future<void> _initializeDesktop() async {
    await localNotifier.setup(
      appName: 'PeerWave',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
    _permissionGranted = true; // Desktop doesn't require explicit permission
    debugPrint('[NotificationService] ✓ Desktop notifications initialized');
  }

  /// Request notification permission (Web only)
  Future<bool> requestPermission() async {
    if (!kIsWeb) {
      return true; // Desktop doesn't need permission
    }

    if (!html.Notification.supported) {
      debugPrint('[NotificationService] Notifications not supported');
      return false;
    }

    try {
      final permission = await html.Notification.requestPermission();
      _permissionGranted = permission == 'granted';
      debugPrint('[NotificationService] Permission: $permission');
      return _permissionGranted;
    } catch (e) {
      debugPrint('[NotificationService] Permission error: $e');
      return false;
    }
  }

  /// Enable or disable notifications
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await PreferencesService().saveNotificationsEnabled(enabled);
    debugPrint(
      '[NotificationService] Notifications ${enabled ? 'enabled' : 'disabled'}',
    );
  }

  /// Enable or disable notification sounds
  Future<void> setSoundEnabled(bool enabled) async {
    _soundEnabled = enabled;
    await PreferencesService().saveSoundsEnabled(enabled);
    debugPrint(
      '[NotificationService] Notification sounds ${enabled ? 'enabled' : 'disabled'}',
    );
  }

  bool get isEnabled => _enabled;
  bool get isSoundEnabled => _soundEnabled;
  bool get hasPermission => _permissionGranted;

  // Preference getters
  bool get directMessageNotificationsEnabled =>
      _directMessageNotificationsEnabled;
  bool get directMessageSoundsEnabled => _directMessageSoundsEnabled;
  bool get directMessagePreviewEnabled => _directMessagePreviewEnabled;
  bool get groupMessageNotificationsEnabled =>
      _groupMessageNotificationsEnabled;
  bool get groupMessageSoundsEnabled => _groupMessageSoundsEnabled;
  bool get groupMessagePreviewEnabled => _groupMessagePreviewEnabled;
  bool get onlyMentionsInGroups => _onlyMentionsInGroups;
  bool get mentionNotificationsEnabled => _mentionNotificationsEnabled;
  bool get reactionNotificationsEnabled => _reactionNotificationsEnabled;
  bool get missedCallNotificationsEnabled => _missedCallNotificationsEnabled;
  bool get channelInviteNotificationsEnabled =>
      _channelInviteNotificationsEnabled;
  bool get permissionChangeNotificationsEnabled =>
      _permissionChangeNotificationsEnabled;
  bool get dndEnabled => _dndEnabled;

  // Preference setters
  Future<void> setDirectMessageNotificationsEnabled(bool enabled) async {
    _directMessageNotificationsEnabled = enabled;
    await PreferencesService().saveDirectMessageNotificationsEnabled(enabled);
  }

  Future<void> setDirectMessageSoundsEnabled(bool enabled) async {
    _directMessageSoundsEnabled = enabled;
    await PreferencesService().saveDirectMessageSoundsEnabled(enabled);
  }

  Future<void> setDirectMessagePreviewEnabled(bool enabled) async {
    _directMessagePreviewEnabled = enabled;
    await PreferencesService().saveDirectMessagePreviewEnabled(enabled);
  }

  Future<void> setGroupMessageNotificationsEnabled(bool enabled) async {
    _groupMessageNotificationsEnabled = enabled;
    await PreferencesService().saveGroupMessageNotificationsEnabled(enabled);
  }

  Future<void> setGroupMessageSoundsEnabled(bool enabled) async {
    _groupMessageSoundsEnabled = enabled;
    await PreferencesService().saveGroupMessageSoundsEnabled(enabled);
  }

  Future<void> setGroupMessagePreviewEnabled(bool enabled) async {
    _groupMessagePreviewEnabled = enabled;
    await PreferencesService().saveGroupMessagePreviewEnabled(enabled);
  }

  Future<void> setOnlyMentionsInGroups(bool enabled) async {
    _onlyMentionsInGroups = enabled;
    await PreferencesService().saveOnlyMentionsInGroups(enabled);
  }

  Future<void> setMentionNotificationsEnabled(bool enabled) async {
    _mentionNotificationsEnabled = enabled;
    await PreferencesService().saveMentionNotificationsEnabled(enabled);
  }

  Future<void> setReactionNotificationsEnabled(bool enabled) async {
    _reactionNotificationsEnabled = enabled;
    await PreferencesService().saveReactionNotificationsEnabled(enabled);
  }

  Future<void> setMissedCallNotificationsEnabled(bool enabled) async {
    _missedCallNotificationsEnabled = enabled;
    await PreferencesService().saveMissedCallNotificationsEnabled(enabled);
  }

  Future<void> setChannelInviteNotificationsEnabled(bool enabled) async {
    _channelInviteNotificationsEnabled = enabled;
    await PreferencesService().saveChannelInviteNotificationsEnabled(enabled);
  }

  Future<void> setPermissionChangeNotificationsEnabled(bool enabled) async {
    _permissionChangeNotificationsEnabled = enabled;
    await PreferencesService().savePermissionChangeNotificationsEnabled(
      enabled,
    );
  }

  Future<void> setDndEnabled(bool enabled) async {
    _dndEnabled = enabled;
    await PreferencesService().saveDndEnabled(enabled);
  }

  /// Show notification for new 1:1 message
  Future<void> notifyNewDirectMessage({
    required String senderName,
    required String messagePreview,
    String? senderId,
    String? messageType,
  }) async {
    debugPrint('[NotificationService] 📬 notifyNewDirectMessage called');
    debugPrint(
      '[NotificationService]   Enabled: $_enabled, Initialized: $_initialized, Permission: $_permissionGranted',
    );

    if (!_enabled || _dndEnabled || !_directMessageNotificationsEnabled) {
      debugPrint('[NotificationService] ⚠️ Notifications disabled, skipping');
      return;
    }

    if (_directMessageSoundsEnabled) {
      await _playSound('sounds/message_received.mp3');
    }

    // Choose icon based on message type
    String icon;
    switch (messageType) {
      case 'voice':
        icon = '🎤';
        break;
      case 'image':
        icon = '📸';
        break;
      case 'file':
        icon = '📎';
        break;
      case 'message':
      default:
        icon = '💬';
    }

    final body = _directMessagePreviewEnabled ? messagePreview : 'New message';
    await _showNotification(
      title: senderName,
      body: body,
      icon: icon,
      identifier: 'dm_$senderId',
    );
  }

  /// Show notification for new group chat message
  Future<void> notifyNewGroupMessage({
    required String channelName,
    required String senderName,
    required String messagePreview,
    String? channelId,
    bool isMention = false,
    String? messageType,
  }) async {
    if (!_enabled || _dndEnabled || !_groupMessageNotificationsEnabled) {
      return;
    }

    // Check if only mentions should trigger notifications
    if (_onlyMentionsInGroups && !isMention) {
      return;
    }

    if (_groupMessageSoundsEnabled) {
      await _playSound('sounds/message_received.mp3');
    }

    // Choose icon based on message type
    String icon;
    switch (messageType) {
      case 'voice':
        icon = '🎤';
        break;
      case 'image':
        icon = '📸';
        break;
      case 'file':
        icon = '📎';
        break;
      case 'message':
      default:
        icon = '💬';
    }

    final body = _groupMessagePreviewEnabled
        ? '$senderName: $messagePreview'
        : '$senderName sent a message';
    await _showNotification(
      title: channelName,
      body: body,
      icon: icon,
      identifier: 'group_$channelId',
    );
  }

  /// Show notification for general app notification
  Future<void> notifyGeneral({
    required String title,
    required String message,
    String? identifier,
  }) async {
    if (!_enabled) return;

    await _playSound('sounds/notification.mp3');
    await _showNotification(
      title: title,
      body: message,
      icon: '🔔',
      identifier: identifier ?? 'general',
    );
  }

  /// Show notification for incoming call
  Future<void> notifyIncomingCall({
    required String callerName,
    required String channelName,
    String? callId,
  }) async {
    if (!_enabled) return;

    await _playSound('sounds/incoming_call.mp3');
    await _showNotification(
      title: '📞 Incoming Call',
      body: '$callerName is calling in $channelName',
      icon: '📞',
      identifier: 'call_$callId',
      actions: ['Answer', 'Decline'],
    );
  }

  /// Internal: Play notification sound
  Future<void> _playSound(String assetPath) async {
    if (!_soundEnabled) return;

    try {
      await _player.play(AssetSource(assetPath));
      debugPrint('[NotificationService] 🔊 Played sound: $assetPath');
    } catch (e) {
      debugPrint('[NotificationService] ❌ Error playing sound: $e');
    }
  }

  /// Internal: Show system notification
  Future<void> _showNotification({
    required String title,
    required String body,
    required String icon,
    required String identifier,
    List<String>? actions,
  }) async {
    if (!_permissionGranted) {
      debugPrint(
        '[NotificationService] ⚠️ No permission, skipping notification',
      );
      return;
    }

    try {
      if (kIsWeb) {
        _showWebNotification(title, body, icon);
      } else {
        await _showDesktopNotification(title, body, identifier, actions);
      }
    } catch (e) {
      debugPrint('[NotificationService] ❌ Error showing notification: $e');
    }
  }

  /// Show web notification
  void _showWebNotification(String title, String body, String icon) {
    try {
      final notification = html.Notification(
        title,
        body: body,
        icon: '/favicon.png', // Use app icon
      );

      notification.onClick.listen((_) {
        debugPrint('[NotificationService] Web notification clicked');
        // Bring window to focus by calling the parent window
        try {
          // Use window.parent to access the window object
          // In universal_html, we need to use a different approach
          notification.close();
        } catch (e) {
          debugPrint('[NotificationService] Error focusing window: $e');
        }
      });

      debugPrint('[NotificationService] ✓ Web notification shown: $title');
    } catch (e) {
      debugPrint('[NotificationService] ❌ Web notification error: $e');
    }
  }

  /// Show desktop notification
  Future<void> _showDesktopNotification(
    String title,
    String body,
    String identifier,
    List<String>? actions,
  ) async {
    try {
      final notification = LocalNotification(
        identifier: identifier,
        title: title,
        body: body,
        silent: true, // Disable Windows system sound - we play our own
        actions: actions?.map((a) => LocalNotificationAction(text: a)).toList(),
      );

      notification.onClick = () {
        debugPrint('[NotificationService] Desktop notification clicked');
        // TODO: Add deep link handling to navigate to specific screen
      };

      if (actions != null) {
        notification.onClickAction = (index) {
          debugPrint('[NotificationService] Action clicked: ${actions[index]}');
          // TODO: Handle action (e.g., Answer call, Decline call)
        };
      }

      await notification.show();
      debugPrint('[NotificationService] ✓ Desktop notification shown: $title');
    } catch (e) {
      debugPrint('[NotificationService] ❌ Desktop notification error: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _player.dispose();
  }
}
