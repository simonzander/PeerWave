import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

// Conditionally import the full page only on supported platforms
import 'webauthn_web.dart' if (dart.library.io) 'webauthn_stub.dart';

class WebauthnPageWrapper extends StatelessWidget {
  const WebauthnPageWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    // On desktop native (Windows/macOS/Linux), show stub
    // On web and mobile (Android/iOS), show full page
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      // Desktop native - show stub
      return Padding(
        padding: const EdgeInsets.all(32.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.computer,
                size: 64,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 24),
              Text(
                'Credentials Management',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'To add a new desktop client, use the "Generate Magic Key" button on the web version or mobile app.',
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'You can view and manage your connected devices from this page.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Web or mobile - show full page
    return const WebauthnPage();
  }
}
