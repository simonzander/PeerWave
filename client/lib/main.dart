import 'package:socket_io_client/socket_io_client.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'auth/auth_layout_web.dart' if (dart.library.io) 'auth/auth_layout_native.dart';
import 'auth/magic_link_web.dart' if (dart.library.io) 'auth/magic_link_native.dart';
import 'auth/otp_web.dart';
import 'auth/invitation_entry_page.dart';
import 'auth/register_webauthn_page.dart' if (dart.library.io) 'auth/register_webauthn_page_native.dart';
import 'auth/register_profile_page.dart';
import 'auth/magic_link_native.dart' show MagicLinkWebPageWithServer;
import 'screens/signal_setup_screen.dart';
import 'services/signal_setup_service.dart';
import 'services/device_identity_service.dart';
import 'services/logout_service.dart';
import 'services/preferences_service.dart';
import 'services/api_service.dart' show setGlobalUnauthorizedHandler;
import 'services/socket_service.dart' show setSocketUnauthorizedHandler;
import 'app/app_layout.dart';
import 'app/dashboard_page.dart';
import 'app/settings_sidebar.dart';
import 'app/profile_page.dart';
import 'app/settings/general_settings_page.dart';
import 'app/settings/server_settings_page.dart';
import 'app/settings/notification_settings_page.dart';
import 'app/settings/system_tray_settings_page.dart';
import 'app/webauthn_web.dart' if (dart.library.io) 'app/webauthn_stub.dart';
import 'app/backupcode_web.dart' if (dart.library.io) 'app/backupcode_web_native.dart';
import 'app/backupcode_settings_page.dart' if (dart.library.io) 'app/backupcode_settings_page_native.dart';
// Use conditional import for 'services/auth_service.dart'
import 'services/auth_service_web.dart' if (dart.library.io) 'services/auth_service_native.dart';
import 'services/api_service.dart';
import 'auth/backup_recover_web.dart' if (dart.library.io) 'auth/backup_recover_web_native.dart';
import 'services/socket_service.dart';
import 'services/server_connection_service.dart';
import 'widgets/server_unavailable_overlay.dart';
// Role management imports
import 'providers/role_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/navigation_state_provider.dart';
import 'services/role_api_service.dart';
import 'screens/admin/role_management_screen.dart';
import 'screens/admin/user_management_screen.dart';
import 'web_config.dart';
// Theme imports
import 'theme/theme_provider.dart';
// Unread Messages Provider
import 'providers/unread_messages_provider.dart';
// File Transfer Stats Provider
import 'providers/file_transfer_stats_provider.dart';
// P2P File Transfer imports
import 'services/file_transfer/webrtc_service.dart';
import 'services/file_transfer/p2p_coordinator.dart';
import 'services/file_transfer/download_manager.dart';
import 'services/file_transfer/storage_interface.dart';
import 'services/file_transfer/encryption_service.dart';
import 'services/file_transfer/chunking_service.dart';
// WebRTC Conference imports
import 'services/video_conference_service.dart';
import 'widgets/call_top_bar.dart';
import 'widgets/call_overlay.dart';
import 'widgets/custom_window_title_bar.dart';
import 'screens/file_transfer/file_upload_screen.dart';
import 'screens/file_transfer/file_manager_screen.dart';
import 'screens/file_transfer/file_browser_screen.dart';
import 'screens/file_transfer/downloads_screen.dart';
import 'screens/file_transfer/file_transfer_hub.dart';
import 'widgets/socket_aware_widget.dart';
// Post-login service orchestration
import 'services/post_login_init_service.dart';
// View Pages (Dashboard Refactoring)
import 'app/views/activities_view_page.dart';
import 'app/views/messages_view_page.dart';
import 'app/views/channels_view_page.dart';
import 'app/views/people_view_page.dart';
import 'app/views/files_view_page.dart';
// Native server selection
import 'screens/server_selection_screen.dart';
import 'services/server_config_web.dart' if (dart.library.io) 'services/server_config_native.dart';
import 'services/clientid_native.dart' if (dart.library.js) 'services/clientid_web_stub.dart';
import 'services/session_auth_service.dart';
import 'debug_storage.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'core/storage/app_directories.dart';
import 'services/system_tray_service_web.dart' if (dart.library.io) 'services/system_tray_service.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ApiService.init();
  String? initialMagicKey;

  // NOTE: Client ID generation moved to POST-LOGIN flow
  // Client ID is now fetched from server after WebAuthn authentication
  // based on the user's email (1:1 mapping email -> clientId)

  // Initialize app directories for native (structured storage)
  if (!kIsWeb) {
    await AppDirectories.initialize();
    debugPrint('[INIT] ✅ AppDirectories initialized');
  }

  // Initialize server config service for native (multi-server support)
  if (!kIsWeb) {
    await ServerConfigService.init();
    debugPrint('[INIT] ✅ ServerConfigService initialized');
    
    // DEBUG: Inspect secure storage contents
    try {
      await DebugStorage.printAllStoredKeys();
    } catch (e) {
      debugPrint('[INIT] ❌ Debug storage inspection failed: $e');
    }
    
    // Listen for initial link (when app is started via deep link)
    try {
      final appLinks = AppLinks();
      final initialUri = await appLinks.getInitialLink();
      if (initialUri != null && initialUri.scheme == 'peerwave') {
        initialMagicKey = initialUri.queryParameters['magicKey'];
      }
    } catch (e) {
      // Handle error
    }
  }
  
  // Load server URL for role management
  String? serverUrl = await loadWebApiServer();
  serverUrl ??= 'http://localhost:3000'; // Fallback for non-web platforms
  
  // NOTE: ICE server configuration is loaded AFTER login (requires authentication)
  // See auth_layout_web.dart -> successful login callback
  
  // Initialize Theme Provider
  debugPrint('[INIT] Initializing Theme Provider...');
  final themeProvider = ThemeProvider();
  await themeProvider.initialize();
  debugPrint('[INIT] ✅ Theme Provider initialized');
  
  // NOTE: Database and P2P services are initialized AFTER login
  // See PostLoginInitService for post-login initialization including WebRTC rejoin
  
  runApp(MyApp(
    initialMagicKey: initialMagicKey, 
    serverUrl: serverUrl,
    themeProvider: themeProvider,
  ));
  
  // Configure native window appearance
  if (!kIsWeb) {
    // Initialize system tray service first
    final systemTray = SystemTrayService();
    await systemTray.initialize();
    
    // Then configure bitsdojo window (if needed for custom frame)
    doWhenWindowReady(() {
      const initialSize = Size(1280, 800);
      appWindow.minSize = const Size(800, 600);
      appWindow.size = initialSize;
      appWindow.alignment = Alignment.center;
      appWindow.title = "PeerWave";
      appWindow.show();
    });
  }
}

