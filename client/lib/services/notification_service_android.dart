import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'preferences_service.dart';

/// Android-specific notification service using flutter_local_notifications
///
/// Adapts the desktop notification service architecture to Android platform.
/// Uses same event flow as desktop: EventBus → NotificationListenerService → this service
class NotificationServiceAndroid {
  static final NotificationServiceAndroid _instance =
      NotificationServiceAndroid._internal();
  static NotificationServiceAndroid get instance => _instance;

  NotificationServiceAndroid._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final AudioPlayer _player = AudioPlayer();

  bool _enabled = true;
  bool _soundEnabled = true;
  bool _initialized = false;
  bool _permissionGranted = false;

  // Notification preferences (same as desktop)
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

  // Meeting email preferences
  bool _meetingInviteEmailEnabled = true;
  bool _meetingRsvpEmailToOrganizerEnabled = true;
  bool _meetingUpdateEmailEnabled = true;
  bool _meetingCancelEmailEnabled = true;
  bool _meetingSelfInviteEmailEnabled = false;

  // Notification channel IDs
  static const String _channelIdMessages = 'peerwave_messages';
  static const String _channelIdCalls = 'peerwave_calls';
  static const String _channelIdMentions = 'peerwave_mentions';
  static const String _channelIdFiles = 'peerwave_files';
  static const String _channelIdGeneral = 'peerwave_general';

  /// Initialize the Android notification service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      debugPrint('[NotificationServiceAndroid] Initializing...');

      // Load preferences
      await _loadPreferences();

      // Initialize notification plugin
      const androidSettings = AndroidInitializationSettings(
        '@drawable/ic_notification', // Use drawable icon for notifications
      );
      const initSettings = InitializationSettings(android: androidSettings);

      await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Create notification channels
      await _createNotificationChannels();

      // Request permission (Android 13+)
      await _requestPermission();

