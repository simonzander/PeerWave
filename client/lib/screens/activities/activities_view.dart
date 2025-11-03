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

  // Cache for user/channel names
  final Map<String, String> _userNames = {};
  final Map<String, String> _channelNames = {};

  @override
  void initState() {
    super.initState();
    _loadActivities();
  }

  Future<void> _loadActivities() async {
    setState(() {
      _loading = true;
    });

    try {
      // Load WebRTC channels with participants
      final webrtcChannels = await ActivitiesService.getWebRTCChannelParticipants(widget.host);
      
      // Load conversations (1:1 + Signal groups)
      await _loadMoreConversations();

      setState(() {
        _webrtcChannels = webrtcChannels.where((ch) => 
          (ch['participants'] as List?)?.isNotEmpty ?? false
        ).toList();
        _loading = false;
      });
    } catch (e) {
      print('[ACTIVITIES_VIEW] Error loading activities: $e');
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

      setState(() {
        _conversations.addAll(newConversations);
        _conversationsPage++;
        _hasMoreConversations = newConversations.length == _conversationsPerPage;
      });
    } catch (e) {
      print('[ACTIVITIES_VIEW] Error loading more conversations: $e');
    }
  }

  /// Enrich conversations with actual user/channel names from API
  Future<void> _enrichConversationsWithNames(List<Map<String, dynamic>> conversations) async {
    for (final conv in conversations) {
      if (conv['type'] == 'direct') {
        final userId = conv['userId'] as String;
        if (!_userNames.containsKey(userId)) {
          // Try to get user info from API
          try {
            ApiService.init();
            final resp = await ApiService.get('${widget.host}/people/$userId');
            if (resp.statusCode == 200) {
              final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
              _userNames[userId] = data['displayName'] ?? data['name'] ?? userId;
            } else {
              _userNames[userId] = userId;
            }
          } catch (e) {
            _userNames[userId] = userId;
          }
        }
        conv['displayName'] = _userNames[userId]!;
      } else if (conv['type'] == 'group') {
        final channelId = conv['channelId'] as String;
        if (!_channelNames.containsKey(channelId)) {
          // Try to get channel info from API
          try {
            ApiService.init();
            final resp = await ApiService.get('${widget.host}/client/channels/$channelId');
            if (resp.statusCode == 200) {
              final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
              _channelNames[channelId] = data['name'] ?? channelId;
            } else {
              _channelNames[channelId] = channelId;
            }
          } catch (e) {
            _channelNames[channelId] = channelId;
          }
        }
        conv['channelName'] = _channelNames[channelId]!;
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
                CircleAvatar(
                  backgroundColor: type == 'direct'
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.tertiaryContainer,
                  child: Icon(
                    type == 'direct' ? Icons.person : Icons.tag,
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
    
    // For group chats, get sender display name
    String? senderName;
    if (isGroupChat && !isSelf && senderUuid != null) {
      // Try to get cached sender name
      senderName = _userNames[senderUuid];
      
      // If not cached, fetch it asynchronously
      if (senderName == null) {
        _fetchUserName(senderUuid);
        senderName = senderUuid; // Fallback to UUID while loading
      }
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

  /// Fetch user display name and update state
  Future<void> _fetchUserName(String userId) async {
    if (_userNames.containsKey(userId)) return;
    
    try {
      ApiService.init();
      final resp = await ApiService.get('${widget.host}/people/$userId');
      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        setState(() {
          _userNames[userId] = data['displayName'] ?? data['name'] ?? userId;
        });
      } else {
        setState(() {
          _userNames[userId] = userId;
        });
      }
    } catch (e) {
      setState(() {
        _userNames[userId] = userId;
      });
    }
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
