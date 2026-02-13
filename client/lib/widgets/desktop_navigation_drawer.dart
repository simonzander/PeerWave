import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'user_avatar.dart';
import 'license_footer.dart';
import '../services/api_service.dart';
import '../services/storage/sqlite_message_store.dart';
import '../services/storage/sqlite_recent_conversations_store.dart';
import '../models/role.dart';
import '../providers/unread_messages_provider.dart';
import '../providers/navigation_state_provider.dart';
import 'animated_widgets.dart';
import '../theme/app_theme_constants.dart';

/// Desktop Navigation Drawer with expandable Messages and Channels sections
///
/// Provides a richer navigation experience on desktop with:
/// - Standard navigation destinations
/// - Expandable Messages section with recent conversations
/// - Expandable Channels section with channel list
/// - Individual notification badges
class DesktopNavigationDrawer extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final Widget? leading;
  final Widget? trailing;
  final String host;
  final void Function(String uuid, String displayName)? onDirectMessageTap;
  final List<Map<String, dynamic>>? channels;
  final void Function(String uuid, String name, String type)? onChannelTap;
  final VoidCallback? onNavigateToPeople;
  final VoidCallback?
  onNavigateToMessagesView; // Navigate to messages list view
  final VoidCallback?
  onNavigateToChannelsView; // Navigate to channels list view

  const DesktopNavigationDrawer({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.leading,
    this.trailing,
    required this.host,
    this.onDirectMessageTap,
    this.channels,
    this.onChannelTap,
    this.onNavigateToPeople,
    this.onNavigateToMessagesView,
    this.onNavigateToChannelsView,
  });

  @override
  State<DesktopNavigationDrawer> createState() =>
      _DesktopNavigationDrawerState();
}

class _DesktopNavigationDrawerState extends State<DesktopNavigationDrawer> {
  bool _messagesExpanded = true; // Non-collapsed by default
  bool _channelsExpanded = true; // Non-collapsed by default
  List<Map<String, dynamic>> _recentConversations = [];
  bool _loadingConversations = false;

  @override
  void initState() {
    super.initState();
    _loadRecentConversations();
  }

