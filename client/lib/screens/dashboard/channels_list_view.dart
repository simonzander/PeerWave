import 'package:flutter/material.dart';
import '../../services/activities_service.dart';
import '../../services/api_service.dart';
import '../../models/role.dart';
import 'package:dio/dio.dart';
import 'dart:convert';

/// Channels List View - Shows member channels and public non-member channels
class ChannelsListView extends StatefulWidget {
  final String host;
  final Function(String uuid, String name, String type) onChannelTap;
  final VoidCallback onCreateChannel;

  const ChannelsListView({
    super.key,
    required this.host,
    required this.onChannelTap,
    required this.onCreateChannel,
  });

  @override
  State<ChannelsListView> createState() => _ChannelsListViewState();
}

class _ChannelsListViewState extends State<ChannelsListView> {
  bool _loading = true;
  
  // Live WebRTC channels (with participants)
  List<Map<String, dynamic>> _liveWebRTCChannels = [];
  
  // Member channels (Signal + inactive WebRTC)
  List<Map<String, dynamic>> _memberSignalChannels = [];
  List<Map<String, dynamic>> _memberInactiveWebRTCChannels = [];
  
  // Non-member public channels
  List<Map<String, dynamic>> _publicChannels = [];
  // int _publicChannelsLimit = 20; // TODO: Use when discover endpoint is ready

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    setState(() {
      _loading = true;
    });

