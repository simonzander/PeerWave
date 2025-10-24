
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../providers/role_provider.dart';
import '../providers/notification_provider.dart';
import '../services/recent_conversations_service.dart';
import '../widgets/notification_badge.dart';
import '../models/role.dart';
import 'dart:convert';


class SidebarPanel extends StatefulWidget {
  final double panelWidth;
  final Widget Function() buildProfileCard;
  final IO.Socket? socket;
  final String host;
  final VoidCallback? onPeopleTap;
  final List<Map<String, String>>? directMessages;
  final void Function(String uuid, String displayName)? onDirectMessageTap;
  final List<Map<String, dynamic>>? channels;
  final void Function(String uuid, String name, String type)? onChannelTap;
  
  const SidebarPanel({
    Key? key,
    required this.panelWidth,
    required this.buildProfileCard,
    this.socket,
    required this.host,
    this.onPeopleTap,
    this.directMessages,
    this.onDirectMessageTap,
    this.channels,
    this.onChannelTap,
  }) : super(key: key);

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel> {
  List<String> generalMessages = [];
  List<String> channelNames = [];

  @override
  void initState() {
    super.initState();
    _fetchChannels();
  }

  Future<void> _fetchChannels() async {
  try {
    ApiService.init();
    final dio = ApiService.dio;
    final resp = await dio.get('${widget.host}/client/channels');
    if (resp.statusCode == 200) {
      final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
      if (data is List) {
        setState(() {
          channelNames = data.map<String>((c) => c['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();
        });
      }
    }
  } catch (e) {
    // Handle error or timeout
    print('Error fetching channels: $e');
  }
}

  @override
  void dispose() {
    //widget.socket?.off('general');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height,
      width: widget.panelWidth,
      margin: EdgeInsets.only(bottom: 0, top: 0, left: 0, right: 0),
      child: Material(
        color: Colors.grey[900],
        elevation: 8,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 0.0, horizontal: 0.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // People entry
              InkWell(
                onTap: widget.onPeopleTap,
                child: Row(
                  children: [
                    const Icon(Icons.people, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text('People', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Files entry
              Row(
                children: [
                  const Icon(Icons.insert_drive_file, color: Colors.white),
                  const SizedBox(width: 8),
                  const Text('Files', style: TextStyle(color: Colors.white)),
                ],
              ),
              const SizedBox(height: 8),
              // Divider
              const Divider(color: Colors.white24),

              // Example: Show general channel messages
              if (generalMessages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('General Channel:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ...generalMessages.map((msg) => Text(msg, style: const TextStyle(color: Colors.white70))),
                    ],
                  ),
                ),

              // Upcoming Meetings dropdown
              const _UpcomingMeetingsDropdown(),
              const Divider(color: Colors.white24),
              _DirectMessagesDropdown(
                directMessages: widget.directMessages ?? [],
                onDirectMessageTap: widget.onDirectMessageTap,
              ),
              const Divider(color: Colors.white24),
              _ChannelsListWidget(
                channels: widget.channels ?? [],
                onChannelTap: widget.onChannelTap,
                host: widget.host,
                onChannelCreated: (channelName) {
                  // Refresh channels when a new one is created
                  setState(() {});
                },
              ),
              const Spacer(),
              widget.buildProfileCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpcomingMeetingsDropdown extends StatefulWidget {
  const _UpcomingMeetingsDropdown({Key? key}) : super(key: key);

  @override
  State<_UpcomingMeetingsDropdown> createState() => _UpcomingMeetingsDropdownState();
}

class _UpcomingMeetingsDropdownState extends State<_UpcomingMeetingsDropdown> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: Colors.white),
              onPressed: () => setState(() => expanded = !expanded),
            ),
            const Text('Upcoming Meetings', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () {},
            ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: Container(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
            child: Text('No meetings', style: TextStyle(color: Colors.white70)),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

class _ChannelsDropdown extends StatefulWidget {
  final List<String> channelNames;
  final String host;
  const _ChannelsDropdown({Key? key, required this.channelNames, required this.host}) : super(key: key);

  @override
  State<_ChannelsDropdown> createState() => _ChannelsDropdownState();
}

class _ChannelsDropdownState extends State<_ChannelsDropdown> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);
    final hasCreatePermission = roleProvider.hasServerPermission('channel.create');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: Colors.white),
              onPressed: () => setState(() => expanded = !expanded),
            ),
            const Text('Channels', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (hasCreatePermission)
              IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                onPressed: () => _showCreateChannelDialog(context),
              ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: Container(),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
            child: widget.channelNames.isEmpty
                ? Text('No channels', style: TextStyle(color: Colors.white70))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.channelNames
                        .map((name) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.0),
                              child: Text(name, style: TextStyle(color: Colors.white)),
                            ))
                        .toList(),
                  ),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  void _showCreateChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _CreateChannelDialog(
        host: widget.host,
        onChannelCreated: (channelName) {
          setState(() {
            widget.channelNames.add(channelName);
          });
        },
      ),
    );
  }
}

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
                    setState(() {
                      isPrivate = value ?? false;
                    });
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
                        _loadRoles();
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
                        _loadRoles();
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(role.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (role.description != null && role.description!.isNotEmpty)
                          Text(
                            role.description!,
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    selectedRole = value;
                  });
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
        Navigator.of(context).pop();
      }
    } catch (e) {
      print('Error creating channel: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error creating channel: $e')),
      );
    }
  }
}


class _DirectMessagesDropdown extends StatefulWidget {
  final List<Map<String, String>> directMessages;
  final void Function(String uuid, String displayName)? onDirectMessageTap;
  const _DirectMessagesDropdown({Key? key, required this.directMessages, this.onDirectMessageTap}) : super(key: key);

