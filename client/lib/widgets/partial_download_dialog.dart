import 'package:flutter/material.dart';

/// Dialog to warn user about partial download availability
/// 
/// Shows:
/// - Chunk quality percentage
/// - Warning about incomplete file
/// - Options: Download Anyway / Wait for More / Cancel
class PartialDownloadDialog extends StatelessWidget {
  final String fileName;
  final int chunkQuality; // 0-100
  final VoidCallback onDownloadAnyway;
  final VoidCallback? onWaitForMore;

  const PartialDownloadDialog({
    Key? key,
    required this.fileName,
    required this.chunkQuality,
    required this.onDownloadAnyway,
    this.onWaitForMore,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // Determine warning severity
    Color warningColor;
    IconData warningIcon;
    String warningText;
    
    if (chunkQuality >= 75) {
      warningColor = Colors.orange;
      warningIcon = Icons.warning_amber;
      warningText = 'Most of the file is available';
    } else if (chunkQuality >= 50) {
      warningColor = Colors.deepOrange;
      warningIcon = Icons.warning;
      warningText = 'About half of the file is available';
    } else {
      warningColor = Colors.red;
      warningIcon = Icons.error_outline;
      warningText = 'Only a small part of the file is available';
    }
    
    return AlertDialog(
      title: const Text('Incomplete File'),
      icon: Icon(
        warningIcon,
        color: warningColor,
        size: 48,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File name
          Text(
            fileName,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          
          const SizedBox(height: 16),
          
          // Chunk quality indicator
          Row(
            children: [
              Text(
                'Available:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinearProgressIndicator(
                  value: chunkQuality / 100,
                  backgroundColor: theme.colorScheme.surfaceVariant,
                  valueColor: AlwaysStoppedAnimation<Color>(warningColor),
                  minHeight: 8,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$chunkQuality%',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: warningColor,
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 16),
          
          // Warning text
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: warningColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: warningColor.withOpacity(0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  warningText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: warningColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'You can start downloading now and the file will complete automatically when more chunks become available from other users.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        // Cancel button
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        
        // Wait button (optional)
        if (onWaitForMore != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onWaitForMore!();
            },
            child: const Text('Wait for More'),
          ),
        
        // Download anyway button
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            onDownloadAnyway();
          },
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Download Anyway'),
          style: FilledButton.styleFrom(
            backgroundColor: warningColor,
          ),
        ),
      ],
    );
  }

  /// Show the dialog
  static Future<void> show({
    required BuildContext context,
    required String fileName,
    required int chunkQuality,
    required VoidCallback onDownloadAnyway,
    VoidCallback? onWaitForMore,
  }) {
    return showDialog(
      context: context,
      builder: (context) => PartialDownloadDialog(
        fileName: fileName,
        chunkQuality: chunkQuality,
        onDownloadAnyway: onDownloadAnyway,
        onWaitForMore: onWaitForMore,
      ),
    );
  }
}
