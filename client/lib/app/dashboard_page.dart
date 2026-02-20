import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../screens/messages/direct_messages_screen.dart';
import '../screens/messages/signal_group_chat_screen.dart';
import '../screens/file_transfer/file_manager_screen.dart';
import '../screens/activities/activities_view.dart';
import '../screens/meetings_screen.dart';
import '../screens/dashboard/messages_list_view.dart';
import '../screens/dashboard/channels_list_view.dart';
import '../screens/people/people_screen.dart';
import '../views/video_conference_prejoin_view.dart';
import '../views/video_conference_view.dart';
import '../views/meeting_video_conference_view.dart';
import '../services/api_service.dart';
import '../services/activities_service.dart';
import '../services/user_profile_service.dart';
import '../services/logout_service.dart';
import '../services/storage/sqlite_message_store.dart';
import '../widgets/theme_widgets.dart';
import '../widgets/adaptive/adaptive_scaffold.dart';
import '../widgets/navigation_badge.dart';
import '../widgets/context_panel.dart';
import '../config/layout_config.dart';
import '../theme/app_theme_constants.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // Navigation: Track current view using index
  int _selectedIndex = 0;

  // Direct Messages
  final List<DirectMessageInfo> _directMessages = [];
  String? _activeDirectMessageUuid;
  String? _activeDirectMessageDisplayName;

  // Channels (both WebRTC and Signal)
  List<ChannelInfo> _channels = [];
  String? _activeChannelUuid;
  String? _activeChannelName;
  String? _activeChannelType;

  // Video conference state
  Map<String, dynamic>? _videoConferenceConfig;

  // People (for context panel)
  List<Map<String, dynamic>> _recentPeople = [];
  bool _isLoadingRecentPeople = false;
  int _recentPeopleLimit = 10;
  bool _hasMoreRecentPeople = true;

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
            icon: Icons.bolt,
            type: NavigationBadgeType.activities,
          ),
          selectedIcon: NavigationBadge(
            icon: Icons.bolt,
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
          icon: Icons.bolt,
          type: NavigationBadgeType.activities,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.bolt,
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

  /// Safe picture extraction from API response
  /// Handles String, Map, JSArray, and null values
  String _extractPictureData(dynamic picture) {
    if (picture == null) return '';

    try {
      if (picture is String) {
        return picture;
      } else if (picture is Map) {
        final data = picture['data'];
        if (data is String) return data;
      }
      // If it's JSArray or other type, return empty string
      return '';
    } catch (e) {
      debugPrint('[DASHBOARD] Error extracting picture: $e');
      return '';
    }
  }

  /// Format message timestamp for display
  String _formatMessageTime(String timestamp) {
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) {
        return 'now';
      } else if (difference.inMinutes < 60) {
        return '${difference.inMinutes}m';
      } else if (difference.inHours < 24) {
        return '${difference.inHours}h';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d';
      } else {
        return DateFormat('MMM d').format(dateTime);
      }
    } catch (e) {
      return '';
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only load once when dependencies are ready
    if (!_hasLoadedInitialData) {
      _hasLoadedInitialData = true;
      _loadChannels();
      _loadRecentPeople();
    }
  }

  Future<void> _loadChannels() async {
    try {
      debugPrint(
        '[DASHBOARD] Loading channels from: /client/channels?limit=20',
      );
      await ApiService.instance.init();
      final resp = await ApiService.instance.get('/client/channels?limit=20');
      debugPrint('[DASHBOARD] Channel response status: ${resp.statusCode}');
      debugPrint(
        '[DASHBOARD] Channel response data type: ${resp.data.runtimeType}',
      );
      debugPrint('[DASHBOARD] Channel response data: ${resp.data}');

      if (resp.statusCode == 200) {
        final channels = (resp.data['channels'] as List<dynamic>? ?? []);
        debugPrint(
          '[DASHBOARD] Loaded ${channels.length} channels: ${channels.map((ch) => ch['name']).toList()}',
        );

        setState(() {
          _channels = channels
              .map(
                (ch) => ChannelInfo(
                  uuid: ch['uuid'],
                  name: ch['name'],
                  type: ch['type'], // 'signal' or 'webrtc'
                  isPrivate:
                      ch['private'] ?? false, // Field is 'private' in backend
                  description: ch['description'],
                ),
              )
              .toList();
        });
        debugPrint(
          '[DASHBOARD] State updated with ${_channels.length} channels',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[DASHBOARD] Error loading channels: $e');
      debugPrint('[DASHBOARD] Stack trace: $stackTrace');
    }
  }

  Future<void> _loadRecentPeople() async {
    if (_isLoadingRecentPeople) return;

    setState(() {
      _isLoadingRecentPeople = true;
    });

    try {
      debugPrint(
        '[DASHBOARD] Loading recent people (limit: $_recentPeopleLimit)...',
      );

      // Get recent direct conversations from ActivitiesService
      final conversations =
          await ActivitiesService.getRecentDirectConversations(
            limit: _recentPeopleLimit,
          );

      debugPrint(
        '[DASHBOARD] Found ${conversations.length} recent conversations',
      );

      // Check if there might be more
      _hasMoreRecentPeople = conversations.length >= _recentPeopleLimit;

      // Get message store for last messages
      final messageStore = await SqliteMessageStore.getInstance();

      final userMap = <String, Map<String, dynamic>>{};

      for (final conv in conversations) {
        final userId = conv['userId'] as String?;
        if (userId != null && userId.isNotEmpty) {
          // Try to get profile from UserProfileService first
          final profile = UserProfileService.instance.getProfile(userId);

          // Get last message from SQLite
          String lastMessage = '';
          String lastMessageTime = '';
          try {
            final messages = await messageStore.getMessagesFromConversation(
              userId,
              limit: 1,
              types: ['message', 'file', 'image', 'voice'],
            );

            if (messages.isNotEmpty) {
              final lastMsg = messages.first;
              final msgType = lastMsg['type'] ?? 'message';

              // Format message preview
              if (msgType == 'file') {
                lastMessage = '📎 File';
              } else if (msgType == 'image') {
                lastMessage = '🖼️ Image';
              } else if (msgType == 'voice') {
                lastMessage = '🎤 Voice';
              } else {
                lastMessage = lastMsg['message'] ?? '';
                if (lastMessage.length > 35) {
                  lastMessage = '${lastMessage.substring(0, 35)}...';
                }
              }

              // Format timestamp
              final timestamp = lastMsg['timestamp'];
              if (timestamp != null) {
                lastMessageTime = _formatMessageTime(timestamp);
              }
            }
          } catch (e) {
            debugPrint(
              '[DASHBOARD] Error loading last message for $userId: $e',
            );
          }

          userMap[userId] = {
            'uuid': userId,
            'displayName':
                profile?['displayName'] ?? conv['displayName'] ?? userId,
            'atName': profile?['atName'] ?? '',
            'picture': profile?['picture'] ?? '',
            'online': false,
            'lastMessage': lastMessage,
            'lastMessageTime': lastMessageTime,
          };
        }
      }

      // Batch fetch display names from API if still showing UUIDs
      final userIdsNeedingNames = userMap.entries
          .where((entry) => entry.value['displayName'] == entry.key)
          .map((entry) => entry.key)
          .toList();

      if (userIdsNeedingNames.isNotEmpty) {
        debugPrint(
          '[DASHBOARD] Fetching display names for ${userIdsNeedingNames.length} users from API...',
        );
        try {
          await ApiService.instance.init();
          final resp = await ApiService.instance.post(
            '/client/people/info',
            data: {'userIds': userIdsNeedingNames},
          );

          if (resp.statusCode == 200) {
            final users = resp.data is List ? resp.data : [];
            for (final user in users) {
              final userId = user['uuid'] as String?;
              if (userId != null && userMap.containsKey(userId)) {
                userMap[userId]!['displayName'] = user['displayName'] ?? userId;
                userMap[userId]!['atName'] = user['atName'] ?? '';
                userMap[userId]!['picture'] = _extractPictureData(
                  user['picture'],
                );
              }
            }
            debugPrint(
              '[DASHBOARD] Updated ${users.length} display names from API',
            );
          }
        } catch (e) {
          debugPrint('[DASHBOARD] Error fetching display names from API: $e');
        }
      }

      if (!mounted) return;

      setState(() {
        _recentPeople = userMap.values.toList();
        _isLoadingRecentPeople = false;
      });

      debugPrint('[DASHBOARD] Loaded ${_recentPeople.length} recent people');
    } catch (e, stackTrace) {
      debugPrint('[DASHBOARD] Error loading recent people: $e');
      debugPrint('[DASHBOARD] Stack trace: $stackTrace');

      if (!mounted) return;

      setState(() {
        _isLoadingRecentPeople = false;
      });
    }
  }

  void _loadMoreRecentPeople() {
    if (_isLoadingRecentPeople || !_hasMoreRecentPeople) return;

    setState(() {
      _recentPeopleLimit += 10;
    });

    _loadRecentPeople();
  }

  void _onDirectMessageTap(String uuid, String displayName) async {
    // Ensure profile is loaded before opening conversation
    try {
      await UserProfileService.instance.ensureProfileLoaded(uuid);
    } catch (e) {
      debugPrint('[DASHBOARD] Warning: Could not load profile for $uuid: $e');
      // Continue anyway - will use fallback display
    }

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
        _directMessages.insert(
          0,
          DirectMessageInfo(uuid: uuid, displayName: displayName),
        );
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
      if (index != 2) {
        // Changed from 1 to 2 (People moved)
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
      // Desktop: 3-column layout (Icon Sidebar + Context Panel + Main View)
      return Scaffold(
        body: Row(
          children: [
            // 1. Narrow Icon-Only Sidebar (~60px)
            Container(
              width: 60,
              color: AppThemeConstants.sidebarBackground,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  // Activity Icon
                  _buildIconButton(
                    icon: Icons.bolt,
                    isSelected: _selectedIndex == 0,
                    onTap: () => _onNavigationSelected(0),
                    tooltip: 'Activity',
                  ),
                  const SizedBox(height: 4),
                  // Meetings Icon
                  _buildIconButton(
                    icon: Icons.today,
                    isSelected: _selectedIndex == 1,
                    onTap: () => _onNavigationSelected(1),
                    tooltip: 'Meetings',
                  ),
                  const SizedBox(height: 4),
                  // People Icon
                  _buildIconButton(
                    icon: Icons.people,
                    isSelected: _selectedIndex == 2,
                    onTap: () => _onNavigationSelected(2),
                    tooltip: 'People',
                  ),
                  const SizedBox(height: 4),
                  // Files Icon
                  _buildIconButton(
                    icon: Icons.folder,
                    isSelected: _selectedIndex == 3,
                    onTap: () => _onNavigationSelected(3),
                    tooltip: 'Files',
                  ),
                  const SizedBox(height: 4),
                  // Channels Icon
                  _buildIconButton(
                    icon: Icons.tag,
                    isSelected: _selectedIndex == 4,
                    onTap: () => _onNavigationSelected(4),
                    tooltip: 'Channels',
                  ),
                  const SizedBox(height: 4),
                  // Messages Icon
                  _buildIconButton(
                    icon: Icons.message,
                    isSelected: _selectedIndex == 5,
                    onTap: () => _onNavigationSelected(5),
                    tooltip: 'Messages',
                  ),
                  const Spacer(),
                  // Settings Icon at bottom
                  _buildIconButton(
                    icon: Icons.settings,
                    isSelected: false,
                    onTap: () => GoRouter.of(context).go('/app/settings'),
                    tooltip: 'Settings',
                  ),
                  const SizedBox(height: 4),
                  // Logout Icon
                  _buildIconButton(
                    icon: Icons.logout,
                    isSelected: false,
                    onTap: () => LogoutService.instance.logout(
                      context,
                      userInitiated: true,
                    ),
                    tooltip: 'Logout',
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),

            // 2. Context Panel (~280px) - Shows different content based on selection
            if (_shouldShowContextPanel())
              ContextPanel(
                type: _getContextPanelType(),
                onChannelTap: _onChannelTap,
                onMessageTap: _onDirectMessageTap,
                onNavigateToPeople: () {
                  setState(() {
                    _selectedIndex = 1; // Navigate to People tab
                  });
                },
                onCreateChannel: _loadChannels,
                recentPeople: _recentPeople,
                starredPeople: [], // TODO: Implement favorites
                isLoadingPeople: _isLoadingRecentPeople,
                onLoadMorePeople: _loadMoreRecentPeople,
                hasMorePeople: _hasMoreRecentPeople,
              ),

            // 3. Main View (rest of space)
            Expanded(
              child: Container(
                color: AppThemeConstants.mainViewBackground,
                child: Column(
                  children: [
                    // AppBar for desktop
                    PreferredSize(
                      preferredSize: const Size.fromHeight(64),
                      child: AppBar(
                        title: Text(_getAppBarTitle()),
                        centerTitle: false,
                        elevation: 0,
                        automaticallyImplyLeading: false,
                        backgroundColor: AppThemeConstants.mainViewBackground,
                      ),
                    ),
                    Expanded(child: body),
                  ],
                ),
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
      drawer: layoutType == LayoutType.mobile
          ? _buildMobileDrawer(context, host ?? '')
          : null,
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
            decoration: BoxDecoration(color: colorScheme.primaryContainer),
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
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () {
              Navigator.pop(context);
              LogoutService.instance.logout(context, userInitiated: true);
            },
          ),
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
    // Tablet/Desktop: 0=Activities, 1=Meetings, 2=People, 3=Files, 4=Channels, 5=Messages

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
          viewType = 'meetings';
          break;
        case 2:
          viewType = 'people';
          break;
        case 3:
          viewType = 'files';
          break;
        case 4:
          viewType = 'channels';
          break;
        case 5:
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
          onDirectMessageTap: _onDirectMessageTap,
          onChannelTap: _onChannelTap,
        );

      case 'meetings':
        return const MeetingsScreen();

      case 'messages':
        // Desktop: Always show messages list view when Messages tab is selected
        // Mobile/Tablet: Show list view when no active conversation
        if (layoutType == LayoutType.desktop) {
          // Desktop: Show list view to allow selecting conversations
          if (_activeDirectMessageUuid == null) {
            return MessagesListView(
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
              recipientUuid: _activeDirectMessageUuid!,
              recipientDisplayName: _activeDirectMessageDisplayName!,
            );
          }
        } else if (_activeDirectMessageUuid == null) {
          // Mobile/Tablet: Show list when no active conversation
          return MessagesListView(
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
              onChannelTap: _onChannelTap,
              onCreateChannel: () {
                // Reload channels after creation
                _loadChannels();
              },
            );
          } else if (_activeChannelType == 'signal') {
            // Show Signal group chat
            return SignalGroupChatScreen(
              channelUuid: _activeChannelUuid!,
              channelName: _activeChannelName!,
            );
          } else if (_activeChannelType == 'webrtc') {
            // Show WebRTC video conference
            if (_videoConferenceConfig != null) {
              final channelId = _videoConferenceConfig!['channelId'] as String;
              final channelName =
                  _videoConferenceConfig!['channelName'] as String;

              if (channelId.startsWith('call_')) {
                return MeetingVideoConferenceView(
                  meetingId: channelId,
                  meetingTitle: channelName,
                  selectedCamera: _videoConferenceConfig!['selectedCamera'],
                  selectedMicrophone:
                      _videoConferenceConfig!['selectedMicrophone'],
                  isInstantCall:
                      _videoConferenceConfig!['isInstantCall'] == true,
                  isInitiator: _videoConferenceConfig!['isInitiator'] == true,
                  sourceUserId:
                      _videoConferenceConfig!['sourceUserId'] as String?,
                  sourceChannelId:
                      _videoConferenceConfig!['sourceChannelId'] as String?,
                );
              }

              return VideoConferenceView(
                channelId: channelId,
                channelName: channelName,
                selectedCamera: _videoConferenceConfig!['selectedCamera'],
                selectedMicrophone:
                    _videoConferenceConfig!['selectedMicrophone'],
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
            onChannelTap: _onChannelTap,
            onCreateChannel: () {
              // TODO: Navigate to channel creation screen
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Channel creation coming soon')),
              );
            },
          );
        }

        if (_activeChannelUuid != null &&
            _activeChannelName != null &&
            _activeChannelType != null) {
          // Use appropriate screen based on channel type
          if (_activeChannelType == 'signal') {
            return SignalGroupChatScreen(
              channelUuid: _activeChannelUuid!,
              channelName: _activeChannelName!,
            );
          } else if (_activeChannelType == 'webrtc') {
            // WebRTC channel - show PreJoin screen or VideoConferenceView
            if (_videoConferenceConfig != null) {
              final channelId = _videoConferenceConfig!['channelId'] as String;
              final channelName =
                  _videoConferenceConfig!['channelName'] as String;

              if (channelId.startsWith('call_')) {
                return MeetingVideoConferenceView(
                  meetingId: channelId,
                  meetingTitle: channelName,
                  selectedCamera: _videoConferenceConfig!['selectedCamera'],
                  selectedMicrophone:
                      _videoConferenceConfig!['selectedMicrophone'],
                  isInstantCall:
                      _videoConferenceConfig!['isInstantCall'] == true,
                  isInitiator: _videoConferenceConfig!['isInitiator'] == true,
                  sourceUserId:
                      _videoConferenceConfig!['sourceUserId'] as String?,
                  sourceChannelId:
                      _videoConferenceConfig!['sourceChannelId'] as String?,
                );
              }

              return VideoConferenceView(
                channelId: channelId,
                channelName: channelName,
                selectedCamera: _videoConferenceConfig!['selectedCamera'],
                selectedMicrophone:
                    _videoConferenceConfig!['selectedMicrophone'],
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
          onMessageTap: _onDirectMessageTap,
          showRecentSection: true, // Always show recent section
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

enum DashboardView { directMessages, channel, people, fileManager }

class DirectMessageInfo {
  final String uuid;
  final String displayName;

  DirectMessageInfo({required this.uuid, required this.displayName});
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
          Icon(
            icon,
            size: 80,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

// Helper extension for _DashboardPageState
extension _DashboardPageHelpers on _DashboardPageState {
  /// Build icon button for sidebar
  Widget _buildIconButton({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isSelected
                ? colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(color: colorScheme.primary, width: 2)
                : null,
          ),
          child: Icon(
            icon,
            color: isSelected
                ? colorScheme.primary
                : AppThemeConstants.textSecondary,
            size: 24,
          ),
        ),
      ),
    );
  }

  /// Get AppBar title based on current selection
  String _getAppBarTitle() {
    switch (_selectedIndex) {
      case 0:
        return 'Activity';
      case 1:
        return 'People';
      case 2:
        return 'Files';
      case 3:
        if (_activeChannelName != null) {
          return '# $_activeChannelName';
        }
        return 'Channels';
      case 4:
        if (_activeDirectMessageDisplayName != null) {
          return _activeDirectMessageDisplayName!;
        }
        return 'Messages';
      default:
        return 'PeerWave';
    }
  }

  /// Determine if context panel should be shown
  bool _shouldShowContextPanel() {
    // Show for Channels, Messages, and optionally People/Files
    return _selectedIndex == 1 || // People (optional, currently placeholder)
        _selectedIndex == 3 || // Channels
        _selectedIndex == 4; // Messages
  }

  /// Get the type of context panel to display
  ContextPanelType _getContextPanelType() {
    switch (_selectedIndex) {
      case 1:
        return ContextPanelType.people; // Currently placeholder
      case 2:
        return ContextPanelType.none; // Files - no context panel for now
      case 3:
        return ContextPanelType.channels;
      case 4:
        return ContextPanelType.messages;
      default:
        return ContextPanelType.none;
    }
  }
}
