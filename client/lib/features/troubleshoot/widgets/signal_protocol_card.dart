import 'package:flutter/material.dart';

/// Card widget displaying Signal Protocol session and key counts.
class SignalProtocolCard extends StatelessWidget {
  final Map<String, int> signalProtocolCounts;

  const SignalProtocolCard({super.key, required this.signalProtocolCounts});

  @override
  Widget build(BuildContext context) {
    final activeSessions = signalProtocolCounts['activeSessions'] ?? 0;
    final preKeysCount = signalProtocolCounts['preKeysCount'] ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Signal Protocol Status',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _buildMetricRow(
              context,
              'Active Sessions',
              activeSessions,
              Icons.speaker_phone,
            ),
            _buildMetricRow(
              context,
              'Available PreKeys',
              preKeysCount,
              Icons.key,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(
    BuildContext context,
    String label,
    int value,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(
            value.toString(),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
