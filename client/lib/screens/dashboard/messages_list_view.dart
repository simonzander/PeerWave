import 'package:flutter/material.dart';
import '../../services/signal_service.dart';
import '../../services/api_service.dart';
import '../../widgets/user_avatar.dart';
import '../../providers/unread_messages_provider.dart';
import '../../widgets/unread_badge.dart';
import 'package:provider/provider.dart';

/// Messages List View - Shows recent 1:1 conversations
class MessagesListView extends StatefulWidget {
  final String host;
  final Function(String uuid, String displayName) onMessageTap;
  final VoidCallback onNavigateToPeople;

  const MessagesListView({
    super.key,
    required this.host,
    required this.onMessageTap,
    required this.onNavigateToPeople,
  });

  @override
  State<MessagesListView> createState() => _MessagesListViewState();
}

class _MessagesListViewState extends State<MessagesListView> {
  bool _loading = true;
  List<Map<String, dynamic>> _conversations = [];
  int _limit = 20;

  // Cache for user info (store full objects)
  final Map<String, Map<String, dynamic>> _userCache = {};

  @override
  void initState() {
    super.initState();
    _loadConversations();
  }

  Future<void> _loadConversations() async {
    setState(() {
      _loading = true;
    });

    try {
      final conversations = <Map<String, dynamic>>[];
      final userIdsSet = <String>{};
      
      // Get all unique senders from received messages (IndexedDB/secure storage)
      final receivedSenders = await SignalService.instance.decryptedMessagesStore.getAllUniqueSenders();
      userIdsSet.addAll(receivedSenders);
      
      // Get all sent messages to find unique recipient IDs (IndexedDB/secure storage)
      final allSentMessages = await SignalService.instance.sentMessagesStore.loadAllSentMessages();
      for (final msg in allSentMessages) {
        final recipientId = msg['recipientId'] as String?;
        if (recipientId != null) {
          userIdsSet.add(recipientId);
        }
      }
      
      // Get messages for each unique user
      for (final userId in userIdsSet) {
        // Get received messages from this user
        final receivedMessages = await SignalService.instance.decryptedMessagesStore.getMessagesFromSender(userId);
        
        // Get sent messages to this user
        final sentMessages = await SignalService.instance.loadSentMessages(userId);
        
        // Combine and convert sent messages to same format
        final allMessages = <Map<String, dynamic>>[
          ...receivedMessages,
          ...sentMessages.map((msg) => {
            'itemId': msg['itemId'],
            'message': msg['message'],
            'timestamp': msg['timestamp'],
            'sender': 'self',
            'type': msg['type'] ?? 'message',
          }),
        ];
        
        if (allMessages.isEmpty) continue;
        
        // Sort by timestamp (newest first)
        allMessages.sort((a, b) {
          final timeA = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeB.compareTo(timeA);
        });
        
        // Get last message
        final lastMessages = allMessages.take(1).toList();
        final lastMessageTime = allMessages.isNotEmpty
            ? DateTime.tryParse(allMessages.first['timestamp'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(0);
        
        conversations.add({
          'userId': userId,
          'displayName': userId, // Will be enriched with actual name
          'lastMessages': lastMessages,
          'lastMessageTime': lastMessageTime.toIso8601String(),
          'messageCount': allMessages.length,
        });
      }
      
      // Sort by last message time
      conversations.sort((a, b) {
        final timeA = DateTime.tryParse(a['lastMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final timeB = DateTime.tryParse(b['lastMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA);
      });
      
      // Limit to requested amount
      final limitedConversations = conversations.take(_limit).toList();

      // Enrich with user info
      await _enrichWithUserInfo(limitedConversations);

      setState(() {
        _conversations = limitedConversations;
        _loading = false;
      });
    } catch (e) {
      print('[MESSAGES_LIST] Error loading conversations: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _enrichWithUserInfo(List<Map<String, dynamic>> conversations) async {
    // Collect all user IDs that need to be fetched
    final userIdsToFetch = conversations
        .map((conv) => conv['userId'] as String)
        .where((userId) => !_userCache.containsKey(userId))
        .toList();

    // Batch fetch all user info in one request
    if (userIdsToFetch.isNotEmpty) {
      try {
        ApiService.init();
        final resp = await ApiService.post(
          '${widget.host}/client/people/info',
          data: {'userIds': userIdsToFetch},
        );
        
        if (resp.statusCode == 200) {
          final users = resp.data is List ? resp.data : [];
          for (final user in users) {
            _userCache[user['uuid']] = {
              'displayName': user['displayName'] ?? user['uuid'],
              'picture': user['picture'] ?? '',
              'atName': user['atName'] ?? '',
            };
          }
        }
      } catch (e) {
        print('[MESSAGES_LIST] Error batch fetching user info: $e');
        // Fallback: cache missing users with UUID as displayName
        for (final userId in userIdsToFetch) {
          _userCache[userId] = {
            'displayName': userId,
            'picture': '',
            'atName': '',
          };
        }
      }
    }
    
    // Apply cached info to conversations
    for (final conv in conversations) {
      final userId = conv['userId'] as String;
      final userInfo = _userCache[userId] ?? {
        'displayName': userId,
        'picture': '',
        'atName': '',
      };
      conv['displayName'] = userInfo['displayName'];
      conv['picture'] = userInfo['picture'];
      conv['atName'] = userInfo['atName'];
    }
  }

  void _loadMore() {
    setState(() {
      _limit += 20;
    });
    _loadConversations();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        automaticallyImplyLeading: false,
      ),
      body: _loading && _conversations.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadConversations,
              child: _conversations.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      itemCount: _conversations.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _conversations.length) {
                          return _buildLoadMoreButton();
                        }
                        return _buildConversationTile(_conversations[index]);
                      },
                    ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: widget.onNavigateToPeople,
        tooltip: 'Start New Conversation',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.message_outlined,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'No conversations yet',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to start a conversation',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationTile(Map<String, dynamic> conv) {
    final displayName = conv['displayName'] as String? ?? 'Unknown User';
    final picture = conv['picture'] as String? ?? '';
    final atName = conv['atName'] as String? ?? '';
    final lastMessages = (conv['lastMessages'] as List?) ?? [];
    final lastMessage = lastMessages.isNotEmpty
        ? (lastMessages.first['message'] as String? ?? '')
        : 'No messages';
    final lastMessageTime = conv['lastMessageTime'] as String? ?? '';
    final userId = conv['userId'] as String;

    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, _) {
        final unreadCount = unreadProvider.getDirectMessageUnreadCount(userId);
        
        return ListTile(
          leading: UserAvatar(
            userId: userId,
            displayName: displayName,
            pictureData: picture,
            size: 48,
          ),
          title: Text(
            displayName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (atName.isNotEmpty)
                Text(
                  '@$atName',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              Text(
                lastMessage.length > 50
                    ? '${lastMessage.substring(0, 50)}...'
                    : lastMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unreadCount > 0) ...[
                UnreadBadge(count: unreadCount, isSmall: true),
                const SizedBox(width: 8),
              ],
              Text(
                _formatTime(lastMessageTime),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
          onTap: () {
            widget.onMessageTap(userId, displayName);
          },
        );
      },
    );
  }

  Widget _buildLoadMoreButton() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: ElevatedButton.icon(
          onPressed: _loadMore,
          icon: const Icon(Icons.expand_more),
          label: const Text('Load More'),
        ),
      ),
    );
  }

  String _formatTime(String timestamp) {
    try {
      final time = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(time);

      if (diff.inMinutes < 1) {
        return 'Now';
      } else if (diff.inMinutes < 60) {
        return '${diff.inMinutes}m';
      } else if (diff.inHours < 24) {
        return '${diff.inHours}h';
      } else if (diff.inDays < 7) {
        return '${diff.inDays}d';
      } else {
        return '${time.day}/${time.month}';
      }
    } catch (e) {
      return '';
    }
  }
}
