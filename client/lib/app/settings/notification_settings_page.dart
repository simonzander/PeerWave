import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../services/notification_service.dart';
import '../../services/sound_service.dart';

/// Notification Settings Page
///
/// Allows users to configure:
/// - Master notification toggles
/// - Video conference sounds (subtle, in-app only)
/// - Message notifications (system notifications + sounds)
/// - Activity notifications (mentions, reactions, etc.)
/// - Platform-specific settings (Web permission request)
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({Key? key}) : super(key: key);

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  // Master controls
  bool _notificationsEnabled = true;
  bool _soundsEnabled = true;

  // Video conference sounds (Type 1 - Subtle)
  bool _videoSoundsEnabled = true;
  bool _participantSoundsEnabled = true;
  bool _screenShareSoundsEnabled = true;

  // Message notifications (Type 2 - Important)
  bool _directMessageNotificationsEnabled = true;
  bool _directMessageSoundsEnabled = true;
  bool _directMessagePreviewEnabled = true;

  bool _groupMessageNotificationsEnabled = true;
  bool _groupMessageSoundsEnabled = true;
  bool _groupMessagePreviewEnabled = true;
  bool _onlyMentionsInGroups = false;

  // Activity notifications
  bool _mentionNotificationsEnabled = true;
  bool _reactionNotificationsEnabled = true;
  bool _missedCallNotificationsEnabled = true;
  bool _channelInviteNotificationsEnabled = true;
  bool _permissionChangeNotificationsEnabled = true;

  // Do Not Disturb
  bool _dndEnabled = false;

  // Platform-specific
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    final notifService = NotificationService.instance;
    final soundService = SoundService.instance;

    setState(() {
      // Master controls
      _notificationsEnabled = notifService.isEnabled;
      _soundsEnabled = notifService.isSoundEnabled;
      _hasPermission = notifService.hasPermission;

      // Video sounds
      _videoSoundsEnabled = soundService.isEnabled;
      // TODO: Load from preferences when implemented
      _participantSoundsEnabled = true;
      _screenShareSoundsEnabled = true;

      // Direct messages
      _directMessageNotificationsEnabled =
          notifService.directMessageNotificationsEnabled;
      _directMessageSoundsEnabled = notifService.directMessageSoundsEnabled;
      _directMessagePreviewEnabled = notifService.directMessagePreviewEnabled;

      // Group messages
      _groupMessageNotificationsEnabled =
          notifService.groupMessageNotificationsEnabled;
      _groupMessageSoundsEnabled = notifService.groupMessageSoundsEnabled;
      _groupMessagePreviewEnabled = notifService.groupMessagePreviewEnabled;
      _onlyMentionsInGroups = notifService.onlyMentionsInGroups;

      // Activity notifications
      _mentionNotificationsEnabled = notifService.mentionNotificationsEnabled;
      _reactionNotificationsEnabled = notifService.reactionNotificationsEnabled;
      _missedCallNotificationsEnabled =
          notifService.missedCallNotificationsEnabled;
      _channelInviteNotificationsEnabled =
          notifService.channelInviteNotificationsEnabled;
      _permissionChangeNotificationsEnabled =
          notifService.permissionChangeNotificationsEnabled;

      // DND
      _dndEnabled = notifService.dndEnabled;
    });
  }

  Future<void> _requestPermission() async {
    final granted = await NotificationService.instance.requestPermission();
    setState(() {
      _hasPermission = granted;
    });

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? 'Notification permission granted'
              : 'Notification permission denied',
        ),
        backgroundColor: granted ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Header
          Text(
            'Notification Settings',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Control how and when you receive notifications',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(height: 32),

          // Master Controls
          _buildSection(
            title: 'Master Controls',
            children: [
              _buildSwitchTile(
                title: 'Enable Notifications',
                subtitle: 'Master switch for all system notifications',
                value: _notificationsEnabled,
                onChanged: (value) {
                  setState(() => _notificationsEnabled = value);
                  NotificationService.instance.setEnabled(value);
                },
              ),
              _buildSwitchTile(
                title: 'Enable Sounds',
                subtitle: 'Master switch for all notification sounds',
                value: _soundsEnabled,
                onChanged: (value) {
                  setState(() => _soundsEnabled = value);
                  NotificationService.instance.setSoundEnabled(value);
                },
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Video Conference Sounds
          _buildSection(
            title: 'Video Conference Sounds',
            subtitle: 'Subtle audio feedback during video calls',
            children: [
              _buildSwitchTile(
                title: 'Enable Video Sounds',
                subtitle: 'In-app audio feedback (no pop-ups)',
                value: _videoSoundsEnabled,
                onChanged: (value) {
                  setState(() => _videoSoundsEnabled = value);
                  SoundService.instance.setEnabled(value);
                },
              ),
              if (_videoSoundsEnabled) ...[
                _buildSwitchTile(
                  title: 'Participant Join/Leave',
                  subtitle: 'Play sound when participants join or leave',
                  value: _participantSoundsEnabled,
                  onChanged: (value) {
                    setState(() => _participantSoundsEnabled = value);
                    // TODO: Store in preferences
                  },
                  indent: true,
                ),
                _buildSwitchTile(
                  title: 'Screen Share',
                  subtitle: 'Play sound when screen sharing starts or stops',
                  value: _screenShareSoundsEnabled,
                  onChanged: (value) {
                    setState(() => _screenShareSoundsEnabled = value);
                    // TODO: Store in preferences
                  },
                  indent: true,
                ),
              ],
            ],
          ),

          const SizedBox(height: 24),

          // Direct Message Notifications
          _buildSection(
            title: 'Direct Messages',
            subtitle: 'Notifications for 1:1 conversations',
            children: [
              _buildSwitchTile(
                title: 'Show Notifications',
                subtitle: 'System notifications for direct messages',
                value: _directMessageNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(
                          () => _directMessageNotificationsEnabled = value,
                        );
                        await NotificationService.instance
                            .setDirectMessageNotificationsEnabled(value);
                      }
                    : null,
              ),
              if (_directMessageNotificationsEnabled) ...[
                _buildSwitchTile(
                  title: 'Play Sound',
                  subtitle: 'Audio notification for new messages',
                  value: _directMessageSoundsEnabled,
                  onChanged: _soundsEnabled
                      ? (value) async {
                          setState(() => _directMessageSoundsEnabled = value);
                          await NotificationService.instance
                              .setDirectMessageSoundsEnabled(value);
                        }
                      : null,
                  indent: true,
                ),
                _buildSwitchTile(
                  title: 'Message Preview',
                  subtitle: 'Show message content in notification',
                  value: _directMessagePreviewEnabled,
                  onChanged: (value) async {
                    setState(() => _directMessagePreviewEnabled = value);
                    await NotificationService.instance
                        .setDirectMessagePreviewEnabled(value);
                  },
                  indent: true,
                ),
              ],
            ],
          ),

          const SizedBox(height: 24),

          // Group Message Notifications
          _buildSection(
            title: 'Group Messages',
            subtitle: 'Notifications for channel conversations',
            children: [
              _buildSwitchTile(
                title: 'Show Notifications',
                subtitle: 'System notifications for group messages',
                value: _groupMessageNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(
                          () => _groupMessageNotificationsEnabled = value,
                        );
                        await NotificationService.instance
                            .setGroupMessageNotificationsEnabled(value);
                      }
                    : null,
              ),
              if (_groupMessageNotificationsEnabled) ...[
                _buildSwitchTile(
                  title: 'Play Sound',
                  subtitle: 'Audio notification for new messages',
                  value: _groupMessageSoundsEnabled,
                  onChanged: _soundsEnabled
                      ? (value) async {
                          setState(() => _groupMessageSoundsEnabled = value);
                          await NotificationService.instance
                              .setGroupMessageSoundsEnabled(value);
                        }
                      : null,
                  indent: true,
                ),
                _buildSwitchTile(
                  title: 'Message Preview',
                  subtitle: 'Show message content in notification',
                  value: _groupMessagePreviewEnabled,
                  onChanged: (value) async {
                    setState(() => _groupMessagePreviewEnabled = value);
                    await NotificationService.instance
                        .setGroupMessagePreviewEnabled(value);
                  },
                  indent: true,
                ),
                _buildSwitchTile(
                  title: 'Only Mentions',
                  subtitle: 'Only notify when you are mentioned',
                  value: _onlyMentionsInGroups,
                  onChanged: (value) async {
                    setState(() => _onlyMentionsInGroups = value);
                    await NotificationService.instance.setOnlyMentionsInGroups(
                      value,
                    );
                  },
                  indent: true,
                ),
              ],
            ],
          ),

          const SizedBox(height: 24),

          // Activity Notifications
          _buildSection(
            title: 'Activity Notifications',
            subtitle: 'Notifications for mentions, reactions, and more',
            children: [
              _buildSwitchTile(
                title: 'Mentions',
                subtitle: 'When someone mentions you',
                value: _mentionNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(() => _mentionNotificationsEnabled = value);
                        await NotificationService.instance
                            .setMentionNotificationsEnabled(value);
                      }
                    : null,
              ),
              _buildSwitchTile(
                title: 'Reactions',
                subtitle: 'When someone reacts to your messages',
                value: _reactionNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(() => _reactionNotificationsEnabled = value);
                        await NotificationService.instance
                            .setReactionNotificationsEnabled(value);
                      }
                    : null,
              ),
              _buildSwitchTile(
                title: 'Missed Calls',
                subtitle: 'When you miss a call',
                value: _missedCallNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(() => _missedCallNotificationsEnabled = value);
                        await NotificationService.instance
                            .setMissedCallNotificationsEnabled(value);
                      }
                    : null,
              ),
              _buildSwitchTile(
                title: 'Channel Invites',
                subtitle: 'When you are added to a channel',
                value: _channelInviteNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(
                          () => _channelInviteNotificationsEnabled = value,
                        );
                        await NotificationService.instance
                            .setChannelInviteNotificationsEnabled(value);
                      }
                    : null,
              ),
              _buildSwitchTile(
                title: 'Permission Changes',
                subtitle: 'When your permissions are modified',
                value: _permissionChangeNotificationsEnabled,
                onChanged: _notificationsEnabled
                    ? (value) async {
                        setState(
                          () => _permissionChangeNotificationsEnabled = value,
                        );
                        await NotificationService.instance
                            .setPermissionChangeNotificationsEnabled(value);
                      }
                    : null,
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Do Not Disturb
          _buildSection(
            title: 'Do Not Disturb',
            subtitle: 'Temporarily silence all notifications',
            children: [
              _buildSwitchTile(
                title: 'Enable Do Not Disturb',
                subtitle: 'Mute all notifications temporarily',
                value: _dndEnabled,
                onChanged: (value) async {
                  setState(() => _dndEnabled = value);
                  await NotificationService.instance.setDndEnabled(value);
                },
              ),
              if (_dndEnabled)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: Text(
                    '🌙 Do Not Disturb is active',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.tertiary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),

          // Web-specific permission section
          if (kIsWeb) ...[
            const SizedBox(height: 24),
            _buildSection(
              title: 'Browser Permissions',
              subtitle: 'Manage notification permissions',
              children: [
                Card(
                  color: _hasPermission
                      ? colorScheme.primaryContainer
                      : colorScheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _hasPermission
                                  ? Icons.check_circle
                                  : Icons.warning,
                              color: _hasPermission
                                  ? colorScheme.primary
                                  : colorScheme.tertiary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _hasPermission
                                    ? 'Notification permission granted'
                                    : 'Notification permission required',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (!_hasPermission) ...[
                          const SizedBox(height: 12),
                          Text(
                            'To receive desktop notifications, you need to grant permission in your browser.',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _requestPermission,
                            icon: const Icon(Icons.notifications_active),
                            label: const Text('Request Permission'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 32),

          // Info card
          Card(
            color: colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: colorScheme.onSecondaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'About Notifications',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Video sounds are subtle in-app feedback only. Message and activity notifications include system notifications and sounds.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required void Function(bool)? onChanged,
    bool indent = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDisabled = onChanged == null;

    return Padding(
      padding: EdgeInsets.only(left: indent ? 16 : 0, bottom: 8),
      child: Card(
        color: colorScheme.surfaceContainerHighest,
        child: SwitchListTile(
          title: Text(
            title,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: isDisabled
                  ? theme.disabledColor
                  : theme.textTheme.bodyLarge?.color,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDisabled
                  ? theme.disabledColor
                  : theme.textTheme.bodySmall?.color,
            ),
          ),
          value: value,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
