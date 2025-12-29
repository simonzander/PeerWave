import 'package:flutter/material.dart';

/// Card widget displaying network diagnostics.
class NetworkMetricsCard extends StatelessWidget {
  final Map<String, dynamic> networkMetrics;

  const NetworkMetricsCard({super.key, required this.networkMetrics});

  @override
  Widget build(BuildContext context) {
    final totalApiCalls = networkMetrics['totalApiCalls'] as int? ?? 0;
    final successfulApiCalls =
        networkMetrics['successfulApiCalls'] as int? ?? 0;
    final failedApiCalls = networkMetrics['failedApiCalls'] as int? ?? 0;
    final socketEmitCount = networkMetrics['socketEmitCount'] as int? ?? 0;
    final socketReceiveCount =
        networkMetrics['socketReceiveCount'] as int? ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Network Diagnostics',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _buildMetricRow(
              context,
              'Total API Calls',
              totalApiCalls,
              Icons.api,
            ),
            _buildMetricRow(
              context,
              'Successful API Calls',
              successfulApiCalls,
              Icons.check_circle,
              color: const Color(0xFF4CAF50), // Green
            ),
            _buildMetricRow(
              context,
              'Failed API Calls',
              failedApiCalls,
              Icons.error,
              color: const Color(0xFFF44336), // Red
            ),
            const Divider(height: 32),
            _buildMetricRow(
              context,
              'Socket Messages Sent',
              socketEmitCount,
              Icons.arrow_upward,
              color: const Color(0xFF2196F3), // Blue
            ),
            _buildMetricRow(
              context,
              'Socket Messages Received',
              socketReceiveCount,
              Icons.arrow_downward,
              color: const Color(0xFFFF9800), // Orange
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
    IconData icon, {
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: color ?? Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(
            value.toString(),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