  Future<void> _loadRecentConversations() async {
    if (_loadingConversations) return;

    setState(() {
      _loadingConversations = true;
    });

    try {
      final conversations = <Map<String, dynamic>>[];

      // Displayable message types whitelist (same as ActivitiesService)
      const displayableTypes = {'message', 'file'};

      // Use SQLite for recent conversations
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        final conversationsStore =
            await SqliteRecentConversationsStore.getInstance();

        // Get recent conversations from SQLite (FAST!)
        var recentConvs = await conversationsStore.getRecentConversations(
          limit: 20,
        );

        // FALLBACK: If conversations store is empty, get from messages
        if (recentConvs.isEmpty) {
          final uniqueSenders = await messageStore
              .getAllUniqueConversationPartners();
          recentConvs = uniqueSenders
              .take(20)
              .map((userId) => {'userId': userId, 'displayName': userId})
              .toList();
        }

        // Get last message for each conversation
        for (final conv in recentConvs) {
          final userId = conv['userId'] ?? conv['uuid'];
          if (userId == null) continue;

          // Get last message from this conversation (FAST indexed query!)
          final allMessages = await messageStore.getMessagesFromConversation(
            userId,
            types: displayableTypes.toList(),
            limit: 1,
          );

          if (allMessages.isEmpty) continue;

          final lastMsg = allMessages.first;
          final lastMessageTime =
              DateTime.tryParse(lastMsg['timestamp'] ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);

          conversations.add({
            'uuid': userId,
            'displayName': conv['displayName'] ?? userId,
            'lastMessageTime': lastMessageTime,
          });
        }
      } catch (sqliteError) {
        debugPrint(
          '[DESKTOP_NAV] ✗ SQLite error loading conversations: $sqliteError',
        );
        // No fallback - SQLite is required
      }

      // Sort by last message time
      conversations.sort((a, b) {
        final timeA = a['lastMessageTime'] as DateTime;
        final timeB = b['lastMessageTime'] as DateTime;
        return timeB.compareTo(timeA);
      });

      // Limit to 20 most recent
      final limitedConversations = conversations.take(20).toList();

      // Batch fetch user info for display names
      await _enrichWithUserInfo(limitedConversations);

      setState(() {
        _recentConversations = limitedConversations;
        _loadingConversations = false;
      });
    } catch (e) {
      debugPrint('[DESKTOP_NAV] Error loading conversations: $e');
      setState(() {
        _loadingConversations = false;
      });
    }
  }

  Future<void> _enrichWithUserInfo(
    List<Map<String, dynamic>> conversations,
  ) async {
    final userIds = conversations.map((c) => c['uuid'] as String).toList();

    if (userIds.isEmpty) return;

    try {
      await ApiService.instance.init();
      final resp = await ApiService.instance.post(
        '/client/people/info',
        data: {'userIds': userIds},
      );

      if (resp.statusCode == 200) {
        final users = resp.data is List ? resp.data : [];
        final userMap = <String, Map<String, String?>>{};

        for (final user in users) {
          // Extract picture as String (handle both direct string and nested objects)
          String? pictureData;
          final picture = user['picture'];
          if (picture is String) {
            pictureData = picture;
          } else if (picture is Map && picture['data'] != null) {
            pictureData = picture['data'] as String?;
          }

          userMap[user['uuid']] = {
            'displayName': user['displayName'] ?? user['uuid'],
            'picture': pictureData,
          };
        }

        // Update display names and pictures
        for (final conv in conversations) {
          final userId = conv['uuid'] as String;
          if (userMap.containsKey(userId)) {
            conv['displayName'] = userMap[userId]!['displayName'] ?? userId;
            conv['picture'] = userMap[userId]!['picture'];
          } else {
            conv['displayName'] = userId;
          }
        }
      }
    } catch (e) {
      debugPrint('[DESKTOP_NAV] Error enriching user info: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Leading (header)
          if (widget.leading != null)
            Padding(padding: const EdgeInsets.all(16.0), child: widget.leading),

          // Main navigation destinations
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // Standard destinations
                ...widget.destinations.asMap().entries.map((entry) {
                  final index = entry.key;
                  final destination = entry.value;

                  // Skip Messages and Channels as they have expandable sections
                  if (destination.label == 'Messages') {
                    return _buildMessagesSection();
                  } else if (destination.label == 'Channels') {
                    return _buildChannelsSection();
                  }

                  // Regular destination
                  return _buildNavigationTile(
                    icon: destination.icon,
                    selectedIcon: destination.selectedIcon ?? destination.icon,
                    label: destination.label,
                    selected: widget.selectedIndex == index,
                    onTap: () => widget.onDestinationSelected(index),
                  );
                }),
              ],
            ),
          ),

          // Trailing (footer)
          if (widget.trailing != null) ...[
            Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: widget.trailing,
            ),
          ],
          // License Footer
          const LicenseFooter(),
        ],
      ),
    );
  }

  Widget _buildNavigationTile({
    required Widget icon,
    required Widget selectedIcon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        leading: selected ? selectedIcon : icon,
        title: Text(label),
        selected: selected,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selectedTileColor: colorScheme.secondaryContainer.withValues(
          alpha: 0.5,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildMessagesSection() {
    // Limit to 10 most recent for sidebar display
    var conversationsList = _recentConversations.take(10).toList();

    return Consumer2<UnreadMessagesProvider, NavigationStateProvider>(
      builder: (context, unreadProvider, navProvider, _) {
        final totalUnread = unreadProvider.totalDirectMessageUnread;

        return Column(
          children: [
            _buildExpandableHeader(
              icon: Icons.message_outlined,
              selectedIcon: Icons.message,
              label: 'Messages',
              badge: totalUnread,
              expanded: _messagesExpanded,
              onTap: () {
                // Navigate to messages list view
                if (widget.onNavigateToMessagesView != null) {
                  widget.onNavigateToMessagesView!();
                }
              },
              onToggle: () =>
                  setState(() => _messagesExpanded = !_messagesExpanded),
              onAdd: widget.onNavigateToPeople, // Navigate to People
            ),
            if (_messagesExpanded)
              ...conversationsList.map((dm) {
                final displayName = dm['displayName'] ?? 'Unknown';
                final uuid = dm['uuid'] ?? '';
                final picture = dm['picture'] as String?;
                final unreadCount = unreadProvider.getDirectMessageUnreadCount(
                  uuid,
                );
                final isSelected = navProvider.isDirectMessageSelected(uuid);

                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppThemeConstants.spacingSm,
                    vertical: 2,
                  ),
                  child: AnimatedSelectionTile(
                    leading: SmallUserAvatar(
                      userId: uuid,
                      displayName: displayName,
                      pictureData: picture,
                    ),
                    title: Text(
                      displayName,
                      style: const TextStyle(
                        fontSize: AppThemeConstants.fontSizeBody,
                        color: AppThemeConstants.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: AnimatedBadge(count: unreadCount, isSmall: true),
                    selected: isSelected,
                    onTap: () {
                      navProvider.selectDirectMessage(uuid);
                      if (widget.onDirectMessageTap != null) {
                        widget.onDirectMessageTap!(uuid, displayName);
                      }
                    },
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Widget _buildChannelsSection() {
    var channelsList = List<Map<String, dynamic>>.from(widget.channels ?? []);

    return Consumer2<UnreadMessagesProvider, NavigationStateProvider>(
      builder: (context, unreadProvider, navProvider, _) {
        final totalUnread = unreadProvider.totalChannelUnread;

        return Column(
          children: [
            _buildExpandableHeader(
              icon: Icons.tag_outlined,
              selectedIcon: Icons.tag,
              label: 'Channels',
              badge: totalUnread,
              expanded: _channelsExpanded,
              onTap: () {
                // Navigate to channels list view
                if (widget.onNavigateToChannelsView != null) {
                  widget.onNavigateToChannelsView!();
                }
              },
              onToggle: () =>
                  setState(() => _channelsExpanded = !_channelsExpanded),
              onAdd: () => _showCreateChannelDialog(context), // Create channel
            ),
            if (_channelsExpanded)
              ...channelsList.map((channel) {
                final name = channel['name'] ?? 'Unknown';
                final uuid = channel['uuid'] ?? '';
                final type = channel['type'] ?? 'webrtc';
                final isPrivate = channel['isPrivate'] ?? false;
                final unreadCount = unreadProvider.getChannelUnreadCount(uuid);
                final isSelected = navProvider.isChannelSelected(uuid);

                // Icon based on channel type
                Widget leadingIcon;
                if (type == 'signal') {
                  leadingIcon = const Text(
                    '# ',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  );
                } else {
                  leadingIcon = const Icon(Icons.campaign, size: 20);
                }

                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppThemeConstants.spacingSm,
                    vertical: 2,
                  ),
                  child: AnimatedSelectionTile(
                    leading: leadingIcon,
                    title: Text(
                      isPrivate ? '🔒 $name' : name,
                      style: const TextStyle(
                        fontSize: AppThemeConstants.fontSizeBody,
                        color: AppThemeConstants.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: AnimatedBadge(count: unreadCount, isSmall: true),
                    selected: isSelected,
                    onTap: () {
                      navProvider.selectChannel(uuid, type);
                      if (widget.onChannelTap != null) {
                        widget.onChannelTap!(uuid, name, type);
                      }
                    },
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Widget _buildExpandableHeader({
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    required int badge,
    required bool expanded,
    required VoidCallback onTap,
    VoidCallback? onToggle,
    VoidCallback? onAdd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 24, color: AppThemeConstants.textPrimary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppThemeConstants.textPrimary,
                  ),
                ),
              ),
              if (badge > 0) ...[
                const SizedBox(width: 8),
                AnimatedBadge(count: badge, isSmall: false),
              ],
              if (onAdd != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: onAdd,
                  tooltip: 'Add',
                  visualDensity: VisualDensity.compact,
                  color: AppThemeConstants.textSecondary,
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 20,
                ),
                onPressed: onToggle,
                tooltip: expanded ? 'Collapse' : 'Expand',
                visualDensity: VisualDensity.compact,
                color: AppThemeConstants.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCreateChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _CreateChannelDialog(
        host: widget.host,
        onChannelCreated: (channelName) {
          // Channels will be reloaded through the parent
          setState(() {});
        },
      ),
    );
  }
}

// Create Channel Dialog
class _CreateChannelDialog extends StatefulWidget {
  final String host;
  final Function(String) onChannelCreated;

  const _CreateChannelDialog({
    required this.host,
    required this.onChannelCreated,
  });

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  String channelName = '';
  String channelDescription = '';
  bool isPrivate = false;
  String channelType = 'webrtc'; // 'webrtc' or 'signal'
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
      await ApiService.instance.init();
      final scope = channelType == 'webrtc' ? 'channelWebRtc' : 'channelSignal';
      final resp = await ApiService.instance.get('/api/roles?scope=$scope');

      if (resp.statusCode == 200) {
        final data = resp.data;
        final rolesList =
            (data['roles'] as List?)?.map((r) => Role.fromJson(r)) ?? [];

        setState(() {
          availableRoles = rolesList.toList();
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
              decoration: InputDecoration(
                labelText: 'Channel Name',
                filled: true,
                fillColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
              ),
              onChanged: (value) => setState(() => channelName = value),
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: InputDecoration(
                labelText: 'Description',
                filled: true,
                fillColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
              ),
              maxLines: 3,
              onChanged: (value) => setState(() => channelDescription = value),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Checkbox(
                  value: isPrivate,
                  onChanged: (value) {
                    setState(() => isPrivate = value ?? false);
                  },
                ),
                Text(
                  'Private',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
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
                        _loadRoles(); // Reload roles for new scope
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
                              _loadRoles(); // Reload roles for new scope
                            });
                          },
                        ),
                        const Text('Video'),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        channelType = 'signal';
                        _loadRoles(); // Reload roles for new scope
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
                              _loadRoles(); // Reload roles for new scope
                            });
                          },
                        ),
                        const Text('Text'),
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
                dropdownColor: Theme.of(context).colorScheme.surface,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                items: availableRoles.map((role) {
                  return DropdownMenuItem<Role>(
                    value: role,
                    child: Text(
                      role.name,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => selectedRole = value);
                },
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
      await ApiService.instance.init();
      final resp = await ApiService.instance.createChannel(
        name: channelName,
        description: channelDescription,
        isPrivate: isPrivate,
        type: channelType,
        defaultRoleId: selectedRole!.uuid,
      );

      if (resp.statusCode == 201) {
        widget.onChannelCreated(channelName);
        if (context.mounted) {
          // ignore: use_build_context_synchronously
          Navigator.of(context).pop();
        }
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
