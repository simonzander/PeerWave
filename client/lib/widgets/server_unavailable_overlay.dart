import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/server_connection_service.dart';

/// Overlay widget that shows when server is not reachable (native only)
class ServerUnavailableOverlay extends StatelessWidget {
  const ServerUnavailableOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    // Only show on native platforms
    if (kIsWeb) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<bool>(
      stream: ServerConnectionService.instance.isConnectedStream,
      initialData: ServerConnectionService.instance.isConnected,
      builder: (context, snapshot) {
        final isConnected = snapshot.data ?? true;

        // Don't show overlay if connected
        if (isConnected) {
          return const SizedBox.shrink();
        }

        // Show full-screen overlay
        return Container(
          color: Theme.of(context).colorScheme.surface,
          child: Center(
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon
                    Icon(
                      Icons.cloud_off,
                      size: 64,
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    
                    // Retry Button
                    FilledButton.icon(
                      onPressed: () {
                        ServerConnectionService.instance.checkConnection();
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
      },
    );
  }
}
