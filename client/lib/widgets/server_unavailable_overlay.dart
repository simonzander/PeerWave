import 'package:flutter/material.dart';

/// Overlay widget that monitors connection status
/// This is a placeholder - actual navigation happens in AppLayout
class ServerUnavailableOverlay extends StatelessWidget {
  const ServerUnavailableOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    // This widget doesn't render anything
    // Connection monitoring and navigation is handled in AppLayout
    return const SizedBox.shrink();
  }
}