class MyApp extends StatefulWidget {
  final String? initialMagicKey;
  final String serverUrl;
  final ThemeProvider themeProvider;
  
  const MyApp({
    Key? key, 
    this.initialMagicKey, 
    required this.serverUrl,
    required this.themeProvider,
  }) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _sub;
  String? _magicKey;
  String? _clientId; // Client ID is fetched/created after login
  late final AppLinks _appLinks;
  
  // Post-login initialization guard - prevent re-initialization on every navigation
  bool _postLoginInitComplete = false;
  
  // Global navigator key for accessing router from anywhere
  static final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();
  
  // Public accessor for navigator key
  static GlobalKey<NavigatorState> get rootNavigatorKey => _rootNavigatorKey;
  
  // Router instance - created once and reused
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    _magicKey = widget.initialMagicKey;
    
    // Start server connection monitoring for native platforms
    if (!kIsWeb) {
      ServerConnectionService.instance.startMonitoring();
      debugPrint('[INIT] ✅ Server connection monitoring started');
    }
    
    // NOTE: P2P services are initialized AFTER login
    // See router redirect logic -> _initServices() is called after successful WebAuthn login
    
    if (!kIsWeb) {
      _appLinks = AppLinks();
      _sub = _appLinks.uriLinkStream.listen((Uri uri) {
        if (uri.scheme == 'peerwave') {
          final magicKey = uri.queryParameters['magicKey'];
          if (magicKey != null) {
            setState(() {
              _magicKey = magicKey;
              debugPrint('Received magicKey: $_magicKey');
            });
            // Optionally, navigate to your magic link page here
          }
        }
      }, onError: (err) {
        // Handle error
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    
    // Stop server connection monitoring
    if (!kIsWeb) {
      ServerConnectionService.instance.stopMonitoring();
      debugPrint('[DISPOSE] Server connection monitoring stopped');
    }
    
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    debugPrint('[MAIN] 🏗️ build() called');
    
    // If magicKey is present, route to magic link native page
    if (!kIsWeb && _magicKey != null) {
      return MagicLinkWebPageWithServer(serverUrl: _magicKey!, clientId: _clientId);
    }
    
    // NOTE: Removed the "_servicesReady" check here because services now
    // initialize AFTER login, not before. The login page needs to be accessible
    // without any services being ready.
    
    // Wrap the entire app with providers
    return MultiProvider(
      providers: [
        // Theme Provider
        ChangeNotifierProvider<ThemeProvider>.value(value: widget.themeProvider),
        // Navigation State Provider
        ChangeNotifierProvider(
          create: (context) => NavigationStateProvider(),
        ),
        // Unread Messages Provider
        ChangeNotifierProvider(
          create: (context) => UnreadMessagesProvider(),
        ),
        // Role Providers
        ChangeNotifierProvider(
          create: (context) => RoleProvider(
            apiService: RoleApiService(baseUrl: widget.serverUrl),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => NotificationProvider(),
        ),
        // File Transfer Stats Provider
        ChangeNotifierProvider(
          create: (context) => FileTransferStatsProvider(),
        ),
        // Video Conference provider (requires SocketService)
        ChangeNotifierProvider(
          create: (context) => VideoConferenceService(),
        ),
        // P2P File Transfer providers - managed by PostLoginInitService (nullable before login)
        Provider<FileStorageInterface?>.value(
          value: PostLoginInitService.instance.fileStorage,
        ),
        Provider<EncryptionService?>.value(
          value: PostLoginInitService.instance.encryptionService,
        ),
        Provider<ChunkingService?>.value(
          value: PostLoginInitService.instance.chunkingService,
        ),
        ChangeNotifierProvider<DownloadManager?>.value(
          value: PostLoginInitService.instance.downloadManager,
        ),
        ChangeNotifierProvider<WebRTCFileService?>.value(
          value: PostLoginInitService.instance.webrtcService,
        ),
        // P2PCoordinator is initialized after Socket.IO connects (can be null initially)
        ChangeNotifierProvider<P2PCoordinator?>.value(
          value: PostLoginInitService.instance.p2pCoordinator,
        ),
      ],
      child: _buildMaterialApp(),
    );
  }

  Widget _buildMaterialApp() {
    // Initialize 401 Unauthorized handlers (one-time setup)
    setGlobalUnauthorizedHandler(() {
      // Use navigator key for navigation instead of context
      LogoutService.instance.autoLogoutWithNavigatorKey(_rootNavigatorKey);
    });
    
    setSocketUnauthorizedHandler(() {
      // Use navigator key for navigation instead of context
      LogoutService.instance.autoLogoutWithNavigatorKey(_rootNavigatorKey);
    });
    
    debugPrint('[MAIN] ✓ Unauthorized handlers initialized');

    // Create router only once
    _router ??= _createRouter();

    return _buildRouterWidget();
  }

  Widget _buildRouterWidget() {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        debugPrint('[MAIN] 🎨 Building MaterialApp with theme: ${themeProvider.themeMode}');
        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          routerConfig: _router!,
          builder: (context, child) {
            // Wrap with custom title bar for desktop
            final contentWithTitleBar = kIsWeb 
              ? child ?? const SizedBox()
              : WindowTitleBarWrapper(
                  title: 'PeerWave',
                  child: child ?? const SizedBox(),
                );
            
            return Stack(
              children: [
                Column(
                  children: [
                    const CallTopBar(),
                    Expanded(child: contentWithTitleBar),
                  ],
                ),
                const CallOverlay(),
                // Server unavailable overlay (native only)
                const ServerUnavailableOverlay(),
              ],
            );
          },
        );
      },
    );
  }

