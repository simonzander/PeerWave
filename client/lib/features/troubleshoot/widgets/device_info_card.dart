import 'package:flutter/material.dart';
import '../models/device_info.dart';

/// Card widget displaying device and identity information.
class DeviceInfoCard extends StatelessWidget {
  final DeviceInfo deviceInfo;

  const DeviceInfoCard({super.key, required this.deviceInfo});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device & Identity',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _buildInfoRow(context, 'User ID', deviceInfo.userId, Icons.person),
            _buildInfoRow(
              context,
              'Device ID',
              deviceInfo.deviceId,
              Icons.phone_android,
            ),
            _buildInfoRow(
              context,
              'Client ID',
              deviceInfo.clientId,
              Icons.fingerprint,
            ),
            _buildInfoRow(
              context,
              'Identity Key',
              deviceInfo.identityKeyFingerprint,
              Icons.vpn_key,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  value,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
