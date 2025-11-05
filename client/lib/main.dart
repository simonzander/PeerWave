import 'package:socket_io_client/socket_io_client.dart';
import 'package:uni_links/uni_links.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'auth/auth_layout_web.dart' if (dart.library.io) 'auth/auth_layout_native.dart';
import 'auth/magic_link_web.dart' if (dart.library.io) 'auth/magic_link_native.dart';
import 'auth/otp_web.dart';
import 'auth/register_webauthn_page.dart';
import 'auth/register_profile_page.dart';
import 'auth/magic_link_native.dart' show MagicLinkWebPageWithServer;
import 'screens/signal_setup_screen.dart';
import 'services/signal_setup_service.dart';
import 'services/signal_service.dart';
import 'services/message_cleanup_service.dart';
import 'services/logout_service.dart';
import 'services/api_service.dart' show setGlobalUnauthorizedHandler;
import 'services/socket_service.dart' show setSocketUnauthorizedHandler;
import 'app/app_layout.dart';
import 'app/dashboard_page.dart';
import 'app/settings_sidebar.dart';
import 'app/credentials_page.dart';
import 'app/profile_page.dart';
import 'app/settings/general_settings_page.dart';
import 'app/webauthn_web.dart' if (dart.library.io) 'app/webauthn_stub.dart';
import 'app/backupcode_web.dart' if (dart.library.io) 'app/backupcode_stub.dart';
import 'app/backupcode_settings_page.dart';
// Use conditional import for 'services/auth_service.dart'
import 'services/auth_service_web.dart' if (dart.library.io) 'services/auth_service_native.dart';
// Import clientid logic only for native
import 'services/clientid_native.dart' if (dart.library.html) 'services/clientid_web.dart';
import 'services/api_service.dart';
import 'auth/backup_recover_web.dart' if (dart.library.io) 'auth/backup_recover_stub.dart';
import 'services/socket_service.dart';
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
// P2P File Transfer imports
import 'services/file_transfer/webrtc_service.dart';
import 'services/file_transfer/p2p_coordinator.dart';
import 'services/file_transfer/download_manager.dart';
import 'services/file_transfer/storage_interface.dart';
import 'services/file_transfer/encryption_service.dart';
import 'services/file_transfer/chunking_service.dart';
import 'services/file_transfer/socket_file_client.dart';
import 'services/file_transfer/file_reannounce_service.dart';
import 'screens/file_transfer/file_upload_screen.dart';
import 'screens/file_transfer/file_manager_screen.dart';
import 'screens/file_transfer/file_browser_screen.dart';
import 'screens/file_transfer/downloads_screen.dart';
import 'screens/file_transfer/file_transfer_hub.dart';
import 'widgets/socket_aware_widget.dart';
// Conditional storage imports
import 'services/file_transfer/indexeddb_storage.dart' if (dart.library.io) 'services/file_transfer/native_storage.dart' show IndexedDBStorage;
// ICE Config Service
import 'services/ice_config_service.dart';
// Video Conference imports
import 'services/video_conference_service.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ApiService.init();
  String? initialMagicKey;
  String? clientId;

  // Initialize and load client ID for native only
    clientId = await ClientIdService.getClientId();
    debugPrint('Client ID: $clientId');

  if (!kIsWeb) {
    // Listen for initial link (when app is started via deep link)
    try {
      final initialUri = await getInitialUri();
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
  
  // Load ICE server configuration
  debugPrint('[INIT] Loading ICE server configuration...');
  try {
    await IceConfigService().loadConfig(serverUrl: serverUrl);
    debugPrint('[INIT] ✅ ICE server configuration loaded');
  } catch (e) {
    debugPrint('[INIT] ⚠️ Failed to load ICE config, will use fallback: $e');
  }
  
  // Initialize Theme Provider
  debugPrint('[INIT] Initializing Theme Provider...');
  final themeProvider = ThemeProvider();
  await themeProvider.initialize();
  debugPrint('[INIT] ✅ Theme Provider initialized');
  
  // Initialize Message Cleanup Service (Auto-Delete)
  debugPrint('[INIT] Initializing Message Cleanup Service...');
  try {
    await MessageCleanupService.instance.init();
    debugPrint('[INIT] ✅ Message Cleanup Service initialized');
  } catch (e) {
    debugPrint('[INIT] ⚠️ Failed to initialize Message Cleanup Service: $e');
  }
  
  runApp(MyApp(
    initialMagicKey: initialMagicKey, 
    clientId: clientId, 
    serverUrl: serverUrl,
    themeProvider: themeProvider,
  ));
}

class MyApp extends StatefulWidget {
  final String? initialMagicKey;
  final String clientId;
  final String serverUrl;
  final ThemeProvider themeProvider;
  
  const MyApp({
    Key? key, 
    this.initialMagicKey, 
    required this.clientId, 
    required this.serverUrl,
    required this.themeProvider,
  }) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _sub;
  String? _magicKey;
  
  // P2P File Transfer services - initialize once
  FileStorageInterface? _fileStorage;
  EncryptionService? _encryptionService;
  ChunkingService? _chunkingService;
  DownloadManager? _downloadManager;
  WebRTCFileService? _webrtcService;
  P2PCoordinator? _p2pCoordinator;
  bool _servicesReady = false;

  @override
  void initState() {
    super.initState();
    _magicKey = widget.initialMagicKey;
    _initServices();
    
    if (!kIsWeb) {
      _sub = uriLinkStream.listen((Uri? uri) {
        if (uri != null && uri.scheme == 'peerwave') {
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
  
  void _initServices() {
    debugPrint('[P2P] Starting service initialization...');
    try {
      _fileStorage = IndexedDBStorage();
      debugPrint('[P2P] FileStorage created');
      _encryptionService = EncryptionService();
      debugPrint('[P2P] EncryptionService created');
      _chunkingService = ChunkingService();
      debugPrint('[P2P] ChunkingService created');
      _downloadManager = DownloadManager(
        storage: _fileStorage!,
        chunkingService: _chunkingService!,
        encryptionService: _encryptionService!,
      );
      debugPrint('[P2P] DownloadManager created');
      
      // Get ICE servers from config service
      final iceServers = IceConfigService().getIceServers();
      debugPrint('[P2P] Using ICE servers: ${iceServers['iceServers']?.length ?? 0} servers');
      
      _webrtcService = WebRTCFileService(iceServers: iceServers);
      debugPrint('[P2P] WebRTCFileService created with dynamic ICE servers');
      
      // NOTE: P2PCoordinator will be created after Socket.IO connects
      // (in _initP2PCoordinator(), called after login)
      debugPrint('[P2P] Basic services created, P2PCoordinator will be initialized after Socket connects');
      
      // Initialize storage asynchronously
      _fileStorage!.initialize().then((_) {
        debugPrint('[P2P] Storage initialized successfully');
        if (mounted) {
          setState(() {
            _servicesReady = true;
          });
          debugPrint('[P2P] Services marked as ready');
        }
      }).catchError((e) {
        debugPrint('[P2P] Storage initialization error: $e');
        // Mark as ready anyway to avoid infinite loading
        if (mounted) {
          setState(() {
            _servicesReady = true;
          });
        }
      });
    } catch (e) {
      debugPrint('[P2P] Service initialization error: $e');
      debugPrint('[P2P] Stack trace: ${StackTrace.current}');
      // Mark as ready anyway
      if (mounted) {
        setState(() {
          _servicesReady = true;
        });
      }
    }
  }
  
  /// Initialize P2PCoordinator after Socket.IO is connected
  void _initP2PCoordinator() async {
    if (_p2pCoordinator != null) {
      debugPrint('[P2P] P2PCoordinator already initialized');
      return;
    }
    
    debugPrint('[P2P] Initializing P2PCoordinator with Socket.IO connection...');
    try {
      final socketService = SocketService();
      if (socketService.socket == null || !socketService.isConnected) {
        debugPrint('[P2P] WARNING: Socket not connected yet, deferring P2PCoordinator initialization');
        return;
      }
      
      final socketFileClient = SocketFileClient(socket: socketService.socket!);
      debugPrint('[P2P] SocketFileClient created');
      
      _p2pCoordinator = P2PCoordinator(
        webrtcService: _webrtcService!,
        downloadManager: _downloadManager!,
        storage: _fileStorage!,
        encryptionService: _encryptionService!,
        signalService: SignalService.instance,
        socketClient: socketFileClient,
        chunkingService: ChunkingService(),
      );
      debugPrint('[P2P] ✓ P2PCoordinator initialized successfully');
      
      // VideoConferenceService is initialized via Provider in build()
      // No separate initialization needed - it will be created with SocketService injection
      debugPrint('[VideoConference] VideoConferenceService will be initialized via Provider');
      
      // Trigger rebuild to add P2PCoordinator to provider tree
      if (mounted) {
        setState(() {});
        debugPrint('[P2P] ✓ Provider tree updated with P2PCoordinator');
      }
      
    } catch (e, stackTrace) {
      debugPrint('[P2P] ERROR initializing P2PCoordinator: $e');
      debugPrint('[P2P] Stack trace: $stackTrace');
    }
  }
  
  /// Re-announce files from local storage after login
  void _reannounceLocalFiles() async {
    try {
      debugPrint('[REANNOUNCE] Starting file re-announcement after login...');
      
      final socketService = SocketService();
      if (socketService.socket == null || !socketService.isConnected) {
        debugPrint('[REANNOUNCE] Socket not connected, skipping re-announcement');
        return;
      }
      
      if (_fileStorage == null) {
        debugPrint('[REANNOUNCE] Storage not initialized, skipping re-announcement');
        return;
      }
      
      final socketFileClient = SocketFileClient(socket: socketService.socket!);
      final reannounceService = FileReannounceService(
        storage: _fileStorage!,
        socketClient: socketFileClient,
      );
      
      final result = await reannounceService.reannounceAllFiles();
      
      if (result.reannounced > 0) {
        debugPrint('[REANNOUNCE] ✓ Successfully re-announced ${result.reannounced} files');
      }
      
      if (result.failed > 0) {
        debugPrint('[REANNOUNCE] ⚠ Failed to re-announce ${result.failed} files');
      }
      
    } catch (e, stackTrace) {
      debugPrint('[REANNOUNCE] ERROR: $e');
      debugPrint('[REANNOUNCE] Stack trace: $stackTrace');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If magicKey is present, route to magic link native page
    if (!kIsWeb && _magicKey != null) {
      return MagicLinkWebPageWithServer(serverUrl: _magicKey!, clientId: widget.clientId);
    }
    
    // Show loading screen until services are ready
    if (!_servicesReady) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Initializing services...'),
              ],
            ),
          ),
        ),
      );
    }
    
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
        // Video Conference provider (requires SocketService)
        ChangeNotifierProvider(
          create: (context) => VideoConferenceService(),
        ),
        // P2P File Transfer providers - use the initialized services
        Provider<FileStorageInterface>.value(value: _fileStorage!),
        Provider<EncryptionService>.value(value: _encryptionService!),
        Provider<ChunkingService>.value(value: _chunkingService!),
        ChangeNotifierProvider<DownloadManager>.value(value: _downloadManager!),
        ChangeNotifierProvider<WebRTCFileService>.value(value: _webrtcService!),
        // P2PCoordinator is initialized after Socket.IO connects (can be null initially)
        ChangeNotifierProvider<P2PCoordinator?>.value(value: _p2pCoordinator),
      ],
      child: _buildMaterialApp(),
    );
  }

  Widget _buildMaterialApp() {
    // Initialize 401 Unauthorized handlers (one-time setup)
    setGlobalUnauthorizedHandler(() {
      try {
        if (mounted) {
          LogoutService.instance.autoLogout(context);
        } else {
          // Context not available, call without context
          LogoutService.instance.autoLogout(null);
        }
      } catch (e) {
        debugPrint('[MAIN] Error in unauthorized handler: $e');
        // Fallback: call without context
        LogoutService.instance.autoLogout(null);
      }
    });
    
    setSocketUnauthorizedHandler(() {
      try {
        if (mounted) {
          LogoutService.instance.autoLogout(context);
        } else {
          // Context not available, call without context
          LogoutService.instance.autoLogout(null);
        }
      } catch (e) {
        debugPrint('[MAIN] Error in socket unauthorized handler: $e');
        // Fallback: call without context
        LogoutService.instance.autoLogout(null);
      }
    });
    
    debugPrint('[MAIN] ✓ Unauthorized handlers initialized');

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
                debugPrint('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: ${widget.clientId}, extra is String: ${extra is String}');
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
                  child: AuthLayout(clientId: widget.clientId),
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
                return OtpWebPage(email: email, serverUrl: serverUrl, clientId: widget.clientId, wait: wait);
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
                GoRoute(
                  path: '/app',
                  builder: (context, state) => const DashboardPage(),
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
                ShellRoute(
                  builder: (context, state, child) => SettingsSidebar(child: child),
                  routes: [
                    GoRoute(
                      path: '/app/settings',
                      builder: (context, state) => const CredentialsPage(),
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
                      builder: (context, state) => Center(child: Text('Notification Settings')), // Placeholder
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
                GoRoute(
                  path: '/magic-link',
                  builder: (context, state) {
                    final extra = state.extra;
                    debugPrint('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: ${widget.clientId}, extra is String: ${extra is String}');
                    if (extra is String && extra.isNotEmpty) {
                      debugPrint("Rendering MagicLinkWebPageWithServer, clientId: ${widget.clientId}");
                      return MagicLinkWebPageWithServer(serverUrl: extra, clientId: widget.clientId);
                    }
                    return const MagicLinkWebPage();
                  },
                ),
                GoRoute(
                  path: '/login',
                  pageBuilder: (context, state) {
                    return MaterialPage(
                      fullscreenDialog: true,
                      child: AuthLayout(clientId: widget.clientId),
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
                  builder: (context, state) => const SizedBox.shrink(), // AppLayout already wraps child
                ),
                // Add more child routes here as needed
              ],
            ),
          ];

    final GoRouter router = GoRouter(
      routes: routes,
      redirect: (context, state) async {
        // Skip session check if logout just completed
        if (!LogoutService.instance.isLogoutComplete) {
          await AuthService.checkSession();
        }
        final loggedIn = AuthService.isLoggedIn;
        final location = state.matchedLocation;
        final uri = Uri.parse(state.uri.toString());
        final fromParam = uri.queryParameters['from'];
        if(loggedIn) {
          // Small delay to ensure session cookies are properly set before Socket.IO connects
          await Future.delayed(const Duration(milliseconds: 100));
          await SocketService().connect();
          
          // Initialize P2PCoordinator after Socket.IO is connected
          _initP2PCoordinator();
          
          // Re-announce files from local storage after connection
          _reannounceLocalFiles();
          
          // Load user roles after successful login
          try {
            final roleProvider = context.read<RoleProvider>();
            if (!roleProvider.isLoaded) {
              await roleProvider.loadUserRoles();
            }
          } catch (e) {
            debugPrint('Error loading user roles: $e');
          }
          
          // ========================================
          // CONSOLIDATED POST-LOGIN INITIALIZATION
          // ========================================
          // This replaces multiple scattered async operations with one
          // sequential flow to avoid race conditions
          
          // Skip Signal key checks for authentication and registration flows
          final isAuthFlow = location == '/otp' 
              || location == '/login'
              || location == '/backupcode/recover'
              || location.startsWith('/register/')
              || location == '/signal-setup';
          
          if (!isAuthFlow) {
            // Check if Signal keys need setup when navigating to main app routes
            if (location == '/app' || location == '/') {
              try {
                final needsSetup = await SignalSetupService.instance.needsSetup();
                if (needsSetup) {
                  debugPrint('[MAIN] Signal keys need setup, redirecting to /signal-setup');
                  return '/signal-setup';
                }
                
                // Keys exist - run consolidated initialization
                debugPrint('[MAIN] ========================================');
                debugPrint('[MAIN] Starting post-login initialization...');
                debugPrint('[MAIN] ========================================');
                
                final unreadProvider = context.read<UnreadMessagesProvider>();
                await SignalSetupService.instance.initializeAfterLogin(
                  unreadProvider: unreadProvider,
                  onProgress: (step, current, total) {
                    debugPrint('[MAIN] [$current/$total] $step');
                  },
                );
                
                debugPrint('[MAIN] ========================================');
                debugPrint('[MAIN] ✅ Post-login initialization complete');
                debugPrint('[MAIN] ========================================');
                
              } catch (e) {
                debugPrint('[MAIN] ⚠ Error during initialization: $e');
              }
            } else {
              // For other app routes (e.g. /app/channels), ensure initialization is done
              try {
                if (!SignalSetupService.instance.isPostLoginInitComplete) {
                  debugPrint('[MAIN] Running initialization for app route: $location');
                  
                  final unreadProvider = context.read<UnreadMessagesProvider>();
                  await SignalSetupService.instance.initializeAfterLogin(
                    unreadProvider: unreadProvider,
                    onProgress: (step, current, total) {
                      debugPrint('[MAIN] [$current/$total] $step');
                    },
                  );
                }
              } catch (e) {
                debugPrint('[MAIN] ⚠ Error initializing for app route: $e');
              }
            }
          }
        } else {
          // Logout cleanup
          if(SocketService().isConnected) SocketService().disconnect();
          
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
          return '/login';
        }
        if (kIsWeb && loggedIn && location == '/login') {
          return '/app';
        }
        // Otherwise, allow navigation
        return null;
      },
    );

    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          routerConfig: router,
        );
      },
    );
  }
}

