import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/troubleshoot_provider.dart';

/// Displays Signal Protocol key management metrics in a card.
class MetricsCard extends StatelessWidget {
  const MetricsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Consumer<TroubleshootProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading && provider.metrics == null) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: colorScheme.primary),
              ),
            ),
          );
        }

        if (provider.error != null) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.error_outline, size: 48, color: colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    provider.error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: provider.loadMetrics,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        final metrics = provider.metrics;
        if (metrics == null) {
          return const SizedBox.shrink();
        }

        return Card(
          elevation: 0,
          color: colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Key Management Metrics',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh metrics',
                      onPressed: provider.loadMetrics,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildMetricsGrid(context, metrics),
                if (metrics.hasIssues) ...[
                  const SizedBox(height: 16),
                  _buildWarningBanner(context),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMetricsGrid(BuildContext context, dynamic metrics) {
    return Wrap(
      spacing: 24,
      runSpacing: 16,
      children: [
        _MetricItem(
          label: 'Identity Regenerations',
          value: metrics.identityRegenerations.toString(),
          icon: Icons.fingerprint,
          warning: metrics.identityRegenerations > 1,
        ),
        _MetricItem(
          label: 'SignedPreKey Rotations',
          value: metrics.signedPreKeyRotations.toString(),
          icon: Icons.vpn_key,
        ),
        _MetricItem(
          label: 'PreKeys Regenerated',
          value: metrics.preKeysRegenerated.toString(),
          icon: Icons.key,
        ),
        _MetricItem(
          label: 'Own PreKeys Consumed',
          value: metrics.ownPreKeysConsumed.toString(),
          icon: Icons.check_circle,
        ),
        _MetricItem(
          label: 'Remote PreKeys Consumed',
          value: metrics.remotePreKeysConsumed.toString(),
          icon: Icons.send,
        ),
        _MetricItem(
          label: 'Sessions Invalidated',
          value: metrics.sessionsInvalidated.toString(),
          icon: Icons.link_off,
        ),
        _MetricItem(
          label: 'Decryption Failures',
          value: metrics.decryptionFailures.toString(),
          icon: Icons.lock_open,
          warning: metrics.decryptionFailures > 0,
        ),
        _MetricItem(
          label: 'Server Key Mismatches',
          value: metrics.serverKeyMismatches.toString(),
          icon: Icons.sync_problem,
          warning: metrics.serverKeyMismatches > 0,
        ),
      ],
    );
  }

  Widget _buildWarningBanner(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Issues detected. Consider performing maintenance operations.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool warning;

  const _MetricItem({
    required this.label,
    required this.value,
    required this.icon,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: warning ? colorScheme.error : colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: warning ? colorScheme.error : colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
