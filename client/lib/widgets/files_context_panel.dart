import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/file_transfer_stats_provider.dart';
import 'package:fl_chart/fl_chart.dart';

/// Context panel for Files view showing transfer statistics
class FilesContextPanel extends StatelessWidget {
  const FilesContextPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Consumer<FileTransferStatsProvider>(
      builder: (context, stats, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 1),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title
                    Text(
                      'Transfer Statistics',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Active Transfers Summary
                    _buildSummaryCard(context, stats),
                    const SizedBox(height: 16),

                    // Upload Speed Section
                    _buildSpeedSection(
                      context,
                      title: 'Upload Speed',
                      speed: stats.totalUploadSpeed,
                      icon: Icons.arrow_upward,
                      color: colorScheme
                          .error, // Use error/warning color for uploads
                    ),
                    const SizedBox(height: 8),
                    _buildSpeedGraph(
                      context,
                      stats.speedHistory,
                      isUpload: true,
                    ),
                    const SizedBox(height: 16),

                    // Download Speed Section
                    _buildSpeedSection(
                      context,
                      title: 'Download Speed',
                      speed: stats.totalDownloadSpeed,
                      icon: Icons.arrow_downward,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 8),
                    _buildSpeedGraph(
                      context,
                      stats.speedHistory,
                      isUpload: false,
                    ),
                    const SizedBox(height: 16),

                    // Recent Activity
                    if (stats.activeTransfers.isNotEmpty) ...[
                      Text(
                        'Active Transfers',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ...stats.activeTransfers
                          .take(10)
                          .map(
                            (transfer) => _buildTransferItem(context, transfer),
                          ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryCard(
    BuildContext context,
    FileTransferStatsProvider stats,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildSummaryItem(
              context,
              icon: Icons.upload,
              label: 'Uploads',
              value: stats.activeUploads.length.toString(),
              color: colorScheme.error, // Use error/warning color for uploads
            ),
            Container(
              width: 1,
              height: 40,
              color: colorScheme.outline.withValues(alpha: 0.3),
            ),
            _buildSummaryItem(
              context,
              icon: Icons.download,
              label: 'Downloads',
              value: stats.activeDownloads.length.toString(),
              color: colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildSpeedSection(
    BuildContext context, {
    required String title,
    required double speed,
    required IconData icon,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Text(
          FileTransferStatsProvider.formatSpeed(speed),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildSpeedGraph(
    BuildContext context,
    List<SpeedDataPoint> history, {
    required bool isUpload,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = isUpload
        ? colorScheme.error
        : colorScheme.primary; // Use error/warning for uploads

    if (history.isEmpty) {
      return Container(
        height: 100,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outline.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'No data yet',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    return Container(
      height: 100,
      padding: const EdgeInsets.only(right: 8, top: 8),
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 1,
            getDrawingHorizontalLine: (value) {
              return FlLine(
                color: colorScheme.outline.withValues(alpha: 0.1),
                strokeWidth: 1,
              );
            },
          ),
          titlesData: FlTitlesData(show: false),
          borderData: FlBorderData(
            show: true,
            border: Border.all(
              color: colorScheme.outline.withValues(alpha: 0.3),
            ),
          ),
          minX: 0,
          maxX: (history.length - 1).toDouble(),
          minY: 0,
          maxY: _getMaxSpeed(history, isUpload),
          lineBarsData: [
            LineChartBarData(
              spots: history.asMap().entries.map((entry) {
                final speed = isUpload
                    ? entry.value.uploadSpeed
                    : entry.value.downloadSpeed;
                return FlSpot(entry.key.toDouble(), speed / 1024); // KB/s
              }).toList(),
              isCurved: true,
              color: color,
              barWidth: 2,
              isStrokeCapRound: true,
              dotData: FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _getMaxSpeed(List<SpeedDataPoint> history, bool isUpload) {
    if (history.isEmpty) return 100;

    final maxSpeed = history
        .map((p) => isUpload ? p.uploadSpeed : p.downloadSpeed)
        .reduce((a, b) => a > b ? a : b);

    // Convert to KB/s and add 20% padding
    return (maxSpeed / 1024) * 1.2 + 10;
  }

  Widget _buildTransferItem(BuildContext context, ActiveTransfer transfer) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUpload = transfer.direction == TransferDirection.upload;
    final color = isUpload ? colorScheme.tertiary : colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Container(
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isUpload ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    transfer.fileName,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: transfer.progress,
              backgroundColor: colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
            const SizedBox(height: 4),
            Text(
              '${(transfer.progress * 100).toInt()}% • ${FileTransferStatsProvider.formatSpeed(transfer.currentSpeed)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
