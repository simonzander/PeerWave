import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../screens/server_selection_screen.dart';
import '../../../screens/mobile_server_selection_screen.dart';
import '../../../screens/mobile_webauthn_login_screen.dart';

/// Native-only server configuration routes
/// These routes handle multi-server setup and selection before authentication
List<GoRoute> getServerConfigRoutes() {
  return [
    // Mobile server selection route (outside ShellRoute - no navbar)
    GoRoute(
      path: '/mobile-server-selection',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final errorMessage = extra?['errorMessage'] as String?;
        return MaterialPage(
          fullscreenDialog: true,
          child: MobileServerSelectionScreen(errorMessage: errorMessage),
        );
      },
    ),
    // Mobile WebAuthn login route (outside ShellRoute - no navbar)
    GoRoute(
      path: '/mobile-webauthn',
      pageBuilder: (context, state) {
        final serverUrl = state.extra as String?;
        return MaterialPage(
          fullscreenDialog: true,
          child: MobileWebAuthnLoginScreen(serverUrl: serverUrl),
        );
      },
    ),
    // Server selection route (outside ShellRoute - no navbar, has own AppBar)
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
  ];
}
