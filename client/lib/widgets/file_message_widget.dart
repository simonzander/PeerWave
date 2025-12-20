import 'package:flutter/material.dart';
import '../models/file_message.dart';

/// Widget to display file messages in group chats (LÖSUNG 18)
/// 
/// Shows:
/// - File icon based on MIME type
/// - File name and size
/// - Download button
/// - Optional message text
/// 
/// Note: Actual download logic should be handled by parent widget
/// via onDownload callback
class FileMessageWidget extends StatelessWidget {
  final FileMessage fileMessage;
  final bool isOwnMessage;
  final VoidCallback? onDownload;
  final void Function(FileMessage)? onDownloadWithMessage;
  final double? downloadProgress;
  final bool isDownloading;
  final int? chunkQuality; // NEW: Chunk availability percentage (0-100)

  const FileMessageWidget({
    super.key,
    required this.fileMessage,
    this.isOwnMessage = false,
    this.onDownload,
    this.onDownloadWithMessage,
    this.downloadProgress,
    this.isDownloading = false,
    this.chunkQuality,
  }) ;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Column(
        crossAxisAlignment: isOwnMessage 
            ? CrossAxisAlignment.end 
            : CrossAxisAlignment.start,
        children: [
          // File card
          Container(
            constraints: const BoxConstraints(maxWidth: 300),
            decoration: BoxDecoration(
              color: isOwnMessage 
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // File icon and info
                Row(
                  children: [
                    // Icon
                    Text(
                      fileMessage.fileIcon,
                      style: const TextStyle(fontSize: 32),
                    ),
                    const SizedBox(width: 12),
                    // File info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fileMessage.fileName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Text(
                                fileMessage.fileSizeFormatted,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              // NEW: Chunk Quality Badge
                              if (chunkQuality != null) ...[
                                const SizedBox(width: 8),
                                _buildChunkQualityBadge(context, chunkQuality!),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                
                // Optional message text
                if (fileMessage.message != null && 
                    fileMessage.message!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    fileMessage.message!,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                
                const SizedBox(height: 12),
                
                // Download button or progress (only for received messages)
                if (!isOwnMessage) ...[
                  if (isDownloading && downloadProgress != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LinearProgressIndicator(
                          value: downloadProgress,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Downloading... ${(downloadProgress! * 100).toStringAsFixed(0)}%',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: () {
                        if (onDownloadWithMessage != null) {
                          onDownloadWithMessage!(fileMessage);
                        } else if (onDownload != null) {
                          onDownload!();
                        }
                      },
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                      ),
                    ),
                ],
              ],
            ),
          ),
          
          // Timestamp
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12, right: 12),
            child: Text(
              _formatTimestamp(fileMessage.timestamp),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    
    if (date.year == now.year && 
        date.month == now.month && 
        date.day == now.day) {
      // Today: show time only
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else {
      // Other day: show date and time
      return '${date.day}.${date.month}.${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
  }

  /// Build chunk quality badge with color-coded availability indicator
  Widget _buildChunkQualityBadge(BuildContext context, int quality) {
    final theme = Theme.of(context);
    
    // Determine color based on quality
    Color badgeColor;
    IconData icon;
    
    if (quality >= 100) {
      // Complete: Green
      badgeColor = Colors.green;
      icon = Icons.check_circle;
    } else if (quality >= 75) {
      // Good: Light green
      badgeColor = Colors.lightGreen;
      icon = Icons.cloud_done;
    } else if (quality >= 50) {
      // Medium: Orange
      badgeColor = Colors.orange;
      icon = Icons.cloud_queue;
    } else if (quality >= 25) {
      // Low: Deep orange
      badgeColor = Colors.deepOrange;
      icon = Icons.cloud_off;
    } else {
      // Very low: Red
      badgeColor = Colors.red;
      icon = Icons.error_outline;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: badgeColor.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: badgeColor,
          ),
          const SizedBox(width: 4),
          Text(
            '$quality%',
            style: theme.textTheme.bodySmall?.copyWith(
              color: badgeColor,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

