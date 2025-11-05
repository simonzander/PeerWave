import 'package:flutter/material.dart';
import '../../services/activities_service.dart';
import '../../services/api_service.dart';
import 'dart:convert';

/// Activities View - Shows WebRTC participants and recent conversations
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

class _ActivitiesViewState extends State<ActivitiesView> {
  bool _loading = true;
  List<Map<String, dynamic>> _webrtcChannels = [];
  List<Map<String, dynamic>> _conversations = [];
  int _conversationsPage = 0;
  static const int _conversationsPerPage = 20;
  bool _hasMoreConversations = true;

  // Cache for user/channel info (store full objects for avatars, @names, etc.)
  final Map<String, Map<String, dynamic>> _userInfo = {};
  final Map<String, Map<String, dynamic>> _channelInfo = {};

  @override
  void initState() {
    super.initState();
    _loadActivities();
  }

  Future<void> _loadActivities() async {
    if (!mounted) return;
    
    setState(() {
      _loading = true;
    });

    try {
      // Load WebRTC channels with participants
      final webrtcChannels = await ActivitiesService.getWebRTCChannelParticipants(widget.host);
      
      // Load conversations (1:1 + Signal groups)
      await _loadMoreConversations();

      // Batch fetch sender names for all messages in conversations
      await _fetchSenderNamesForConversations();

      if (!mounted) return;
      
      setState(() {
        _webrtcChannels = webrtcChannels.where((ch) => 
          (ch['participants'] as List?)?.isNotEmpty ?? false
        ).toList();
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
        _hasMoreConversations = newConversations.length == _conversationsPerPage;
      });
    } catch (e) {
      debugPrint('[ACTIVITIES_VIEW] Error loading more conversations: $e');
    }
  }

  /// Enrich conversations with actual user/channel names from API (BATCH OPTIMIZED)
  Future<void> _enrichConversationsWithNames(List<Map<String, dynamic>> conversations) async {
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
        final userInfo = _userInfo[userId] ?? {
          'displayName': userId,
          'picture': '',
          'atName': '',
        };
        conv['displayName'] = userInfo['displayName'];
        conv['picture'] = userInfo['picture'];
        conv['atName'] = userInfo['atName'];
      } else if (conv['type'] == 'group') {
        final channelId = conv['channelId'] as String;
        final channelInfo = _channelInfo[channelId] ?? {
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
        if (sender != null && sender != 'self' && !_userInfo.containsKey(sender)) {
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
    if (_loading && _conversations.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(),
      );
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
            ..._webrtcChannels.map((channel) => _buildWebRTCChannelCard(channel)),
            const SizedBox(height: 24),
          ],

          // Recent Conversations Section
          _buildSectionHeader('Recent Conversations', Icons.chat_bubble_outline),
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
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
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
    final channelDescription = type == 'group' ? (conv['channelDescription'] as String? ?? '') : '';
    final isPrivate = type == 'group' ? (conv['channelPrivate'] as bool? ?? false) : false;
    
    // Subtitle text
    final subtitle = type == 'direct'
        ? (atName.isNotEmpty ? '@$atName' : '')
        : (channelDescription.isNotEmpty ? channelDescription : '');
    
    // Ensure we show at least 3 messages, or all if less than 3
    final messagesToShow = lastMessages.length >= 3 ? lastMessages.take(3).toList() : lastMessages;
    
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
                              ? Theme.of(context).colorScheme.onSecondaryContainer
                              : Theme.of(context).colorScheme.onTertiaryContainer,
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
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  onPressed: () {
                    if (type == 'direct' && widget.onDirectMessageTap != null) {
                      widget.onDirectMessageTap!(
                        conv['userId'],
                        title,
                      );
                    } else if (type == 'group' && widget.onChannelTap != null) {
                      widget.onChannelTap!(
                        conv['channelId'],
                        title,
                        'signal',
                      );
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
              ...messagesToShow.map((msg) => _buildMessagePreview(msg, type == 'group')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMessagePreview(Map<String, dynamic> msg, bool isGroupChat) {
    final isSelf = msg['sender'] == 'self';
    final message = msg['message'] as String? ?? '';
    final timestamp = _formatMessageTime(msg['timestamp'] ?? '');
    final senderUuid = msg['sender'] as String?;
    
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
                  message.length > 150 ? '${message.substring(0, 150)}...' : message,
                  style: const TextStyle(fontSize: 14),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  timestamp,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                  ),
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
}

