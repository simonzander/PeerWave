import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/file_transfer/download_manager.dart';

/// Downloads Screen - Monitor active and completed downloads
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  @override
  Widget build(BuildContext context) {
    // Get download manager from Provider
    final downloadManager = Provider.of<DownloadManager>(context);
    final downloads = downloadManager.getAllDownloads();

    final activeDownloads = downloads
        .where(
          (d) =>
              d.status == DownloadStatus.downloading ||
              d.status == DownloadStatus.queued ||
              d.status == DownloadStatus.verifying,
        )
        .toList();

    final pausedDownloads = downloads
        .where((d) => d.status == DownloadStatus.paused)
        .toList();

    final completedDownloads = downloads
        .where((d) => d.status == DownloadStatus.completed)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (activeDownloads.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.pause_circle),
              onPressed: _pauseAllDownloads,
              tooltip: 'Pause all',
            ),
        ],
      ),
      body: downloads.isEmpty
          ? _buildEmptyState()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (activeDownloads.isNotEmpty) ...[
                  _buildSectionHeader('Active', activeDownloads.length),
                  ...activeDownloads.map((d) => _buildDownloadItem(d)),
                  const SizedBox(height: 16),
                ],

                if (pausedDownloads.isNotEmpty) ...[
                  _buildSectionHeader('Paused', pausedDownloads.length),
                  ...pausedDownloads.map((d) => _buildDownloadItem(d)),
                  const SizedBox(height: 16),
                ],

                if (completedDownloads.isNotEmpty) ...[
                  _buildSectionHeader('Completed', completedDownloads.length),
                  ...completedDownloads.map((d) => _buildDownloadItem(d)),
                ],
              ],
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_done,
            size: 64,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'No downloads',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Browse files to start downloading',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pushNamed(context, '/file-browser');
            },
            icon: const Icon(Icons.folder_open),
            label: const Text('Browse Files'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadItem(DownloadTask task) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File name and status
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.fileName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _buildStatusBadge(task),
              ],
            ),

            const SizedBox(height: 12),

            // Progress bar
            if (task.status == DownloadStatus.downloading ||
                task.status == DownloadStatus.verifying)
              Column(
                children: [
                  LinearProgressIndicator(
                    value: task.progress / 100,
                    minHeight: 8,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                  const SizedBox(height: 8),
                ],
              ),

            // Download stats
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${task.downloadedChunks} / ${task.chunkCount} chunks',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if (task.status == DownloadStatus.downloading)
                        Text(
                          _formatSpeed(task.speed),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                    ],
                  ),
                ),

                if (task.status == DownloadStatus.downloading)
                  Text(
                    _formatETA(task.estimatedTimeRemaining),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // Connected seeders
            if (task.status == DownloadStatus.downloading)
              _buildSeederChips(task),

            const SizedBox(height: 12),

            // Action buttons
            _buildActionButtons(task),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(DownloadTask task) {
    Color color;
    IconData icon;

    switch (task.status) {
      case DownloadStatus.queued:
        color = Colors.orange;
        icon = Icons.schedule;
        break;
      case DownloadStatus.downloading:
        color = Colors.blue;
        icon = Icons.download;
        break;
      case DownloadStatus.paused:
        color = Colors.grey;
        icon = Icons.pause;
        break;
      case DownloadStatus.verifying:
        color = Colors.purple;
        icon = Icons.verified;
        break;
      case DownloadStatus.completed:
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case DownloadStatus.failed:
        color = Colors.red;
        icon = Icons.error;
        break;
      case DownloadStatus.cancelled:
        color = Colors.grey;
        icon = Icons.cancel;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            task.statusText,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeederChips(DownloadTask task) {
    final connectedSeeders = task.seederChunks.keys.toList();

    if (connectedSeeders.isEmpty) {
      return Text(
        'No seeders connected',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      );
    }

    final chips = <Widget>[];

    // Add first 3 seeders
    for (final peerId in connectedSeeders.take(3)) {
      chips.add(
        Chip(
          avatar: Icon(
            Icons.person,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          label: Text(
            peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
        ),
      );
    }

    // Add "+X more" chip if there are more than 3 seeders
    if (connectedSeeders.length > 3) {
      chips.add(
        Chip(
          label: Text(
            '+${connectedSeeders.length - 3}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
        ),
      );
    }

    return Wrap(spacing: 8, children: chips);
  }

  Widget _buildActionButtons(DownloadTask task) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (task.status == DownloadStatus.downloading)
          TextButton.icon(
            onPressed: () => _pauseDownload(task.fileId),
            icon: const Icon(Icons.pause, size: 16),
            label: const Text('Pause'),
          ),

        if (task.status == DownloadStatus.paused)
          TextButton.icon(
            onPressed: () => _resumeDownload(task.fileId),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Resume'),
          ),

        if (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.queued)
          TextButton.icon(
            onPressed: () => _cancelDownload(task.fileId),
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Cancel'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),

        if (task.status == DownloadStatus.completed)
          TextButton.icon(
            onPressed: () => _openFile(task.fileId),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open'),
          ),

        if (task.status == DownloadStatus.failed)
          TextButton.icon(
            onPressed: () => _retryDownload(task.fileId),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
      ],
    );
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024)
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatETA(Duration? eta) {
    if (eta == null) return 'Calculating...';

    if (eta.inSeconds < 60) return '${eta.inSeconds}s';
    if (eta.inMinutes < 60) return '${eta.inMinutes}m ${eta.inSeconds % 60}s';
    return '${eta.inHours}h ${eta.inMinutes % 60}m';
  }

  // ============================================
  // DOWNLOAD ACTIONS
  // ============================================

  void _pauseDownload(String fileId) {
    // TODO: _downloadManager.pauseDownload(fileId);
  }

  void _resumeDownload(String fileId) {
    // TODO: _downloadManager.resumeDownload(fileId);
  }

  void _cancelDownload(String fileId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Download?'),
        content: const Text(
          'This will delete all downloaded data for this file.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: _downloadManager.cancelDownload(fileId);
            },
            child: const Text('Yes', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _pauseAllDownloads() {
    // TODO: Pause all active downloads
  }

  void _retryDownload(String fileId) {
    // TODO: Retry failed download
  }

  void _openFile(String fileId) {
    // TODO: Open completed file
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File open feature coming soon')),
    );
  }
}
