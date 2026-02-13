import 'package:socket_io_client/socket_io_client.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'dart:io' show Platform, Directory;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'auth/magic_link_native.dart' show MagicLinkWebPageWithServer;

import 'services/device_identity_service.dart';
import 'services/logout_service.dart';
import 'services/preferences_service.dart';
import 'services/server_settings_service.dart';
import 'app/app_layout.dart';
// Use conditional import for 'services/auth_service.dart'
import 'services/auth_service_web.dart'
    if (dart.library.io) 'services/auth_service_native.dart';
import 'services/api_service.dart';

import 'services/socket_service_web_export.dart'
    if (dart.library.io) 'services/socket_service_native_export.dart';
import 'services/server_connection_service.dart';
import 'widgets/server_unavailable_overlay.dart';
// Role management imports
import 'providers/role_provider.dart';
import 'providers/navigation_state_provider.dart';
import 'services/role_api_service.dart';
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
import 'widgets/incoming_call_listener.dart';
import 'widgets/custom_window_title_bar.dart';
// Post-login service orchestration
import 'services/post_login_init_service.dart';
// Native server selection
import 'services/server_config_web.dart'
    if (dart.library.io) 'services/server_config_native.dart';
import 'services/clientid_native.dart'
    if (dart.library.js) 'services/clientid_web.dart';
import 'services/session_auth_service.dart';
import 'debug_storage.dart';
import 'utils/window_stub.dart';
import 'core/routes/web/auth_routes_web.dart'
    if (dart.library.io) 'core/routes/native/auth_routes_native.dart';
import 'core/routes/settings_routes.dart';
import 'core/routes/file_routes.dart';
import 'core/routes/meeting_routes.dart';
import 'core/routes/app_routes.dart';
import 'core/routes/native/server_config_routes.dart'
    if (dart.library.js) 'core/routes/web/server_config_routes_stub.dart';
import 'screens/signal_setup_screen.dart';
import 'core/storage/app_directories.dart';
import 'services/system_tray_service_web.dart'
    if (dart.library.io) 'services/system_tray_service.dart';
import 'services/storage/database_helper.dart';
import 'services/device_scoped_storage_service.dart';
import 'services/idb_factory_web.dart'
    if (dart.library.io) 'services/idb_factory_native.dart';
