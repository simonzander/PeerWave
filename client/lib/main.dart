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
import 'app/app_layout.dart';
import 'app/dashboard_page.dart';
import 'app/settings_sidebar.dart';
import 'app/credentials_page.dart';
import 'app/profile_page.dart';
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
import 'services/message_listener_service.dart';
// Role management imports
import 'providers/role_provider.dart';
import 'providers/notification_provider.dart';
import 'services/role_api_service.dart';
import 'screens/admin/role_management_screen.dart';
import 'screens/admin/user_management_screen.dart';
import 'web_config.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ApiService.init();
  String? initialMagicKey;
  String? clientId;

  // Initialize and load client ID for native only
    clientId = await ClientIdService.getClientId();
    print('Client ID: $clientId');

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
  
  runApp(MyApp(initialMagicKey: initialMagicKey, clientId: clientId, serverUrl: serverUrl));
}

class MyApp extends StatefulWidget {
  final String? initialMagicKey;
  final String clientId;
  final String serverUrl;
  const MyApp({Key? key, this.initialMagicKey, required this.clientId, required this.serverUrl}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _sub;
  String? _magicKey;

  @override
  void initState() {
    super.initState();
    _magicKey = widget.initialMagicKey;
    if (!kIsWeb) {
      _sub = uriLinkStream.listen((Uri? uri) {
        if (uri != null && uri.scheme == 'peerwave') {
          final magicKey = uri.queryParameters['magicKey'];
          if (magicKey != null) {
            setState(() {
              _magicKey = magicKey;
              print('Received magicKey: $_magicKey');
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If magicKey is present, route to magic link native page
    if (!kIsWeb && _magicKey != null) {
      return MagicLinkWebPageWithServer(serverUrl: _magicKey!, clientId: widget.clientId);
    }
    
    // Wrap the entire app with RoleProvider
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) => RoleProvider(
            apiService: RoleApiService(baseUrl: widget.serverUrl),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => NotificationProvider(),
        ),
      ],
      child: _buildMaterialApp(),
    );
  }

  Widget _buildMaterialApp() {

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
                print('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: ${widget.clientId}, extra is String: ${extra is String}');
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
                print('Navigating to OtpWebPage with email: $email, serverUrl: $serverUrl, wait: $wait');
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
                    print('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: ${widget.clientId}, extra is String: ${extra is String}');
                    if (extra is String && extra.isNotEmpty) {
                      print("Rendering MagicLinkWebPageWithServer, clientId: ${widget.clientId}");
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
        await AuthService.checkSession();
        final loggedIn = AuthService.isLoggedIn;
        final location = state.matchedLocation;
        final uri = Uri.parse(state.uri.toString());
        final fromParam = uri.queryParameters['from'];
        if(loggedIn) {
          // Small delay to ensure session cookies are properly set before Socket.IO connects
          await Future.delayed(const Duration(milliseconds: 100));
          await SocketService().connect();
          
          // Load user roles after successful login
          try {
            final roleProvider = context.read<RoleProvider>();
            if (!roleProvider.isLoaded) {
              await roleProvider.loadUserRoles();
            }
          } catch (e) {
            print('Error loading user roles: $e');
          }
          
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
                  print('Signal keys need setup, redirecting to /signal-setup');
                  return '/signal-setup';
                }
                
                // If we get here, keys are already present
                // Initialize SignalService stores and listeners (without generating keys)
                if (!SignalService.instance.isInitialized) {
                  print('[MAIN] Signal keys exist, initializing stores and listeners...');
                  await SignalService.instance.initStoresAndListeners();
                }
                
              } catch (e) {
                print('Error checking Signal key status: $e');
              }
            } else {
              // For other app routes (e.g. /app/channels), just initialize stores if not already done
              try {
                if (!SignalService.instance.isInitialized) {
                  print('[MAIN] Initializing Signal stores for app route: $location');
                  await SignalService.instance.initStoresAndListeners();
                }
              } catch (e) {
                print('Error initializing Signal stores: $e');
              }
            }
          }
          
          // Initialize global message listeners (after SignalService is ready)
          await MessageListenerService.instance.initialize();
        } else {
          if(SocketService().isConnected) SocketService().disconnect();
          
          // Dispose global message listeners
          MessageListenerService.instance.dispose();
          
          // Clear roles on logout
          try {
            final roleProvider = context.read<RoleProvider>();
            roleProvider.clearRoles();
          } catch (e) {
            print('Error clearing roles: $e');
          }
        }
        // ...existing redirect logic...
        print("kIsWeb: $kIsWeb");
        print("loggedIn: $loggedIn");
        print("location: $location");
        print("fromParam: $fromParam");
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
        if (kIsWeb && !loggedIn) {
          return '/login';
        }
        if (kIsWeb && loggedIn && location == '/login') {
          return '/app';
        }
        // Otherwise, allow navigation
        return null;
      },
    );

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      routerConfig: router,
    );
  }
}
