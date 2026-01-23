import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/auth_layout_web.dart';
import '../../../auth/otp_web.dart';
import '../../../auth/invitation_entry_page.dart';
import '../../../auth/register_webauthn_page.dart';
import '../../../auth/register_profile_page.dart';
import '../../../auth/magic_link_web.dart';
import '../../../auth/backup_recover_web.dart';
import '../../../app/backupcode_web.dart';
import '../../../screens/mobile_webauthn_login_screen.dart';
import '../../../screens/mobile_backupcode_login_screen.dart';
import '../../../screens/mobile_server_selection_screen.dart';
import '../../../screens/server_selection_screen.dart';
import '../../../screens/signal_setup_screen.dart';
import '../../../services/custom_tab_auth_service.dart';
import '../../../services/server_config_web.dart';

/// Returns common authentication-related routes for the application.
/// These routes handle registration, OTP verification, and mobile auth flows (callback, webauthn, backup code).
/// Used by both web and native platforms.
List<GoRoute> getAuthRoutes({required String clientId}) {
  return [
    // Mobile server selection route (Android/iOS only)
    GoRoute(
      path: '/mobile-server-selection',
      pageBuilder: (context, state) {
        return const MaterialPage(child: MobileServerSelectionScreen());
      },
    ),

    // Chrome Custom Tab callback route (handles deep link after auth)
    // Note: Manually triggers CustomTabAuthService completion since GoRouter
    // intercepts the deep link before app_links can deliver it to the service.
    GoRoute(
      path: '/callback',
      builder: (context, state) {
        final token = state.uri.queryParameters['token'];
        final cancelled = state.uri.queryParameters['cancelled'] == 'true';

        debugPrint(
          '[ROUTER] /callback route - token: ${token != null}, cancelled: $cancelled',
        );

        // Complete token exchange and navigate after a delay
        if (token != null && token.isNotEmpty) {
          // Check if authenticate() is waiting for the token BEFORE completing it
          // This check must happen before completeWithToken() which clears the completer
          final isAuthenticateWaiting =
              CustomTabAuthService.instance.hasAuthCompleter;

          // Complete the auth completer (unblocks authenticate() call in background)
          CustomTabAuthService.instance.completeWithToken(token);

          if (isAuthenticateWaiting) {
            // authenticate() is waiting - it will call finishLogin() and navigate
            debugPrint(
              '[ROUTER] ✓ Token sent to authenticate() - it will handle finishLogin',
            );

            // Show loading spinner while authenticate() completes
            // The screen will navigate away once authenticate() finishes
            // No need to do anything else here
          } else {
            // No authenticate() waiting - handle token exchange ourselves
            debugPrint(
              '[ROUTER] No authenticate() waiting - handling token exchange',
            );

            () async {
              // Get server URL from active server config
              final activeServer = ServerConfigService.getActiveServer();
              if (activeServer == null) {
                debugPrint('[ROUTER] ✗ No active server configured');
                if (context.mounted) {
                  context.go('/mobile-webauthn');
                }
                return;
              }

              try {
                // Call finishLogin which will handle the token exchange
                // It creates its own completer internally
                await CustomTabAuthService.instance.finishLogin(
                  token: token,
                  serverUrl: activeServer.serverUrl,
                );

                // If we reach here, login was successful
                debugPrint(
                  '[ROUTER] ✓ Token exchange successful, navigating to /app/activities',
                );
                if (context.mounted) {
                  context.go('/app/activities');
                }
              } catch (e) {
                debugPrint('[ROUTER] ✗ Token exchange failed: $e');
                if (context.mounted) {
                  context.go('/mobile-webauthn');
                }
              }
            }();
          }
        } else {
          // Cancelled or no token - go back to login immediately
          CustomTabAuthService.instance.completeWithToken(null);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              context.go('/mobile-webauthn');
            }
          });
        }

        // Show spinner with polling and abort button
        return _AuthCallbackLoadingScreen(
          hasToken: token != null && token.isNotEmpty,
        );
      },
    ),

    // Mobile WebAuthn login route (Android/iOS only)
    GoRoute(
      path: '/mobile-webauthn',
      pageBuilder: (context, state) {
        final serverUrl = state.extra as String?;
        return MaterialPage(
          child: MobileWebAuthnLoginScreen(serverUrl: serverUrl),
        );
      },
    ),

    // Mobile Backup Code login route (Android/iOS only)
    GoRoute(
      path: '/mobile-backupcode-login',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final serverUrl = extra?['serverUrl'] as String?;
        return MaterialPage(
          child: MobileBackupcodeLoginScreen(serverUrl: serverUrl),
        );
      },
    ),

    // OTP verification (used by both web and mobile registration)
    GoRoute(
      path: '/otp',
      builder: (context, state) {
        final extra = state.extra;
        String email = '';
        String serverUrl = '';
        int wait = 0;
        if (extra is Map<String, dynamic>) {
          email = extra['email'] ?? '';
          serverUrl = extra['serverUrl'] ?? '';
          wait = extra['wait'] ?? 0;
        }
        if (email.isEmpty || serverUrl.isEmpty) {
          return const Scaffold(
            body: Center(child: Text('Missing email or serverUrl')),
          );
        }
        return OtpWebPage(
          email: email,
          serverUrl: serverUrl,
          clientId: clientId,
          wait: wait,
        );
      },
    ),

    // Registration routes (shared by web and mobile)
    GoRoute(
      path: '/register/invitation',
      builder: (context, state) {
        final extra = state.extra as Map?;
        final email = extra?['email'] as String? ?? '';
        final serverUrl = extra?['serverUrl'] as String?;
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
        return InvitationEntryPage(email: email, serverUrl: serverUrl);
      },
    ),

    GoRoute(
      path: '/register/backupcode',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final serverUrl = extra?['serverUrl'] as String?;
        final email = extra?['email'] as String?;
        return BackupCodeListPage(serverUrl: serverUrl, email: email);
      },
    ),

    GoRoute(
      path: '/register/webauthn',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final serverUrl = extra?['serverUrl'] as String?;
        final email = extra?['email'] as String?;
        return RegisterWebauthnPage(serverUrl: serverUrl, email: email);
      },
    ),

    GoRoute(
      path: '/register/profile',
      builder: (context, state) => const RegisterProfilePage(),
    ),
  ];
}

