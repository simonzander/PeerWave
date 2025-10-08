import 'package:socket_io_client/socket_io_client.dart';
import 'package:uni_links/uni_links.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'auth/auth_layout_web.dart' if (dart.library.io) 'auth/auth_layout_native.dart';
import 'auth/magic_link_web.dart' if (dart.library.io) 'auth/magic_link_native.dart';
import 'auth/otp_web.dart';
import 'auth/magic_link_native.dart' show MagicLinkWebPageWithServer;
import 'app/app_layout.dart';
import 'app/dashboard_page.dart';
import 'app/settings_sidebar.dart';
import 'app/credentials_page.dart';
import 'app/webauthn_web.dart' if (dart.library.io) 'app/webauthn_stub.dart';
import 'app/backupcode_web.dart' if (dart.library.io) 'app/backupcode_stub.dart';
// Use conditional import for 'services/auth_service.dart'
import 'services/auth_service_web.dart' if (dart.library.io) 'services/auth_service_native.dart';
// Import clientid logic only for native
import 'services/clientid_native.dart' if (dart.library.html) 'services/clientid_stub.dart';
import 'services/api_service.dart';
import 'auth/backup_recover_web.dart' if (dart.library.io) 'auth/backup_recover_stub.dart';
import 'services/socket_service.dart';
import 'services/signal_service.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ApiService.init();
  String? initialMagicKey;
  String? clientId;
  if (!kIsWeb) {
    // Initialize and load client ID for native only
    clientId = await ClientIdService.getClientId();
    print('Client ID: $clientId');

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
  runApp(MyApp(initialMagicKey: initialMagicKey, clientId: clientId));
}

class MyApp extends StatefulWidget {
  final String? initialMagicKey;
  final String? clientId;
  const MyApp({Key? key, this.initialMagicKey, this.clientId}) : super(key: key);

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
                  child: const AuthLayout(),
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
                return OtpWebPage(email: email, serverUrl: serverUrl, wait: wait);
              },
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
                      builder: (context, state) => const BackupCodeListPage(),
                    ),
                    GoRoute(
                      path: '/app/settings/profile',
                      builder: (context, state) => Center(child: Text('Profile Settings')), // Placeholder
                    ),
                    GoRoute(
                      path: '/app/settings/notifications',
                      builder: (context, state) => Center(child: Text('Notification Settings')), // Placeholder
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
                      child: const AuthLayout(),
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
          await SocketService().connect();
          await SignalService().init();
        } else {
          if(SocketService().isConnected) SocketService().disconnect();
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
