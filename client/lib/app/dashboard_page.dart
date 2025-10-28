import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:go_router/go_router.dart';
import '../screens/messages/direct_messages_screen.dart';
import '../screens/messages/signal_group_chat_screen.dart';
import '../screens/file_transfer/file_manager_screen.dart';
import 'sidebar_panel.dart';
import 'profile_card.dart';
import '../services/api_service.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // Track current view
  DashboardView _currentView = DashboardView.directMessages;
  
  // Direct Messages
  List<DirectMessageInfo> _directMessages = [];
  String? _activeDirectMessageUuid;
  String? _activeDirectMessageDisplayName;
  
  // Channels (both WebRTC and Signal)
  List<ChannelInfo> _channels = [];
  String? _activeChannelUuid;
  String? _activeChannelName;
  String? _activeChannelType;
  
  // People list
  List<dynamic> _people = [];

  @override
  void initState() {
    super.initState();
    _loadPeople();
    _loadChannels();
  }

  Future<void> _loadPeople() async {
    try {
      final host = GoRouterState.of(context).extra as Map?;
      final hostUrl = host?['host'] as String? ?? '';
      
      ApiService.init();
      final resp = await ApiService.get('$hostUrl/people/list');
      if (resp.statusCode == 200) {
        setState(() {
          _people = resp.data is String ? [resp.data] : (resp.data as List<dynamic>);
        });
      }
    } catch (e) {
      print('[NEW_DASHBOARD] Error loading people: $e');
    }
  }

  Future<void> _loadChannels() async {
    try {
      final host = GoRouterState.of(context).extra as Map?;
      final hostUrl = host?['host'] as String? ?? '';
      
      ApiService.init();
      final resp = await ApiService.get('$hostUrl/client/channels?limit=20');
      if (resp.statusCode == 200) {
        final channels = (resp.data['channels'] as List<dynamic>? ?? []);
        print('[DASHBOARD] Loaded ${channels.length} channels: ${channels.map((ch) => ch['name']).toList()}');
        
        setState(() {
          _channels = channels.map((ch) => ChannelInfo(
            uuid: ch['uuid'],
            name: ch['name'],
            type: ch['type'], // 'signal' or 'webrtc'
            isPrivate: ch['private'] ?? false, // Field is 'private' in backend
            description: ch['description'],
          )).toList();
        });
      }
    } catch (e) {
      print('[DASHBOARD] Error loading channels: $e');
    }
  }

  void _onDirectMessageTap(String uuid, String displayName) {
    setState(() {
      _activeDirectMessageUuid = uuid;
      _activeDirectMessageDisplayName = displayName;
      _currentView = DashboardView.directMessages;
      
      // Add to direct messages list if not already present
      if (!_directMessages.any((dm) => dm.uuid == uuid)) {
        _directMessages.insert(0, DirectMessageInfo(
          uuid: uuid,
          displayName: displayName,
        ));
      }
    });
  }

  void _onChannelTap(String uuid, String name, String type) {
    setState(() {
      _activeChannelUuid = uuid;
      _activeChannelName = name;
      _activeChannelType = type;
      _currentView = DashboardView.channel;
    });
  }

  void _onPeopleViewTap() {
    setState(() {
      _currentView = DashboardView.people;
    });
  }

  void _onFileManagerTap() {
    setState(() {
      _currentView = DashboardView.fileManager;
    });
  }

  @override
  Widget build(BuildContext context) {
    final extra = GoRouterState.of(context).extra;
    String? host;
    IO.Socket? socket;
    if (extra is Map) {
      host = extra['host'] as String?;
      socket = extra['socket'] as IO.Socket?;
    }

    final bool isWeb = MediaQuery.of(context).size.width > 600 ||
        Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.windows;
    final double sidebarWidth = isWeb ? 350 : 300;

    // Build content widget based on current view
    Widget contentWidget;
    switch (_currentView) {
      case DashboardView.directMessages:
        if (_activeDirectMessageUuid != null && _activeDirectMessageDisplayName != null) {
          contentWidget = DirectMessagesScreen(
            host: host ?? '',
            recipientUuid: _activeDirectMessageUuid!,
            recipientDisplayName: _activeDirectMessageDisplayName!,
          );
        } else {
          contentWidget = _EmptyStateWidget(
            icon: Icons.chat_bubble_outline,
            title: 'Direct Messages',
            subtitle: 'Select a conversation or start a new one',
          );
        }
        break;

      case DashboardView.channel:
        if (_activeChannelUuid != null && _activeChannelName != null && _activeChannelType != null) {
          // Use appropriate screen based on channel type
          if (_activeChannelType == 'signal') {
            contentWidget = SignalGroupChatScreen(
              host: host ?? '',
              channelUuid: _activeChannelUuid!,
              channelName: _activeChannelName!,
            );
          } else {
            // WebRTC channel - placeholder for now
            contentWidget = _EmptyStateWidget(
              icon: Icons.campaign,
              title: 'WebRTC Channel',
              subtitle: 'WebRTC channels are not yet implemented',
            );
          }
        } else {
          contentWidget = _EmptyStateWidget(
            icon: Icons.tag,
            title: 'Channels',
            subtitle: 'Select a channel from the sidebar',
          );
        }
        break;

      case DashboardView.people:
        contentWidget = _PeopleListWidget(
          people: _people,
          onMessageTap: _onDirectMessageTap,
          onRefresh: _loadPeople,
        );
        break;

      case DashboardView.fileManager:
        contentWidget = const FileManagerScreen();
        break;
    }

    return Material(
      color: Colors.transparent,
      child: SizedBox.expand(
        child: Row(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                double width = sidebarWidth;
                if (constraints.maxWidth < 600) width = 80;
                return SizedBox(
                  width: width,
                  child: SidebarPanel(
                    panelWidth: width,
                    buildProfileCard: () => const ProfileCard(),
                    socket: socket,
                    host: host ?? '',
                    onPeopleTap: _onPeopleViewTap,
                    onFileManagerTap: _onFileManagerTap,
                    directMessages: _directMessages.map((dm) => {
                      'uuid': dm.uuid,
                      'displayName': dm.displayName,
                    }).toList(),
                    onDirectMessageTap: _onDirectMessageTap,
                    channels: _channels.map((ch) => {
                      'uuid': ch.uuid,
                      'name': ch.name,
                      'type': ch.type,
                      'isPrivate': ch.isPrivate,
                    }).toList(),
                    onChannelTap: _onChannelTap,
                  ),
                );
              },
            ),
            Expanded(
              child: Container(
                color: const Color(0xFF36393F),
                child: contentWidget,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum DashboardView {
  directMessages,
  channel,
  people,
  fileManager,
}

class DirectMessageInfo {
  final String uuid;
  final String displayName;

  DirectMessageInfo({
    required this.uuid,
    required this.displayName,
  });
}

class SignalGroupInfo {
  final String uuid;
  final String name;
  final String type; // 'signal' or 'webrtc'
  final bool isPrivate;
  final String? description;

  SignalGroupInfo({
    required this.uuid,
    required this.name,
    required this.type,
    required this.isPrivate,
    this.description,
  });
}

// Alias for better naming
typedef ChannelInfo = SignalGroupInfo;

// Empty state widget
class _EmptyStateWidget extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyStateWidget({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 80, color: Colors.grey[600]),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

// People list widget
class _PeopleListWidget extends StatelessWidget {
  final List<dynamic> people;
  final Function(String uuid, String displayName) onMessageTap;
  final VoidCallback onRefresh;

  const _PeopleListWidget({
    required this.people,
    required this.onMessageTap,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        backgroundColor: Colors.grey[850],
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      backgroundColor: const Color(0xFF36393F),
      body: people.isEmpty
          ? const Center(
              child: Text(
                'No people found',
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView.builder(
              itemCount: people.length,
              itemBuilder: (context, index) {
                final person = people[index];
                final avatarUrl = person['picture'] ?? '';
                final displayName = person['displayName'] ?? 'Unknown';
                final uuid = person['uuid'] ?? '';
                
                return ListTile(
                  leading: avatarUrl.isNotEmpty
                      ? CircleAvatar(backgroundImage: NetworkImage(avatarUrl))
                      : const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(displayName, style: const TextStyle(color: Colors.white)),
                  trailing: IconButton(
                    icon: const Icon(Icons.message, color: Colors.amber),
                    tooltip: 'Message',
                    onPressed: () {
                      onMessageTap(uuid, displayName);
                    },
                  ),
                );
              },
            ),
    );
  }
}
