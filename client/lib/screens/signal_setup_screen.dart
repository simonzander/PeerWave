import 'package:flutter/foundation.dart';
// ignore_for_file: use_build_context_synchronously

import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/preferences_service.dart';
import '../services/signal/views/setup.dart';
import '../services/server_settings_service.dart';

/// Screen wrapper for Signal Protocol setup view
/// Uses SignalSetupView that watches key states and initializes via SignalClient
class SignalSetupScreen extends StatelessWidget {
  const SignalSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalSetupView(
      // Initialize SignalClient for the active server
      onInitialize: () async {
        debugPrint('[SIGNAL_SETUP_SCREEN] Getting SignalClient...');
        // Get or create SignalClient for active server
        final client = await ServerSettingsService.instance
            .getOrCreateSignalClientWithStoredCredentials();

        debugPrint(
          '[SIGNAL_SETUP_SCREEN] SignalClient obtained, initializing...',
        );
        // Initialize SignalClient (creates KeyManager + SessionManager)
        await client.initialize();
        debugPrint(
          '[SIGNAL_SETUP_SCREEN] SignalClient initialized successfully',
        );

        // Return the SignalClient instance
        return client;
      },
      onComplete: () async {
        // Try to restore last route, otherwise go to /app/activities (default view)
        final lastRoute = await PreferencesService().loadLastRoute();
        if (!context.mounted) return;

        if (lastRoute != null &&
            lastRoute.startsWith('/app/') &&
            lastRoute != '/app') {
          debugPrint('[SIGNAL SETUP] Restoring last route: $lastRoute');
          await PreferencesService().clearLastRoute(); // Clear after using
          if (!context.mounted) return;
          GoRouter.of(context).go(lastRoute);
        } else {
          // No saved route or route was just /app - go to default view
          debugPrint(
            '[SIGNAL SETUP] No saved route, going to /app/activities (default)',
          );
          if (lastRoute != null) {
            await PreferencesService().clearLastRoute(); // Clear if it was /app
          }
          if (!context.mounted) return;
          GoRouter.of(context).go('/app/activities');
        }
      },
      onError: () {
        // Redirect to appropriate auth page on error
        if (!context.mounted) return;

        if (kIsWeb) {
          debugPrint(
            '[SIGNAL SETUP SCREEN] Authentication error, redirecting to login...',
          );
          GoRouter.of(context).go('/login');
        } else {
          debugPrint(
            '[SIGNAL SETUP SCREEN] Authentication error, redirecting to server-selection...',
          );
          if (Platform.isAndroid || Platform.isIOS) {
            GoRouter.of(context).go('/mobile-server-selection');
          } else {
            GoRouter.of(context).go('/server-selection');
          }
        }
      },
    );
  }
}

/// Legacy code below - kept for reference but not used
/// The old progress-based approach is replaced by state observation
/*
class _SignalSetupScreenOld extends StatefulWidget {
  const _SignalSetupScreenOld({super.key});

  @override
  State<_SignalSetupScreenOld> createState() => _SignalSetupScreenOldState();
}

class _SignalSetupScreenOldState extends State<_SignalSetupScreenOld> {
  String _statusText = 'Initializing Signal Protocol...';
  double _progress = 0.0;
  bool _isComplete = false;

  Future<void> _startSignalSetup() async {
    try {
      // OLD: Manual progress tracking via callback
      await SignalService.instance.initWithProgress((
        String statusText,
        int current,
        int total,
        double percentage,
      ) {
        if (mounted) {
          setState(() {
            _statusText = statusText;
            _progress = percentage / 100.0;
          });
        }
      });

      // Setup complete - navigate to app
      if (mounted) {
        setState(() {
          _isComplete = true;
          _statusText = 'Setup complete! Redirecting...';
          _progress = 1.0;
        });

        // OLD: Manual service calls
        // SignalSetupService.instance.markSetupCompleted();

        // Small delay before navigation
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted) {
          // Try to restore last route, otherwise go to /app/activities (default view)
          final lastRoute = await PreferencesService().loadLastRoute();
          if (!mounted) return;
          if (lastRoute != null &&
              lastRoute.startsWith('/app/') &&
              lastRoute != '/app') {
            debugPrint('[SIGNAL SETUP] Restoring last route: $lastRoute');
            await PreferencesService().clearLastRoute(); // Clear after using
            if (!mounted) return;
            GoRouter.of(context).go(lastRoute);
          } else {
            // No saved route or route was just /app - go to default view
            debugPrint(
              '[SIGNAL SETUP] No saved route, going to /app/activities (default)',
            );
            if (lastRoute != null) {
              await PreferencesService()
                  .clearLastRoute(); // Clear if it was /app
            }
            if (!mounted) return;
            GoRouter.of(context).go('/app/activities');
          }
        }
      }
    } catch (e) {
      debugPrint('[SIGNAL SETUP SCREEN] Error during setup: $e');

      // Check if it's an authentication error
      final errorMessage = e.toString();
      if (errorMessage.contains('Device identity not initialized') ||
          errorMessage.contains('Encryption key not found') ||
          errorMessage.contains('Please log in')) {
        // Redirect to appropriate auth page
        if (mounted) {
          if (kIsWeb) {
            debugPrint(
              '[SIGNAL SETUP SCREEN] Authentication required, redirecting to login...',
            );
            GoRouter.of(context).go('/login');
          } else {
            debugPrint(
              '[SIGNAL SETUP SCREEN] Authentication required, redirecting to server-selection...',
            );
            if (Platform.isAndroid || Platform.isIOS) {
              GoRouter.of(context).go('/mobile-server-selection');
            } else {
              GoRouter.of(context).go('/server-selection');
            }
          }
        }
        return;
      }

      // Other errors - show retry dialog
      if (mounted) {
        setState(() {
          _statusText = 'Setup failed. Please try again.';
        });

        // Show error dialog
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Setup Failed'),
            content: const Text(
              'Failed to initialize Signal Protocol. This may be due to encryption key mismatch.\n\nPlease try logging out and logging in again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }
}
*/
