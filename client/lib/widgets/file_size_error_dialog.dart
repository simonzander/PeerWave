import 'package:flutter/material.dart';
import '../services/file_transfer/file_transfer_config.dart';

/// Dialog shown when user tries to upload a file that's too large
class FileSizeErrorDialog extends StatelessWidget {
  final int fileSize;
  final String fileName;
  
  const FileSizeErrorDialog({
    Key? key,
    required this.fileSize,
    required this.fileName,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final maxSize = FileTransferConfig.getMaxFileSize();
    final recommendedSize = FileTransferConfig.getRecommendedSize();
    final platform = FileTransferConfig.getPlatformName();
    final isOverRecommended = fileSize > recommendedSize && fileSize <= maxSize;
    
    return AlertDialog(
      title: Text(
        isOverRecommended ? 'Large File Warning' : 'File Too Large',
        style: TextStyle(
          color: isOverRecommended ? Colors.orange : Colors.red,
        ),
      ),
      icon: Icon(
        isOverRecommended ? Icons.warning : Icons.error,
        color: isOverRecommended ? Colors.orange : Colors.red,
        size: 48,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Size: ${FileTransferConfig.formatFileSize(fileSize)}',
                    style: TextStyle(
                      color: Colors.grey[700],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Error message
            if (!isOverRecommended) ...[
              Text(
                'This file exceeds the maximum allowed size for $platform.',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              _buildLimitInfo('Maximum allowed', maxSize, Colors.red),
              _buildLimitInfo('Your file', fileSize, Colors.red),
            ] else ...[
              Text(
                'This file is larger than recommended and may cause performance issues.',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              _buildLimitInfo('Recommended size', recommendedSize, Colors.orange),
              _buildLimitInfo('Your file', fileSize, Colors.orange),
              _buildLimitInfo('Maximum allowed', maxSize, Colors.grey[700]!),
            ],
            
            const SizedBox(height: 16),
            
            // Suggestions
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb, size: 18, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      Text(
                        'Suggestions:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue[900],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildSuggestion('Compress the file (ZIP, RAR)'),
                  _buildSuggestion('Split into smaller parts'),
                  if (fileSize > maxSize)
                    _buildSuggestion('Use desktop app for large files'),
                  if (isOverRecommended)
                    _buildSuggestion('Transfer may take several minutes'),
                ],
              ),
            ),
            
            // Platform limits info
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 6),
                      Text(
                        'Platform Limits:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildPlatformLimit('Web', FileTransferConfig.MAX_FILE_SIZE_WEB),
                  _buildPlatformLimit('Mobile', FileTransferConfig.MAX_FILE_SIZE_MOBILE),
                  _buildPlatformLimit('Desktop', FileTransferConfig.MAX_FILE_SIZE_DESKTOP),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (isOverRecommended)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        if (isOverRecommended)
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Continue Anyway'),
          )
        else
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('OK'),
          ),
      ],
    );
  }
  
  Widget _buildLimitInfo(String label, int size, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$label:',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
            ),
          ),
          Text(
            FileTransferConfig.formatFileSize(size),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSuggestion(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: TextStyle(color: Colors.blue[700])),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildPlatformLimit(String platform, int size) {
    final currentPlatform = FileTransferConfig.getPlatformName();
    final isCurrent = platform == currentPlatform;
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$platform:',
            style: TextStyle(
              fontSize: 11,
              color: isCurrent ? Colors.blue[700] : Colors.grey[600],
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            FileTransferConfig.formatFileSize(size),
            style: TextStyle(
              fontSize: 11,
              color: isCurrent ? Colors.blue[700] : Colors.grey[600],
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// Show file size error dialog
/// Returns true if user wants to continue (for warnings), false otherwise
Future<bool?> showFileSizeErrorDialog(
  BuildContext context,
  int fileSize,
  String fileName,
) {
  return showDialog<bool>(
    context: context,
    builder: (context) => FileSizeErrorDialog(
      fileSize: fileSize,
      fileName: fileName,
    ),
  );
}