  @override
  State<_DirectMessagesDropdown> createState() => _DirectMessagesDropdownState();
}

class _DirectMessagesDropdownState extends State<_DirectMessagesDropdown> {
  bool expanded = true;
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
    // Merge props and recent conversations
    final allConversations = <String, Map<String, String>>{};
    
    // Add recent conversations from storage
    for (final conv in _recentConversations) {
      allConversations[conv['uuid']!] = conv;
    }
    
    // Add/override with prop conversations (these have priority)
    for (final dm in widget.directMessages) {
      allConversations[dm['uuid']!] = dm;
    }

    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        // Get conversation list
        var conversationsList = allConversations.values.toList();

        // Sort by last message time (most recent first)
        conversationsList.sort((a, b) {
          final aTime = notificationProvider.lastMessageTimes[a['uuid']];
          final bTime = notificationProvider.lastMessageTimes[b['uuid']];
          
          // If both have timestamps, compare them (descending)
          if (aTime != null && bTime != null) {
            return bTime.compareTo(aTime);
          }
          // If only one has timestamp, put it first
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          // Neither has timestamp, keep original order
          return 0;
        });

        // Limit to 20 most recent
        if (conversationsList.length > 20) {
          conversationsList = conversationsList.sublist(0, 20);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: Colors.white),
                  onPressed: () => setState(() => expanded = !expanded),
                ),
                const Text('Direct Messages', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.white),
                  onPressed: () {},
                ),
              ],
            ),
            AnimatedCrossFade(
              firstChild: Container(),
              secondChild: Padding(
                padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
                child: conversationsList.isEmpty
                    ? const Text('No messages', style: TextStyle(color: Colors.white70))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: conversationsList.map((dm) {
                          final displayName = dm['displayName'] ?? 'Unknown';
                          final uuid = dm['uuid'] ?? '';
                          return InkWell(
                            onTap: () {
                              if (widget.onDirectMessageTap != null) {
                                widget.onDirectMessageTap!(uuid, displayName);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
                              child: Row(
                                children: [
                                  const Icon(Icons.person, color: Colors.white70, size: 18),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(displayName, style: const TextStyle(color: Colors.white)),
                                  ),
                                  // Notification badge
                                  NotificationBadge(
                                    userId: uuid,
                                    child: const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
              ),
              crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        );
      },
    );
  }
}

// Channels List Widget (both Signal and WebRTC)
class _ChannelsListWidget extends StatefulWidget {
  final List<Map<String, dynamic>> channels;
  final void Function(String uuid, String name, String type)? onChannelTap;
  final String host;
  final Function(String)? onChannelCreated;
  
  const _ChannelsListWidget({
    Key? key,
    required this.channels,
    this.onChannelTap,
    required this.host,
    this.onChannelCreated,
  }) : super(key: key);

  @override
  State<_ChannelsListWidget> createState() => _ChannelsListWidgetState();
}

class _ChannelsListWidgetState extends State<_ChannelsListWidget> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        // Sort channels by last message time (most recent first)
        final sortedChannels = List<Map<String, dynamic>>.from(widget.channels);
        sortedChannels.sort((a, b) {
          final aTime = notificationProvider.lastMessageTimes[a['uuid']];
          final bTime = notificationProvider.lastMessageTimes[b['uuid']];
          
          // If both have timestamps, compare them (descending)
          if (aTime != null && bTime != null) {
            return bTime.compareTo(aTime);
          }
          // If only one has timestamp, put it first
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          // Neither has timestamp, keep original order
          return 0;
        });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                    color: Colors.white,
                  ),
                  onPressed: () => setState(() => expanded = !expanded),
                ),
                const Text(
                  'Channels',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.white),
                  onPressed: () => _showCreateChannelDialog(context),
                  tooltip: 'Create Channel',
                ),
              ],
            ),
            AnimatedCrossFade(
              firstChild: Container(),
              secondChild: Padding(
                padding: const EdgeInsets.only(left: 32.0, top: 4.0, bottom: 4.0),
                child: sortedChannels.isEmpty
                    ? const Text(
                        'No channels yet',
                        style: TextStyle(color: Colors.white70),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: sortedChannels.map((channel) {
                          final name = channel['name'] ?? 'Unknown';
                          final uuid = channel['uuid'] ?? '';
                          final type = channel['type'] ?? 'webrtc';
                          final isPrivate = channel['isPrivate'] ?? false;
                          
                          // Icon based on channel type
                          Widget leadingIcon;
                          if (type == 'signal') {
                            // Signal channels get # prefix
                            leadingIcon = const Text(
                              '# ',
                              style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold),
                            );
                          } else {
                            // WebRTC channels get speaker icon
                            leadingIcon = const Icon(Icons.campaign, color: Colors.white70, size: 18);
                          }
                          
                          return InkWell(
                            onTap: () {
                              if (widget.onChannelTap != null) {
                                widget.onChannelTap!(uuid, name, type);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
                              child: Row(
                                children: [
                                  leadingIcon,
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(color: Colors.white),
                                    ),
                                  ),
                                  if (isPrivate)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 6),
                                      child: Icon(Icons.lock, color: Colors.white54, size: 16),
                                    ),
                                  // Notification badge
                                  NotificationBadge(
                                    channelId: uuid,
                                    child: const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
              ),
              crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        );
      },
    );
  }

  void _showCreateChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _CreateChannelDialog(
        host: widget.host,
        onChannelCreated: (channelName) {
          if (widget.onChannelCreated != null) {
            widget.onChannelCreated!(channelName);
          }
        },
      ),
    );
  }
}