import 'services/network_checker_service.dart';
import 'services/filesystem_checker_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ========================================
  // 5️⃣ Initialize Firebase (Flutter) - Mobile Only
  // ========================================
  // Firebase initialization will be handled by FCM service on iOS/Android
  // Windows/Linux/macOS use NoOp stub - no Firebase SDK needed
  debugPrint('[INIT] Firebase will be initialized on mobile platforms only');

  String? initialMagicKey;

  // NOTE: Client ID generation moved to POST-LOGIN flow
  // Client ID is now fetched from server after WebAuthn authentication
  // based on the user's email (1:1 mapping email -> clientId)

  // ========================================
  // PHASE 1: Core Infrastructure Setup
  // ========================================
  // Initialize app directories for native (structured storage)
  if (!kIsWeb) {
    // CRITICAL: Fix Windows autostart working directory issue
    // At autostart, cwd is often C:\Windows\System32 (no write permissions)
    // SQLite creates temp files in cwd → error 14 (SQLITE_CANTOPEN)
    // Solution: Set cwd to app data directory before any database operations
    if (Platform.isWindows) {
      try {
        final exeDir = path.dirname(Platform.resolvedExecutable);
        Directory.current = exeDir;
        debugPrint(
          '[INIT] ✅ Set working directory to: ${Directory.current.path}',
        );
      } catch (e) {
        debugPrint('[INIT] ⚠️ Could not set working directory: $e');
      }
    }

    await AppDirectories.initialize();
    debugPrint('[INIT] ✅ AppDirectories initialized');

    // Initialize Database early (ensure connection pool ready)
    try {
      debugPrint('[INIT] Initializing database...');
      await DatabaseHelper.database;
      debugPrint('[INIT] ✅ Database initialized and ready');
    } catch (e) {
      debugPrint('[INIT] ⚠️ Database initialization failed: $e');
      // Don't block app startup - database will retry on first use
    }

    // Initialize SecureStorage early (ensure keychain/credential store accessible)
    try {
      debugPrint('[INIT] Validating secure storage access...');
      // Test read to ensure keychain is accessible (may need user unlock on some platforms)
      await ClientIdService.getClientId();
      debugPrint('[INIT] ✅ Secure storage accessible');
    } catch (e) {
      debugPrint('[INIT] ⚠️ Secure storage access validation failed: $e');
      // Don't block - will retry on first actual use
    }

    // Initialize server config early (needed for session checks)
    await ServerConfigService.init();
    debugPrint('[INIT] ✅ ServerConfigService initialized');

    // ========================================
    // PHASE 2: Server Availability Check
    // ========================================
    // Check if servers are configured - if not, skip heavy initialization
    // User will be routed to server-selection screen
    final bool hasServers = ServerConfigService.hasServers();

    if (!hasServers) {
      debugPrint(
        '[INIT] ⚠️ No servers configured - skipping session checks and autostart logic',
      );
      debugPrint('[INIT] User will be prompted to add a server');
      // Skip to Phase 3 for minimal setup (deep links, API config, theme)
    } else {
      // ========================================
      // PHASE 2A: Autostart Detection & Enhanced Initialization
      // ========================================
      // Detect autostart scenario (presence of session without explicit login action)
      // This helps identify cases where window appears before initialization completes
      final bool isAutostart = await _detectAutostart();
      final bool isDesktop =
          !kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

      if (isAutostart && isDesktop) {
        debugPrint(
          '[INIT] 🚀 DESKTOP AUTOSTART DETECTED - Using enhanced initialization',
        );
        debugPrint('[INIT] Platform: ${Platform.operatingSystem}');

        // Phase 1: Wait for network interface (up to 3 minutes)
        debugPrint('[INIT] Phase 1: Checking network availability...');
        final networkAvailable = await NetworkCheckerService.waitForNetwork();
        if (!networkAvailable) {
          debugPrint('[INIT] ⚠️ Network timeout reached - proceeding anyway');
        } else {
          debugPrint('[INIT] ✅ Network available');
        }

        // Phase 2: Wait for file system access (up to 1 minute)
        debugPrint('[INIT] Phase 2: Checking file system access...');
        final appDir = AppDirectories.appDataDirectory.path;
        final fsAvailable =
            await FileSystemCheckerService.waitForFileSystemAccess(
              testPath: appDir,
              timeout: const Duration(minutes: 1),
            );
        if (!fsAvailable) {
          debugPrint(
            '[INIT] ⚠️ File system timeout reached - attempting to proceed',
          );
        } else {
          debugPrint('[INIT] ✅ File system accessible');
        }

        // Phase 3: Enhanced database initialization will use autostart-aware retry logic
        debugPrint(
          '[INIT] Phase 3: Initializing database with enhanced retry...',
        );

        // Phase 4: Proactive session refresh if close to expiry (for active server)
        debugPrint('[INIT] Phase 4: Checking session expiry...');
        try {
          final activeServer = ServerConfigService.getActiveServer();
          if (activeServer != null) {
            final clientId = await ClientIdService.getClientId();
            await SessionAuthService().checkAndRefreshSession(
              serverUrl: activeServer.serverUrl,
              clientId: clientId,
            );
            debugPrint(
              '[INIT] ✅ Session check completed for ${activeServer.serverUrl}',
            );
          }
        } catch (e) {
          debugPrint('[INIT] ⚠️ Session refresh check failed: $e');
        }
      } else if (isAutostart) {
        debugPrint(
          '[INIT] 🚀 AUTOSTART DETECTED (mobile) - Using standard initialization',
        );

        // Also check session on mobile autostart
        try {
          final activeServer = ServerConfigService.getActiveServer();
          if (activeServer != null) {
            final clientId = await ClientIdService.getClientId();
            await SessionAuthService().checkAndRefreshSession(
              serverUrl: activeServer.serverUrl,
              clientId: clientId,
            );
          }
        } catch (e) {
          debugPrint('[INIT] ⚠️ Session refresh check failed: $e');
        }
      }
    } // End hasServers check
  } else {
    // ========================================
    // PHASE 2 (Web): Session Check
    // ========================================
    // Web platform - check if session exists before attempting refresh
    // Use hostname as server identifier (e.g., "app.peerwave.com" or "localhost:3000")
    final serverIdentifier = Uri.base.host.isNotEmpty
        ? Uri.base.host
        : 'localhost';

    try {
      final clientId = await ClientIdService.getClientId();
      final sessionAuth = SessionAuthService();

      // Check if session exists before attempting refresh
      final hasSession = await sessionAuth.hasSession(
        clientId: clientId,
        serverUrl: serverIdentifier,
      );

      if (hasSession) {
        debugPrint(
          '[INIT] Session found for $serverIdentifier - checking expiry...',
        );
        await sessionAuth.checkAndRefreshSession(
          serverUrl: serverIdentifier,
          clientId: clientId,
        );
        debugPrint(
          '[INIT] ✅ Web session check completed for $serverIdentifier',
        );
      } else {
        debugPrint(
          '[INIT] ℹ️ No session found for $serverIdentifier - skipping refresh',
        );
      }
    } catch (e) {
      debugPrint('[INIT] ⚠️ Web session check failed: $e');
      // Ignore errors on web (will prompt for login)
    }
  }

  // ========================================
  // PHASE 3: Server Configuration & API Setup
  // ========================================
  // Server configuration for native (multi-server support)
  if (!kIsWeb) {
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
  debugPrint('[INIT] Loading API server configuration...');
  String? serverUrl = await loadWebApiServer();

  // Use current origin for web, fallback to localhost for desktop/mobile
  if (kIsWeb) {
    if (serverUrl == null || serverUrl.isEmpty) {
      // Use current domain for web deployments
      serverUrl = Uri.base.origin;
      debugPrint('[INIT] ⚠️ Using fallback URL (Uri.base.origin): $serverUrl');
    } else {
      debugPrint(
        '[INIT] ✅ Loaded API server config: $serverUrl (ignored for web - using relative paths)',
      );
    }
    // DO NOT set baseUrl for web - let relative paths resolve to current origin
    // ApiService.setBaseUrl(''); // This would break relative paths
    debugPrint(
      '[INIT] ✅ Web platform: Using relative paths (resolve to ${Uri.base.origin})',
    );
  } else {
    // Native platforms: Use already-initialized ServerConfigService
    // (ServerConfigService.init() was called in Phase 1)
    final activeServer = ServerConfigService.getActiveServer();
    if (activeServer != null) {
      serverUrl = activeServer.serverUrl;
      debugPrint('[INIT] ✅ Using active server: $serverUrl');
      // Initialize ApiService for the active server
      await ApiService.instance.initForServer(
        activeServer.id,
        serverUrl: serverUrl,
      );
      debugPrint(
        '[INIT] ✅ ApiService initialized for active server: ${activeServer.id}',
      );
    } else {
      // No servers configured - skip ApiService init (user will be prompted to add server)
      serverUrl = 'http://localhost:3000';
      debugPrint('[INIT] ⚠️ No active server, skipping ApiService init');
    }
  }

  // ========================================
  // PHASE 4: Initialize API Service for Web
  // ========================================
  if (kIsWeb) {
    await ApiService.instance.init();
    debugPrint('[INIT] ✅ ApiService initialized for web');
  }

  // NOTE: ICE server configuration is loaded AFTER login (requires authentication)
  // See auth_layout_web.dart -> successful login callback

  // ========================================
  // PHASE 5: Theme Provider
  // ========================================
  // Initialize Theme Provider
  debugPrint('[INIT] Initializing Theme Provider...');
  final themeProvider = ThemeProvider();
  await themeProvider.initialize();
  debugPrint('[INIT] ✅ Theme Provider initialized');

  // NOTE: Database and P2P services are initialized AFTER login
  // See PostLoginInitService for post-login initialization including WebRTC rejoin

  runApp(
    MyApp(
      initialMagicKey: initialMagicKey,
      serverUrl: serverUrl,
      themeProvider: themeProvider,
    ),
  );

  // Configure native window appearance (desktop only)
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
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
    super.key,
    this.initialMagicKey,
    required this.serverUrl,
    required this.themeProvider,
  });

  // Public static accessor for root navigator key
  static GlobalKey<NavigatorState> get rootNavigatorKey =>
      _MyAppState._rootNavigatorKey;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  StreamSubscription? _sub;
  String? _magicKey;
  String? _clientId; // Client ID is fetched/created after login
  late final AppLinks _appLinks;

  // Post-login initialization guard - prevent re-initialization on every navigation
  bool _postLoginInitComplete = false;

  // Global navigator key for accessing router from anywhere
  static final GlobalKey<NavigatorState> _rootNavigatorKey =
      GlobalKey<NavigatorState>();

  // Router instance - created once and reused
  GoRouter? _router;

  // Flag to track if initial session check is complete
  bool _sessionCheckComplete = false;

  @override
  void initState() {
    super.initState();
    _magicKey = widget.initialMagicKey;

    // Check session on app startup for native platforms
    // This ensures AuthService.isLoggedIn is set before router determines initial location
    if (!kIsWeb) {
      _checkInitialSession();
    }

    // Register as app lifecycle observer
    WidgetsBinding.instance.addObserver(this);
    debugPrint('[LIFECYCLE] App lifecycle observer registered');

    // Start server connection monitoring for native platforms
    if (!kIsWeb) {
      ServerConnectionService.instance.startMonitoring();
      debugPrint('[INIT] ✅ Server connection monitoring started');
    }

    // NOTE: P2P services are initialized AFTER login
    // See router redirect logic -> _initServices() is called after successful WebAuthn login

    if (!kIsWeb) {
      _appLinks = AppLinks();
      _sub = _appLinks.uriLinkStream.listen(
        (Uri uri) {
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
        },
        onError: (err) {
          // Handle error
        },
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();

    // Unregister lifecycle observer
    WidgetsBinding.instance.removeObserver(this);
    debugPrint('[LIFECYCLE] App lifecycle observer removed');

    // Stop server connection monitoring
    if (!kIsWeb) {
      ServerConnectionService.instance.stopMonitoring();
      debugPrint('[DISPOSE] Server connection monitoring stopped');
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('[LIFECYCLE] App state changed to: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        // App came back to foreground - reconnect socket if logged in
        debugPrint('[LIFECYCLE] App resumed - checking authentication status');
        if (AuthService.isLoggedIn) {
          debugPrint(
            '[LIFECYCLE] User is logged in - attempting socket reconnection',
          );
          _reconnectSocket();
        } else {
          debugPrint(
            '[LIFECYCLE] User not logged in - skipping socket reconnect',
          );
        }
        break;

      case AppLifecycleState.paused:
        // App went to background
        debugPrint('[LIFECYCLE] App paused - socket will maintain connection');
        // Note: We don't disconnect on pause to maintain real-time notifications
        // Socket.IO handles reconnection automatically
        break;

      case AppLifecycleState.inactive:
        debugPrint('[LIFECYCLE] App inactive');
        break;

      case AppLifecycleState.detached:
        debugPrint('[LIFECYCLE] App detached');
        break;

      case AppLifecycleState.hidden:
        debugPrint('[LIFECYCLE] App hidden');
        break;
    }
  }

  Future<void> _reconnectSocket() async {
    try {
      final socketService = SocketService.instance;

      // With multi-server support, reconnect ALL servers on app resume
      debugPrint('[LIFECYCLE] Reconnecting all servers...');

      // Add a short delay to allow network to stabilize after app resume
      // This helps prevent DNS resolution failures on mobile
      await Future.delayed(Duration(milliseconds: 500));

      await socketService.connectAllServers();

      // Verify active server is connected
      final activeSocket = socketService.socket;
      final isActiveConnected = activeSocket?.connected ?? false;

      if (isActiveConnected) {
        debugPrint(
          '[LIFECYCLE] ✅ All servers reconnected, active server connected',
        );
      } else {
        debugPrint(
          '[LIFECYCLE] ⚠️ Reconnection complete but active server not connected',
        );
      }

      await _retryPendingSenderKeys();
    } catch (e) {
      debugPrint('[LIFECYCLE] ❌ Failed to reconnect servers: $e');
      // Don't throw - allow app to continue functioning
      // Sockets will retry connection according to their configuration
    }
  }

  Future<void> _retryPendingSenderKeys() async {
    try {
      if (!ServerSettingsService.instance.isSignalClientInitialized()) {
        return;
      }

      final signalClient = ServerSettingsService.instance.getSignalClient();
      if (signalClient == null) return;

      await signalClient.messagingService.retryPendingSenderKeyRequests();
    } catch (e) {
      debugPrint('[LIFECYCLE] Failed to retry sender key requests: $e');
    }
  }

  @override
  void reassemble() {
    super.reassemble();

    // Hot reload detected - reset database and storage caches
    debugPrint(
      '[HOT_RELOAD] 🔥 Hot reload detected - resetting storage caches',
    );

    // Close all cached IndexedDB connections
    DeviceScopedStorageService.instance.closeAllDatabases();

    // Reset SQLite database helper (prevents "database_closed" errors)
    DatabaseHelper.reset();

    // Reset IndexedDB factory for native platforms
    if (!kIsWeb) {
      resetIdbFactoryNative();
    }

    debugPrint(
      '[HOT_RELOAD] ✅ Storage caches reset - ready for new connections',
    );
  }

  /// Check session on app startup to restore authentication state
  /// This must complete before router determines initial location
  Future<void> _checkInitialSession() async {
    try {
      debugPrint('[INIT] Checking session on app startup...');
      await AuthService.checkSession();
      debugPrint('[INIT] ✓ Session check complete: ${AuthService.isLoggedIn}');
      setState(() {
        _sessionCheckComplete = true;
      });
    } catch (e) {
      debugPrint('[INIT] ✗ Session check failed: $e');
      setState(() {
        _sessionCheckComplete = true;
      });
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    debugPrint('[MAIN] 🏗️ build() called');

    // If magicKey is present, route to magic link native page
    if (!kIsWeb && _magicKey != null) {
      return MagicLinkWebPageWithServer(
        serverUrl: _magicKey!,
        clientId: _clientId,
      );
    }

    // For native: Wait for session check to complete before building router
    // This ensures AuthService.isLoggedIn is set correctly for initial location
    if (!kIsWeb && !_sessionCheckComplete) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    // NOTE: Removed the "_servicesReady" check here because services now
    // initialize AFTER login, not before. The login page needs to be accessible
    // without any services being ready.

    // Wrap the entire app with providers
    return MultiProvider(
      providers: [
        // Theme Provider
        ChangeNotifierProvider<ThemeProvider>.value(
          value: widget.themeProvider,
        ),
        // Navigation State Provider
        ChangeNotifierProvider(create: (context) => NavigationStateProvider()),
        // Unread Messages Provider
        ChangeNotifierProvider(create: (context) => UnreadMessagesProvider()),
        // Role Providers
        ChangeNotifierProvider(
          create: (context) => RoleProvider(
            apiService: RoleApiService(baseUrl: widget.serverUrl),
          ),
        ),
        // File Transfer Stats Provider
        ChangeNotifierProvider(
          create: (context) => FileTransferStatsProvider(),
        ),
        // Video Conference provider (requires SocketService)
        ChangeNotifierProvider(create: (context) => VideoConferenceService()),
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
        debugPrint(
          '[MAIN] 🎨 Building MaterialApp with theme: ${themeProvider.themeMode}',
        );
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

            return IncomingCallListener(
              child: Stack(
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
              ),
            );
          },
        );
      },
    );
  }

  /// Determine initial location for native platforms (mobile + desktop)
  /// Returns the appropriate initial route based on server config and auth status
  String _getNativeInitialLocation() {
    final isMobile = Platform.isAndroid || Platform.isIOS;

    // Check if there are any configured servers
    if (!ServerConfigService.hasServers()) {
      final route = isMobile ? '/mobile-server-selection' : '/server-selection';
      debugPrint('[MAIN] No servers configured, starting at $route');
      return route;
    }

    // Check if user is logged in AND active server has credentials
    // This ensures we're checking auth for the specific active server
    final hasServerCredentials =
        ServerConfigService.activeServerHasCredentials();

    if (AuthService.isLoggedIn && hasServerCredentials) {
      debugPrint(
        '[MAIN] User is logged in for active server, starting at /app/activities',
      );
      return '/app/activities';
    }

    // Has servers but not authenticated for active server
    // Mobile: Go directly to mobile-webauthn which will load the active server URL
    // Desktop: Go to server-selection (magic key flow)
    final route = isMobile ? '/mobile-webauthn' : '/server-selection';
    debugPrint(
      '[MAIN] Active server needs authentication (isLoggedIn: ${AuthService.isLoggedIn}, hasCredentials: $hasServerCredentials), going to $route',
    );
    return route;
  }

  GoRouter _createRouter() {
    debugPrint('[MAIN] 🏗️ Creating GoRouter...');

    // Common routes shared across all platforms (registration flow, mobile auth)
    final List<GoRoute> commonRoutes = getAuthRoutes(clientId: _clientId ?? '');

    // Signal setup route (after authentication)
    final signalSetupRoute = GoRoute(
      path: '/signal-setup',
      builder: (context, state) => const SignalSetupScreen(),
    );

    // Use ShellRoute for native, flat routes for web
    final List<RouteBase> routes = kIsWeb
        ? [
            signalSetupRoute, // Signal setup after auth
            ...commonRoutes, // Add common registration & mobile routes
            ...getAuthRoutesWeb(
              clientId: _clientId ?? '',
            ), // Add web-specific auth routes
            GoRoute(path: '/', redirect: (context, state) => '/app'),
            // External Participant (Guest) Routes
            ...getMeetingRoutesExternal(),
            ShellRoute(
              builder: (context, state, child) => AppLayout(child: child),
              routes: [
                // Main App View Routes
                ...getAppRoutesWeb(),
                // Meetings & Calls
                ...getMeetingRoutes(),
                // File Transfer routes
                ...getFileRoutes(),
                // Settings routes
                getSettingsRoutes(),
              ],
            ),
          ]
        : [
            signalSetupRoute, // Signal setup after auth
            // Native server configuration routes (multi-server setup)
            ...getServerConfigRoutes(),
            // Add common registration routes for native platforms
            ...commonRoutes,
            ShellRoute(
              builder: (context, state, child) => AppLayout(child: child),
              routes: [
                GoRoute(path: '/', redirect: (context, state) => '/app'),
                // Native-specific auth routes (signal setup, magic link, login)
                ...getAuthRoutesNative(clientId: _clientId ?? ''),
                // Main App View Routes
                ...getAppRoutesNative(),
                // Meetings & Calls
                ...getMeetingRoutes(),
                // File Transfer routes
                ...getFileRoutes(),
                // Settings routes
                getSettingsRoutes(),
              ],
            ),
          ];

    debugPrint('[MAIN] 🏗️ Creating GoRouter...');
    final GoRouter router = GoRouter(
      navigatorKey: _rootNavigatorKey,
      initialLocation: !kIsWeb ? _getNativeInitialLocation() : '/login',
      routes: routes,
      redirect: (context, state) async {
        final location = state.matchedLocation;
        debugPrint('[ROUTER] 🔀 Redirect called for location: $location');

        // Allow guest routes (external participants) without authentication checks
        if (kIsWeb &&
            (location.startsWith('/join/') ||
                location.startsWith('/meeting/video/'))) {
          debugPrint(
            '[ROUTER] 🔓 Guest route detected, skipping authentication checks: $location',
          );
          return null;
        }

        // Native: Check if server selection is needed (no servers configured)
        if (!kIsWeb &&
            location != '/server-selection' &&
            location != '/mobile-server-selection' &&
            location != '/mobile-webauthn' &&
            location != '/mobile-backupcode-login' && // Allow backup code login
            !location.startsWith(
              '/callback',
            ) && // Allow Chrome Custom Tab callback (with query params)
            location != '/otp' && // Allow OTP during registration
            !location.startsWith('/register/')) {
          // Allow registration routes
          debugPrint('[ROUTER] 🔍 Checking servers for location: $location');
          if (!ServerConfigService.hasServers()) {
            // Mobile: Redirect to mobile server selection screen
            if (Platform.isAndroid || Platform.isIOS) {
              debugPrint(
                '[ROUTER] 📱 Mobile: No servers configured, redirecting to mobile server selection',
              );
              return '/mobile-server-selection';
            }
            // Desktop: Redirect to server selection
            debugPrint(
              '[ROUTER] 🖥️ Desktop: No servers configured, redirecting to server selection',
            );
            return '/server-selection';
          }
        } else if (!kIsWeb) {
          debugPrint('[ROUTER] ✅ Skipping server check for: $location');
        }

        // Only check session on initial load (when going to root or login page)
        // Also check when navigating to /app after login or after server-selection
        // Don't check session on every navigation - that's too expensive
        final shouldCheckSession =
            !LogoutService.instance.isLogoutComplete &&
            (location == '/' ||
                location == '/login' ||
                location == '/app' ||
                (location.startsWith('/app/') && !_postLoginInitComplete));

        if (shouldCheckSession) {
          debugPrint(
            '[ROUTER] 🔍 Checking session (initial load or post-login)...',
          );
          await AuthService.checkSession();
          debugPrint('[ROUTER] ✅ Session check complete');
        }

        final loggedIn = AuthService.isLoggedIn;
        debugPrint('[ROUTER] 🔐 Login status: $loggedIn, Location: $location');

        // Restore device identity from storage if not already initialized
        // This is required for database and Signal Protocol operations
        if (loggedIn && !DeviceIdentityService.instance.isInitialized) {
          debugPrint('[ROUTER] 🔄 Restoring device identity from storage...');

          // For native, get the active server URL to restore the correct identity
          String? serverUrl;
          if (!kIsWeb) {
            final activeServer = ServerConfigService.getActiveServer();
            serverUrl = activeServer?.serverUrl;
            if (serverUrl != null) {
              debugPrint('[ROUTER] 🔄 Active server: $serverUrl');
            }
          }

          final restored = await DeviceIdentityService.instance
              .tryRestoreFromSession(serverUrl: serverUrl);
          if (restored) {
            debugPrint('[ROUTER] ✅ Device identity restored');
          } else {
            // Device identity is required for database and Signal Protocol
            // If missing, this is an old session from before device identity was implemented
            // Force re-authentication with new magic key to initialize device identity
            debugPrint(
              '[ROUTER] ⚠️ Device identity not found - old session detected',
            );
            debugPrint(
              '[ROUTER] 🔄 Clearing HMAC session and forcing re-authentication...',
            );

            if (!kIsWeb) {
              // Clear HMAC session for native
              final clientId = await ClientIdService.getClientId();
              final activeServer = ServerConfigService.getActiveServer();
              if (activeServer != null) {
                await SessionAuthService().clearSession(
                  clientId,
                  serverUrl: activeServer.serverUrl,
                );
              }
              AuthService.isLoggedIn = false;

              // Redirect to server-selection to re-authenticate
              debugPrint(
                '[ROUTER] ↩️ Redirecting to server-selection for re-authentication',
              );
              return '/server-selection';
            }
          }
        }

        final uri = Uri.parse(state.uri.toString());
        final fromParam = uri.queryParameters['from'];
        if (loggedIn) {
          debugPrint('[ROUTER] ========================================');
          debugPrint(
            '[ROUTER] 🔐 User is logged in - checking post-login initialization',
          );
          debugPrint('[ROUTER] Current location: $location');
          debugPrint(
            '[ROUTER] _postLoginInitComplete: $_postLoginInitComplete',
          );
          debugPrint(
            '[ROUTER] PostLoginInitService.isInitialized: ${PostLoginInitService.instance.isInitialized}',
          );
          debugPrint('[ROUTER] ========================================');

          // ========================================
          // CREATE SIGNALCLIENT AFTER AUTHENTICATION
          // ========================================
          // After successful auth, create SignalClient for active server
          if (!_postLoginInitComplete && location != '/signal-setup') {
            debugPrint(
              '[ROUTER] 🔄 Creating SignalClient for active server...',
            );

            // CRITICAL: Initialize ApiService and SocketService FIRST
            // This must happen before we try to initialize SignalClient or redirect to signal-setup
            if (!PostLoginInitService.instance.isInitialized) {
              debugPrint(
                '[ROUTER] 🔧 Initializing ApiService and SocketService first...',
              );

              try {
                // Capture providers before any async operations
                // ignore: use_build_context_synchronously
                final unreadProvider = context.read<UnreadMessagesProvider>();
                // ignore: use_build_context_synchronously
                final roleProvider = context.read<RoleProvider>();
                // ignore: use_build_context_synchronously
                final statsProvider = context.read<FileTransferStatsProvider>();

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
                if (serverUrl.isNotEmpty &&
                    !serverUrl.startsWith('http://') &&
                    !serverUrl.startsWith('https://')) {
                  serverUrl = 'https://$serverUrl';
                }

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

                debugPrint(
                  '[ROUTER] ✅ ApiService and SocketService initialized',
                );
              } catch (e) {
                debugPrint('[ROUTER] ❌ Error during initialization: $e');
                // On error, redirect to login to be safe
                return '/login';
              }
            }

            try {
              // Check if SignalClient already exists and is initialized
              if (!ServerSettingsService.instance.isSignalClientInitialized()) {
                debugPrint('[ROUTER] 📡 SignalClient not initialized');
                debugPrint('[ROUTER] ↪️ Redirecting to /signal-setup');
                return '/signal-setup';
              }
            } catch (e) {
              debugPrint('[ROUTER] ❌ Error checking SignalClient: $e');
              // Continue without blocking - will show error in setup screen
            }
          }

          // ========================================
          // POST-LOGIN SERVICE INITIALIZATION (ONCE)
          // ========================================
          // Skip Signal key checks ONLY for authentication flows when NOT logged in
          // If logged in, we should always run initialization checks
          final isAuthFlow =
              !loggedIn &&
              (location == '/otp' ||
                  location == '/login' ||
                  location == '/backupcode/recover' ||
                  location.startsWith('/register/') ||
                  location == '/signal-setup');

          debugPrint('[ROUTER] isAuthFlow: $isAuthFlow');

          if (!isAuthFlow) {
            debugPrint(
              '[ROUTER] Not an auth flow - checking Signal keys status...',
            );
            // Check if Signal keys need setup when navigating to main app routes
            if (location == '/app' ||
                location == '/' ||
                location.startsWith('/app/')) {
              debugPrint(
                '[ROUTER] App route detected - checking SignalClient initialization...',
              );

              try {
                if (!ServerSettingsService.instance
                    .isSignalClientInitialized()) {
                  debugPrint(
                    '[ROUTER] SignalClient not initialized - redirecting to /signal-setup',
                  );

                  // Save current route for restoration after setup
                  if (location.startsWith('/app/') &&
                      location != '/app/' &&
                      location.length > 5) {
                    debugPrint(
                      '[MAIN] Saving current route before signal-setup: $location',
                    );
                    await PreferencesService().saveLastRoute(location);
                  }

                  return '/signal-setup';
                }

                debugPrint('[ROUTER] ✅ SignalClient initialized');
              } catch (e) {
                debugPrint('[ROUTER] ❌ Error checking SignalClient: $e');
                // Continue - will be caught in setup screen
              }
            }
          }

          // ========================================
          // POST-LOGIN SERVICE INITIALIZATION (ONCE)
          // ========================================
          // This section is now handled earlier in the router redirect (lines 994-1060)
          // to ensure services are initialized before redirecting to signal-setup
          // Keeping this comment for reference
        } else {
          // Logout cleanup
          // Reset post-login initialization flag so it runs again on next login
          _postLoginInitComplete = false;
          debugPrint('[MAIN] 🔄 Reset post-login initialization flag');

          // Reset PostLoginInitService state
          PostLoginInitService.instance.reset();
          debugPrint('[MAIN] 🔄 Reset PostLoginInitService');

          // Cleanup all servers (SignalClient, SocketService, ApiService, etc.)
          await ServerSettingsService.instance.removeAllServers();

          // Clear roles on logout
          try {
            // ignore: use_build_context_synchronously
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
            debugPrint(
              '[ROUTER] ✅ Web: Logged in at /login, redirecting to /app/activities',
            );
            return '/app/activities';
          } else {
            // Native: Redirect to /app/activities which will trigger signal setup check
            debugPrint(
              '[ROUTER] ✅ Native: Logged in at /login, redirecting to /app/activities',
            );
            return '/app/activities';
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
        if (kIsWeb && loggedIn && location == '/magic-link') {
          return null;
        }
        if (kIsWeb && !loggedIn && location == '/magic-link') {
          return '/login?from=magic-link';
        }
        if (kIsWeb && loggedIn && fromParam == 'magic-link') {
          return '/magic-link';
        }

        // Allow guest join routes (external participants) without authentication
        debugPrint('[ROUTER] Checking guest routes - location: $location');
        if (kIsWeb &&
            !loggedIn &&
            (location.startsWith('/join/') ||
                location.startsWith('/meeting/video/'))) {
          debugPrint('[ROUTER] 🔓 Guest access allowed for: $location');
          return null;
        }
        // Allow registration flow even when not logged in
        if (kIsWeb &&
            !loggedIn &&
            !location.startsWith('/register/') &&
            !location.startsWith('/join/') &&
            !location.startsWith('/meeting/video/')) {
          debugPrint('[ROUTER] ⚠️ Web: Not logged in, redirecting to /login');
          return '/login';
        }

        // Native: If not logged in and not on auth flow, redirect to appropriate screen
        if (!kIsWeb &&
            !loggedIn &&
            location != '/server-selection' &&
            location != '/mobile-server-selection' &&
            location != '/mobile-webauthn' &&
            location != '/mobile-backupcode-login' &&
            location != '/callback' && // Allow Chrome Custom Tab callback
            location != '/register' &&
            location != '/login' &&
            !location.startsWith('/register/') &&
            !location.startsWith('/otp')) {
          // Mobile: Redirect to mobile server selection
          if (Platform.isAndroid || Platform.isIOS) {
            debugPrint(
              '[ROUTER] ⚠️ Mobile: Not logged in, redirecting to mobile server selection',
            );
            return '/mobile-server-selection';
          }
          // Desktop: Redirect to server selection
          debugPrint(
            '[ROUTER] ⚠️ Desktop: Not logged in, redirecting to server-selection for re-authentication',
          );
          return '/server-selection';
        }

        // Otherwise, allow navigation
        return null;
      },
    );

    debugPrint('[MAIN] ✅ GoRouter created');

    return router;
  }
}

/// Detects if the app was started via autostart (Windows startup)
///
/// Returns true if:
/// - A valid session exists (user was previously logged in)
/// - No explicit login action was taken (not launched via magic link or deep link)
///
/// This helps identify scenarios where the window appears before
/// initialization completes, which is common with autostart.
Future<bool> _detectAutostart() async {
  try {
    // Check if a session exists for the active server (indicates autostart scenario)
    final clientId = await ClientIdService.getClientId();
    final sessionAuth = SessionAuthService();

    // For native, check active server; for web, use hostname
    String? serverIdentifier;
    if (!kIsWeb) {
      final activeServer = ServerConfigService.getActiveServer();
      serverIdentifier = activeServer?.serverUrl;
    } else {
      serverIdentifier = Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
    }

    if (serverIdentifier != null) {
      final hasSession = await sessionAuth.hasSession(
        clientId: clientId,
        serverUrl: serverIdentifier,
      );

      if (hasSession) {
        debugPrint(
          '[INIT] Session found for $serverIdentifier - likely autostart scenario',
        );
        return true;
      }
    }

    return false;
  } catch (e) {
    debugPrint('[INIT] Error detecting autostart: $e');
    return false; // Assume not autostart on error
  }
}

/// Loading screen for auth callback with polling and abort button
