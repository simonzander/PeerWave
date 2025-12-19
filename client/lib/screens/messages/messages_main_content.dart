import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/user_avatar.dart';
import '../../widgets/animated_widgets.dart';
import '../../providers/unread_messages_provider.dart';
import '../../services/user_profile_service.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/recent_conversations_service.dart';
import '../../services/starred_conversations_service.dart';
import '../../app/views/people_context_data_loader.dart';
import 'dart:async';

/// Messages Main Content - Shows conversation list with enhanced UI
/// 
/// This is displayed when no specific conversation is selected.
/// Features larger cards, search, and better organization than the context panel.
class MessagesMainContent extends StatefulWidget {
  final String host;
  final Function(String uuid, String displayName) onConversationTap;

  const MessagesMainContent({
    super.key,
    required this.host,
    required this.onConversationTap,
  });

  @override
  State<MessagesMainContent> createState() => _MessagesMainContentState();
}

class _MessagesMainContentState extends State<MessagesMainContent> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;
  
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _filteredConversations = [];
  
  bool _isLoading = false;
  String _searchQuery = '';
  String _selectedFilter = 'all'; // 'all', 'unread', 'starred'

  @override
  void initState() {
    super.initState();
    _initializeStarredService();
    _loadConversations();
    _searchController.addListener(_onSearchChanged);
  }
  
  Future<void> _initializeStarredService() async {
    await StarredConversationsService.instance.initialize();
    if (mounted) {
      setState(() {}); // Refresh UI after starred service loads
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      final query = _searchController.text.trim().toLowerCase();
      setState(() {
        _searchQuery = query;
        _applyFilters();
      });
    });
  }
  
  void _applyFilters() {
    var filtered = _conversations;
    
    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((conv) {
        final displayName = (conv['displayName'] as String? ?? '').toLowerCase();
        final atName = (conv['atName'] as String? ?? '').toLowerCase();
        return displayName.contains(_searchQuery) || atName.contains(_searchQuery);
      }).toList();
    }
    
    // Apply category filter
    if (_selectedFilter == 'unread') {
      filtered = filtered.where((conv) {
        final unreadCount = conv['unreadCount'] as int? ?? 0;
        return unreadCount > 0;
      }).toList();
    } else if (_selectedFilter == 'starred') {
      filtered = filtered.where((conv) {
        final isStarred = conv['isStarred'] as bool? ?? false;
        return isStarred;
      }).toList();
    }
    
    setState(() {
      _filteredConversations = filtered;
    });
  }

  Future<void> _loadConversations() async {
    if (!mounted) return;
    
    setState(() => _isLoading = true);
    
    try {
      debugPrint('[MESSAGES_MAIN] Loading conversations...');
      
      // Get recent conversations from service (returns List<Map<String, String>>)
      final conversations = await RecentConversationsService.getRecentConversations();
      
      debugPrint('[MESSAGES_MAIN] Found ${conversations.length} conversations');
      
      if (conversations.isEmpty) {
        if (mounted) {
          setState(() {
            _conversations = [];
            _filteredConversations = [];
            _isLoading = false;
          });
        }
        return;
      }
      
      // Get message store instance for last messages
      final messageStore = await SqliteMessageStore.getInstance();
      
      // Get unread provider
      final unreadProvider = context.read<UnreadMessagesProvider>();
      
      // Build conversation list with profile data
      final conversationList = <Map<String, dynamic>>[];
      
      for (final conv in conversations) {
        final userId = conv['uuid'];
        final displayName = conv['displayName'];
        final picture = conv['picture'];
        
        if (userId != null && userId.isNotEmpty) {
          // Get last message info
          final messages = await messageStore.getMessagesFromConversation(
            userId,
            limit: 1,
            types: ['message', 'file', 'image', 'voice'],
          );
          
          String lastMessage = '';
          String lastMessageTime = '';
          String lastMessageType = 'message';
          
          if (messages.isNotEmpty) {
            final lastMsg = messages.first;
            final msgType = lastMsg['type'] ?? 'message';
            lastMessageType = msgType;
            lastMessage = PeopleContextDataLoader.formatMessagePreview(msgType, lastMsg['message']);
            lastMessageTime = lastMsg['timestamp'] as String? ?? '';
          }
          
          // Get atName from UserProfileService
          final profile = UserProfileService.instance.getProfile(userId);
          
          conversationList.add({
            'uuid': userId,
            'displayName': displayName ?? userId,
            'atName': profile?['atName'] ?? '',
            'picture': picture ?? '',
            'online': false, // TODO: Get online status
            'lastMessage': lastMessage,
            'lastMessageTime': lastMessageTime,
            'lastMessageType': lastMessageType,
            'unreadCount': unreadProvider.directMessageUnreadCounts[userId] ?? 0,
            'isStarred': StarredConversationsService.instance.isStarred(userId),
          });
        }
      }
      
      if (mounted) {
        setState(() {
          _conversations = conversationList;
          _filteredConversations = conversationList;
          _isLoading = false;
        });
      }
      
      debugPrint('[MESSAGES_MAIN] Loaded ${_conversations.length} conversations');
    } catch (e, stackTrace) {
      debugPrint('[MESSAGES_MAIN] Error loading conversations: $e');
      debugPrint('[MESSAGES_MAIN] Stack trace: $stackTrace');
      
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // Search Bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(color: colorScheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Search conversations...',
                      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                      prefixIcon: Icon(Icons.search, color: colorScheme.onSurfaceVariant),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear, color: colorScheme.onSurfaceVariant),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Filter Chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                _buildFilterChip(
                  label: 'All',
                  value: 'all',
                  icon: Icons.inbox,
                ),
                const SizedBox(width: 8),
                _buildFilterChip(
                  label: 'Unread',
                  value: 'unread',
                  icon: Icons.circle,
                  iconSize: 12,
                ),
                const SizedBox(width: 8),
                _buildFilterChip(
                  label: 'Starred',
                  value: 'starred',
                  icon: Icons.star,
                ),
              ],
            ),
          ),
          
          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredConversations.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadConversations,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filteredConversations.length,
                          itemBuilder: (context, index) {
                            return _buildConversationCard(_filteredConversations[index]);
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // Navigate to people page to start new conversation
          context.go('/app/people');
        },
        icon: const Icon(Icons.add),
        label: const Text('New Message'),
        tooltip: 'Start a new conversation',
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required String value,
    required IconData icon,
    double? iconSize,
  }) {
    final isSelected = _selectedFilter == value;
    final theme = Theme.of(context);
    
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: iconSize ?? 16,
            color: isSelected 
                ? theme.colorScheme.onSecondaryContainer 
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: isSelected
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _selectedFilter = value;
          _applyFilters();
        });
      },
      showCheckmark: false,
      backgroundColor: theme.colorScheme.surface,
      selectedColor: theme.colorScheme.secondaryContainer,
      side: BorderSide(
        color: isSelected 
            ? theme.colorScheme.secondary 
            : theme.colorScheme.outlineVariant,
        width: 1,
      ),
    );
  }

  Widget _buildConversationCard(Map<String, dynamic> conversation) {
    final displayName = conversation['displayName'] as String? ?? 'Unknown';
    final atName = conversation['atName'] as String? ?? '';
    final picture = conversation['picture'] as String? ?? '';
    final isOnline = conversation['online'] as bool? ?? false;
    final userId = conversation['uuid'] as String? ?? '';
    final lastMessage = conversation['lastMessage'] as String? ?? '';
    final lastMessageTime = conversation['lastMessageTime'] as String? ?? '';
    
    return Consumer<UnreadMessagesProvider>(
      builder: (context, unreadProvider, child) {
        final currentUnreadCount = unreadProvider.directMessageUnreadCounts[userId] ?? 0;
        
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
          ),
          child: InkWell(
            onTap: () => widget.onConversationTap(userId, displayName),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar with online indicator
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: Stack(
                      children: [
                        SquareUserAvatar(
                          userId: userId,
                          displayName: displayName,
                          pictureData: picture.isNotEmpty ? picture : null,
                          size: 56,
                        ),
                        if (isOnline)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.surface,
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(width: 16),
                  
                  // Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name row
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: currentUnreadCount > 0 ? FontWeight.bold : FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (lastMessageTime.isNotEmpty)
                              Text(
                                _formatTime(lastMessageTime),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                        
                        if (atName.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            '@$atName',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        
                        if (lastMessage.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  lastMessage,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: currentUnreadCount > 0
                                        ? Theme.of(context).colorScheme.onSurface
                                        : Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontWeight: currentUnreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (currentUnreadCount > 0) ...[
                                const SizedBox(width: 8),
                                AnimatedBadge(
                                  count: currentUnreadCount,
                                  isSmall: false,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  
                  // Star icon button
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      StarredConversationsService.instance.isStarred(userId) 
                          ? Icons.star 
                          : Icons.star_border,
                      color: StarredConversationsService.instance.isStarred(userId) 
                          ? Colors.amber 
                          : Colors.grey,
                      size: 24,
                    ),
                    onPressed: () => _toggleStar(userId),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  
  void _toggleStar(String userId) async {
    final success = await StarredConversationsService.instance.toggleStar(userId);
    if (success && mounted) {
      setState(() {
        // Trigger rebuild to update star icon
      });
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(
              _searchQuery.isEmpty ? 'No conversations yet' : 'No conversations found',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isEmpty
                  ? 'Start a new conversation by tapping the button below'
                  : 'Try a different search term',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (_searchQuery.isEmpty) ...[
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () {
                  context.go('/app/people');
                },
                icon: const Icon(Icons.people),
                label: const Text('Browse People'),
              ),
            ],
          ],
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
        return 'now';
      } else if (diff.inMinutes < 60) {
        return '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        return '${diff.inHours}h ago';
      } else if (diff.inDays == 1) {
        return 'yesterday';
      } else if (diff.inDays < 7) {
        return '${diff.inDays}d ago';
      } else {
        return '${time.day}/${time.month}/${time.year}';
      }
    } catch (e) {
      return '';
    }
  }
}
