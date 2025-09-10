import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'auth/auth_layout.dart';
import 'app/app_layout.dart';
import 'services/auth_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final GoRouter router = GoRouter(
      initialLocation: "/login",
      routes: [
        GoRoute(
          path: "/login",
          builder: (context, state) => AuthLayout(),
        ),
        GoRoute(
          path: "/app",
          builder: (context, state) => const AppLayout(),
        ),
      ],
      redirect: (context, state) {
        final loggedIn = AuthService.isLoggedIn;
        final loggingIn = state.matchedLocation == "/login";

        if (!loggedIn && !loggingIn) return "/login";
        if (loggedIn && loggingIn) return "/app";
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
