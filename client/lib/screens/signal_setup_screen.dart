import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../widgets/license_footer.dart';
import '../services/signal_service.dart';
import '../services/signal_setup_service.dart';
import '../services/logout_service.dart';
import '../services/device_identity_service.dart';
import '../services/device_scoped_storage_service.dart';
import '../services/preferences_service.dart';
import '../services/server_connection_service.dart';
import 'dart:async';

/// Screen displayed during Signal Protocol key generation
/// Shows PeerWave logo, progress bar, and status text
class SignalSetupScreen extends StatefulWidget {
  const SignalSetupScreen({super.key});

  @override
  State<SignalSetupScreen> createState() => _SignalSetupScreenState();
}

class _SignalSetupScreenState extends State<SignalSetupScreen> {
  String _statusText = 'Initializing Signal Protocol...';
  double _progress = 0.0;
  bool _isComplete = false;
  bool _showServerError = false;
  StreamSubscription<bool>? _connectionSubscription;

  @override
  void initState() {
    super.initState();

    // Monitor connection status (native only)
    if (!kIsWeb) {
      _connectionSubscription = ServerConnectionService
          .instance
          .isConnectedStream
          .listen((isConnected) {
            if (mounted) {
              setState(() {
                _showServerError = !isConnected;
              });
            }
          });
    }

    _startSignalSetup();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startSignalSetup() async {
    try {
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

        // Mark setup as completed to prevent immediate re-check
        SignalSetupService.instance.markSetupCompleted();

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
            GoRouter.of(context).go('/server-selection');
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
            content: Text(
              'Failed to initialize Signal Protocol:\n\n$e\n\nYou can delete local encrypted data and start fresh, or logout and try again.',
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();

                  // Show confirmation dialog for data deletion
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete Local Data?'),
                      content: const Text(
                        'This will delete all locally encrypted Signal Protocol data for this device.\n\n'
                        'You will need to log in again and re-initialize encryption.\n\n'
                        'Are you sure?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          child: const Text('Delete & Logout'),
                        ),
                      ],
                    ),
                  );

                  if (confirmed == true && mounted) {
                    try {
                      // Get device ID to delete account-specific data
                      final deviceId = DeviceIdentityService.instance.deviceId;
                      debugPrint(
                        '[SIGNAL SETUP] Deleting local data for device: $deviceId',
                      );

                      // Delete all device-specific databases
                      await DeviceScopedStorageService.instance
                          .deleteAllDeviceDatabases();
                      debugPrint(
                        '[SIGNAL SETUP] ✓ Deleted all device-specific databases',
                      );

                      // Logout and redirect
                      if (mounted) {
                        await LogoutService.instance.logout(
                          context,
                          userInitiated: true,
                        );
                      }
                    } catch (e) {
                      debugPrint(
                        '[SIGNAL SETUP] Error deleting local data: $e',
                      );
                      // Still logout even if deletion fails
                      if (mounted) {
                        await LogoutService.instance.logout(
                          context,
                          userInitiated: true,
                        );
                      }
                    }
                  }
                },
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Delete Local Data'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  // Logout and redirect to login
                  if (mounted) {
                    await LogoutService.instance.logout(
                      context,
                      userInitiated: true,
                    );
                  }
                },
                child: const Text('Logout'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Show server unavailable screen if connection is lost
    if (_showServerError && !kIsWeb) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Icon(Icons.cloud_off, size: 64, color: colorScheme.error),
                  const SizedBox(height: 24),

                  // Title
                  Text(
                    'Server Unavailable',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Message
                  Text(
                    'Server is temporarily not available',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Retry Button
                  FilledButton.icon(
                    onPressed: () {
                      // Reset connection status and retry setup
                      ServerConnectionService.instance.checkConnection();
                      setState(() {
                        _showServerError = false;
                        _statusText = 'Retrying...';
                      });
                      _startSignalSetup();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Normal signal setup screen
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(40),
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // PeerWave Logo
              Image.asset(
                Theme.of(context).brightness == Brightness.light
                    ? 'assets/images/peerwave_dark.png'
                    : 'assets/images/peerwave.png',
                width: 200,
                height: 200,
                errorBuilder: (context, error, stackTrace) {
                  // Fallback if image not found
                  return Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Icon(
                      Icons.security,
                      size: 100,
                      color: colorScheme.primary,
                    ),
                  );
                },
              ),
              const SizedBox(height: 60),

              // Progress Bar
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 12,
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Status Text
              Text(
                _statusText,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              // Progress Details
              if (!_isComplete)
                Text(
                  '${(_progress * 100).toInt()}% complete',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),

              // Completion indicator
              if (_isComplete)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Ready!',
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),

              // License Footer
              const SizedBox(height: 40),
              const LicenseFooter(),
            ],
          ),
        ),
      ),
    );
  }
}
