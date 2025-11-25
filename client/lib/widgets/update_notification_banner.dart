import 'dart:io';
import 'package:flutter/material.dart';
import 'package:peerwave_client/core/update/update_checker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Banner that appears at the top of the app when an update is available
class UpdateNotificationBanner extends StatelessWidget {
  final UpdateChecker updateChecker;
  
  const UpdateNotificationBanner({
    Key? key,
    required this.updateChecker,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updateChecker,
      builder: (context, _) {
        if (!updateChecker.hasUpdate) {
          return const SizedBox.shrink();
        }
        
        final update = updateChecker.latestUpdate!;
        final theme = Theme.of(context);
        
        return Material(
          color: theme.colorScheme.primaryContainer,
          elevation: 2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.system_update,
                  color: theme.colorScheme.onPrimaryContainer,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Neue Version verfügbar: ${update.displayVersion}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Veröffentlicht am ${_formatDate(update.releaseDate)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onPrimaryContainer.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                TextButton.icon(
                  onPressed: () => _showUpdateDialog(context, update),
                  icon: const Icon(Icons.download),
                  label: const Text('Details'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    backgroundColor: theme.colorScheme.surface,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 20,
                  color: theme.colorScheme.onPrimaryContainer,
                  onPressed: () => updateChecker.dismissUpdate(),
                  tooltip: 'Ausblenden',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  String _formatDate(DateTime date) {
    return '${date.day}.${date.month}.${date.year}';
  }
  
  void _showUpdateDialog(BuildContext context, UpdateInfo update) {
    showDialog(
      context: context,
      builder: (context) => UpdateDetailsDialog(update: update),
    );
  }
}

/// Dialog showing detailed update information and download options
class UpdateDetailsDialog extends StatelessWidget {
  final UpdateInfo update;
  
  const UpdateDetailsDialog({
    Key? key,
    required this.update,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = _detectPlatform();
    final downloadUrl = update.getDownloadUrlForPlatform(platform);
    
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Text('Update verfügbar'),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Version info
              _buildInfoRow(
                context,
                'Neue Version:',
                update.displayVersion,
                bold: true,
              ),
              _buildInfoRow(
                context,
                'Veröffentlicht:',
                '${update.releaseDate.day}.${update.releaseDate.month}.${update.releaseDate.year}',
              ),
              if (update.minServerVersion != null)
                _buildInfoRow(
                  context,
                  'Server Kompatibilität:',
                  '${update.minServerVersion} - ${update.maxServerVersion}',
                ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              
              // Changelog
              Text(
                'Was ist neu:',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  update.changelog,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 16),
              
              // Platform-specific download
              if (downloadUrl != null) ...[
                Text(
                  'Download für $platform:',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDownloadButton(context, platform, downloadUrl),
              ] else ...[
                Text(
                  'Kein Download für $platform verfügbar',
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Später'),
        ),
        FilledButton.icon(
          onPressed: () {
            _launchUrl(update.releaseUrl);
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.open_in_new),
          label: const Text('GitHub Release'),
        ),
      ],
    );
  }
  
  Widget _buildInfoRow(BuildContext context, String label, String value, {bool bold = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildDownloadButton(BuildContext context, String platform, String url) {
    final theme = Theme.of(context);
    
    return InkWell(
      onTap: () => _launchUrl(url),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              _getPlatformIcon(platform),
              color: theme.colorScheme.primary,
              size: 32,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Download für $platform',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    url.split('/').last,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Icon(
              Icons.download,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
  
  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'windows':
        return Icons.window;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.download;
    }
  }
  
  String _detectPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
  
  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
