import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'auth/auth_layout_web.dart' if (dart.library.io) 'auth/auth_layout_native.dart';
import 'auth/magic_link_web.dart' if (dart.library.io) 'auth/magic_link_native.dart';
import 'auth/magic_link_native.dart' show MagicLinkWebPageWithServer;
import 'app/app_layout.dart';
// Use conditional import for 'services/auth_service.dart'
import 'services/auth_service_web.dart' if (dart.library.io) 'services/auth_service_native.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final List<GoRoute> routes = [
      GoRoute(
        path: '/magic-link',
        builder: (context, state) {
          // On native, use MagicLinkWebPageWithServer if extra is provided
          final extra = state.extra;
          if (!kIsWeb && extra is String && extra.isNotEmpty) {
            return MagicLinkWebPageWithServer(serverUrl: extra);
          }
          return const MagicLinkWebPage();
        },
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const AuthLayout(),
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
        final from = state.extra;

        // WEB: If not logged in and accessing /magic-link, show login page
        if (kIsWeb && !loggedIn && location == '/magic-link') {
          // Pass info that user came from /magic-link
          return '/login?from=magic-link';
        }

        // WEB: If not logged in and accessing /app, show login page
        if (kIsWeb && !loggedIn && location == '/app') {
          return '/login';
        }

        // WEB: If logged in and on /login, redirect to /magic-link if came from there, else /app
        if (kIsWeb && loggedIn && location == '/login') {
          final uri = Uri.parse(state.uri.toString());
          final fromParam = uri.queryParameters['from'];
          if (fromParam == 'magic-link') {
            return '/magic-link';
          }
          return '/app';
        }

        if(!kIsWeb && !loggedIn && location == '/app') {
          return '/login';
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
