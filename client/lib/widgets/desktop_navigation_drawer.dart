import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/notification_provider.dart';
import '../services/recent_conversations_service.dart';
import '../services/api_service.dart';
import '../models/role.dart';
import 'package:dio/dio.dart';

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
  });

  @override
  State<DesktopNavigationDrawer> createState() => _DesktopNavigationDrawerState();
}

class _DesktopNavigationDrawerState extends State<DesktopNavigationDrawer> {
  bool _messagesExpanded = true; // Non-collapsed by default
  bool _channelsExpanded = true; // Non-collapsed by default
  List<Map<String, String>> _recentConversations = [];

  @override
  void initState() {
    super.initState();
    _loadRecentConversations();
  }

  Future<void> _loadRecentConversations() async {
    final conversations = await RecentConversationsService.getRecentConversations();
    setState(() {
      _recentConversations = conversations;
    });
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
            color: colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Leading (header)
          if (widget.leading != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: widget.leading,
            ),
          
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
            Divider(color: colorScheme.outlineVariant.withOpacity(0.5)),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: widget.trailing,
            ),
          ],
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        selectedTileColor: colorScheme.secondaryContainer.withOpacity(0.5),
        onTap: onTap,
      ),
    );
  }

  Widget _buildMessagesSection() {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        // Get and sort conversations by last message time
        var conversationsList = List<Map<String, String>>.from(_recentConversations);
        conversationsList.sort((a, b) {
          final aTime = notificationProvider.lastMessageTimes[a['uuid']];
          final bTime = notificationProvider.lastMessageTimes[b['uuid']];
          
          if (aTime != null && bTime != null) {
            return bTime.compareTo(aTime);
          }
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          return 0;
        });

        // Limit to 10 most recent
        if (conversationsList.length > 10) {
          conversationsList = conversationsList.sublist(0, 10);
        }

        // Calculate total unread count for Messages
        final totalUnread = conversationsList.fold(0, (sum, dm) {
          return sum + notificationProvider.getUnreadCount(dm['uuid'] ?? '');
        });

        return Column(
          children: [
            _buildExpandableHeader(
              icon: Icons.message_outlined,
              selectedIcon: Icons.message,
              label: 'Messages',
              badge: totalUnread,
              expanded: _messagesExpanded,
              onTap: () => setState(() => _messagesExpanded = !_messagesExpanded),
              onAdd: widget.onNavigateToPeople, // Navigate to People
            ),
            if (_messagesExpanded)
              ...conversationsList.map((dm) {
                final displayName = dm['displayName'] ?? 'Unknown';
                final uuid = dm['uuid'] ?? '';
                final unreadCount = notificationProvider.getUnreadCount(uuid);
                
                return Padding(
                  padding: const EdgeInsets.only(left: 28, right: 12, top: 2, bottom: 2),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.person, size: 20),
                    title: Text(
                      displayName,
                      style: const TextStyle(fontSize: 14),
                    ),
                    trailing: unreadCount > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.error,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              unreadCount > 99 ? '99+' : unreadCount.toString(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onError,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () {
                      if (widget.onDirectMessageTap != null) {
                        widget.onDirectMessageTap!(uuid, displayName);
                      }
                    },
                  ),
                );
              }).toList(),
          ],
        );
      },
    );
  }

  Widget _buildChannelsSection() {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        // Get and sort channels by last message time
        var channelsList = List<Map<String, dynamic>>.from(widget.channels ?? []);
        channelsList.sort((a, b) {
          final aTime = notificationProvider.lastMessageTimes[a['uuid']];
          final bTime = notificationProvider.lastMessageTimes[b['uuid']];
          
          if (aTime != null && bTime != null) {
            return bTime.compareTo(aTime);
          }
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          return 0;
        });

        // Calculate total unread count for Channels
        final totalUnread = channelsList.fold(0, (sum, channel) {
          return sum + notificationProvider.getUnreadCount(channel['uuid'] ?? '');
        });

        return Column(
          children: [
            _buildExpandableHeader(
              icon: Icons.tag_outlined,
              selectedIcon: Icons.tag,
              label: 'Channels',
              badge: totalUnread,
              expanded: _channelsExpanded,
              onTap: () => setState(() => _channelsExpanded = !_channelsExpanded),
              onAdd: () => _showCreateChannelDialog(context), // Create channel
            ),
            if (_channelsExpanded)
              ...channelsList.map((channel) {
                final name = channel['name'] ?? 'Unknown';
                final uuid = channel['uuid'] ?? '';
                final type = channel['type'] ?? 'webrtc';
                final isPrivate = channel['isPrivate'] ?? false;
                final unreadCount = notificationProvider.getUnreadCount(uuid);
                
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
                  padding: const EdgeInsets.only(left: 28, right: 12, top: 2, bottom: 2),
                  child: ListTile(
                    dense: true,
                    leading: leadingIcon,
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        if (isPrivate)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.lock, size: 14, color: Colors.grey),
                          ),
                      ],
                    ),
                    trailing: unreadCount > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.error,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              unreadCount > 99 ? '99+' : unreadCount.toString(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onError,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () {
                      if (widget.onChannelTap != null) {
                        widget.onChannelTap!(uuid, name, type);
                      }
                    },
                  ),
                );
              }).toList(),
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
    VoidCallback? onAdd,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        leading: Icon(icon),
        title: Row(
          children: [
            Expanded(child: Text(label)),
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.error,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  badge > 99 ? '99+' : badge.toString(),
                  style: TextStyle(
                    color: colorScheme.onError,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (onAdd != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                onPressed: onAdd,
                tooltip: 'Add',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
        trailing: Icon(
          expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          size: 20,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        onTap: onTap,
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
    Key? key,
    required this.host,
    required this.onChannelCreated,
  }) : super(key: key);

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
      ApiService.init();
      final dio = ApiService.dio;
      final scope = channelType == 'webrtc' ? 'channelWebRtc' : 'channelSignal';
      final resp = await dio.get('${widget.host}/api/roles?scope=$scope');
      
      if (resp.statusCode == 200) {
        final data = resp.data;
        final rolesList = (data['roles'] as List?)
            ?.map((r) => Role.fromJson(r))
            .toList() ?? [];
        
        setState(() {
          availableRoles = rolesList;
          selectedRole = rolesList.isNotEmpty ? rolesList.first : null;
          isLoadingRoles = false;
        });
      }
    } catch (e) {
      setState(() => isLoadingRoles = false);
      print('Error loading roles: $e');
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
                  onChanged: (value) {
                    setState(() => isPrivate = value ?? false);
                  },
                ),
                const Text('Private'),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Channel Type:', style: TextStyle(fontWeight: FontWeight.bold)),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('WebRTC'),
                    value: 'webrtc',
                    groupValue: channelType,
                    onChanged: (value) {
                      setState(() {
                        channelType = value!;
                        _loadRoles(); // Reload roles for new scope
                      });
                    },
                  ),
                ),
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Signal'),
                    value: 'signal',
                    groupValue: channelType,
                    onChanged: (value) {
                      setState(() {
                        channelType = value!;
                        _loadRoles(); // Reload roles for new scope
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Default Join Role:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (isLoadingRoles)
              const Center(child: CircularProgressIndicator())
            else if (availableRoles.isEmpty)
              const Text('No standard roles available', style: TextStyle(color: Colors.grey))
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
      ApiService.init();
      final dio = ApiService.dio;
      final resp = await dio.post(
        '${widget.host}/client/channels',
        data: {
          'name': channelName,
          'description': channelDescription,
          'private': isPrivate,
          'type': channelType,
          'defaultRoleId': selectedRole!.uuid,
        },
        options: Options(contentType: 'application/json'),
      );
      
      if (resp.statusCode == 201) {
        widget.onChannelCreated(channelName);
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      print('Error creating channel: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating channel: $e')),
        );
      }
    }
  }
}
