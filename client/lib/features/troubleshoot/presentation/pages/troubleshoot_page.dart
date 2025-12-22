import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/troubleshoot_provider.dart';
import '../widgets/metrics_card.dart';
import '../widgets/troubleshoot_action_button.dart';
import '../widgets/channel_selection_dialog.dart';

/// Troubleshooting page for Signal Protocol diagnostics and maintenance.
class TroubleshootPage extends StatefulWidget {
  const TroubleshootPage({super.key});

  @override
  State<TroubleshootPage> createState() => _TroubleshootPageState();
}

class _TroubleshootPageState extends State<TroubleshootPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TroubleshootProvider>().loadMetrics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Signal Protocol Diagnostics',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Monitor key management metrics and perform maintenance operations',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),

            // Metrics Card
            const MetricsCard(),
            const SizedBox(height: 32),

            // Actions Section
            Text(
              'Maintenance Operations',
              style: theme.textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            _buildActionsGrid(context),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsGrid(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        TroubleshootActionButton(
          title: 'Delete Identity Key',
          description:
              'Regenerate identity key pair. Requires new session establishment.',
          icon: Icons.key_off,
          severity: ActionSeverity.critical,
          onPressed: () => _showConfirmationDialog(
            context,
            title: 'Delete Identity Key?',
            content:
                'This will regenerate your identity key pair. All existing sessions will be invalidated and contacts must re-establish sessions.',
            action: () =>
                context.read<TroubleshootProvider>().deleteIdentityKey(),
          ),
        ),
        TroubleshootActionButton(
          title: 'Delete Signed PreKey',
          description: 'Remove signed pre-key locally and on server.',
          icon: Icons.vpn_key_off,
          severity: ActionSeverity.high,
          onPressed: () => _showConfirmationDialog(
            context,
            title: 'Delete Signed PreKey?',
            content:
                'This will remove your signed pre-key. New keys will be generated automatically.',
            action: () =>
                context.read<TroubleshootProvider>().deleteSignedPreKey(),
          ),
        ),
        TroubleshootActionButton(
          title: 'Delete PreKeys',
          description: 'Remove all pre-keys locally and on server.',
          icon: Icons.delete_sweep,
          severity: ActionSeverity.high,
          onPressed: () => _showConfirmationDialog(
            context,
            title: 'Delete All PreKeys?',
            content:
                'This will remove all pre-keys from local storage and server. New keys will be generated automatically.',
            action: () => context.read<TroubleshootProvider>().deletePreKeys(),
          ),
        ),
        TroubleshootActionButton(
          title: 'Delete Group Key',
          description: 'Remove encryption key for a specific group channel.',
          icon: Icons.group_remove,
          severity: ActionSeverity.medium,
          onPressed: () => _showChannelSelectionDialog(context),
        ),
        TroubleshootActionButton(
          title: 'Force SignedPreKey Rotation',
          description: 'Manually trigger signed pre-key rotation cycle.',
          icon: Icons.refresh,
          severity: ActionSeverity.low,
          onPressed: () =>
              context.read<TroubleshootProvider>().forceSignedPreKeyRotation(),
        ),
        TroubleshootActionButton(
          title: 'Force PreKey Regeneration',
          description: 'Delete all pre-keys and generate fresh set.',
          icon: Icons.autorenew,
          severity: ActionSeverity.high,
          onPressed: () => _showConfirmationDialog(
            context,
            title: 'Regenerate All PreKeys?',
            content:
                'This will delete all existing pre-keys and generate a fresh set. This may temporarily affect incoming messages.',
            action: () =>
                context.read<TroubleshootProvider>().forcePreKeyRegeneration(),
          ),
        ),
      ],
    );
  }

  Future<void> _showConfirmationDialog(
    BuildContext context, {
    required String title,
    required String content,
    required Future<void> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await action();
      if (context.mounted) {
        _showResultSnackbar(context);
      }
    }
  }

  Future<void> _showChannelSelectionDialog(BuildContext context) async {
    final provider = context.read<TroubleshootProvider>();
    final channels = await provider.getActiveChannels();

    if (!context.mounted) return;

    if (channels.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No active channels found')));
      return;
    }

    final selectedChannel = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => ChannelSelectionDialog(channels: channels),
    );

    if (selectedChannel != null && context.mounted) {
      await _showConfirmationDialog(
        context,
        title: 'Delete Group Key?',
        content:
            'This will delete the encryption key for "${selectedChannel['name']}". The channel will require a new encryption key.',
        action: () => provider.deleteGroupKey(selectedChannel['id']!),
      );
    }
  }

  void _showResultSnackbar(BuildContext context) {
    final provider = context.read<TroubleshootProvider>();

    if (provider.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.error!),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } else if (provider.successMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.successMessage!),
          backgroundColor: Colors.green,
        ),
      );
    }

    provider.clearMessages();
  }
}
