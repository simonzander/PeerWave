import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/troubleshoot_provider.dart';
import '../widgets/device_info_card.dart';
import '../widgets/server_config_card.dart';
import '../widgets/storage_info_card.dart';
import '../widgets/signal_protocol_card.dart';
import '../widgets/metrics_card.dart';
import '../widgets/network_metrics_card.dart';
import '../widgets/troubleshoot_action_button.dart';

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
        child: Consumer<TroubleshootProvider>(
          builder: (context, provider, _) {
            if (provider.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Device & Identity Information
                if (provider.deviceInfo != null) ...[
                  DeviceInfoCard(deviceInfo: provider.deviceInfo!),
                  const SizedBox(height: 16),
                ],

                // Server Configuration
                if (provider.serverConfig != null) ...[
                  ServerConfigCard(serverConfig: provider.serverConfig!),
                  const SizedBox(height: 16),
                ],

                // Storage Information
                if (provider.storageInfo != null) ...[
                  StorageInfoCard(storageInfo: provider.storageInfo!),
                  const SizedBox(height: 16),
                ],

                // Signal Protocol Status
                Text(
                  'Signal Protocol Diagnostics',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Monitor key management metrics and encryption operations',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),

                // Signal Protocol Counts (Sessions & PreKeys)
                if (provider.signalProtocolCounts != null) ...[
                  SignalProtocolCard(
                    signalProtocolCounts: provider.signalProtocolCounts!,
                  ),
                  const SizedBox(height: 16),
                ],

                // Key Management Metrics
                const MetricsCard(),
                const SizedBox(height: 32),

                // Network Diagnostics
                if (provider.networkMetrics != null) ...[
                  NetworkMetricsCard(networkMetrics: provider.networkMetrics!),
                  const SizedBox(height: 32),
                ],

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
            );
          },
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
        // New Maintenance Operations
        TroubleshootActionButton(
          title: 'Reset Network Metrics',
          description: 'Clear API and socket counters to start fresh tracking.',
          icon: Icons.query_stats,
          severity: ActionSeverity.low,
          onPressed: () =>
              context.read<TroubleshootProvider>().resetNetworkMetrics(),
        ),
        TroubleshootActionButton(
          title: 'Force Socket Reconnect',
          description: 'Disconnect and reconnect the WebSocket connection.',
          icon: Icons.refresh,
          severity: ActionSeverity.low,
          onPressed: () =>
              context.read<TroubleshootProvider>().forceSocketReconnect(),
        ),
        TroubleshootActionButton(
          title: 'Test Server Connection',
          description: 'Send ping to verify server is responding.',
          icon: Icons.network_check,
          severity: ActionSeverity.low,
          onPressed: () =>
              context.read<TroubleshootProvider>().testServerConnection(),
        ),
        TroubleshootActionButton(
          title: 'Clear Signal Sessions',
          description: 'Remove all sessions, forces re-key exchange.',
          icon: Icons.lock_reset,
          severity: ActionSeverity.high,
          onPressed: () => _showConfirmationDialog(
            context,
            title: 'Clear All Signal Sessions?',
            content:
                'This will remove all Signal Protocol sessions. Encryption will be re-established automatically on next message.',
            action: () =>
                context.read<TroubleshootProvider>().clearSignalSessions(),
          ),
        ),
        TroubleshootActionButton(
          title: 'Sync Keys with Server',
          description: 'Re-upload identity and PreKeys to server.',
          icon: Icons.sync,
          severity: ActionSeverity.low,
          onPressed: () =>
              context.read<TroubleshootProvider>().syncKeysWithServer(),
        ),
        TroubleshootActionButton(
          title: 'Clear Message Storage',
          description: 'Delete all locally stored messages permanently.',
          icon: Icons.delete_forever,
          severity: ActionSeverity.critical,
          onPressed: () => _showConfirmationDialog(
            context,
            title: 'Clear All Message Storage?',
            content:
                'This will permanently delete all locally stored messages from the database. This action cannot be undone. Messages are NOT backed up on the server.',
            action: () =>
                context.read<TroubleshootProvider>().clearMessageStorage(),
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
      builder: (context) => AlertDialog(
        title: const Text('Select Channel'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: channels.length,
            itemBuilder: (context, index) {
              final channel = channels[index];
              return ListTile(
                title: Text(channel['name'] ?? ''),
                subtitle: Text(channel['id'] ?? ''),
                onTap: () => Navigator.of(context).pop(channel),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
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
