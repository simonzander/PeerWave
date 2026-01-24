import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/activities_service.dart';
import '../../services/api_service.dart';
import '../../services/video_conference_service.dart';
import '../../services/starred_channels_service.dart';
import '../../services/signal_service.dart';
import '../../models/role.dart';
import '../../providers/unread_messages_provider.dart';
import '../../providers/navigation_state_provider.dart';
import '../../widgets/animated_widgets.dart';
import '../../theme/app_theme_constants.dart';
import '../../services/storage/sqlite_message_store.dart';
import '../../services/event_bus.dart';
import '../../services/sent_group_items_store.dart';
import '../../services/decrypted_group_items_store.dart';
import 'package:provider/provider.dart';
import 'dart:convert';

/// Channels List View - Shows all channels with smart categorization
class ChannelsListView extends StatefulWidget {
  final Function(String uuid, String name, String type) onChannelTap;
  final VoidCallback onCreateChannel;

  const ChannelsListView({
    super.key,
    required this.onChannelTap,
    required this.onCreateChannel,
  });

  @override
  State<ChannelsListView> createState() => _ChannelsListViewState();
}

class _ChannelsListViewState extends State<ChannelsListView>
    with TickerProviderStateMixin {
  bool _loading = true;
  final TextEditingController _searchController = TextEditingController();

  // All channels (unified from API)
  List<Map<String, dynamic>> _allChannels = [];

  // Discover (public non-member/non-owner channels)
  List<Map<String, dynamic>> _discoverChannels = [];
  int _discoverOffset = 0;
  final int _discoverLimit = 10;
  bool _hasMoreDiscover = true;
  bool _loadingMoreDiscover = false;

  // Search and filter state
  String _searchQuery = '';
  String _selectedFilter = 'all';

  // Animation controller for live indicator
  late AnimationController _liveAnimationController;
  late Animation<double> _liveAnimation;

  @override
  void initState() {
    super.initState();
    _liveAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _liveAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _liveAnimationController,
        curve: Curves.easeInOut,
      ),
    );
    _initializeStarredService();
    _loadChannels();
    _searchController.addListener(_onSearchChanged);
  }

  Future<void> _initializeStarredService() async {
    await StarredChannelsService.instance.initialize();
    if (mounted) {
      setState(() {}); // Refresh UI after starred service loads
    }
  }

  @override
  void dispose() {
    _liveAnimationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _loadChannels() async {
    setState(() => _loading = true);

    try {
      await _loadAllChannels();
      await _loadDiscoverChannels(reset: true);
      setState(() => _loading = false);
    } catch (e) {
      debugPrint('[CHANNELS_LIST] Error loading channels: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _loadAllChannels() async {
    try {
      // Get WebRTC channels with live participants
      final webrtcWithParticipants =
          await ActivitiesService.getWebRTCChannelParticipants();

      // Get all member/owner channels
      ApiService.init();
      final resp = await ApiService.get('/client/channels?limit=1000');

      debugPrint('[CHANNELS_LIST] API Response status: ${resp.statusCode}');

      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        debugPrint(
          '[CHANNELS_LIST] API Response data type: ${data.runtimeType}',
        );
        debugPrint(
          '[CHANNELS_LIST] API Response keys: ${data is Map ? data.keys.toList() : "not a map"}',
        );

        final channels = (data['channels'] as List<dynamic>? ?? []);

        debugPrint(
          '[CHANNELS_LIST] Loaded ${channels.length} channels from API',
        );

        // Get current user ID to determine ownership
        final currentUserId = SignalService.instance.currentUserId;

        _allChannels = channels.map((ch) {
          final channelMap = Map<String, dynamic>.from(ch as Map);
          channelMap['isMember'] = true; // These are all member/owner channels
          // Determine ownership by comparing channel owner with current user
          channelMap['isOwner'] =
              (currentUserId != null && channelMap['owner'] == currentUserId);

          // Get starred state from local encrypted database (server has no knowledge)
          try {
            channelMap['isStarred'] = StarredChannelsService.instance.isStarred(
              channelMap['uuid'] as String? ?? '',
            );
          } catch (e) {
            debugPrint('[CHANNELS_LIST] Error checking starred state: $e');
            channelMap['isStarred'] = false;
          }

          // Add live participant data for WebRTC channels
          if (channelMap['type'] == 'webrtc') {
            final liveData = webrtcWithParticipants.firstWhere(
              (ch) => ch['uuid'] == channelMap['uuid'],
              orElse: () => <String, dynamic>{},
            );
            if (liveData.isNotEmpty &&
                (liveData['participants'] as List?)?.isNotEmpty == true) {
              channelMap['participants'] = liveData['participants'];
            }
          }

          return channelMap;
        }).toList();

        // Enrich Signal channels with last message
        await _enrichSignalChannelsWithLastMessage();
      } else {
        debugPrint(
          '[CHANNELS_LIST] API Error: ${resp.statusCode} - ${resp.data}',
        );
      }
    } catch (e) {
      debugPrint('[CHANNELS_LIST] Error loading member channels: $e');
    }
  }

  Future<void> _enrichSignalChannelsWithLastMessage() async {
    try {
      final conversations = await ActivitiesService.getRecentGroupConversations(
        limit: 100,
      );

      for (final channel in _allChannels.where(
        (ch) => ch['type'] == 'signal',
      )) {
        final conv = conversations.firstWhere(
          (c) => c['channelId'] == channel['uuid'],
          orElse: () => <String, dynamic>{},
        );

        if (conv.isNotEmpty) {
          final lastMessages = (conv['lastMessages'] as List?) ?? [];
          channel['lastMessage'] = lastMessages.isNotEmpty
              ? (lastMessages.first['message'] as String? ?? '')
              : '';
          channel['lastMessageTime'] = conv['lastMessageTime'] ?? '';
        } else {
          channel['lastMessage'] = '';
          channel['lastMessageTime'] = '';
        }
      }
    } catch (e) {
      debugPrint('[CHANNELS_LIST] Error enriching signal channels: $e');
    }
  }

  Future<void> _loadDiscoverChannels({bool reset = false}) async {
    if (reset) {
      _discoverOffset = 0;
      _hasMoreDiscover = true;
      _discoverChannels = [];
    }

    if (!_hasMoreDiscover || _loadingMoreDiscover) return;

    setState(() => _loadingMoreDiscover = true);

    try {
      ApiService.init();
      final resp = await ApiService.get(
        '/client/channels/discover?limit=$_discoverLimit&offset=$_discoverOffset',
      );

      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        final channels = (data['channels'] as List<dynamic>? ?? []);

        final newChannels = channels.map((ch) {
          final channelMap = Map<String, dynamic>.from(ch as Map);
          channelMap['isMember'] = false;
          channelMap['isOwner'] = false;
          return channelMap;
        }).toList();

        setState(() {
          if (reset) {
            _discoverChannels = newChannels;
          } else {
            _discoverChannels.addAll(newChannels);
          }
          _discoverOffset += newChannels.length;
          _hasMoreDiscover = newChannels.length >= _discoverLimit;
          _loadingMoreDiscover = false;
        });
      } else {
        setState(() {
          _loadingMoreDiscover = false;
          _hasMoreDiscover = false;
        });
      }
    } catch (e) {
      debugPrint('[CHANNELS_LIST] Error loading discover channels: $e');
      setState(() {
        _loadingMoreDiscover = false;
        _hasMoreDiscover = false;
      });
    }
  }

  List<Map<String, dynamic>> _getFilteredChannels() {
    final unreadProvider = context.watch<UnreadMessagesProvider>();

    // Apply search filter first
    var channels = _searchQuery.isEmpty
        ? _allChannels
        : _allChannels.where((ch) {
            final name = (ch['name'] as String? ?? '').toLowerCase();
            final description = (ch['description'] as String? ?? '')
                .toLowerCase();
            return name.contains(_searchQuery) ||
                description.contains(_searchQuery);
          }).toList();

    // Apply chip filter
    switch (_selectedFilter) {
      case 'live':
        return channels
            .where(
              (ch) =>
                  ch['type'] == 'webrtc' &&
                  (ch['participants'] as List?)?.isNotEmpty == true,
            )
            .toList();

      case 'unread':
        return channels
            .where(
              (ch) => (unreadProvider.channelUnreadCounts[ch['uuid']] ?? 0) > 0,
            )
            .toList();

      case 'calls':
        return channels.where((ch) => ch['type'] == 'webrtc').toList();

      case 'text':
        return channels.where((ch) => ch['type'] == 'signal').toList();

      case 'starred':
        return channels.where((ch) => ch['isStarred'] == true).toList();

      case 'discover':
        // Return discover channels with search applied
        return _searchQuery.isEmpty
            ? _discoverChannels
            : _discoverChannels.where((ch) {
                final name = (ch['name'] as String? ?? '').toLowerCase();
                final description = (ch['description'] as String? ?? '')
                    .toLowerCase();
                return name.contains(_searchQuery) ||
                    description.contains(_searchQuery);
              }).toList();

      case 'all':
      default:
        return channels;
    }
  }

  Map<String, List<Map<String, dynamic>>> _getCategorizedChannelsForAll() {
    final unreadProvider = context.watch<UnreadMessagesProvider>();
    final allFiltered = _getFilteredChannels();
    final displayedIds = <String>{};

    // 1. Starred channels
    final starred = allFiltered.where((ch) => ch['isStarred'] == true).toList();
    displayedIds.addAll(starred.map((ch) => ch['uuid'] as String));

    // 2. Live WebRTC channels
    final live = allFiltered
        .where(
          (ch) =>
              ch['type'] == 'webrtc' &&
              (ch['participants'] as List?)?.isNotEmpty == true &&
              !displayedIds.contains(ch['uuid']),
        )
        .toList();
    displayedIds.addAll(live.map((ch) => ch['uuid'] as String));

    // 3. Signal channels with unread messages (sorted by latest message)
    final unread = allFiltered
        .where(
          (ch) =>
              ch['type'] == 'signal' &&
              (unreadProvider.channelUnreadCounts[ch['uuid']] ?? 0) > 0 &&
              !displayedIds.contains(ch['uuid']),
        )
        .toList();
    unread.sort((a, b) {
      final timeA =
          DateTime.tryParse(a['lastMessageTime'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final timeB =
          DateTime.tryParse(b['lastMessageTime'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return timeB.compareTo(timeA);
    });
    displayedIds.addAll(unread.map((ch) => ch['uuid'] as String));

    // 4. Other member/owner channels not yet displayed
    final other = allFiltered
        .where((ch) => !displayedIds.contains(ch['uuid']))
        .toList();

    // 5. Discover channels (public non-member)
    final discover = _searchQuery.isEmpty
        ? _discoverChannels.take(10).toList()
        : _discoverChannels
              .where((ch) {
                final name = (ch['name'] as String? ?? '').toLowerCase();
                final description = (ch['description'] as String? ?? '')
                    .toLowerCase();
                return name.contains(_searchQuery) ||
                    description.contains(_searchQuery);
              })
              .take(10)
              .toList();

    return {
      'starred': starred,
      'live': live,
      'unread': unread,
      'other': other,
      'discover': discover,
    };
  }

  void _toggleStar(String channelId) async {
    final channel = _allChannels.firstWhere(
      (ch) => ch['uuid'] == channelId,
      orElse: () => <String, dynamic>{},
    );
    if (channel.isNotEmpty) {
      // Toggle in local encrypted database
      final success = await StarredChannelsService.instance.toggleStar(
        channelId,
      );

      if (success && mounted) {
        setState(() {
          // Update local state for immediate UI feedback
          channel['isStarred'] = StarredChannelsService.instance.isStarred(
            channelId,
          );
        });
      }
    }
  }

  Future<void> _showDeleteChannelDialog(
    String channelId,
    String channelName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Channel Messages'),
        content: Text(
          'Are you sure you want to delete all messages from "$channelName"? This action cannot be undone.',
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
      await _deleteChannelMessages(channelId);
    }
  }

  Future<void> _deleteChannelMessages(String channelId) async {
    debugPrint('[CHANNELS_LIST] ===== START DELETING CHANNEL MESSAGES =====');
    debugPrint('[CHANNELS_LIST] Channel ID: $channelId');

    try {
      // Delete from sent items store (old storage + SQLite)
      debugPrint('[CHANNELS_LIST] Step 1: Deleting sent items...');
      final sentStore = await SentGroupItemsStore.getInstance();
      await sentStore.deleteChannelItems(channelId);
      debugPrint('[CHANNELS_LIST] Step 2: Sent items deleted');

      // Delete from received/decrypted items store (old storage + SQLite)
      debugPrint('[CHANNELS_LIST] Step 3: Deleting received items...');
      final receivedStore = await DecryptedGroupItemsStore.getInstance();
      await receivedStore.deleteChannelItems(channelId);
      debugPrint('[CHANNELS_LIST] Step 4: Received items deleted');

      // Also delete from DM message store (in case any were stored there incorrectly)
      debugPrint('[CHANNELS_LIST] Step 5: Cleaning up DM store...');
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.deleteChannel(channelId);
      debugPrint('[CHANNELS_LIST] Step 6: DM store cleanup completed');

      // Remove from starred if it was starred
      debugPrint('[CHANNELS_LIST] Step 7: Unstarring channel...');
      await StarredChannelsService.instance.unstarChannel(channelId);
      debugPrint('[CHANNELS_LIST] Step 8: Unstar completed');

      // Emit event to update UI
      debugPrint('[CHANNELS_LIST] Step 9: Emitting event...');
      EventBus.instance.emit(AppEvent.conversationDeleted, {
        'channelId': channelId,
      });

      debugPrint(
        '[CHANNELS_LIST] ✓ Successfully deleted all messages from channel: $channelId',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Channel messages deleted')),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[CHANNELS_LIST] ✗ Error deleting channel messages: $e');
      debugPrint('[CHANNELS_LIST] Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete channel messages: $e')),
        );
      }
    }
  }

  void _showChannelContextMenu(
    BuildContext context,
    Offset position,
    String channelId,
    String channelName,
    String channelType,
  ) {
    // Only show delete option for text channels (signal), not video channels (webrtc)
    if (channelType != 'signal') {
      return; // Don't show menu for video channels
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
              Text('Delete Messages'),
            ],
          ),
          onTap: () {
            // Delay to allow menu to close first
            Future.delayed(const Duration(milliseconds: 100), () {
              _showDeleteChannelDialog(channelId, channelName);
            });
          },
        ),
      ],
    );
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
                bottom: BorderSide(color: colorScheme.outlineVariant, width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(color: colorScheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Search channels...',
                      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                      prefixIcon: Icon(
                        Icons.search,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                Icons.clear,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
                bottom: BorderSide(color: colorScheme.outlineVariant, width: 1),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildFilterChip(
                    label: 'All',
                    value: 'all',
                    icon: Icons.inbox,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: 'Live',
                    value: 'live',
                    icon: Icons.circle,
                    iconColor: Theme.of(context).colorScheme.error,
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
                    label: 'Calls',
                    value: 'calls',
                    icon: Icons.videocam,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: 'Text',
                    value: 'text',
                    icon: Icons.tag,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: 'Starred',
                    value: 'starred',
                    icon: Icons.star,
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: 'Discover',
                    value: 'discover',
                    icon: Icons.explore,
                  ),
                ],
              ),
            ),
          ),

          // Content
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _loadChannels,
                    child: _buildChannelsList(),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateChannelDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Add Channel'),
        tooltip: 'Create Channel',
      ),
    );
  }

  Widget _buildChannelsList() {
    if (_selectedFilter == 'all') {
      return _buildAllView();
    } else if (_selectedFilter == 'discover') {
      return _buildDiscoverView();
    } else {
      return _buildFilteredView();
    }
  }

  Widget _buildAllView() {
    final categorized = _getCategorizedChannelsForAll();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Starred Section
        if (categorized['starred']!.isNotEmpty) ...[
          _buildSectionHeader('Starred', Icons.star),
          ...categorized['starred']!.map((ch) => _buildChannelTile(ch)),
          const SizedBox(height: 16),
        ],

        // Live Section
        if (categorized['live']!.isNotEmpty) ...[
          _buildSectionHeader('Live', Icons.videocam),
          ...categorized['live']!.map((ch) => _buildChannelTile(ch)),
          const SizedBox(height: 16),
        ],

        // Unread Messages Section
        if (categorized['unread']!.isNotEmpty) ...[
          _buildSectionHeader('Unread Messages', Icons.message),
          ...categorized['unread']!.map((ch) => _buildChannelTile(ch)),
          const SizedBox(height: 16),
        ],

        // Other Channels Section
        if (categorized['other']!.isNotEmpty) ...[
          _buildSectionHeader('My Channels', Icons.topic),
          ...categorized['other']!.map((ch) => _buildChannelTile(ch)),
          const SizedBox(height: 16),
        ],

        // Discover Section
        if (categorized['discover']!.isNotEmpty) ...[
          _buildSectionHeader('Discover', Icons.explore),
          ...categorized['discover']!.map(
            (ch) => _buildDiscoverChannelTile(ch),
          ),
        ],

        // Empty state
        if (categorized.values.every((list) => list.isEmpty))
          _buildEmptyState(
            'No channels found',
            _searchQuery.isNotEmpty
                ? 'Try a different search term'
                : 'Tap + to create a channel',
          ),
      ],
    );
  }

  Widget _buildDiscoverView() {
    final channels = _getFilteredChannels();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (channels.isEmpty && !_loadingMoreDiscover)
          _buildEmptyState(
            'No public channels available',
            'Check back later for new channels',
          ),

        ...channels.map((ch) => _buildDiscoverChannelTile(ch)),

        if (_hasMoreDiscover && !_loadingMoreDiscover)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: ElevatedButton.icon(
                onPressed: () => _loadDiscoverChannels(),
                icon: const Icon(Icons.expand_more),
                label: const Text('Load More'),
              ),
            ),
          ),

        if (_loadingMoreDiscover)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _buildFilteredView() {
    final channels = _getFilteredChannels();

    String emptyTitle = 'No channels';
    String emptyMessage = '';

    switch (_selectedFilter) {
      case 'live':
        emptyTitle = 'No live channels';
        emptyMessage = 'Join a video channel to see it here';
        break;
      case 'unread':
        emptyTitle = 'No unread messages';
        emptyMessage = 'You\'re all caught up!';
        break;
      case 'calls':
        emptyTitle = 'No video channels';
        emptyMessage = 'Create a video channel to get started';
        break;
      case 'text':
        emptyTitle = 'No text channels';
        emptyMessage = 'Create a text channel to get started';
        break;
      case 'starred':
        emptyTitle = 'No starred channels';
        emptyMessage = 'Star your favorite channels to see them here';
        break;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (channels.isEmpty)
          _buildEmptyState(emptyTitle, emptyMessage)
        else
          ...channels.map((ch) => _buildChannelTile(ch)),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, [Color? color]) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8, top: 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: color ?? Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelTile(Map<String, dynamic> channel) {
    final unreadProvider = context.watch<UnreadMessagesProvider>();
    final navProvider = context.read<NavigationStateProvider>();

    final name = channel['name'] as String? ?? 'Unknown Channel';
    final uuid = channel['uuid'] as String;
    final type = channel['type'] as String? ?? 'signal';
    final isPrivate = channel['private'] as bool? ?? false;
    final isStarred = channel['isStarred'] as bool? ?? false;
    final isLive =
        type == 'webrtc' &&
        (channel['participants'] as List?)?.isNotEmpty == true;
    final unreadCount = unreadProvider.getChannelUnreadCount(uuid);
    final isSelected = navProvider.isChannelSelected(uuid);
    final hasUnread = unreadCount > 0;

    // Squared icon container (consistent with squared avatars)
    Widget leading = isLive
        ? FadeTransition(
            opacity: _liveAnimation,
            child: AppThemeConstants.squaredIconContainer(
              icon: Icons.videocam,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.error.withValues(alpha: 0.2),
              iconColor: Theme.of(context).colorScheme.error,
              size: 40,
            ),
          )
        : AppThemeConstants.squaredIconContainer(
            icon: isPrivate
                ? Icons.lock
                : (type == 'webrtc' ? Icons.videocam : Icons.tag),
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            iconColor: Theme.of(context).colorScheme.onSecondaryContainer,
            size: 40,
          );

    if (isLive) {
      leading = Stack(
        children: [
          leading,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.circle,
                size: 8,
                color: Theme.of(context).colorScheme.onError,
              ),
            ),
          ),
        ],
      );
    }

    // Add unread badge to icon if present
    if (hasUnread) {
      leading = SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            leading,
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : '$unreadCount',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onError,
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
      onSecondaryTapDown: (details) {
        _showChannelContextMenu(
          context,
          details.globalPosition,
          uuid,
          name,
          type,
        );
      },
      onLongPressStart: (details) {
        _showChannelContextMenu(
          context,
          details.globalPosition,
          uuid,
          name,
          type,
        );
      },
      child: AnimatedSelectionTile(
        leading: leading,
        title: Text(
          type == 'signal' ? '# $name' : name,
          style: TextStyle(
            fontWeight: hasUnread ? FontWeight.bold : FontWeight.w500,
            color: hasUnread
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
        subtitle: _buildChannelSubtitle(channel),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                isStarred ? Icons.star : Icons.star_border,
                color: isStarred
                    ? Theme.of(context).colorScheme.tertiary
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                size: 20,
              ),
              onPressed: () => _toggleStar(uuid),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_ios, size: 16),
          ],
        ),
        selected: isSelected,
        onTap: () {
          if (type == 'signal') {
            navProvider.selectChannel(uuid, 'signal');
          }

          // Enter full-view mode for WebRTC
          final videoService = VideoConferenceService.instance;
          if (type == 'webrtc' && videoService.isInCall) {
            videoService.enterFullView();
          }

          context.go(
            '/app/channels/$uuid',
            extra: <String, dynamic>{'name': name, 'type': type},
          );
        },
      ),
    );
  }

  Widget _buildChannelSubtitle(Map<String, dynamic> channel) {
    final type = channel['type'] as String?;
    final description = channel['description'] as String? ?? '';

    if (type == 'webrtc') {
      final participants = (channel['participants'] as List?) ?? [];
      final isLive = participants.isNotEmpty;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (description.isNotEmpty)
            Text(
              description,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            isLive
                ? '${participants.length} ${participants.length == 1 ? 'participant' : 'participants'} • LIVE'
                : 'Video channel • No active participants',
            style: TextStyle(
              color: isLive
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      );
    } else {
      // Signal channel
      final lastMessage = channel['lastMessage'] as String? ?? '';
      final lastMessageTime = channel['lastMessageTime'] as String? ?? '';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (description.isNotEmpty)
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
          if (lastMessage.isNotEmpty) ...[
            Text(
              lastMessage.length > 50
                  ? '${lastMessage.substring(0, 50)}...'
                  : lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (lastMessageTime.isNotEmpty)
              Text(
                _formatTime(lastMessageTime),
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
          ] else
            Text(
              'Text channel',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
        ],
      );
    }
  }

  Widget _buildDiscoverChannelTile(Map<String, dynamic> channel) {
    final name = channel['name'] as String? ?? 'Unknown Channel';
    final uuid = channel['uuid'] as String;
    final description = channel['description'] as String? ?? '';
    final type = channel['type'] as String? ?? 'signal';

    return ListTile(
      leading: AppThemeConstants.squaredIconContainer(
        icon: type == 'webrtc' ? Icons.videocam : Icons.explore,
        backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
        iconColor: Theme.of(context).colorScheme.onTertiaryContainer,
        size: 40,
      ),
      title: Text(name),
      subtitle: Text(
        description.isNotEmpty ? description : 'Public channel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: SizedBox(
        width: 80,
        child: ElevatedButton(
          onPressed: () => _joinChannel(uuid, name, type),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: const Text('Join', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }

  Future<void> _joinChannel(
    String channelId,
    String channelName,
    String channelType,
  ) async {
    try {
      final resp = await ApiService.joinChannel(channelId);

      if (resp.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Joined $channelName successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }

        // Reload channels to update the list
        await _loadChannels();

        // Navigate to the newly joined channel
        if (mounted) {
          context.go(
            '/app/channels/$channelId',
            extra: <String, dynamic>{'name': channelName, 'type': channelType},
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to join channel: ${resp.data['message'] ?? 'Unknown error'}',
              ),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[CHANNELS_LIST] Error joining channel: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error joining channel: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Widget _buildFilterChip({
    required String label,
    required String value,
    required IconData icon,
    double? iconSize,
    Color? iconColor,
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
                ? (iconColor ?? theme.colorScheme.onSecondaryContainer)
                : (iconColor ?? theme.colorScheme.onSurfaceVariant),
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

  Widget _buildEmptyState(String title, String message) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 80,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              textAlign: TextAlign.center,
            ),
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

      if (diff.inMinutes < 1) return 'Now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m';
      if (diff.inHours < 24) return '${diff.inHours}h';
      if (diff.inDays < 7) return '${diff.inDays}d';
      return '${time.day}/${time.month}';
    } catch (e) {
      return '';
    }
  }

  void _showCreateChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _CreateChannelDialog(
        onChannelCreated: (channelName) => _loadChannels(),
      ),
    );
  }
}

// Create Channel Dialog
class _CreateChannelDialog extends StatefulWidget {
  final Function(String) onChannelCreated;

  const _CreateChannelDialog({required this.onChannelCreated});

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  String channelName = '';
  String channelDescription = '';
  bool isPrivate = false;
  String channelType = 'webrtc';
  List<Role> availableRoles = [];
  Role? selectedRole;
  bool isLoadingRoles = false;

  @override
  void initState() {
    super.initState();
    _loadRoles();
  }

  Future<void> _loadRoles() async {
    setState(() => isLoadingRoles = true);
    try {
      ApiService.init();
      final scope = channelType == 'webrtc' ? 'channelWebRtc' : 'channelSignal';
      final resp = await ApiService.get('/api/roles?scope=$scope');

      if (resp.statusCode == 200) {
        final data = resp.data;
        final rolesList =
            (data['roles'] as List?)?.map((r) => Role.fromJson(r)).toList() ??
            [];

        setState(() {
          availableRoles = rolesList;
          selectedRole = rolesList.isNotEmpty ? rolesList.first : null;
          isLoadingRoles = false;
        });
      }
    } catch (e) {
      setState(() => isLoadingRoles = false);
      debugPrint('Error loading roles: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Channel'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Channel Name'),
              onChanged: (value) => setState(() => channelName = value),
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 3,
              onChanged: (value) => setState(() => channelDescription = value),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Checkbox(
                  value: isPrivate,
                  onChanged: (value) =>
                      setState(() => isPrivate = value ?? false),
                ),
                const Text('Private'),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Channel Type:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        channelType = 'webrtc';
                        _loadRoles();
                      });
                    },
                    child: Row(
                      children: [
                        // ignore: deprecated_member_use
                        Radio<String>(
                          value: 'webrtc',
                          // ignore: deprecated_member_use
                          groupValue: channelType,
                          // ignore: deprecated_member_use
                          onChanged: (value) {
                            setState(() {
                              channelType = value!;
                              _loadRoles();
                            });
                          },
                        ),
                        const Text('WebRTC'),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        channelType = 'signal';
                        _loadRoles();
                      });
                    },
                    child: Row(
                      children: [
                        // ignore: deprecated_member_use
                        Radio<String>(
                          value: 'signal',
                          // ignore: deprecated_member_use
                          groupValue: channelType,
                          // ignore: deprecated_member_use
                          onChanged: (value) {
                            setState(() {
                              channelType = value!;
                              _loadRoles();
                            });
                          },
                        ),
                        const Text('Signal'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Default Join Role:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (isLoadingRoles)
              const Center(child: CircularProgressIndicator())
            else if (availableRoles.isEmpty)
              Text(
                'No standard roles available',
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              )
            else
              DropdownButton<Role>(
                isExpanded: true,
                value: selectedRole,
                items: availableRoles.map((role) {
                  return DropdownMenuItem<Role>(
                    value: role,
                    child: Text(role.name),
                  );
                }).toList(),
                onChanged: (value) => setState(() => selectedRole = value),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: selectedRole == null ? null : () => _createChannel(),
          child: const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _createChannel() async {
    if (channelName.isEmpty || selectedRole == null) return;

    try {
      ApiService.init();
      final resp = await ApiService.createChannel(
        name: channelName,
        description: channelDescription,
        isPrivate: isPrivate,
        type: channelType,
        defaultRoleId: selectedRole!.uuid,
      );

      if (resp.statusCode == 201) {
        widget.onChannelCreated(channelName);
        // ignore: use_build_context_synchronously
        if (context.mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('Error creating channel: $e');
      if (mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error creating channel: $e')));
      }
    }
  }
}
