import 'package:uni_links/uni_links.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'auth/auth_layout_web.dart' if (dart.library.io) 'auth/auth_layout_native.dart';
import 'auth/magic_link_web.dart' if (dart.library.io) 'auth/magic_link_native.dart';
import 'auth/magic_link_native.dart' show MagicLinkWebPageWithServer;
import 'app/app_layout.dart';
// Use conditional import for 'services/auth_service.dart'
import 'services/auth_service_web.dart' if (dart.library.io) 'services/auth_service_native.dart';
// Import clientid logic only for native
import 'services/clientid_native.dart' if (dart.library.html) 'services/clientid_stub.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    // ...existing MaterialApp.router or other app code...
    final List<GoRoute> routes = [
      GoRoute(
        path: '/magic-link',
        builder: (context, state) {
          final extra = state.extra;
          print('Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: ${widget.clientId}, extra is String: ${extra is String}');
          if (!kIsWeb && extra is String && extra.isNotEmpty) {
            print("Rendering MagicLinkWebPageWithServer, clientId: ${widget.clientId}");
            return MagicLinkWebPageWithServer(serverUrl: extra, clientId: widget.clientId);
          }
          return const MagicLinkWebPage();
        },
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) {
          // Use fullscreenDialog for native, standard for web
          if (!kIsWeb) {
            return MaterialPage(
              fullscreenDialog: true,
              child: const AuthLayout(),
            );
          } else {
            return MaterialPage(
              child: const AuthLayout(),
            );
          }
        },
      ),
      GoRoute(
        path: '/app',
        builder: (context, state) => const AppLayout(),
      ),
    ];

    final GoRouter router = GoRouter(
      initialLocation: '/app',
      routes: routes,
      redirect: (context, state) async {
        await AuthService.checkSession();
        final loggedIn = AuthService.isLoggedIn;
        final location = state.matchedLocation;
        final uri = Uri.parse(state.uri.toString());
        final fromParam = uri.queryParameters['from'];

        // ...existing redirect logic...
        if (kIsWeb && !loggedIn && location == '/magic-link') {
          return '/login?from=magic-link';
        }
        if (kIsWeb && loggedIn && fromParam == 'magic-link') {
          return '/magic-link';
        }
        if (kIsWeb && !loggedIn && location == '/magic-link') {
          return '/login?from=magic-link';
        }
        if(kIsWeb && !loggedIn) {
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
