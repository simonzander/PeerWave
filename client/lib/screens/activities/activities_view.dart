import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../services/activities_service.dart';
import '../../services/api_service.dart';
import '../../services/event_bus.dart';
import '../../services/storage/sqlite_group_message_store.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../providers/unread_messages_provider.dart';
import '../../app/views/people_context_data_loader.dart';
import 'dart:convert';
import 'dart:async';

/// Activities View - Shows notifications and recent conversations
class ActivitiesView extends StatefulWidget {
  final String host;
  final Function(String uuid, String displayName)? onDirectMessageTap;
  final Function(String uuid, String name, String type)? onChannelTap;

  const ActivitiesView({
    super.key,
    required this.host,
    this.onDirectMessageTap,
    this.onChannelTap,
  });

  @override
  State<ActivitiesView> createState() => _ActivitiesViewState();
}

class _ActivitiesViewState extends State<ActivitiesView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = true;
  List<Map<String, dynamic>> _webrtcChannels = [];
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _notifications = [];
  int _conversationsPage = 0;
  static const int _conversationsPerPage = 20;
  bool _hasMoreConversations = true;
  StreamSubscription? _notificationSubscription;

  // Cache for user/channel info (store full objects for avatars, @names, etc.)
  final Map<String, Map<String, dynamic>> _userInfo = {};
  final Map<String, Map<String, dynamic>> _channelInfo = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadActivities();
    _loadNotifications();

    // Listen for new notifications
    _notificationSubscription = EventBus.instance
        .on<Map<String, dynamic>>(AppEvent.newNotification)
        .listen((data) {
          debugPrint('[ACTIVITIES_VIEW] New notification received');
          _loadNotifications();
        });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _notificationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadNotifications() async {
    try {
      final groupMessageStore = await SqliteGroupMessageStore.getInstance();
      final dmMessageStore = await SqliteMessageStore.getInstance();

      // Load notifications from both group and DM storage
      final groupNotifs = await groupMessageStore.getNotificationMessages(
        limit: 100,
      );
      final dmNotifs = await dmMessageStore.getNotificationMessages(limit: 100);

      // Parse notification messages to extract metadata
      final parsedNotifs = <Map<String, dynamic>>[];
      for (final notif in [...groupNotifs, ...dmNotifs]) {
        final parsed = Map<String, dynamic>.from(notif);

        // Try to parse JSON from message field for mention/emote notifications
        if (notif['message'] != null &&
            notif['message'].toString().isNotEmpty) {
          try {
            final messageData = jsonDecode(notif['message']);
            if (messageData is Map<String, dynamic>) {
              // Extract messageId for navigation
              parsed['targetMessageId'] = messageData['messageId'];

              // For emote reactions, fetch the original message content
              if (notif['type'] == 'emote' &&
                  messageData['messageId'] != null) {
                parsed['emoji'] = messageData['emoji'];
                parsed['action'] = messageData['action'];

                // Fetch the original message being reacted to
                try {
                  final targetMessageId = messageData['messageId'] as String;
                  Map<String, dynamic>? originalMessage;

                  if (notif['channelId'] != null) {
                    // Group message - need channelId to fetch
                    final channelId = notif['channelId'] as String;
                    originalMessage = await groupMessageStore.getGroupItem(
                      channelId,
                      targetMessageId,
                    );
                  } else {
                    // DM
                    originalMessage = await dmMessageStore.getMessage(
                      targetMessageId,
                    );
                  }

                  if (originalMessage != null &&
                      originalMessage['message'] != null) {
                    // Get first 50 characters of original message
                    final originalContent = originalMessage['message']
                        .toString();
                    parsed['originalMessageContent'] =
                        originalContent.length > 50
                        ? '${originalContent.substring(0, 50)}...'
                        : originalContent;
                  }
                } catch (e) {
                  debugPrint(
                    '[ACTIVITIES_VIEW] Error fetching original message: $e',
                  );
                }
              }

              // Extract content for display
              if (messageData['content'] != null) {
                parsed['content'] = messageData['content'];
              }
              // Preserve other metadata
              parsed['notificationData'] = messageData;
            }
          } catch (e) {
            // Not JSON or invalid - use raw message as content
            parsed['content'] = notif['message'].toString();
          }
        }

        parsedNotifs.add(parsed);
      }

      // Sort by timestamp
      parsedNotifs.sort((a, b) {
        final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.now();
        final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.now();
        return bTime.compareTo(aTime); // Newest first
      });

      // Enrich notifications with sender user info
      await _enrichNotificationsWithUserInfo(parsedNotifs);

      if (!mounted) return;

      setState(() {
        _notifications = parsedNotifs;
      });

      debugPrint(
        '[ACTIVITIES_VIEW] Loaded ${_notifications.length} notifications',
      );
    } catch (e) {
      debugPrint('[ACTIVITIES_VIEW] Error loading notifications: $e');
    }
  }

  /// Enrich notifications with sender user info (BATCH OPTIMIZED)
  Future<void> _enrichNotificationsWithUserInfo(
    List<Map<String, dynamic>> notifications,
  ) async {
    // Collect all uncached sender IDs
    final senderIds = notifications
        .map((n) => n['sender'] as String?)
        .where((id) => id != null && !_userInfo.containsKey(id))
        .cast<String>()
        .toSet()
        .toList();

    // Batch fetch all user info in one request
    if (senderIds.isNotEmpty) {
      try {
        ApiService.init();
        final resp = await ApiService.post(
          '${widget.host}/client/people/info',
          data: {'userIds': senderIds},
        );

        if (resp.statusCode == 200) {
          final users = resp.data is List ? resp.data : [];
          for (final user in users) {
            _userInfo[user['uuid']] = {
              'displayName': user['displayName'] ?? user['uuid'],
              'picture': user['picture'] ?? '',
              'atName': user['atName'] ?? '',
            };
          }
          debugPrint('[ACTIVITIES_VIEW] Fetched user info for ${users.length} senders');
        }
      } catch (e) {
        debugPrint('[ACTIVITIES_VIEW] Error batch fetching user info for notifications: $e');
        // Fallback: cache missing users with UUID as displayName
        for (final senderId in senderIds) {
          _userInfo[senderId] = {
            'displayName': senderId,
            'picture': '',
            'atName': '',
          };
        }
      }
    }
  }

  Future<void> _markNotificationAsRead(String itemId, String? channelId) async {
    try {
      final unreadProvider = Provider.of<UnreadMessagesProvider>(
        context,
        listen: false,
      );

      if (channelId != null) {
        // Group notification
        final groupMessageStore = await SqliteGroupMessageStore.getInstance();
        await groupMessageStore.markNotificationAsRead(itemId);
      } else {
        // DM notification
        final dmMessageStore = await SqliteMessageStore.getInstance();
        await dmMessageStore.markNotificationAsRead(itemId);
      }

      // Update unread counter
      unreadProvider.markActivityNotificationAsRead(itemId);

      // Reload notifications to reflect the change
      await _loadNotifications();

      debugPrint('[ACTIVITIES_VIEW] Marked notification as read: $itemId');
    } catch (e) {
      debugPrint('[ACTIVITIES_VIEW] Error marking notification as read: $e');
    }
  }

  Future<void> _markAllNotificationsAsRead() async {
    try {
      final unreadProvider = Provider.of<UnreadMessagesProvider>(
        context,
        listen: false,
      );
      final groupMessageStore = await SqliteGroupMessageStore.getInstance();
      final dmMessageStore = await SqliteMessageStore.getInstance();

      // Mark all as read in storage
      await groupMessageStore.markAllNotificationsAsRead();
      await dmMessageStore.markAllNotificationsAsRead();

      // Clear all from unread counter
      unreadProvider.markAllActivityNotificationsAsRead();

      // Reload notifications
      await _loadNotifications();

      debugPrint('[ACTIVITIES_VIEW] Marked all notifications as read');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All notifications marked as read')),
        );
      }
    } catch (e) {
      debugPrint(
        '[ACTIVITIES_VIEW] Error marking all notifications as read: $e',
      );
    }
  }

  Future<void> _loadActivities() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
    });

    try {
      // Load WebRTC channels with participants
      final webrtcChannels =
          await ActivitiesService.getWebRTCChannelParticipants(widget.host);

      // Load conversations (1:1 + Signal groups)
      await _loadMoreConversations();

      // Batch fetch sender names for all messages in conversations
      await _fetchSenderNamesForConversations();

      if (!mounted) return;

      setState(() {
        _webrtcChannels = webrtcChannels
            .where((ch) => (ch['participants'] as List?)?.isNotEmpty ?? false)
            .toList();
        _loading = false;
      });
    } catch (e) {
      debugPrint('[ACTIVITIES_VIEW] Error loading activities: $e');
      if (!mounted) return;

      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreConversations() async {
    try {
      // Load direct and group conversations
      final directConvs = await ActivitiesService.getRecentDirectConversations(
        limit: _conversationsPerPage,
      );
      final groupConvs = await ActivitiesService.getRecentGroupConversations(
        widget.host,
        limit: _conversationsPerPage,
      );

      // Mix and sort
      final mixed = ActivitiesService.mixAndSortConversations(
        directConvs,
        groupConvs,
        limit: _conversationsPerPage * (_conversationsPage + 1),
      );

      // Skip already loaded conversations
      final newConversations = mixed.skip(_conversations.length).toList();

      // Enrich with names
      await _enrichConversationsWithNames(newConversations);

      if (!mounted) return;

      setState(() {
        _conversations.addAll(newConversations);
        _conversationsPage++;
        _hasMoreConversations =
            newConversations.length == _conversationsPerPage;
      });
    } catch (e) {
      debugPrint('[ACTIVITIES_VIEW] Error loading more conversations: $e');
    }
  }

  /// Enrich conversations with actual user/channel names from API (BATCH OPTIMIZED)
  Future<void> _enrichConversationsWithNames(
    List<Map<String, dynamic>> conversations,
  ) async {
    // Collect all uncached user IDs
    final userIds = conversations
        .where((c) => c['type'] == 'direct')
        .map((c) => c['userId'] as String)
        .where((id) => !_userInfo.containsKey(id))
        .toList();

    // Batch fetch all user info in one request
    if (userIds.isNotEmpty) {
      try {
        ApiService.init();
        final resp = await ApiService.post(
          '${widget.host}/client/people/info',
          data: {'userIds': userIds},
        );

        if (resp.statusCode == 200) {
          final users = resp.data is List ? resp.data : [];
          for (final user in users) {
            _userInfo[user['uuid']] = {
              'displayName': user['displayName'] ?? user['uuid'],
              'picture': user['picture'] ?? '',
              'atName': user['atName'] ?? '',
            };
          }
        }
      } catch (e) {
        debugPrint('[ACTIVITIES_VIEW] Error batch fetching user info: $e');
        // Fallback: cache missing users with UUID as displayName
        for (final userId in userIds) {
          _userInfo[userId] = {
            'displayName': userId,
            'picture': '',
            'atName': '',
          };
        }
      }
    }

    // Collect all uncached channel IDs
    final channelIds = conversations
        .where((c) => c['type'] == 'group')
        .map((c) => c['channelId'] as String)
        .where((id) => !_channelInfo.containsKey(id))
        .toList();

    // Batch fetch all channel info in one request
    if (channelIds.isNotEmpty) {
      try {
        ApiService.init();
        final resp = await ApiService.post(
          '${widget.host}/client/channels/info',
          data: {'channelIds': channelIds},
        );

        if (resp.statusCode == 200) {
          final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
          final channels = data['channels'] as List? ?? [];
          for (final channel in channels) {
            _channelInfo[channel['uuid']] = {
              'name': channel['name'] ?? channel['uuid'],
              'description': channel['description'] ?? '',
              'private': channel['private'] ?? false,
              'type': channel['type'] ?? 'signal',
            };
          }
        }
      } catch (e) {
        debugPrint('[ACTIVITIES_VIEW] Error batch fetching channel info: $e');
        // Fallback: cache missing channels with UUID as name
        for (final channelId in channelIds) {
          _channelInfo[channelId] = {
            'name': channelId,
            'description': '',
            'private': false,
            'type': 'signal',
          };
        }
      }
    }

    // Apply cached info to conversations
    for (final conv in conversations) {
      if (conv['type'] == 'direct') {
        final userId = conv['userId'] as String;
        final userInfo =
            _userInfo[userId] ??
            {'displayName': userId, 'picture': '', 'atName': ''};
        conv['displayName'] = userInfo['displayName'];
        conv['picture'] = userInfo['picture'];
        conv['atName'] = userInfo['atName'];
      } else if (conv['type'] == 'group') {
        final channelId = conv['channelId'] as String;
        final channelInfo =
            _channelInfo[channelId] ??
            {
              'name': channelId,
              'description': '',
              'private': false,
              'type': 'signal',
            };
        conv['channelName'] = channelInfo['name'];
        conv['channelDescription'] = channelInfo['description'];
        conv['channelPrivate'] = channelInfo['private'];
        conv['channelType'] = channelInfo['type'];
      }
    }
  }

  /// Batch fetch sender names for all messages in conversations
  Future<void> _fetchSenderNamesForConversations() async {
    final senderIds = <String>{};

    // Collect all unique sender IDs from all messages
    for (final conv in _conversations) {
      final messages = (conv['lastMessages'] as List?) ?? [];
      for (final msg in messages) {
        final sender = msg['sender'] as String?;
        if (sender != null &&
            sender != 'self' &&
            !_userInfo.containsKey(sender)) {
          senderIds.add(sender);
        }
      }
    }

    // Batch fetch all at once
    if (senderIds.isNotEmpty) {
      try {
        ApiService.init();
        final resp = await ApiService.post(
          '${widget.host}/client/people/info',
          data: {'userIds': senderIds.toList()},
        );

        if (resp.statusCode == 200) {
          final users = resp.data is List ? resp.data : [];
          if (!mounted) return;

          setState(() {
            for (final user in users) {
              _userInfo[user['uuid']] = {
                'displayName': user['displayName'] ?? user['uuid'],
                'picture': user['picture'] ?? '',
                'atName': user['atName'] ?? '',
              };
            }
          });
        }
      } catch (e) {
        debugPrint('[ACTIVITIES_VIEW] Error batch fetching sender names: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show tabs with notifications and recent activities
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activities'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Notifications', icon: Icon(Icons.notifications)),
            Tab(text: 'Recent', icon: Icon(Icons.history)),
          ],
        ),
        actions: [
          // Show "mark all as read" button only on notifications tab
          if (_tabController.index == 0 && _notifications.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.done_all),
              onPressed: _markAllNotificationsAsRead,
              tooltip: 'Mark all as read',
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildNotificationsTab(), _buildRecentActivitiesTab()],
      ),
    );
  }

  Widget _buildNotificationsTab() {
    if (_notifications.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.notifications_none, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No notifications',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _notifications.length,
      itemBuilder: (context, index) {
        final notification = _notifications[index];
        return _buildNotificationItem(notification);
      },
    );
  }

  Widget _buildRecentActivitiesTab() {
    if (_loading && _conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () async {
        if (!mounted) return;

        setState(() {
          _conversations.clear();
          _conversationsPage = 0;
          _hasMoreConversations = true;
        });
        await _loadActivities();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // WebRTC Channels Section
          if (_webrtcChannels.isNotEmpty) ...[
            _buildSectionHeader('Active Video Channels', Icons.videocam),
            const SizedBox(height: 12),
            ..._webrtcChannels.map(
              (channel) => _buildWebRTCChannelCard(channel),
            ),
            const SizedBox(height: 24),
          ],

          // Recent Conversations Section
          _buildSectionHeader(
            'Recent Conversations',
            Icons.chat_bubble_outline,
          ),
          const SizedBox(height: 12),

          if (_conversations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32.0),
              child: Center(
                child: Text(
                  'No recent conversations',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            ..._conversations.map((conv) => _buildConversationCard(conv)),

          // Load More Button
          if (_hasMoreConversations)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              child: Center(
                child: ElevatedButton.icon(
                  onPressed: _loadMoreConversations,
                  icon: const Icon(Icons.expand_more),
                  label: const Text('Load More'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildWebRTCChannelCard(Map<String, dynamic> channel) {
    final participants = (channel['participants'] as List?) ?? [];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.videocam,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          channel['name'] ?? 'Unknown Channel',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${participants.length} ${participants.length == 1 ? 'participant' : 'participants'}',
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () {
          if (widget.onChannelTap != null) {
            widget.onChannelTap!(
              channel['uuid'],
              channel['name'] ?? 'Unknown',
              'webrtc',
            );
          }
        },
      ),
    );
  }

  Widget _buildConversationCard(Map<String, dynamic> conv) {
    final lastMessages = (conv['lastMessages'] as List?) ?? [];
    final type = conv['type'] as String;
    final title = type == 'direct'
        ? (conv['displayName'] ?? 'Unknown User')
        : (conv['channelName'] ?? 'Unknown Channel');

    // Get additional info
    final picture = type == 'direct' ? (conv['picture'] as String? ?? '') : '';
    final atName = type == 'direct' ? (conv['atName'] as String? ?? '') : '';
    final channelDescription = type == 'group'
        ? (conv['channelDescription'] as String? ?? '')
        : '';
    final isPrivate = type == 'group'
        ? (conv['channelPrivate'] as bool? ?? false)
        : false;

    // Subtitle text
    final subtitle = type == 'direct'
        ? (atName.isNotEmpty ? '@$atName' : '')
        : (channelDescription.isNotEmpty ? channelDescription : '');

    // Ensure we show at least 3 messages, or all if less than 3
    final messagesToShow = lastMessages.length >= 3
        ? lastMessages.take(3).toList()
        : lastMessages;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                // Avatar with picture support
                type == 'direct' && picture.isNotEmpty
                    ? CircleAvatar(
                        backgroundImage: NetworkImage('${widget.host}$picture'),
                        onBackgroundImageError: (_, __) {
                          // Fallback handled by error widget
                        },
                      )
                    : CircleAvatar(
                        backgroundColor: type == 'direct'
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : Theme.of(context).colorScheme.tertiaryContainer,
                        child: Icon(
                          type == 'direct'
                              ? Icons.person
                              : (isPrivate ? Icons.lock : Icons.tag),
                          color: type == 'direct'
                              ? Theme.of(
                                  context,
                                ).colorScheme.onSecondaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.onTertiaryContainer,
                        ),
                      ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      Text(
                        _formatLastMessageTime(conv['lastMessageTime'] ?? ''),
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  onPressed: () {
                    if (type == 'direct' && widget.onDirectMessageTap != null) {
                      widget.onDirectMessageTap!(conv['userId'], title);
                    } else if (type == 'group' && widget.onChannelTap != null) {
                      widget.onChannelTap!(conv['channelId'], title, 'signal');
                    }
                  },
                ),
              ],
            ),

            // Messages
            if (messagesToShow.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              ...messagesToShow.map(
                (msg) => _buildMessagePreview(msg, type == 'group'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMessagePreview(Map<String, dynamic> msg, bool isGroupChat) {
    final isSelf = msg['sender'] == 'self';
    final messageContent = msg['message'] as String? ?? '';
    final messageType = msg['type'] as String? ?? 'message';
    final timestamp = _formatMessageTime(msg['timestamp'] ?? '');
    final senderUuid = msg['sender'] as String?;

    // Format message with type icon
    final formattedMessage = PeopleContextDataLoader.formatMessagePreview(messageType, messageContent);

    // For group chats, get sender display name from cache
    String? senderName;
    if (isGroupChat && !isSelf && senderUuid != null) {
      final userInfo = _userInfo[senderUuid];
      senderName = userInfo?['displayName'] ?? senderUuid;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSelf ? Icons.arrow_forward : Icons.arrow_back,
            size: 16,
            color: isSelf ? Colors.blue : Colors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Show sender name for group chats
                if (isGroupChat && senderName != null) ...[
                  Text(
                    senderName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  formattedMessage.length > 150
                      ? '${formattedMessage.substring(0, 150)}...'
                      : formattedMessage,
                  style: const TextStyle(fontSize: 14),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  timestamp,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatLastMessageTime(String timestamp) {
    try {
      final time = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(time);

      if (diff.inMinutes < 1) {
        return 'Just now';
      } else if (diff.inMinutes < 60) {
        return '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        return '${diff.inHours}h ago';
      } else if (diff.inDays < 7) {
        return '${diff.inDays}d ago';
      } else {
        return '${time.day}/${time.month}/${time.year}';
      }
    } catch (e) {
      return '';
    }
  }

  String _formatMessageTime(String timestamp) {
    try {
      final time = DateTime.parse(timestamp);
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return '';
    }
  }

  Widget _buildNotificationItem(Map<String, dynamic> notification) {
    final type = notification['type'] ?? '';
    final sender = notification['sender'] ?? '';
    final timestamp = notification['timestamp'] ?? '';
    final content = notification['content'] ?? '';

    // Get type-specific icon and title
    IconData icon;
    String title;
    String subtitle = '';

    switch (type) {
      case 'emote':
        icon = Icons.emoji_emotions;
        // Get sender name
        final senderInfo = _userInfo[sender];
        final senderName = senderInfo?['displayName'] ?? 'Someone';
        final emoji = notification['emoji'] ?? '👍';
        final originalMsg = notification['originalMessageContent'];

        title = '$senderName reacted $emoji';
        if (originalMsg != null && originalMsg.isNotEmpty) {
          subtitle = 'to: $originalMsg';
        } else {
          subtitle = 'to your message';
        }
        break;
      case 'mention':
        icon = Icons.alternate_email;
        title = 'You were mentioned';
        subtitle = content.isNotEmpty ? content : 'Mentioned you in a message';
        break;
      case 'missingcall':
        icon = Icons.phone_missed;
        title = 'Missed Call';
        subtitle = 'You missed a call';
        break;
      case 'addtochannel':
        icon = Icons.person_add;
        title = 'Added to Channel';
        subtitle = 'You were added to a channel';
        break;
      case 'removefromchannel':
        icon = Icons.person_remove;
        title = 'Removed from Channel';
        subtitle = 'You were removed from a channel';
        break;
      case 'permissionchange':
        icon = Icons.admin_panel_settings;
        title = 'Permission Changed';
        subtitle = 'Your permissions were updated';
        break;
      default:
        icon = Icons.notifications;
        title = 'Notification';
        subtitle = content;
    }

    // Format timestamp
    String timeAgo = '';
    try {
      final time = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(time);

      if (difference.inMinutes < 1) {
        timeAgo = 'Just now';
      } else if (difference.inHours < 1) {
        timeAgo = '${difference.inMinutes}m ago';
      } else if (difference.inDays < 1) {
        timeAgo = '${difference.inHours}h ago';
      } else if (difference.inDays < 7) {
        timeAgo = '${difference.inDays}d ago';
      } else {
        timeAgo = '${(difference.inDays / 7).floor()}w ago';
      }
    } catch (e) {
      timeAgo = '';
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            icon,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle.isNotEmpty) Text(subtitle),
            if (timeAgo.isNotEmpty)
              Text(
                timeAgo,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
          ],
        ),
        onTap: () => _handleNotificationTap(notification),
      ),
    );
  }

  Future<void> _handleNotificationTap(Map<String, dynamic> notification) async {
    final type = notification['type'] ?? '';
    final itemId = notification['itemId'] ?? '';
    final channelId = notification['channelId'];
    final sender = notification['sender'];
    final targetMessageId =
        notification['targetMessageId']; // Extracted from JSON

    // Mark as read
    await _markNotificationAsRead(itemId, channelId);

    // Navigate based on type
    if (!mounted) return;

    switch (type) {
      case 'mention':
      case 'emote':
        // Navigate to conversation with messageId for scrolling
        if (channelId != null) {
          // Group channel - navigate using go_router
          final channelInfoData = _channelInfo[channelId];
          final channelName = channelInfoData?['name'] ?? 'Unknown';
          final channelType = channelInfoData?['type'] ?? 'public';

          context.go(
            '/app/channels/$channelId',
            extra: {
              'host': widget.host,
              'name': channelName,
              'type': channelType,
              if (targetMessageId != null) 'scrollToMessageId': targetMessageId,
            },
          );
        } else if (sender != null) {
          // Direct message - navigate using go_router
          final userInfoData = _userInfo[sender];
          final displayName = userInfoData?['displayName'] ?? 'Unknown';

          context.go(
            '/app/messages/$sender',
            extra: {
              'host': widget.host,
              'displayName': displayName,
              if (targetMessageId != null) 'scrollToMessageId': targetMessageId,
            },
          );
        }
        break;

      case 'missingcall':
        // Navigate to user or channel
        if (channelId != null) {
          final channelInfoData = _channelInfo[channelId];
          final channelName = channelInfoData?['name'] ?? 'Unknown';
          final channelType = channelInfoData?['type'] ?? 'public';

          context.go(
            '/app/channels/$channelId',
            extra: {
              'host': widget.host,
              'name': channelName,
              'type': channelType,
            },
          );
        } else if (sender != null) {
          final userInfoData = _userInfo[sender];
          final displayName = userInfoData?['displayName'] ?? 'Unknown';

          context.go(
            '/app/messages/$sender',
            extra: {'host': widget.host, 'displayName': displayName},
          );
        }
        break;

      case 'addtochannel':
      case 'removefromchannel':
      case 'permissionchange':
        // Navigate to channel
        if (channelId != null) {
          final channelInfoData = _channelInfo[channelId];
          final channelName = channelInfoData?['name'] ?? 'Unknown';
          final channelType = channelInfoData?['type'] ?? 'public';

          context.go(
            '/app/channels/$channelId',
            extra: {
              'host': widget.host,
              'name': channelName,
              'type': channelType,
            },
          );
        }
        break;
    }
  }
}
