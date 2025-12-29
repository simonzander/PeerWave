import 'package:flutter/material.dart';
import '../models/storage_info.dart';

/// Card widget displaying storage database information.
class StorageInfoCard extends StatelessWidget {
  final StorageInfo storageInfo;

  const StorageInfoCard({super.key, required this.storageInfo});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Storage Information',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _buildInfoRow(
              context,
              'Session Store',
              storageInfo.sessionStore,
              Icons.speaker_phone,
            ),
            _buildInfoRow(
              context,
              'Identity Store',
              storageInfo.identityStore,
              Icons.person_outline,
            ),
            _buildInfoRow(
              context,
              'PreKey Store',
              storageInfo.preKeyStore,
              Icons.key,
            ),
            _buildInfoRow(
              context,
              'SignedPreKey Store',
              storageInfo.signedPreKeyStore,
              Icons.verified_user,
            ),
            _buildInfoRow(
              context,
              'Message Store',
              storageInfo.messageStore,
              Icons.message,
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