/// Returns web-specific auth routes (magic link, backup recovery, login)
List<GoRoute> getAuthRoutesWeb({required String clientId}) {
  final routes = <GoRoute>[
    GoRoute(
      path: '/magic-link',
      builder: (context, state) {
        final extra = state.extra;
        debugPrint(
          'Navigated to /magic-link with extra: $extra, kIsWeb: $kIsWeb, clientId: $clientId, extra is String: ${extra is String}',
        );
        return const MagicLinkWebPage();
      },
    ),

    GoRoute(
      path: '/backupcode/recover',
      pageBuilder: (context, state) {
        return const MaterialPage(child: BackupCodeRecoveryPage());
      },
    ),

    GoRoute(
      path: '/login',
      pageBuilder: (context, state) {
        final qp = state.uri.queryParameters;
        final fromApp = (qp['from'] ?? '').trim().toLowerCase() == 'app';
        final email = qp['email']?.trim();
        return MaterialPage(
          child: AuthLayout(
            clientId: clientId,
            fromApp: fromApp,
            initialEmail: email,
          ),
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
      path: '/signal-setup',
      builder: (context, state) => const SignalSetupScreen(),
    ),
  ];

  return routes;
}

/// Returns native-specific auth routes (magic link with server, server selection inside shell)
/// These routes are used inside ShellRoute for native platforms.
List<GoRoute> getAuthRoutesNative({required String clientId}) {
  return [];
}

/// Helper widget for showing loading state during auth callback with polling and abort
class _AuthCallbackLoadingScreen extends StatefulWidget {
  final bool hasToken;

  const _AuthCallbackLoadingScreen({required this.hasToken});

  @override
  State<_AuthCallbackLoadingScreen> createState() =>
      _AuthCallbackLoadingScreenState();
}

class _AuthCallbackLoadingScreenState
    extends State<_AuthCallbackLoadingScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              widget.hasToken
                  ? 'Completing authentication...'
                  : 'Redirecting...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
