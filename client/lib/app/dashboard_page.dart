import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../screens/messages/direct_messages_screen.dart';
import '../screens/messages/signal_group_chat_screen.dart';
import '../screens/file_transfer/file_manager_screen.dart';
import '../screens/activities/activities_view.dart';
import '../screens/dashboard/messages_list_view.dart';
import '../screens/dashboard/channels_list_view.dart';
import '../screens/people/people_screen.dart';
import '../views/video_conference_prejoin_view.dart';
import '../views/video_conference_view.dart';
import '../services/api_service.dart';
import '../widgets/theme_widgets.dart';
import '../widgets/adaptive/adaptive_scaffold.dart';
import '../widgets/navigation_badge.dart';
import '../widgets/desktop_navigation_drawer.dart';
import '../config/layout_config.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // Navigation: Track current view using index
  int _selectedIndex = 0;
  
  // Direct Messages
  List<DirectMessageInfo> _directMessages = [];
  String? _activeDirectMessageUuid;
  String? _activeDirectMessageDisplayName;
  
  // Channels (both WebRTC and Signal)
  List<ChannelInfo> _channels = [];
  String? _activeChannelUuid;
  String? _activeChannelName;
  String? _activeChannelType;
  
  // Video conference state
  Map<String, dynamic>? _videoConferenceConfig;
  
  // Flag to track if data has been loaded
  bool _hasLoadedInitialData = false;

  // Get device-specific navigation destinations
  List<NavigationDestination> _getNavigationDestinations(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);
    
    // Mobile: Activities, Channels, Messages, Files (4 items)
    if (layoutType == LayoutType.mobile) {
      return [
        NavigationDestination(
          icon: NavigationBadge(
            icon: Icons.notifications_none,
            type: NavigationBadgeType.activities,
          ),
          selectedIcon: NavigationBadge(
            icon: Icons.notifications,
            type: NavigationBadgeType.activities,
            selected: true,
          ),
          label: 'Activitiy',
        ),
        NavigationDestination(
          icon: NavigationBadge(
            icon: Icons.tag_outlined,
            type: NavigationBadgeType.channels,
          ),
          selectedIcon: NavigationBadge(
            icon: Icons.tag,
            type: NavigationBadgeType.channels,
            selected: true,
          ),
          label: 'Channels',
        ),
        NavigationDestination(
          icon: NavigationBadge(
            icon: Icons.message_outlined,
            type: NavigationBadgeType.messages,
          ),
          selectedIcon: NavigationBadge(
            icon: Icons.message,
            type: NavigationBadgeType.messages,
            selected: true,
          ),
          label: 'Messages',
        ),
        NavigationDestination(
          icon: NavigationBadge(
            icon: Icons.folder_outlined,
            type: NavigationBadgeType.files,
          ),
          selectedIcon: NavigationBadge(
            icon: Icons.folder,
            type: NavigationBadgeType.files,
            selected: true,
          ),
          label: 'Files',
        ),
      ];
    }
    
    // Tablet & Desktop: Activities, People, Files, Channels, Messages (5 items)
    return [
      NavigationDestination(
        icon: NavigationBadge(
          icon: Icons.notifications_none,
          type: NavigationBadgeType.activities,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.notifications,
          type: NavigationBadgeType.activities,
          selected: true,
        ),
        label: 'Activity',
      ),
      NavigationDestination(
        icon: NavigationBadge(
          icon: Icons.people_outline,
          type: NavigationBadgeType.people,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.people,
          type: NavigationBadgeType.people,
          selected: true,
        ),
        label: 'People',
      ),
      NavigationDestination(
        icon: NavigationBadge(
          icon: Icons.folder_outlined,
          type: NavigationBadgeType.files,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.folder,
          type: NavigationBadgeType.files,
          selected: true,
        ),
        label: 'Files',
      ),
      NavigationDestination(
        icon: NavigationBadge(
          icon: Icons.tag_outlined,
          type: NavigationBadgeType.channels,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.tag,
          type: NavigationBadgeType.channels,
          selected: true,
        ),
        label: 'Channels',
      ),
      NavigationDestination(
        icon: NavigationBadge(
          icon: Icons.message_outlined,
          type: NavigationBadgeType.messages,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.message,
          type: NavigationBadgeType.messages,
          selected: true,
        ),
        label: 'Messages',
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    // Don't access context here - wait for didChangeDependencies
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only load once when dependencies are ready
    if (!_hasLoadedInitialData) {
      _hasLoadedInitialData = true;
      _loadChannels();
    }
  }

  Future<void> _loadChannels() async {
    try {
      final host = GoRouterState.of(context).extra as Map?;
      final hostUrl = host?['host'] as String? ?? '';
      
      print('[DASHBOARD] Loading channels from: $hostUrl/client/channels?limit=20');
      ApiService.init();
      final resp = await ApiService.get('$hostUrl/client/channels?limit=20');
      print('[DASHBOARD] Channel response status: ${resp.statusCode}');
      print('[DASHBOARD] Channel response data type: ${resp.data.runtimeType}');
      print('[DASHBOARD] Channel response data: ${resp.data}');
      
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
        print('[DASHBOARD] State updated with ${_channels.length} channels');
      }
    } catch (e, stackTrace) {
      print('[DASHBOARD] Error loading channels: $e');
      print('[DASHBOARD] Stack trace: $stackTrace');
    }
  }

  void _onDirectMessageTap(String uuid, String displayName) {
    setState(() {
      _activeDirectMessageUuid = uuid;
      _activeDirectMessageDisplayName = displayName;
      _videoConferenceConfig = null;
      
      // Set correct index based on device layout
      final width = MediaQuery.of(context).size.width;
      final layoutType = LayoutConfig.getLayoutType(width);
      
      if (layoutType == LayoutType.mobile) {
        _selectedIndex = 2; // Mobile: Messages is at index 2
      } else {
        _selectedIndex = 4; // Tablet/Desktop: Messages is at index 4
      }
      
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
      _videoConferenceConfig = null;
      
      // Set correct index based on device layout
      final width = MediaQuery.of(context).size.width;
      final layoutType = LayoutConfig.getLayoutType(width);
      
      if (layoutType == LayoutType.mobile) {
        _selectedIndex = 1; // Mobile: Channels is at index 1
      } else {
        _selectedIndex = 3; // Tablet/Desktop: Channels is at index 3
      }
    });
  }

  void _onNavigationSelected(int index) {
    setState(() {
      _selectedIndex = index;
      _videoConferenceConfig = null;
      
      // Reset active items when switching views
      if (index != 0) {
        _activeDirectMessageUuid = null;
        _activeDirectMessageDisplayName = null;
      }
      if (index != 1) {
        _activeChannelUuid = null;
        _activeChannelName = null;
        _activeChannelType = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final extra = GoRouterState.of(context).extra;
    String? host;
    if (extra is Map) {
      host = extra['host'] as String?;
    }

    // Get device-specific destinations
    final destinations = _getNavigationDestinations(context);
    
    // Build content based on selected index
    Widget body = _buildContent(host ?? '');

    // Check layout type for custom desktop drawer
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);
    
    if (layoutType == LayoutType.desktop) {
      // Desktop: Use custom drawer with expandable sections
      return Scaffold(
        body: Row(
          children: [
            DesktopNavigationDrawer(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _onNavigationSelected,
              destinations: destinations,
              host: host ?? '',
              channels: _channels.map((ch) => {
                'uuid': ch.uuid,
                'name': ch.name,
                'type': ch.type,
                'isPrivate': ch.isPrivate,
              }).toList(),
              onChannelTap: _onChannelTap,
              onDirectMessageTap: _onDirectMessageTap,
              onNavigateToPeople: () {
                setState(() {
                  _selectedIndex = 1; // Navigate to People tab (index 1 on desktop)
                });
              },
              onNavigateToMessagesView: () {
                setState(() {
                  _selectedIndex = 4; // Navigate to Messages list view (index 4 on desktop)
                  _activeDirectMessageUuid = null;
                  _activeDirectMessageDisplayName = null;
                });
              },
              onNavigateToChannelsView: () {
                setState(() {
                  _selectedIndex = 3; // Navigate to Channels list view (index 3 on desktop)
                  _activeChannelUuid = null;
                  _activeChannelName = null;
                  _activeChannelType = null;
                });
              },
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => GoRouter.of(context).go('/app/settings'),
                    tooltip: 'Settings',
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  // AppBar for desktop
                  PreferredSize(
                    preferredSize: const Size.fromHeight(64),
                    child: AppBar(
                      title: const Text('PeerWave'),
                      centerTitle: true,
                      elevation: 1,
                      automaticallyImplyLeading: false,
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Mobile & Tablet: Use standard AdaptiveScaffold
    return AdaptiveScaffold(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _onNavigationSelected,
      destinations: destinations,
      appBarTitle: 'PeerWave',
      appBarActions: [
        const ThemeToggleButton(),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => GoRouter.of(context).go('/app/settings'),
          tooltip: 'Settings',
        ),
      ],
      // Mobile: Add drawer with additional menu items
      drawer: layoutType == LayoutType.mobile ? _buildMobileDrawer(context, host ?? '') : null,
      body: body,
    );
  }

  // Build mobile drawer with additional options
  Widget _buildMobileDrawer(BuildContext context, String host) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.waves,
                  size: 48,
                  color: colorScheme.onPrimaryContainer,
                ),
                const SizedBox(height: 16),
                Text(
                  'PeerWave',
                  style: TextStyle(
                    color: colorScheme.onPrimaryContainer,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('People'),
            onTap: () {
              Navigator.pop(context);
              // Navigate to People view (not available in mobile, so show message)
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('People view available on tablet/desktop'),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              GoRouter.of(context).go('/app/settings');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.pop(context);
              showAboutDialog(
                context: context,
                applicationName: 'PeerWave',
                applicationVersion: '1.0.0',
                applicationLegalese: '© 2025 PeerWave',
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildContent(String host) {
    // Get layout type to determine index mapping
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);
    
    // Map index based on device type
    // Mobile: 0=Activities, 1=Channels, 2=Messages, 3=Files
    // Tablet/Desktop: 0=Activities, 1=People, 2=Files, 3=Channels, 4=Messages
    
    String viewType;
    if (layoutType == LayoutType.mobile) {
      switch (_selectedIndex) {
        case 0:
          viewType = 'activities';
          break;
        case 1:
          viewType = 'channels';
          break;
        case 2:
          viewType = 'messages';
          break;
        case 3:
          viewType = 'files';
          break;
        default:
          viewType = 'activities';
      }
    } else {
      // Tablet & Desktop
      switch (_selectedIndex) {
        case 0:
          viewType = 'activities';
          break;
        case 1:
          viewType = 'people';
          break;
        case 2:
          viewType = 'files';
          break;
        case 3:
          viewType = 'channels';
          break;
        case 4:
          viewType = 'messages';
          break;
        default:
          viewType = 'activities';
      }
    }
    
    // Build content based on view type
    switch (viewType) {
      case 'activities':
        return ActivitiesView(
          host: host,
          onDirectMessageTap: _onDirectMessageTap,
          onChannelTap: _onChannelTap,
        );
        
      case 'messages':
        // Desktop: Always show messages list view when Messages tab is selected
        // Mobile/Tablet: Show list view when no active conversation
        if (layoutType == LayoutType.desktop) {
          // Desktop: Show list view to allow selecting conversations
          if (_activeDirectMessageUuid == null) {
            return MessagesListView(
              host: host,
              onMessageTap: _onDirectMessageTap,
              onNavigateToPeople: () {
                setState(() {
                  _selectedIndex = 1; // Navigate to People tab
                });
              },
            );
          } else {
            // Show conversation
            return DirectMessagesScreen(
              host: host,
              recipientUuid: _activeDirectMessageUuid!,
              recipientDisplayName: _activeDirectMessageDisplayName!,
            );
          }
        } else if (_activeDirectMessageUuid == null) {
          // Mobile/Tablet: Show list when no active conversation
          return MessagesListView(
            host: host,
            onMessageTap: _onDirectMessageTap,
            onNavigateToPeople: () {
              setState(() {
                if (layoutType == LayoutType.mobile) {
                  // Mobile doesn't have People tab, show drawer
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Open drawer to access People'),
                    ),
                  );
                } else {
                  // Tablet/Desktop - switch to People tab
                  _selectedIndex = 1;
                }
              });
            },
          );
        } else {
          // Mobile/Tablet: Show active conversation
          return DirectMessagesScreen(
            host: host,
            recipientUuid: _activeDirectMessageUuid!,
            recipientDisplayName: _activeDirectMessageDisplayName!,
          );
        }

      case 'channels':
        // Desktop: Always show channels list view when Channels tab is selected
        // Mobile/Tablet: Show list view when no active channel
        if (layoutType == LayoutType.desktop) {
          // Desktop: Show list view to allow selecting channels
          if (_activeChannelUuid == null) {
            return ChannelsListView(
              host: host,
              onChannelTap: _onChannelTap,
              onCreateChannel: () {
                // Reload channels after creation
                _loadChannels();
              },
            );
          } else if (_activeChannelType == 'signal') {
            // Show Signal group chat
            return SignalGroupChatScreen(
              host: host,
              channelUuid: _activeChannelUuid!,
              channelName: _activeChannelName!,
            );
          } else if (_activeChannelType == 'webrtc') {
            // Show WebRTC video conference
            if (_videoConferenceConfig != null) {
              return VideoConferenceView(
                channelId: _videoConferenceConfig!['channelId'],
                channelName: _videoConferenceConfig!['channelName'],
                selectedCamera: _videoConferenceConfig!['selectedCamera'],
                selectedMicrophone: _videoConferenceConfig!['selectedMicrophone'],
              );
            } else {
              return VideoConferencePreJoinView(
                channelId: _activeChannelUuid!,
                channelName: _activeChannelName!,
                onJoinReady: (config) {
                  setState(() {
                    _videoConferenceConfig = config;
                  });
                },
              );
            }
          } else {
            return _EmptyStateWidget(
              icon: Icons.campaign,
              title: 'Unknown Channel Type',
              subtitle: 'Channel type "$_activeChannelType" is not supported',
            );
          }
        } else if (_activeChannelUuid == null) {
          // Show channels list view
          return ChannelsListView(
            host: host,
            onChannelTap: _onChannelTap,
            onCreateChannel: () {
              // TODO: Navigate to channel creation screen
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Channel creation coming soon'),
                ),
              );
            },
          );
        }
        
        if (_activeChannelUuid != null && _activeChannelName != null && _activeChannelType != null) {
          // Use appropriate screen based on channel type
          if (_activeChannelType == 'signal') {
            return SignalGroupChatScreen(
              host: host,
              channelUuid: _activeChannelUuid!,
              channelName: _activeChannelName!,
            );
          } else if (_activeChannelType == 'webrtc') {
            // WebRTC channel - show PreJoin screen or VideoConferenceView
            if (_videoConferenceConfig != null) {
              return VideoConferenceView(
                channelId: _videoConferenceConfig!['channelId'],
                channelName: _videoConferenceConfig!['channelName'],
                selectedCamera: _videoConferenceConfig!['selectedCamera'],
                selectedMicrophone: _videoConferenceConfig!['selectedMicrophone'],
              );
            } else {
              return VideoConferencePreJoinView(
                channelId: _activeChannelUuid!,
                channelName: _activeChannelName!,
                onJoinReady: (config) {
                  setState(() {
                    _videoConferenceConfig = config;
                  });
                },
              );
            }
          } else {
            return _EmptyStateWidget(
              icon: Icons.campaign,
              title: 'Unknown Channel Type',
              subtitle: 'Channel type "$_activeChannelType" is not supported',
            );
          }
        } else {
          return _EmptyStateWidget(
            icon: Icons.tag,
            title: 'Channels',
            subtitle: 'Select a channel to start chatting',
          );
        }

      case 'people':
        return PeopleScreen(
          host: host,
          onMessageTap: _onDirectMessageTap,
        );

      case 'files':
        return const FileManagerScreen();

      default:
        return _EmptyStateWidget(
          icon: Icons.error_outline,
          title: 'Error',
          subtitle: 'Unknown view',
        );
    }
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
