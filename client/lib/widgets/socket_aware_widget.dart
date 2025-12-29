import 'package:flutter/material.dart';
import '../services/socket_service.dart'
    if (dart.library.io) '../services/socket_service_native.dart';

/// Wrapper widget that ensures Socket.IO connection before showing child
class SocketAwareWidget extends StatefulWidget {
  final Widget child;
  final String featureName;

  const SocketAwareWidget({
    super.key,
    required this.child,
    this.featureName = 'This feature',
  });

  @override
  State<SocketAwareWidget> createState() => _SocketAwareWidgetState();
}

class _SocketAwareWidgetState extends State<SocketAwareWidget> {
  bool _isConnected = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  void _checkConnection() {
    try {
      final socketService = SocketService();
      final connected =
          socketService.socket != null && socketService.isConnected;
      debugPrint(
        '[SOCKET_AWARE] Checking connection: socket=${socketService.socket != null}, connected=${socketService.isConnected}',
      );

      if (mounted) {
        setState(() {
          _isConnected = connected;
          _isChecking = false;
        });
      }
    } catch (e) {
      debugPrint('[SOCKET_AWARE] Error checking connection: $e');
      if (mounted) {
        setState(() {
          _isConnected = false;
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isConnected) {
      return Scaffold(
        appBar: AppBar(title: const Text('Connection Required')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off,
                size: 80,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 24),
              const Text(
                'Not Connected',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.featureName} requires an active connection',
                style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () async {
                  // Try to reconnect
                  final socketService = SocketService();
                  await socketService.connect();
                  // Check again
                  _checkConnection();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry Connection'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return widget.child;
  }
}
