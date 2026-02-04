import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/api_service.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/storage/sqlite_recent_conversations_store.dart';
import '../../services/starred_conversations_service.dart';
import '../../widgets/user_avatar.dart';
import '../../providers/unread_messages_provider.dart';
import '../../providers/navigation_state_provider.dart';
import '../../widgets/animated_widgets.dart';
import '../../widgets/people_context_panel.dart';
import '../../services/recent_conversations_service.dart';
import '../../theme/app_theme_constants.dart';
import 'package:provider/provider.dart';
import '../../services/event_bus.dart';

/// Messages List View - Shows recent 1:1 conversations
class MessagesListView extends StatefulWidget {
  final Function(String uuid, String displayName) onMessageTap;
  final VoidCallback onNavigateToPeople;

  const MessagesListView({
    super.key,
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

  // Context panel state
  List<Map<String, dynamic>> _recentPeople = [];
  bool _isLoadingRecentPeople = false;
  int _recentPeopleLimit = 10;
  bool _hasMoreRecentPeople = true;

  @override
  void initState() {
    super.initState();
    _initializeStarredService();
    _loadConversations();
    _loadRecentPeople();
  }

  Future<void> _initializeStarredService() async {
    await StarredConversationsService.instance.initialize();
    if (mounted) {
      setState(() {}); // Refresh UI after starred service loads
    }
  }

  Future<void> _loadConversations() async {
    setState(() {
      _loading = true;
    });

    try {
      final conversations = <Map<String, dynamic>>[];

      // MIGRATED: Use SQLite for better performance
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        final conversationsStore =
            await SqliteRecentConversationsStore.getInstance();

        // Get recent conversations from SQLite (FAST!)
        var recentConvs = await conversationsStore.getRecentConversations(
          limit: null, // Get ALL conversations, not just 50
        );

        // Get all unique senders from messages table
        final allUniqueSenders = await messageStore
            .getAllUniqueConversationPartners();

        // Combine both sources: recent_conversations + any missing from messages
        final conversationUserIds = recentConvs
            .map((conv) => conv['userId'] ?? conv['uuid'])
            .where((id) => id != null)
            .cast<String>()
            .toSet();

        // Add any conversations that exist in messages but not in recent_conversations
        for (final userId in allUniqueSenders) {
          if (!conversationUserIds.contains(userId)) {
            recentConvs.add({'userId': userId, 'displayName': userId});
          }
        }

        debugPrint(
          '[MESSAGES_LIST] Found ${recentConvs.length} total conversations (recent_conversations + messages)',
        );

        // Get last message for each conversation
        for (final conv in recentConvs) {
          final userId = conv['userId'] ?? conv['uuid'];
          if (userId == null) continue;

          // Get all messages from this conversation (FAST indexed query!)
          final allMessages = await messageStore.getMessagesFromConversation(
            userId,
            types: ['message', 'file', 'image', 'voice'],
            limit: 1, // Only need last message
          );

          if (allMessages.isEmpty) continue;

          final lastMsg = allMessages.first;
          final lastMessageTime =
              DateTime.tryParse(lastMsg['timestamp'] ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);

          conversations.add({
            'userId': userId,
            'displayName': conv['displayName'] ?? userId,
            'lastMessages': [
              {
                'message': lastMsg['message'],
                'timestamp': lastMsg['timestamp'],
              },
            ],
            'lastMessageTime': lastMessageTime.toIso8601String(),
            'lastMessageSender': lastMsg['direction'] == 'sent'
                ? 'self'
                : userId,
          });
        }
      } catch (sqliteError) {
        debugPrint(
          '[MESSAGES_LIST] ✗ SQLite error loading conversations: $sqliteError',
        );
        // No fallback - SQLite is required
      }

      // Sort by last message time
      conversations.sort((a, b) {
        final timeA =
            DateTime.tryParse(a['lastMessageTime'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeB =
            DateTime.tryParse(b['lastMessageTime'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
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
      debugPrint('[MESSAGES_LIST] Error loading conversations: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _enrichWithUserInfo(
    List<Map<String, dynamic>> conversations,
  ) async {
    // Collect all user IDs that need to be fetched
    final userIdsToFetch = conversations
        .map((conv) => conv['userId'] as String)
        .where((userId) => !_userCache.containsKey(userId))
        .toList();

    // Batch fetch all user info in one request
    if (userIdsToFetch.isNotEmpty) {
      try {
        await ApiService.instance.init();
        final resp = await ApiService.instance.post(
          '/client/people/info',
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
        debugPrint('[MESSAGES_LIST] Error batch fetching user info: $e');
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
      final userInfo =
          _userCache[userId] ??
          {'displayName': userId, 'picture': '', 'atName': ''};
      conv['displayName'] = userInfo['displayName'];
      conv['picture'] = userInfo['picture'];
      conv['atName'] = userInfo['atName'];
    }
  }

  /// Load recent conversation partners for context panel
  Future<void> _loadRecentPeople() async {
    if (_isLoadingRecentPeople) return;

    setState(() {
      _isLoadingRecentPeople = true;
    });

    try {
      // Load from RecentConversationsService with SQLite + profiles
      final allConversations =
          await RecentConversationsService.getRecentConversations();

      // Apply limit
      final conversations = allConversations.take(_recentPeopleLimit).toList();

      // Load last messages from SQLite
      final messageStore = await SqliteMessageStore.getInstance();
      final List<Map<String, dynamic>> peopleWithMessages = [];

      for (final conv in conversations) {
        final userId = conv['uuid'] as String;

        // Get last message
        final messages = await messageStore.getMessagesFromConversation(
          userId,
          limit: 1,
          offset: 0,
          types: ['message', 'file', 'image', 'voice'],
        );

        String? lastMessage;
        String? lastMessageTime;

        if (messages.isNotEmpty) {
          final msg = messages.first;
          final messageText = msg['message'] as String?;
          final messageType = msg['type'] as String?;

          // Format message preview
          if (messageType == 'file') {
            lastMessage = '📎 File';
          } else if (messageType == 'image') {
            lastMessage = '🖼️ Image';
          } else if (messageType == 'voice') {
            lastMessage = '🎤 Voice';
          } else {
            lastMessage = messageText;
          }

          // Truncate if too long
          if (lastMessage != null && lastMessage.length > 40) {
            lastMessage = '${lastMessage.substring(0, 40)}...';
          }

          // Pass raw ISO timestamp (not formatted) so widgets can calculate relative time with Timer
          lastMessageTime = msg['timestamp'] as String?;
        }

        peopleWithMessages.add({
          'uuid': userId,
          'displayName': conv['displayName'],
          'username': userId, // Use userId as username fallback
          'profilePicture': conv['picture'],
          'lastMessage': lastMessage,
          'lastMessageTime': lastMessageTime,
        });
      }

      setState(() {
        _recentPeople = peopleWithMessages;
        _isLoadingRecentPeople = false;
        _hasMoreRecentPeople = allConversations.length > _recentPeopleLimit;
      });
    } catch (e) {
      debugPrint('[MESSAGES_LIST] Error loading recent people: $e');
      setState(() {
        _isLoadingRecentPeople = false;
      });
    }
  }

  /// Load more recent people (incremental)
  Future<void> _loadMoreRecentPeople() async {
    if (_isLoadingRecentPeople || !_hasMoreRecentPeople) return;

    setState(() {
      _recentPeopleLimit += 10;
    });

    await _loadRecentPeople();
  }

  void _loadMore() {
    setState(() {
      _limit += 20;
    });
    _loadConversations();
  }

  void _toggleStar(String userId) async {
    // Toggle in local encrypted database
    final success = await StarredConversationsService.instance.toggleStar(
      userId,
    );

    if (success && mounted) {
      setState(() {
        // Trigger rebuild to update star icon
      });
    }
  }

  Future<void> _showDeleteConversationDialog(
    String userId,
    String displayName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text(
          'Are you sure you want to delete all messages with $displayName? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteConversation(userId);
    }
  }

  Future<void> _deleteConversation(String userId) async {
    try {
      // Delete from SQLite message store
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.deleteConversation(userId);

      // Delete from recent conversations
      final conversationsStore =
          await SqliteRecentConversationsStore.getInstance();
      await conversationsStore.removeConversation(userId);

      // Remove from starred if it was starred
      await StarredConversationsService.instance.unstarConversation(userId);

      // Emit event to update UI
      EventBus.instance.emit(AppEvent.conversationDeleted, <String, dynamic>{
        'userId': userId,
      });

      // Reload conversations
      await _loadConversations();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Conversation deleted')));

        // Navigate to messages list
        context.go('/app/messages');
      }
    } catch (e) {
      debugPrint('[MESSAGES_LIST] Error deleting conversation: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete conversation: $e')),
        );
      }
    }
  }

  void _showConversationContextMenu(
    BuildContext context,
    Offset position,
    String userId,
    String displayName,
  ) {
    debugPrint(
      '[MESSAGES_LIST] Showing context menu for $displayName at position: $position',
    );

    // Ensure we have a valid context
    if (!mounted) {
      debugPrint(
        '[MESSAGES_LIST] Widget not mounted, cannot show context menu',
      );
      return;
    }

    showMenu(
          context: context,
          position: RelativeRect.fromLTRB(
            position.dx,
            position.dy,
            position.dx,
            position.dy,
          ),
          items: [
            PopupMenuItem(
              child: const Row(
                children: [
                  Icon(Icons.delete, size: 20),
                  SizedBox(width: 8),
                  Text('Delete Conversation'),
                ],
              ),
              onTap: () {
                debugPrint(
                  '[MESSAGES_LIST] Delete menu item tapped for user: $userId',
                );
                // Delay to allow menu to close first
                Future.delayed(const Duration(milliseconds: 100), () {
                  if (mounted) {
                    _showDeleteConversationDialog(userId, displayName);
                  }
                });
              },
            ),
          ],
        )
        .then((value) {
          debugPrint('[MESSAGES_LIST] Context menu closed with value: $value');
        })
        .catchError((error) {
          debugPrint('[MESSAGES_LIST] Error showing context menu: $error');
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        automaticallyImplyLeading: false,
      ),
      body: Row(
        children: [
          // Left: Context Panel (Recent Conversations)
          PeopleContextPanel(
            recentPeople: _recentPeople,
            starredPeople: const [], // No favorites for now
            onPersonTap: (uuid, displayName) {
              // Navigate to conversation
              widget.onMessageTap(uuid, displayName);
            },
            isLoading: _isLoadingRecentPeople,
            onLoadMore: _loadMoreRecentPeople,
            hasMore: _hasMoreRecentPeople,
          ),

          // Right: Main Messages List
          Expanded(
            child: _loading && _conversations.isEmpty
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
                              return _buildConversationTile(
                                _conversations[index],
                              );
                            },
                          ),
                  ),
          ),
        ],
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
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'No conversations yet',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to start a conversation',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
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

    // Check if conversation is starred
    final isStarred = StarredConversationsService.instance.isStarred(userId);

    return Consumer2<UnreadMessagesProvider, NavigationStateProvider>(
      builder: (context, unreadProvider, navProvider, _) {
        final unreadCount = unreadProvider.getDirectMessageUnreadCount(userId);
        final isSelected = navProvider.isDirectMessageSelected(userId);

        // Create avatar with badge if unread
        Widget avatarWidget = UserAvatar(
          userId: userId,
          displayName: displayName,
          pictureData: picture,
          size: 40,
        );

        if (unreadCount > 0) {
          avatarWidget = SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                avatarWidget,
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      unreadCount > 99 ? '99+' : '$unreadCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            debugPrint('[MESSAGES_LIST] Tap detected for user: $userId');
            navProvider.selectDirectMessage(userId);
            widget.onMessageTap(userId, displayName);
          },
          onSecondaryTapDown: (details) {
            debugPrint(
              '[MESSAGES_LIST] *** RIGHT-CLICK DETECTED *** for user: $userId',
            );
            _showConversationContextMenu(
              context,
              details.globalPosition,
              userId,
              displayName,
            );
          },
          onLongPressStart: (details) {
            debugPrint('[MESSAGES_LIST] Long-press detected for user: $userId');
            _showConversationContextMenu(
              context,
              details.globalPosition,
              userId,
              displayName,
            );
          },
          child: AnimatedSelectionTile(
            leading: avatarWidget,
            title: Text(
              displayName,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: AppThemeConstants.textPrimary,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (atName.isNotEmpty)
                  Text(
                    '@$atName',
                    style: const TextStyle(
                      fontSize: AppThemeConstants.fontSizeCaption,
                      color: AppThemeConstants.textSecondary,
                    ),
                  ),
                Text(
                  lastMessage.length > 50
                      ? '${lastMessage.substring(0, 50)}...'
                      : lastMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppThemeConstants.fontSizeCaption,
                    color: AppThemeConstants.textSecondary,
                  ),
                ),
                Text(
                  _formatTime(lastMessageTime),
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppThemeConstants.textSecondary,
                  ),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    isStarred ? Icons.star : Icons.star_border,
                    color: isStarred ? Colors.amber : Colors.grey,
                    size: 20,
                  ),
                  onPressed: () => _toggleStar(userId),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_ios, size: 16),
              ],
            ),
            selected: isSelected,
            // Remove onTap from AnimatedSelectionTile - handled by GestureDetector
            onTap: null,
          ),
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
