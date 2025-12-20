import 'package:flutter/material.dart';
import 'package:peerwave_client/core/version/version_info.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows application information including version, build info, and links
class AppAboutDialog extends StatelessWidget {
  const AppAboutDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AlertDialog(
      title: Row(
        children: [
          Image.asset(
            'assets/images/peerwave.png',
            width: 32,
            height: 32,
          ),
          const SizedBox(width: 12),
          Text('Über ${VersionInfo.projectName}'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description
            Text(
              VersionInfo.projectDescription,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            
            // Version Information
            _buildInfoSection(
              context,
              'Version',
              [
                _InfoRow('Client Version:', VersionInfo.detailedVersion),
                _InfoRow('Server Version:', 'v${VersionInfo.serverVersion}'),
                _InfoRow('Build Datum:', _formatBuildDate(VersionInfo.buildDate)),
              ],
            ),
            const SizedBox(height: 16),
            
            // Compatibility
            _buildInfoSection(
              context,
              'Kompatibilität',
              [
                _InfoRow(
                  'Server:',
                  '${VersionInfo.minServerVersion} - ${VersionInfo.maxServerVersion}',
                ),
                _InfoRow(
                  'Client:',
                  '${VersionInfo.minClientVersion} - ${VersionInfo.maxClientVersion}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Links
            _buildLinkButton(
              context,
              icon: Icons.code,
              label: 'GitHub Repository',
              onTap: () => _launchUrl(VersionInfo.repository),
            ),
            const SizedBox(height: 8),
            _buildLinkButton(
              context,
              icon: Icons.bug_report,
              label: 'Fehler melden',
              onTap: () => _launchUrl('${VersionInfo.repository}/issues'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Schließen'),
        ),
      ],
    );
  }
  
  Widget _buildInfoSection(
    BuildContext context,
    String title,
    List<_InfoRow> rows,
  ) {
    final theme = Theme.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        ...rows.map((row) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              SizedBox(
                width: 140,
                child: Text(
                  row.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  row.value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        )),
      ],
    );
  }
  
  Widget _buildLinkButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.open_in_new,
              size: 16,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
  
  String _formatBuildDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      return '${date.day}.${date.month}.${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDate;
    }
  }
  
  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class _InfoRow {
  final String label;
  final String value;
  
  const _InfoRow(this.label, this.value);
}

/// Helper function to show the about dialog
void showAppAboutDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const AppAboutDialog(),
  );
}
