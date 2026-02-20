import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dashboard_page.dart';
import '../widgets/navigation_sidebar.dart';
import '../widgets/adaptive/adaptive_scaffold.dart';
import '../widgets/navigation_badge.dart';
import '../widgets/sync_progress_banner.dart';
import '../widgets/server_panel.dart';
import '../widgets/app_drawer.dart';
import '../services/server_connection_service.dart';
import '../services/post_login_init_service.dart';
import '../services/socket_service.dart'
    if (dart.library.io) '../services/socket_service_native.dart';
import '../services/server_config_web.dart'
    if (dart.library.io) '../services/server_config_native.dart';
import '../config/layout_config.dart';
import 'package:go_router/go_router.dart';

class AppLayout extends StatefulWidget {
  final Widget? child;
  const AppLayout({super.key, this.child});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  int _selectedIndex = 0;
  StreamSubscription<bool>? _connectionSubscription;
  bool _lastKnownConnectionStatus = true;
  bool _showServerError = false;
  Timer? _activeServerStatusTimer;

  @override
  void initState() {
    super.initState();

    // Monitor connection status (native only)
    if (!kIsWeb) {
      _connectionSubscription = ServerConnectionService
          .instance
          .isConnectedStream
          .listen((isConnected) {
            if (mounted) {
              _updateActiveServerConnectionStatus();
            }

            if (!isConnected && _lastKnownConnectionStatus) {
              // Connection lost
              _lastKnownConnectionStatus = false;
              debugPrint('[APP_LAYOUT] Connection lost - showing error screen');
            } else if (isConnected && !_lastKnownConnectionStatus) {
              // Connection restored
              _lastKnownConnectionStatus = true;
              debugPrint(
                '[APP_LAYOUT] Connection restored - hiding error screen',
              );
            }
          });

      _activeServerStatusTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _updateActiveServerConnectionStatus(),
      );
    }
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _activeServerStatusTimer?.cancel();
    super.dispose();
  }

  void _updateActiveServerConnectionStatus() {
    if (kIsWeb) return;
    final activeServer = ServerConfigService.getActiveServer();
    if (activeServer == null) {
      if (_showServerError) {
        setState(() {
          _showServerError = false;
        });
      }
      return;
    }

    final socketService = SocketService.instance;
    final isConnecting = socketService.isServerConnecting(activeServer.id);
    final isConnected = socketService.isServerConnected(activeServer.id);
    final shouldShowError = !isConnected && !isConnecting;

    if (shouldShowError != _showServerError) {
      setState(() {
        _showServerError = shouldShowError;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSelectedIndexFromRoute();
  }

  /// Update selected index based on current route
  void _updateSelectedIndexFromRoute() {
    final location = GoRouterState.of(context).matchedLocation;

    int newIndex = 0;

    // Check layout type to determine index mapping
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);

    if (layoutType == LayoutType.mobile) {
      // Mobile: 0=Activities, 1=Channels, 2=Messages, 3=Files (Meetings in burger menu)
      if (location.startsWith('/app/activities')) {
        newIndex = 0;
      } else if (location.startsWith('/app/channels')) {
        newIndex = 1;
      } else if (location.startsWith('/app/messages')) {
        newIndex = 2;
      } else if (location.startsWith('/app/files')) {
        newIndex = 3;
      }
    } else {
      // Tablet/Desktop: 0=Activities, 1=Meetings, 2=People, 3=Files, 4=Channels, 5=Messages
      if (location.startsWith('/app/activities')) {
        newIndex = 0;
      } else if (location.startsWith('/app/meetings')) {
        newIndex = 1;
      } else if (location.startsWith('/app/people')) {
        newIndex = 2;
      } else if (location.startsWith('/app/files')) {
        newIndex = 3;
      } else if (location.startsWith('/app/channels')) {
        newIndex = 4;
      } else if (location.startsWith('/app/messages')) {
        newIndex = 5;
      }
    }

    if (newIndex != _selectedIndex) {
      setState(() {
        _selectedIndex = newIndex;
      });
    }
  }

  void _onNavigationSelected(int index) {
    // Check if initialization is complete before allowing navigation
    // This prevents "unable to open database" errors during autostart
    if (!PostLoginInitService.instance.isInitialized) {
      debugPrint(
        '[APP_LAYOUT] ⏸ Navigation blocked - initialization in progress',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait, initializing...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() {
      _selectedIndex = index;
    });

    // Check layout type for different navigation
    final width = MediaQuery.of(context).size.width;
    final layoutType = LayoutConfig.getLayoutType(width);

    if (layoutType == LayoutType.mobile) {
      // Mobile navigation: Activities, Channels, Messages, Files
      switch (index) {
        case 0:
          context.go('/app/activities');
          break;
        case 1:
          context.go('/app/channels');
          break;
        case 2:
          context.go('/app/messages');
          break;
        case 3:
          context.go('/app/files');
          break;
      }
    } else {
      // Tablet/Desktop navigation: Activities, Meetings, People, Files, Channels, Messages
      switch (index) {
        case 0:
          context.go('/app/activities');
          break;
        case 1:
          context.go('/app/meetings');
          break;
        case 2:
          context.go('/app/people');
          break;
        case 3:
          context.go('/app/files');
          break;
        case 4:
          context.go('/app/channels');
          break;
        case 5:
          context.go('/app/messages');
          break;
      }
    }
  }

  /// Get device-specific navigation destinations
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
          label: 'Activity',
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

    // Tablet & Desktop: Activities, Meetings, People, Files, Channels, Messages (6 items)
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
          icon: Icons.today_outlined,
          type: NavigationBadgeType.meetings,
        ),
        selectedIcon: NavigationBadge(
          icon: Icons.today,
          type: NavigationBadgeType.meetings,
          selected: true,
        ),
        label: 'Meetings',
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
  Widget build(BuildContext context) {
    return _buildContent(context);
  }

  Widget _buildContent(BuildContext context) {
    // If server is unavailable (native only), show error screen
    if (_showServerError && !kIsWeb) {
      final colorScheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Row(
          children: [
            // Keep server panel visible so user can switch servers
            const ServerPanel(),

            // Error message
            Expanded(
              child: Center(
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_off,
                          size: 64,
                          color: colorScheme.error,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Server Unavailable',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Server is temporarily not available',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                        FilledButton.icon(
                          onPressed: () {
                            // Reset connection status to retry
                            ServerConnectionService.instance.checkConnection();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Normal app layout
    final bool isWeb = kIsWeb;
    final location = GoRouterState.of(context).matchedLocation;

    // Hide navigation sidebar on signal-setup, login, and server-selection screens
    // But keep server panel visible on native
    final shouldShowNavigation =
        !location.startsWith('/signal-setup') &&
        location != '/login' &&
        location != '/server-selection';

    if (isWeb) {
      // Check layout type
      final width = MediaQuery.of(context).size.width;
      final layoutType = LayoutConfig.getLayoutType(width);

      if (layoutType == LayoutType.desktop || layoutType == LayoutType.tablet) {
        // Desktop/Tablet: Navigation Sidebar + Content
        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Row(
            children: [
              // Navigation Sidebar (60px)
              const NavigationSidebar(),

              // Content with Sync Banner
              Expanded(
                child: Column(
                  children: [
                    // 🚀 Sync Progress Banner
                    const SyncProgressBanner(),

                    // Main Content (Views handle their own Context Panel + Main Content)
                    Expanded(child: widget.child ?? const DashboardPage()),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      // Mobile: Use AdaptiveScaffold with bottom navigation
      final destinations = _getNavigationDestinations(context);

      return AdaptiveScaffold(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onNavigationSelected,
        destinations: destinations,
        appBarTitle: 'PeerWave',
        appBarActions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/app/settings'),
            tooltip: 'Settings',
          ),
        ],
        drawer: AppDrawer(
          isAuthenticated: true,
          currentRoute: GoRouterState.of(context).matchedLocation,
        ),
        body: Column(
          children: [
            // 🚀 Sync Progress Banner
            const SyncProgressBanner(),

            // Main Content
            Expanded(child: widget.child ?? const DashboardPage()),
          ],
        ),
      );
    } else {
      // Native Desktop: Server Panel (far left) + Navigation Sidebar + Content
      final width = MediaQuery.of(context).size.width;
      final layoutType = LayoutConfig.getLayoutType(width);

      if (layoutType == LayoutType.desktop || layoutType == LayoutType.tablet) {
        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Row(
            children: [
              // Server Panel (far left, 72px) - Always visible on native
              const ServerPanel(),

              // Navigation Sidebar (60px) - Hidden on signal-setup/login
              if (shouldShowNavigation) const NavigationSidebar(),

              // Content with Sync Banner
              Expanded(
                child: Column(
                  children: [
                    // 🚀 Sync Progress Banner
                    const SyncProgressBanner(),

                    // Main Content (Views handle their own Context Panel + Main Content)
                    Expanded(child: widget.child ?? const DashboardPage()),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      // Mobile native - use AdaptiveScaffold with bottom navigation
      final destinations = _getNavigationDestinations(context);

      return AdaptiveScaffold(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onNavigationSelected,
        destinations: destinations,
        appBarTitle: 'PeerWave',
        appBarActions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/app/settings'),
            tooltip: 'Settings',
          ),
        ],
        drawer: AppDrawer(
          isAuthenticated: true,
          currentRoute: GoRouterState.of(context).matchedLocation,
        ),
        body: Column(
          children: [
            // 🚀 Sync Progress Banner
            const SyncProgressBanner(),

            // Main Content
            Expanded(child: widget.child ?? const DashboardPage()),
          ],
        ),
      );
    }
  }
}