      _initialized = true;
      debugPrint('[NotificationServiceAndroid] ✓ Initialized successfully');
    } catch (e) {
      debugPrint('[NotificationServiceAndroid] ❌ Initialization error: $e');
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

    _meetingInviteEmailEnabled = await prefs.loadMeetingInviteEmailEnabled();
    _meetingRsvpEmailToOrganizerEnabled = await prefs
        .loadMeetingRsvpEmailToOrganizerEnabled();
    _meetingUpdateEmailEnabled = await prefs.loadMeetingUpdateEmailEnabled();
    _meetingCancelEmailEnabled = await prefs.loadMeetingCancelEmailEnabled();
    _meetingSelfInviteEmailEnabled = await prefs
        .loadMeetingSelfInviteEmailEnabled();

    debugPrint('[NotificationServiceAndroid] Preferences loaded');
  }

  /// Create Android notification channels
  Future<void> _createNotificationChannels() async {
    // Messages channel (default importance)
    const messagesChannel = AndroidNotificationChannel(
      _channelIdMessages,
      'Messages',
      description: 'Direct and group message notifications',
      importance: Importance.defaultImportance,
      enableVibration: true,
      playSound: false, // We play custom sounds
    );

    // Calls channel (high importance)
    const callsChannel = AndroidNotificationChannel(
      _channelIdCalls,
      'Calls',
      description: 'Incoming call notifications',
      importance: Importance.high,
      enableVibration: true,
      playSound: false,
    );

    // Mentions channel (high importance)
    const mentionsChannel = AndroidNotificationChannel(
      _channelIdMentions,
      'Mentions',
      description: 'When someone mentions you',
      importance: Importance.high,
      enableVibration: true,
      playSound: false,
    );

    // Files channel (default importance)
    const filesChannel = AndroidNotificationChannel(
      _channelIdFiles,
      'Files',
      description: 'File share notifications',
      importance: Importance.defaultImportance,
      enableVibration: true,
      playSound: false,
    );

    // General channel (low importance)
    const generalChannel = AndroidNotificationChannel(
      _channelIdGeneral,
      'General',
      description: 'General app notifications',
      importance: Importance.low,
      enableVibration: false,
      playSound: false,
    );

    // Register all channels
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(messagesChannel);
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(callsChannel);
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(mentionsChannel);
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(filesChannel);
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(generalChannel);

    debugPrint('[NotificationServiceAndroid] ✓ Notification channels created');
  }

  /// Request notification permission (Android 13+)
  Future<void> _requestPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;

      if (status.isGranted) {
        _permissionGranted = true;
        debugPrint(
          '[NotificationServiceAndroid] ✓ Notification permission granted',
        );
      } else if (status.isDenied) {
        // Request permission
        final result = await Permission.notification.request();
        _permissionGranted = result.isGranted;
        debugPrint(
          '[NotificationServiceAndroid] Permission request result: $result',
        );
      } else if (status.isPermanentlyDenied) {
        debugPrint(
          '[NotificationServiceAndroid] ❌ Permission permanently denied',
        );
        _permissionGranted = false;
      }
    }
  }

  /// Request notification permission (can be called from settings)
  Future<bool> requestPermission() async {
    await _requestPermission();
    return _permissionGranted;
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint(
      '[NotificationServiceAndroid] Notification tapped: ${response.payload}',
    );
    // TODO: Add deep link handling to navigate to specific screen
    // Parse response.payload (e.g., "dm_userId" or "group_channelId")
    // Use GoRouter to navigate to the appropriate chat
  }

  /// Enable or disable notifications
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await PreferencesService().saveNotificationsEnabled(enabled);
    debugPrint(
      '[NotificationServiceAndroid] Notifications ${enabled ? 'enabled' : 'disabled'}',
    );
  }

  /// Enable or disable notification sounds
  Future<void> setSoundEnabled(bool enabled) async {
    _soundEnabled = enabled;
    await PreferencesService().saveSoundsEnabled(enabled);
    debugPrint(
      '[NotificationServiceAndroid] Notification sounds ${enabled ? 'enabled' : 'disabled'}',
    );
  }

  // Getters
  bool get isEnabled => _enabled;
  bool get isSoundEnabled => _soundEnabled;
  bool get hasPermission => _permissionGranted;

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

  bool get meetingInviteEmailEnabled => _meetingInviteEmailEnabled;
  bool get meetingRsvpEmailToOrganizerEnabled =>
      _meetingRsvpEmailToOrganizerEnabled;
  bool get meetingUpdateEmailEnabled => _meetingUpdateEmailEnabled;
  bool get meetingCancelEmailEnabled => _meetingCancelEmailEnabled;
  bool get meetingSelfInviteEmailEnabled => _meetingSelfInviteEmailEnabled;

  // Setters (same as desktop)
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

  Future<void> setMeetingInviteEmailEnabled(bool enabled) async {
    _meetingInviteEmailEnabled = enabled;
    await PreferencesService().saveMeetingInviteEmailEnabled(enabled);
  }

  Future<void> setMeetingRsvpEmailToOrganizerEnabled(bool enabled) async {
    _meetingRsvpEmailToOrganizerEnabled = enabled;
    await PreferencesService().saveMeetingRsvpEmailToOrganizerEnabled(enabled);
  }

  Future<void> setMeetingUpdateEmailEnabled(bool enabled) async {
    _meetingUpdateEmailEnabled = enabled;
    await PreferencesService().saveMeetingUpdateEmailEnabled(enabled);
  }

  Future<void> setMeetingCancelEmailEnabled(bool enabled) async {
    _meetingCancelEmailEnabled = enabled;
    await PreferencesService().saveMeetingCancelEmailEnabled(enabled);
  }

  Future<void> setMeetingSelfInviteEmailEnabled(bool enabled) async {
    _meetingSelfInviteEmailEnabled = enabled;
    await PreferencesService().saveMeetingSelfInviteEmailEnabled(enabled);
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
    debugPrint('[NotificationServiceAndroid] 📬 notifyNewDirectMessage called');

    if (!_enabled || _dndEnabled || !_directMessageNotificationsEnabled) {
      debugPrint(
        '[NotificationServiceAndroid] ⚠️ Notifications disabled, skipping',
      );
      return;
    }

    if (!_permissionGranted) {
      debugPrint('[NotificationServiceAndroid] ⚠️ No permission, skipping');
      return;
    }

    if (_directMessageSoundsEnabled) {
      await _playSound('sounds/message_received.mp3');
    }

    final body = _directMessagePreviewEnabled ? messagePreview : 'New message';

    await _showNotification(
      id: senderId.hashCode,
      channelId: _channelIdMessages,
      title: senderName,
      body: body,
      payload: 'dm_$senderId',
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

    if (!_permissionGranted) {
      debugPrint('[NotificationServiceAndroid] ⚠️ No permission, skipping');
      return;
    }

    // Check if only mentions should trigger notifications
    if (_onlyMentionsInGroups && !isMention) {
      return;
    }

    // Use mentions channel for mentions
    final channelIdToUse = isMention ? _channelIdMentions : _channelIdMessages;

    if (_groupMessageSoundsEnabled) {
      await _playSound('sounds/message_received.mp3');
    }

    final body = _groupMessagePreviewEnabled
        ? '$senderName: $messagePreview'
        : '$senderName sent a message';

    await _showNotification(
      id: channelId.hashCode,
      channelId: channelIdToUse,
      title: channelName,
      body: body,
      payload: 'group_$channelId',
    );
  }

  /// Show notification for general app notification
  Future<void> notifyGeneral({
    required String title,
    required String message,
    String? identifier,
  }) async {
    if (!_enabled || !_permissionGranted) return;

    await _playSound('sounds/notification.mp3');
    await _showNotification(
      id: identifier.hashCode,
      channelId: _channelIdGeneral,
      title: title,
      body: message,
      payload: identifier ?? 'general',
    );
  }

  /// Show notification for incoming call
  Future<void> notifyIncomingCall({
    required String callerName,
    required String channelName,
    String? callId,
  }) async {
    if (!_enabled || !_permissionGranted) return;

    await _playSound('sounds/incoming_call.mp3');
    await _showNotification(
      id: callId.hashCode,
      channelId: _channelIdCalls,
      title: '📞 Incoming Call',
      body: '$callerName is calling in $channelName',
      payload: 'call_$callId',
      actions: ['Answer', 'Decline'],
    );
  }

  /// Internal: Play notification sound
  Future<void> _playSound(String assetPath) async {
    if (!_soundEnabled) return;

    try {
      await _player.play(AssetSource(assetPath));
      debugPrint('[NotificationServiceAndroid] 🔊 Played sound: $assetPath');
    } catch (e) {
      debugPrint('[NotificationServiceAndroid] ❌ Error playing sound: $e');
    }
  }

  /// Internal: Show Android notification
  Future<void> _showNotification({
    required int id,
    required String channelId,
    required String title,
    required String body,
    required String payload,
    List<String>? actions,
  }) async {
    try {
      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelId == _channelIdMessages
            ? 'Messages'
            : channelId == _channelIdCalls
            ? 'Calls'
            : channelId == _channelIdMentions
            ? 'Mentions'
            : channelId == _channelIdFiles
            ? 'Files'
            : 'General',
        channelDescription: 'PeerWave notifications',
        importance:
            channelId == _channelIdCalls || channelId == _channelIdMentions
            ? Importance.high
            : Importance.defaultImportance,
        priority:
            channelId == _channelIdCalls || channelId == _channelIdMentions
            ? Priority.high
            : Priority.defaultPriority,
        icon: '@drawable/ic_notification', // Use proper notification icon
        enableVibration: true,
        playSound: false, // We play custom sounds
        actions: actions
            ?.map(
              (action) => AndroidNotificationAction(
                action.toLowerCase().replaceAll(' ', '_'),
                action,
              ),
            )
            .toList(),
      );

      final notificationDetails = NotificationDetails(android: androidDetails);

      await _notifications.show(
        id,
        title,
        body,
        notificationDetails,
        payload: payload,
      );

      debugPrint('[NotificationServiceAndroid] ✓ Notification shown: $title');
    } catch (e) {
      debugPrint(
        '[NotificationServiceAndroid] ❌ Error showing notification: $e',
      );
    }
  }

  /// Dispose resources
  void dispose() {
    _player.dispose();
  }
}