  GoRouter _createRouter() {
    debugPrint('[MAIN] 🏗️ Creating GoRouter...');
    
    // Use ShellRoute for native, flat routes for web
    final List<RouteBase> routes = kIsWeb
        ? [
            GoRoute(
              path: '/',
              redirect: (context, state) => '/app',
            ),
            GoRoute(
              path: '/magic-link',
              builder: (context, state) {
                final extra = state.extra;
                debugPrint('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: $_clientId, extra is String: ${extra is String}');
                return const MagicLinkWebPage();
              },
            ),
            GoRoute(
              path: '/backupcode/recover',
              pageBuilder: (context, state) {
                return MaterialPage(
                  child: const BackupCodeRecoveryPage(),
                );
              },
            ),
            GoRoute(
              path: '/login',
              pageBuilder: (context, state) {
                return MaterialPage(
                  child: AuthLayout(clientId: _clientId),
                );
              },
            ),
            GoRoute(
              path: '/server-selection',
              pageBuilder: (context, state) {
                final extra = state.extra as Map<String, dynamic>?;
                final isAddingServer = extra?['isAddingServer'] as bool? ?? false;
                return MaterialPage(
                  child: ServerSelectionScreen(isAddingServer: isAddingServer),
                );
              },
            ),
            GoRoute(
              path: '/otp',
              builder: (context, state) {
                // Extract email and serverUrl from state.extra
                final extra = state.extra;
                String email = '';
                String serverUrl = '';
                int wait = 0;
                if (extra is Map<String, dynamic>) {
                  email = extra['email'] ?? '';
                  serverUrl = extra['serverUrl'] ?? '';
                  wait = extra['wait'] ?? 0;
                }
                debugPrint('Navigating to OtpWebPage with email: $email, serverUrl: $serverUrl, wait: $wait');
                if (email.isEmpty || serverUrl.isEmpty) {
                  // Optionally show an error page or message
                  return Scaffold(body: Center(child: Text('Missing email or serverUrl')));
                }
                return OtpWebPage(email: email, serverUrl: serverUrl, clientId: _clientId, wait: wait);
              },
            ),
            GoRoute(
              path: '/register/invitation',
              builder: (context, state) {
                final extra = state.extra as Map?;
                final email = extra?['email'] as String? ?? '';
                if (email.isEmpty) {
                  return Scaffold(
                    body: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Email required'),
                          TextButton(
                            onPressed: () => context.go('/login'),
                            child: const Text('Back to Login'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return InvitationEntryPage(email: email);
              },
            ),
            GoRoute(
              path: '/register/backupcode',
              builder: (context, state) => const BackupCodeListPage(),
            ),
            GoRoute(
              path: '/register/webauthn',
              builder: (context, state) => const RegisterWebauthnPage(),
            ),
            GoRoute(
              path: '/register/profile',
              builder: (context, state) => const RegisterProfilePage(),
            ),
            GoRoute(
              path: '/signal-setup',
              builder: (context, state) => const SignalSetupScreen(),
            ),
            ShellRoute(
              builder: (context, state, child) => AppLayout(child: child),
              routes: [
                // ========================================
                // Main App Route - Redirect to Activities
                // ========================================
                GoRoute(
                  path: '/app',
                  redirect: (context, state) => '/app/activities',
                ),
                // ========================================
                // Dashboard View Routes (Refactored)
                // ========================================
                GoRoute(
                  path: '/app/activities',
                  builder: (context, state) {
                    return FutureBuilder<String?>(
                      future: loadWebApiServer(),
                      builder: (context, snapshot) {
                        final host = snapshot.data ?? 'localhost:3000';
                        return ActivitiesViewPage(host: host);
                      },
                    );
                  },
                ),
                GoRoute(
                  path: '/app/messages/:id',
                  builder: (context, state) {
                    final contactUuid = state.pathParameters['id'];
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? 'localhost:3000';
                    final displayName = extra?['displayName'] as String? ?? 'Unknown';
                    
                    return MessagesViewPage(
                      host: host,
                      initialContactUuid: contactUuid,
                      initialDisplayName: displayName,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/messages',
                  builder: (context, state) {
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? 'localhost:3000';
                    
                    return MessagesViewPage(
                      host: host,
                      initialContactUuid: null,
                      initialDisplayName: null,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/messages/:uuid',
                  builder: (context, state) {
                    final contactUuid = state.pathParameters['uuid'];
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? 'localhost:3000';
                    final displayName = extra?['displayName'] as String? ?? 'Unknown';
                    
                    return MessagesViewPage(
                      host: host,
                      initialContactUuid: contactUuid,
                      initialDisplayName: displayName,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/channels/:id',
                  builder: (context, state) {
                    final channelUuid = state.pathParameters['id'];
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? 'localhost:3000';
                    final name = extra?['name'] as String? ?? 'Unknown';
                    final type = extra?['type'] as String? ?? 'public';
                    
                    return ChannelsViewPage(
                      host: host,
                      initialChannelUuid: channelUuid,
                      initialChannelName: name,
                      initialChannelType: type,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/channels',
                  builder: (context, state) {
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? 'localhost:3000';
                    
                    return ChannelsViewPage(
                      host: host,
                      initialChannelUuid: null,
                      initialChannelName: null,
                      initialChannelType: null,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/people',
                  builder: (context, state) {
                    return FutureBuilder<String?>(
                      future: loadWebApiServer(),
                      builder: (context, snapshot) {
                        final host = snapshot.data ?? 'localhost:3000';
                        return PeopleViewPage(host: host);
                      },
                    );
                  },
                ),
                GoRoute(
                  path: '/app/files',
                  builder: (context, state) {
                    return FutureBuilder<String?>(
                      future: loadWebApiServer(),
                      builder: (context, snapshot) {
                        final host = snapshot.data ?? 'localhost:3000';
                        return FilesViewPage(host: host);
                      },
                    );
                  },
                ),
                // ========================================
                // P2P File Transfer routes
                // ========================================
                GoRoute(
                  path: '/file-transfer',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Transfer Hub',
                    child: FileTransferHub(),
                  ),
                ),
                GoRoute(
                  path: '/file-upload',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Upload',
                    child: FileUploadScreen(),
                  ),
                ),
                GoRoute(
                  path: '/file-manager',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Manager',
                    child: FileManagerScreen(),
                  ),
                ),
                GoRoute(
                  path: '/file-browser',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Browser',
                    child: FileBrowserScreen(),
                  ),
                ),
                GoRoute(
                  path: '/downloads',
                  builder: (context, state) => const DownloadsScreen(),
                ),
                ShellRoute(
                  builder: (context, state, child) => SettingsSidebar(child: child),
                  routes: [
                    GoRoute(
                      path: '/app/settings',
                      redirect: (context, state) => '/app/settings/general',
                    ),
                    GoRoute(
                      path: '/app/settings/webauthn',
                      builder: (context, state) => const WebauthnPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/backupcode/list',
                      builder: (context, state) => const BackupCodeSettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/general',
                      builder: (context, state) => const GeneralSettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/profile',
                      builder: (context, state) => const ProfilePage(),
                    ),
                    GoRoute(
                      path: '/app/settings/notifications',
                      builder: (context, state) => const NotificationSettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/system-tray',
                      builder: (context, state) => const SystemTraySettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/server',
                      builder: (context, state) => const ServerSettingsPage(),
                      redirect: (context, state) {
                        final roleProvider = context.read<RoleProvider>();
                        // Only allow access if user has server.manage permission
                        if (!roleProvider.hasServerPermission('server.manage')) {
                          return '/app/settings';
                        }
                        return null; // Allow navigation
                      },
                    ),
                    GoRoute(
                      path: '/app/settings/roles',
                      builder: (context, state) => const RoleManagementScreen(),
                      redirect: (context, state) {
                        final roleProvider = context.read<RoleProvider>();
                        // Only allow access if user is admin
                        if (!roleProvider.isAdmin) {
                          return '/app/settings';
                        }
                        return null; // Allow navigation
                      },
                    ),
                    GoRoute(
                      path: '/app/settings/users',
                      builder: (context, state) => const UserManagementScreen(),
                      redirect: (context, state) {
                        final roleProvider = context.read<RoleProvider>();
                        // Only allow access if user has user.manage permission
                        if (!roleProvider.hasServerPermission('user.manage')) {
                          return '/app/settings';
                        }
                        return null; // Allow navigation
                      },
                    ),
                  ],
                ),
              ],
            ),
          ]
        : [
            ShellRoute(
              builder: (context, state, child) => AppLayout(child: child),
              routes: [
                GoRoute(
                  path: '/',
                  redirect: (context, state) => '/app',
                ),
                // Server selection route (inside ShellRoute - shows server navbar)
                GoRoute(
                  path: '/server-selection',
                  pageBuilder: (context, state) {
                    final extra = state.extra as Map<String, dynamic>?;
                    final isAddingServer = extra?['isAddingServer'] as bool? ?? false;
                    return MaterialPage(
                      fullscreenDialog: true,
                      child: ServerSelectionScreen(isAddingServer: isAddingServer),
                    );
                  },
                ),
                // Signal setup route (inside ShellRoute for native - shows server navbar)
                GoRoute(
                  path: '/signal-setup',
                  builder: (context, state) => const SignalSetupScreen(),
                ),
                GoRoute(
                  path: '/magic-link',
                  builder: (context, state) {
                    final extra = state.extra;
                    debugPrint('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: $_clientId, extra is String: ${extra is String}');
                    if (extra is String && extra.isNotEmpty) {
                      debugPrint("Rendering MagicLinkWebPageWithServer, clientId: $_clientId");
                      return MagicLinkWebPageWithServer(serverUrl: extra, clientId: _clientId);
                    }
                    return const MagicLinkWebPage();
                  },
                ),
                GoRoute(
                  path: '/login',
                  pageBuilder: (context, state) {
                    return MaterialPage(
                      fullscreenDialog: true,
                      child: AuthLayout(clientId: _clientId),
                    );
                  },
                ),
                GoRoute(
                  path: '/dashboard',
                  pageBuilder: (context, state) {
                    return MaterialPage(
                      child: const DashboardPage(),
                    );
                  },
                ),
                GoRoute(
                  path: '/app',
                  builder: (context, state) => const SizedBox.shrink(),
                ),
                // View routes
                GoRoute(
                  path: '/app/channels/:id',
                  builder: (context, state) {
                    final channelUuid = state.pathParameters['id'];
                    final extra = state.extra as Map<String, dynamic>?;
                    final server = ServerConfigService.getActiveServer();
                    final host = extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';
                    final name = extra?['name'] as String? ?? 'Unknown';
                    final type = extra?['type'] as String? ?? 'public';
                    
                    return ChannelsViewPage(
                      host: host,
                      initialChannelUuid: channelUuid,
                      initialChannelName: name,
                      initialChannelType: type,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/channels',
                  builder: (context, state) {
                    final server = ServerConfigService.getActiveServer();
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';
                    
                    return ChannelsViewPage(
                      host: host,
                      initialChannelUuid: null,
                      initialChannelName: null,
                      initialChannelType: null,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/messages/:id',
                  builder: (context, state) {
                    final contactUuid = state.pathParameters['id'];
                    final extra = state.extra as Map<String, dynamic>?;
                    final server = ServerConfigService.getActiveServer();
                    final host = extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';
                    final displayName = extra?['displayName'] as String? ?? 'Unknown';
                    
                    return MessagesViewPage(
                      host: host,
                      initialContactUuid: contactUuid,
                      initialDisplayName: displayName,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/messages',
                  builder: (context, state) {
                    final server = ServerConfigService.getActiveServer();
                    final extra = state.extra as Map<String, dynamic>?;
                    final host = extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';
                    
                    return MessagesViewPage(
                      host: host,
                      initialContactUuid: null,
                      initialDisplayName: null,
                    );
                  },
                ),
                GoRoute(
                  path: '/app/activities',
                  builder: (context, state) {
                    final server = ServerConfigService.getActiveServer();
                    return ActivitiesViewPage(host: server?.serverUrl ?? 'localhost:3000');
                  },
                ),
                GoRoute(
                  path: '/app/people',
                  builder: (context, state) {
                    final server = ServerConfigService.getActiveServer();
                    return PeopleViewPage(host: server?.serverUrl ?? 'localhost:3000');
                  },
                ),
                GoRoute(
                  path: '/app/files',
                  builder: (context, state) {
                    final server = ServerConfigService.getActiveServer();
                    return FilesViewPage(host: server?.serverUrl ?? 'localhost:3000');
                  },
                ),
                // P2P File Transfer routes
                GoRoute(
                  path: '/file-transfer',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Transfer Hub',
                    child: FileTransferHub(),
                  ),
                ),
                GoRoute(
                  path: '/file-upload',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Upload',
                    child: FileUploadScreen(),
                  ),
                ),
                GoRoute(
                  path: '/file-manager',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Manager',
                    child: FileManagerScreen(),
                  ),
                ),
                GoRoute(
                  path: '/file-browser',
                  builder: (context, state) => const SocketAwareWidget(
                    featureName: 'File Browser',
                    child: FileBrowserScreen(),
                  ),
                ),
                GoRoute(
                  path: '/downloads',
                  builder: (context, state) => const DownloadsScreen(),
                ),
                // Settings routes
                ShellRoute(
                  builder: (context, state, child) => SettingsSidebar(child: child),
                  routes: [
                    GoRoute(
                      path: '/app/settings',
                      redirect: (context, state) => '/app/settings/general',
                    ),
                    GoRoute(
                      path: '/app/settings/webauthn',
                      builder: (context, state) => const WebauthnPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/backupcode/list',
                      builder: (context, state) => const BackupCodeSettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/general',
                      builder: (context, state) => const GeneralSettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/profile',
                      builder: (context, state) => const ProfilePage(),
                    ),
                    GoRoute(
                      path: '/app/settings/notifications',
                      builder: (context, state) => const NotificationSettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/system-tray',
                      builder: (context, state) => const SystemTraySettingsPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/server',
                      builder: (context, state) => const ServerSettingsPage(),
                      redirect: (context, state) {
                        final roleProvider = context.read<RoleProvider>();
                        if (!roleProvider.hasServerPermission('server.manage')) {
                          return '/app/settings';
                        }
                        return null;
                      },
                    ),
                    GoRoute(
                      path: '/app/settings/roles',
                      builder: (context, state) => const RoleManagementScreen(),
                      redirect: (context, state) {
                        final roleProvider = context.read<RoleProvider>();
                        if (!roleProvider.isAdmin) {
                          return '/app/settings';
                        }
                        return null;
                      },
                    ),
                    GoRoute(
                      path: '/app/settings/users',
                      builder: (context, state) => const UserManagementScreen(),
                      redirect: (context, state) {
                        final roleProvider = context.read<RoleProvider>();
                        if (!roleProvider.hasServerPermission('user.manage')) {
                          return '/app/settings';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ],
            ),
          ];

    debugPrint('[MAIN] 🏗️ Creating GoRouter...');
    final GoRouter router = GoRouter(
      navigatorKey: _rootNavigatorKey,
      initialLocation: '/login',
      routes: routes,
      redirect: (context, state) async {
        final location = state.matchedLocation;
        debugPrint('[ROUTER] 🔀 Redirect called for location: $location');
        
        // Native: Check if server selection is needed (no servers configured)
        if (!kIsWeb && location != '/server-selection') {
          if (!ServerConfigService.hasServers()) {
            debugPrint('[ROUTER] 📱 Native: No servers configured, redirecting to server selection');
            return '/server-selection';
          }
        }
        
        // Only check session on initial load (when going to root or login page)
        // Also check when navigating to /app after login or after server-selection
        // Don't check session on every navigation - that's too expensive
        final shouldCheckSession = !LogoutService.instance.isLogoutComplete && 
                                   (location == '/' || 
                                    location == '/login' || 
                                    location == '/app' ||
                                    (location.startsWith('/app/') && !_postLoginInitComplete));
        
        if (shouldCheckSession) {
          debugPrint('[ROUTER] 🔍 Checking session (initial load or post-login)...');
          await AuthService.checkSession();
          debugPrint('[ROUTER] ✅ Session check complete');
        }
        
        final loggedIn = AuthService.isLoggedIn;
        debugPrint('[ROUTER] 🔐 Login status: $loggedIn, Location: $location');
        
        // Restore device identity from storage if not already initialized
        // This is required for database and Signal Protocol operations
        if (loggedIn && !DeviceIdentityService.instance.isInitialized) {
          debugPrint('[ROUTER] 🔄 Restoring device identity from storage...');
          final restored = await DeviceIdentityService.instance.tryRestoreFromSession();
          if (restored) {
            debugPrint('[ROUTER] ✅ Device identity restored');
          } else {
            // Device identity is required for database and Signal Protocol
            // If missing, this is an old session from before device identity was implemented
            // Force re-authentication with new magic key to initialize device identity
            debugPrint('[ROUTER] ⚠️ Device identity not found - old session detected');
            debugPrint('[ROUTER] 🔄 Clearing HMAC session and forcing re-authentication...');
            
            if (!kIsWeb) {
              // Clear HMAC session for native
              final clientId = await ClientIdService.getClientId();
              await SessionAuthService().clearSession(clientId);
              AuthService.isLoggedIn = false;
              
              // Redirect to server-selection to re-authenticate
              debugPrint('[ROUTER] ↩️ Redirecting to server-selection for re-authentication');
              return '/server-selection';
            }
          }
        }
        
        final uri = Uri.parse(state.uri.toString());
        final fromParam = uri.queryParameters['from'];
        if(loggedIn) {
          debugPrint('[ROUTER] ========================================');
          debugPrint('[ROUTER] 🔐 User is logged in - checking post-login initialization');
          debugPrint('[ROUTER] Current location: $location');
          debugPrint('[ROUTER] _postLoginInitComplete: $_postLoginInitComplete');
          debugPrint('[ROUTER] PostLoginInitService.isInitialized: ${PostLoginInitService.instance.isInitialized}');
          debugPrint('[ROUTER] ========================================');
          
          // ========================================
          // POST-LOGIN SERVICE INITIALIZATION (ONCE)
          // ========================================
          // Skip Signal key checks for authentication and registration flows
          final isAuthFlow = location == '/otp' 
              || location == '/login'
              || location == '/backupcode/recover'
              || location.startsWith('/register/')
              || location == '/signal-setup';
          
          debugPrint('[ROUTER] isAuthFlow: $isAuthFlow');
          
          if (!isAuthFlow) {
            debugPrint('[ROUTER] Not an auth flow - checking Signal keys status...');
            // Check if Signal keys need setup when navigating to main app routes
            if (location == '/app' || location == '/' || location.startsWith('/app/')) {
              debugPrint('[ROUTER] App route detected - checking keys status...');
              try {
                final status = await SignalSetupService.instance.checkKeysStatus();
                final needsSetup = status['needsSetup'] as bool;
                final missingKeys = status['missingKeys'] as Map<String, dynamic>;
                
                debugPrint('[ROUTER] Keys status: needsSetup=$needsSetup, missingKeys=$missingKeys');
                
                if (needsSetup) {
                  // Save current route if it's a specific /app/* route (not base routes like /app or /)
                  // This allows restoration after signal-setup completes
                  if (location.startsWith('/app/') && location != '/app/' && location.length > 5) {
                    // Only save routes like /app/people, /app/messages, etc. (not /app or /)
                    debugPrint('[MAIN] Saving current route before signal-setup: $location');
                    await PreferencesService().saveLastRoute(location);
                  } else {
                    debugPrint('[MAIN] Not saving route (base route or coming from login): $location');
                  }
                  
                  // Check if it's an auth issue (device identity or encryption key missing)
                  // Only for web - native uses HMAC and doesn't have device identity
                  if (kIsWeb && (missingKeys.containsKey('deviceIdentity') || 
                      missingKeys.containsKey('encryptionKey'))) {
                    debugPrint('[MAIN] Authentication keys missing (IndexedDB deleted?) - logging out...');
                    
                    // Logout to clear server session and avoid redirect loop
                    // This happens when IndexedDB is deleted but server session still exists
                    await LogoutService.instance.logout(null, showMessage: false);
                    
                    debugPrint('[MAIN] Logout complete, redirecting to /login');
                    return '/login';
                  }
                  
                  // Otherwise, it's a Signal keys setup issue
                  debugPrint('[MAIN] Signal keys need setup, redirecting to /signal-setup');
                  return '/signal-setup';
                }
                
                // Keys exist - run post-login initialization via PostLoginInitService
                if (!_postLoginInitComplete && !PostLoginInitService.instance.isInitialized) {
                  debugPrint('[MAIN] ========================================');
                  debugPrint('[MAIN] Starting post-login initialization...');
                  debugPrint('[MAIN] ========================================');
                  
                  try {
                    // Get server URL based on platform
                    String serverUrl = '';
                    if (kIsWeb) {
                      final apiServer = await loadWebApiServer();
                      serverUrl = apiServer ?? '';
                    } else {
                      final activeServer = ServerConfigService.getActiveServer();
                      serverUrl = activeServer?.serverUrl ?? '';
                    }
                    
                    // Ensure server URL has protocol
                    if (serverUrl.isNotEmpty && !serverUrl.startsWith('http://') && !serverUrl.startsWith('https://')) {
                      serverUrl = 'https://$serverUrl';
                    }
                    
                    final unreadProvider = context.read<UnreadMessagesProvider>();
                    final roleProvider = context.read<RoleProvider>();
                    final statsProvider = context.read<FileTransferStatsProvider>();
                    
                    await PostLoginInitService.instance.initialize(
                      serverUrl: serverUrl,
                      unreadProvider: unreadProvider,
                      roleProvider: roleProvider,
                      statsProvider: statsProvider,
                      onProgress: (step, current, total) {
                        debugPrint('[MAIN] [$current/$total] $step');
                      },
                    );
                    
                    _postLoginInitComplete = true;
                    
                    // Trigger rebuild to update providers with initialized services
                    if (mounted) {
                      setState(() {});
                    }
                    
                    debugPrint('[MAIN] ========================================');
                    debugPrint('[MAIN] ✅ Post-login initialization complete');
                    debugPrint('[MAIN] ========================================');
                  } catch (e) {
                    debugPrint('[MAIN] ⚠ Error during initialization: $e');
                    // On error, redirect to login to be safe
                    return '/login';
                  }
                }
                
              } catch (e) {
                debugPrint('[MAIN] ⚠ Error checking keys status: $e');
                // On error, redirect to login to be safe
                return '/login';
              }
            } else {
              // For other app routes (e.g. /app/channels), ensure initialization is done
              if (!PostLoginInitService.instance.isInitialized) {
                debugPrint('[MAIN] Running initialization for app route: $location');
                
                try {
                  // Get server URL based on platform
                  String serverUrl = '';
                  if (kIsWeb) {
                    final apiServer = await loadWebApiServer();
                    serverUrl = apiServer ?? '';
                  } else {
                    final activeServer = ServerConfigService.getActiveServer();
                    serverUrl = activeServer?.serverUrl ?? '';
                  }
                  
                  // Ensure server URL has protocol
                  if (serverUrl.isNotEmpty && !serverUrl.startsWith('http://') && !serverUrl.startsWith('https://')) {
                    serverUrl = 'https://$serverUrl';
                  }
                  
                  final unreadProvider = context.read<UnreadMessagesProvider>();
                  final roleProvider = context.read<RoleProvider>();
                  final statsProvider = context.read<FileTransferStatsProvider>();
                  
                  await PostLoginInitService.instance.initialize(
                    serverUrl: serverUrl,
                    unreadProvider: unreadProvider,
                    roleProvider: roleProvider,
                    statsProvider: statsProvider,
                    onProgress: (step, current, total) {
                      debugPrint('[MAIN] [$current/$total] $step');
                    },
                  );
                  
                  _postLoginInitComplete = true;
                  
                  // Trigger rebuild to update providers with initialized services
                  if (mounted) {
                    setState(() {});
                  }
                } catch (e) {
                  debugPrint('[MAIN] ⚠ Error initializing for app route: $e');
                }
              }
            }
          }
        } else {
          // Logout cleanup
          if(SocketService().isConnected) SocketService().disconnect();
          
          // Reset post-login initialization flag so it runs again on next login
          _postLoginInitComplete = false;
          debugPrint('[MAIN] 🔄 Reset post-login initialization flag');
          
          // Reset PostLoginInitService state
          PostLoginInitService.instance.reset();
          debugPrint('[MAIN] 🔄 Reset PostLoginInitService');
          
          // Consolidated cleanup via SignalSetupService
          SignalSetupService.instance.cleanupOnLogout();
          
          // Clear roles on logout
          try {
            final roleProvider = context.read<RoleProvider>();
            roleProvider.clearRoles();
          } catch (e) {
            debugPrint('Error clearing roles: $e');
          }
        }
        // ...existing redirect logic...
        debugPrint("kIsWeb: $kIsWeb");
        debugPrint("loggedIn: $loggedIn");
        debugPrint("location: $location");
        debugPrint("fromParam: $fromParam");
        
        // If logged in and at /login, redirect appropriately
        if (loggedIn && location == '/login') {
          if (kIsWeb) {
            debugPrint('[ROUTER] ✅ Web: Logged in at /login, redirecting to /app');
            return '/app';
          } else {
            // Native: Redirect to /app which will trigger signal setup check
            debugPrint('[ROUTER] ✅ Native: Logged in at /login, redirecting to /app for signal check');
            return '/app';
          }
        }
        
        if (kIsWeb && !loggedIn && location == '/login') {
          return null;
        }
        if (kIsWeb && location == '/otp') {
          return null;
        }
        if (kIsWeb && location == '/backupcode/recover') {
          return null;
        }
        if (kIsWeb && location.startsWith('/register/')) {
          return null;
        }
        if (kIsWeb && location == '/signal-setup') {
          return null;
        }
        if (!kIsWeb && location == '/signal-setup') {
          return null;
        }
        if(kIsWeb && loggedIn && location == '/magic-link') {
          return null;
        }
        if (kIsWeb && !loggedIn && location == '/magic-link') {
          return '/login?from=magic-link';
        }
        if (kIsWeb && loggedIn && fromParam == 'magic-link') {
          return '/magic-link';
        }
        // Allow registration flow even when not logged in
        if (kIsWeb && !loggedIn && !location.startsWith('/register/')) {
          debugPrint('[ROUTER] ⚠️ Web: Not logged in, redirecting to /login');
          return '/login';
        }
        
        // Native: If not logged in and not on auth flow, redirect to server-selection
        if (!kIsWeb && !loggedIn && location != '/server-selection') {
          debugPrint('[ROUTER] ⚠️ Native: Not logged in, redirecting to server-selection for re-authentication');
          return '/server-selection';
        }
        
        // Otherwise, allow navigation
        return null;
      },
    );
    
    debugPrint('[MAIN] ✅ GoRouter created');
    
    // Attach router to VideoConferenceService
    VideoConferenceService.instance.attachRouter(router);
    
    return router;
  }
}