    try {
      // Load all channels where user is member
      await _loadMemberChannels();
      
      // Load public non-member channels
      await _loadPublicChannels();

      setState(() {
        _loading = false;
      });
    } catch (e) {
      print('[CHANNELS_LIST] Error loading channels: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _loadMemberChannels() async {
    try {
      // Get WebRTC channels with participants
      final webrtcWithParticipants = await ActivitiesService.getWebRTCChannelParticipants(widget.host);
      
      // Get all member channels (both types)
      ApiService.init();
      final resp = await ApiService.get('${widget.host}/client/channels?limit=100');
      
      if (resp.statusCode == 200) {
        final data = resp.data is String ? jsonDecode(resp.data) : resp.data;
        final allChannels = (data['channels'] as List<dynamic>? ?? []);
        
        // Separate channels by type
        final webrtcChannels = <Map<String, dynamic>>[];
        final signalChannels = <Map<String, dynamic>>[];
        
        for (final channel in allChannels) {
          final channelMap = channel as Map<String, dynamic>;
          final type = channelMap['type'] as String?;
          
          if (type == 'webrtc') {
            // Check if this WebRTC channel has live participants
            final hasParticipants = webrtcWithParticipants.any((ch) => 
              ch['uuid'] == channelMap['uuid'] && 
              (ch['participants'] as List?)?.isNotEmpty == true
            );
            
            if (hasParticipants) {
              // Add participant count
              final participantsData = webrtcWithParticipants.firstWhere(
                (ch) => ch['uuid'] == channelMap['uuid']
              );
              channelMap['participants'] = participantsData['participants'];
              _liveWebRTCChannels.add(channelMap);
            } else {
              webrtcChannels.add(channelMap);
            }
          } else if (type == 'signal') {
            signalChannels.add(channelMap);
          }
        }
        
        // Get last message for Signal channels
        await _enrichSignalChannelsWithLastMessage(signalChannels);
        
        // Sort Signal channels by last message time
        signalChannels.sort((a, b) {
          final timeA = DateTime.tryParse(a['lastMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB = DateTime.tryParse(b['lastMessageTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeB.compareTo(timeA);
        });
        
        setState(() {
          _memberSignalChannels = signalChannels;
          _memberInactiveWebRTCChannels = webrtcChannels;
        });
      }
    } catch (e) {
      print('[CHANNELS_LIST] Error loading member channels: $e');
    }
  }

  Future<void> _enrichSignalChannelsWithLastMessage(List<Map<String, dynamic>> channels) async {
    for (final channel in channels) {
      try {
        final conversations = await ActivitiesService.getRecentGroupConversations(
          widget.host,
          limit: 1,
        );
        
        final channelConv = conversations.firstWhere(
          (conv) => conv['channelId'] == channel['uuid'],
          orElse: () => <String, dynamic>{},
        );
        
        if (channelConv.isNotEmpty) {
          final lastMessages = (channelConv['lastMessages'] as List?) ?? [];
          channel['lastMessage'] = lastMessages.isNotEmpty
              ? (lastMessages.first['message'] as String? ?? '')
              : '';
          channel['lastMessageTime'] = channelConv['lastMessageTime'] ?? '';
        } else {
          channel['lastMessage'] = '';
          channel['lastMessageTime'] = '';
        }
      } catch (e) {
        channel['lastMessage'] = '';
        channel['lastMessageTime'] = '';
      }
    }
  }

  Future<void> _loadPublicChannels() async {
    try {
      // TODO: Backend should provide endpoint for non-member public channels
      // For now, this would need a new endpoint like /client/channels/discover
      // that returns public channels where user is NOT a member
      
      // Placeholder - in production this would be:
      // final resp = await ApiService.get('${widget.host}/client/channels/discover?limit=$_publicChannelsLimit');
      
      setState(() {
        _publicChannels = [];
      });
    } catch (e) {
      print('[CHANNELS_LIST] Error loading public channels: $e');
    }
  }

  void _loadMorePublicChannels() {
    // setState(() {
    //   _publicChannelsLimit += 20;
    // });
    _loadPublicChannels();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Channels'),
        automaticallyImplyLeading: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadChannels,
              child: ListView(
                children: [
                  // Live WebRTC Channels (with participants)
                  if (_liveWebRTCChannels.isNotEmpty) ...[
                    _buildSectionHeader('Live Video Channels', Icons.videocam, Colors.red),
                    ..._liveWebRTCChannels.map((ch) => _buildLiveWebRTCChannelTile(ch)),
                    const SizedBox(height: 16),
                  ],

                  // Member Signal Channels
                  if (_memberSignalChannels.isNotEmpty) ...[
                    _buildSectionHeader('My Channels', Icons.tag),
                    ..._memberSignalChannels.map((ch) => _buildSignalChannelTile(ch)),
                    const SizedBox(height: 16),
                  ],

                  // Inactive WebRTC Channels (mixed with Signal if no live channels)
                  if (_liveWebRTCChannels.isEmpty && _memberInactiveWebRTCChannels.isNotEmpty) ...[
                    ..._memberInactiveWebRTCChannels.map((ch) => _buildWebRTCChannelTile(ch)),
                    const SizedBox(height: 16),
                  ],

                  // Empty state if no channels
                  if (_liveWebRTCChannels.isEmpty && 
                      _memberSignalChannels.isEmpty && 
                      _memberInactiveWebRTCChannels.isEmpty)
                    _buildEmptyState(),

                  // Public Non-Member Channels
                  if (_publicChannels.isNotEmpty) ...[
                    _buildSectionHeader('Discover', Icons.explore),
                    ..._publicChannels.map((ch) => _buildPublicChannelTile(ch)),
                    _buildLoadMoreButton(),
                  ],
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateChannelDialog(context),
        tooltip: 'Create Channel',
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showCreateChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _CreateChannelDialog(
        host: widget.host,
        onChannelCreated: (channelName) {
          // Reload channels after creation
          _loadChannels();
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, [Color? color]) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: color ?? Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveWebRTCChannelTile(Map<String, dynamic> channel) {
    final name = channel['name'] as String? ?? 'Unknown Channel';
    final uuid = channel['uuid'] as String;
    final participants = (channel['participants'] as List?) ?? [];
    final participantCount = participants.length;

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: Colors.red.withOpacity(0.2),
            child: const Icon(Icons.videocam, color: Colors.red),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.circle,
                size: 8,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        '$participantCount ${participantCount == 1 ? 'participant' : 'participants'} • LIVE',
        style: const TextStyle(color: Colors.red),
      ),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: () {
        widget.onChannelTap(uuid, name, 'webrtc');
      },
    );
  }

  Widget _buildSignalChannelTile(Map<String, dynamic> channel) {
    final name = channel['name'] as String? ?? 'Unknown Channel';
    final uuid = channel['uuid'] as String;
    final lastMessage = channel['lastMessage'] as String? ?? 'No messages';
    final lastMessageTime = channel['lastMessageTime'] as String? ?? '';
    final isPrivate = channel['private'] as bool? ?? false;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          isPrivate ? Icons.lock : Icons.tag,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        lastMessage.length > 50
            ? '${lastMessage.substring(0, 50)}...'
            : lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatTime(lastMessageTime),
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey[600],
        ),
      ),
      onTap: () {
        widget.onChannelTap(uuid, name, 'signal');
      },
    );
  }

  Widget _buildWebRTCChannelTile(Map<String, dynamic> channel) {
    final name = channel['name'] as String? ?? 'Unknown Channel';
    final uuid = channel['uuid'] as String;
    final isPrivate = channel['private'] as bool? ?? false;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(
          isPrivate ? Icons.lock : Icons.videocam,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: const Text('Video channel • No active participants'),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: () {
        widget.onChannelTap(uuid, name, 'webrtc');
      },
    );
  }

  Widget _buildPublicChannelTile(Map<String, dynamic> channel) {
    final name = channel['name'] as String? ?? 'Unknown Channel';
    final uuid = channel['uuid'] as String;
    final description = channel['description'] as String? ?? '';
    final type = channel['type'] as String? ?? 'signal';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
        child: Icon(
          type == 'webrtc' ? Icons.videocam : Icons.explore,
          color: Theme.of(context).colorScheme.onTertiaryContainer,
        ),
      ),
      title: Text(name),
      subtitle: Text(
        description.isNotEmpty ? description : 'Public channel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: ElevatedButton(
        onPressed: () {
          // TODO: Join channel API call
          widget.onChannelTap(uuid, name, type);
        },
        child: const Text('Join'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.tag,
              size: 80,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              'No channels yet',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to create a channel',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMoreButton() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: ElevatedButton.icon(
          onPressed: _loadMorePublicChannels,
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
