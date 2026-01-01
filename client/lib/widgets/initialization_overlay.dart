import 'package:flutter/material.dart';
import 'dart:async';
import '../services/post_login_init_service.dart';
import '../services/storage/database_helper.dart';

/// Overlay that displays during post-login initialization
///
/// Shows a loading spinner and prevents interaction while services
/// are being initialized. Particularly important for autostart scenarios
/// where the window may appear before initialization completes.
class InitializationOverlay extends StatefulWidget {
  final Widget child;

  const InitializationOverlay({super.key, required this.child});

  @override
  State<InitializationOverlay> createState() => _InitializationOverlayState();
}

class _InitializationOverlayState extends State<InitializationOverlay> {
  Timer? _statusCheckTimer;
  bool _isInitializing = false;
  String _statusMessage = 'Initializing...';
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    _checkInitializationStatus();

    // Poll initialization status every 500ms
    _statusCheckTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkInitializationStatus(),
    );
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    super.dispose();
  }

  void _checkInitializationStatus() {
    if (!mounted) return;

    final initService = PostLoginInitService.instance;

    // Check if initialization is in progress
    final isInitializing =
        initService.isInitializing && !initService.isInitialized;
    final dbInitializing =
        DatabaseHelper.isInitializing && !DatabaseHelper.isReady;

    if (isInitializing || dbInitializing) {
      String message = 'Initializing services...';

      if (dbInitializing) {
        // Database is initializing - check retry count
        final dbError = DatabaseHelper.lastError;
        if (dbError != null && dbError.isNotEmpty) {
          _retryCount++;
          message = 'Initializing database (retry $_retryCount)...';
        } else {
          message = 'Initializing database...';
          _retryCount = 0;
        }
      } else if (isInitializing) {
        final initError = initService.lastError;
        if (initError != null && initError.isNotEmpty) {
          message = 'Initializing services... ($initError)';
        } else {
          message = 'Starting services...';
        }
      }

      setState(() {
        _isInitializing = true;
        _statusMessage = message;
      });
    } else {
      // Initialization complete
      if (_isInitializing) {
        debugPrint('[INIT_OVERLAY] ✅ Initialization complete');
      }
      setState(() {
        _isInitializing = false;
        _retryCount = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_isInitializing)
          Container(
            color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.7),
            child: Center(
              child: Card(
                elevation: 8,
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 24),
                      Text(
                        _statusMessage,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      if (_retryCount > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          'This may take a moment...',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
