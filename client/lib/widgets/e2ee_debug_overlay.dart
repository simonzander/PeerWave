import 'package:flutter/material.dart';
import '../services/e2ee_service.dart';
import '../services/insertable_streams_web.dart';

/// E2EE Debug Overlay
/// 
/// Shows encryption statistics and browser compatibility info
/// Useful for debugging and development
class E2EEDebugOverlay extends StatelessWidget {
  final E2EEService? e2eeService;
  final InsertableStreamsManager? insertableStreams;
  
  const E2EEDebugOverlay({
    super.key,
    this.e2eeService,
    this.insertableStreams,
  });
  
  @override
  Widget build(BuildContext context) {
    if (e2eeService == null) {
      return const SizedBox.shrink();
    }
    
    final stats = e2eeService!.getStats();
    final browserInfo = BrowserDetector.getBrowserInfo();
    final insertableStats = insertableStreams?.getStats();
    
    return Positioned(
      top: 80,
      right: 16,
      child: Material(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
        borderRadius: BorderRadius.circular(8),
        elevation: 4,
        child: Container(
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    stats['enabled'] ? Icons.lock : Icons.lock_open,
                    color: stats['enabled'] ? Colors.green : Colors.red,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'E2EE Debug',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              Divider(color: Theme.of(context).colorScheme.outline),
              
              // Browser Info
              _buildInfoRow(context, 'Browser', '${browserInfo['name']} ${browserInfo['version']}'),
              _buildInfoRow(
                context,
                'Insertable Streams',
                browserInfo['insertableStreamsSupported'] ? '✅ Supported' : '❌ Not Supported',
              ),
              const SizedBox(height: 8),
              
              // Encryption Stats
              Text(
                'Encryption Stats:',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              _buildInfoRow(context, 'Encrypted Frames', '${stats['encryptedFrames']}'),
              _buildInfoRow(context, 'Decrypted Frames', '${stats['decryptedFrames']}'),
              _buildInfoRow(context, 'Encryption Errors', '${stats['encryptionErrors']}',
                  valueColor: stats['encryptionErrors'] > 0 ? Colors.red : Colors.green),
              _buildInfoRow(context, 'Decryption Errors', '${stats['decryptionErrors']}',
                  valueColor: stats['decryptionErrors'] > 0 ? Colors.red : Colors.green),
              _buildInfoRow(context, 'Peer Count', '${stats['peerCount']}'),
              
              // Insertable Streams Stats
              if (insertableStats != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Insertable Streams:',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                _buildInfoRow(context, 'Transformed Frames', '${insertableStats['transformedFrames']}'),
                _buildInfoRow(context, 'Errors', '${insertableStats['errors']}',
                    valueColor: insertableStats['errors'] > 0 ? Colors.red : Colors.green),
                _buildInfoRow(context, 'Worker Status', insertableStats['workerReady'] ? '✅ Ready' : '⏳ Initializing'),
              ],
              
              // Key Info
              if (stats['keyGeneratedAt'] != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow(context, 'Key Generated', _formatTimestamp(stats['keyGeneratedAt'])),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildInfoRow(BuildContext context, String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$label:',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Theme.of(context).colorScheme.onSurface,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
  
  String _formatTimestamp(String? timestamp) {
    if (timestamp == null) return 'N/A';
    try {
      final dt = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(dt);
      
      if (diff.inMinutes < 1) {
        return 'Just now';
      } else if (diff.inMinutes < 60) {
        return '${diff.inMinutes}m ago';
      } else {
        return '${diff.inHours}h ago';
      }
    } catch (e) {
      return 'N/A';
    }
  }
}

