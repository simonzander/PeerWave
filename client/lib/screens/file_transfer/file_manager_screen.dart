import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/file_transfer/storage_interface.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../services/socket_service.dart';

/// File Manager Screen - Manage locally stored files
/// 
/// Features:
/// - List all files in localStorage
/// - Show seeding status (download count, transfer rate)
/// - Delete files from localStorage and unannounce
/// - Share files via Signal (1:1 or Channel)
class FileManagerScreen extends StatefulWidget {
  const FileManagerScreen({Key? key}) : super(key: key);

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  SocketFileClient? _socketClient;
  FileStorageInterface? _storage;
  
  List<Map<String, dynamic>> _localFiles = [];
  Map<String, Map<String, dynamic>> _seedingStats = {}; // fileId -> {downloaders, transferRate}
  bool _isLoading = false;
  bool _hasLoadedOnce = false;
  
  @override
  void initState() {
    super.initState();
    // Load files on first build
  }
  
  SocketFileClient _getSocketClient() {
    if (_socketClient == null) {
      final socketService = SocketService();
      if (socketService.socket == null) {
        throw Exception('Socket not connected');
      }
      _socketClient = SocketFileClient(socket: socketService.socket!);
    }
    return _socketClient!;
  }
  
  FileStorageInterface _getStorage() {
    if (_storage == null) {
      _storage = Provider.of<FileStorageInterface>(context, listen: false);
    }
    return _storage!;
  }
  
  @override
  void dispose() {
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    // Load files on first build
    if (!_hasLoadedOnce && !_isLoading) {
      _hasLoadedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadLocalFiles();
      });
    }
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Manager'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLocalFiles,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _localFiles.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadLocalFiles,
                  child: ListView.builder(
                    itemCount: _localFiles.length,
                    padding: const EdgeInsets.all(16),
                    itemBuilder: (context, index) {
                      return _buildFileCard(_localFiles[index]);
                    },
                  ),
                ),
    );
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'No files in storage',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upload a file to get started',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildFileCard(Map<String, dynamic> file) {
    final fileId = file['fileId'] as String? ?? '';
    final fileName = file['fileName'] as String? ?? 'Unknown';
    final fileSize = file['fileSize'] as int? ?? 0;
    final mimeType = file['mimeType'] as String? ?? 'application/octet-stream';
    final isSeeder = file['isSeeder'] as bool? ?? false;
    final status = file['status'] as String? ?? 'unknown';
    final chunkCount = file['chunkCount'] as int? ?? 0;
    
    final seedingStats = _seedingStats[fileId];
    final downloaderCount = seedingStats?['downloaders'] ?? 0;
    final transferRate = seedingStats?['transferRate'] ?? 0.0;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row with icon, name, and actions
            Row(
              children: [
                _buildFileIcon(mimeType),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatFileSize(fileSize),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) => _handleMenuAction(value, file),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'share',
                      child: Row(
                        children: [
                          Icon(Icons.share),
                          SizedBox(width: 8),
                          Text('Share'),
                        ],
                      ),
                    ),
                    if (!isSeeder)
                      const PopupMenuItem(
                        value: 'announce',
                        child: Row(
                          children: [
                            Icon(Icons.cloud_upload),
                            SizedBox(width: 8),
                            Text('Start Seeding'),
                          ],
                        ),
                      ),
                    if (isSeeder)
                      const PopupMenuItem(
                        value: 'unannounce',
                        child: Row(
                          children: [
                            Icon(Icons.cloud_off),
                            SizedBox(width: 8),
                            Text('Stop Seeding'),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            
            const SizedBox(height: 12),
            
            // Status badges row
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildStatusBadge(status, isSeeder),
                _buildChunksBadge(chunkCount),
                if (isSeeder && downloaderCount > 0)
                  _buildDownloadersBadge(downloaderCount),
                if (isSeeder && transferRate > 0)
                  _buildTransferRateBadge(transferRate),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildFileIcon(String mimeType) {
    IconData icon;
    Color color;
    
    if (mimeType.startsWith('image/')) {
      icon = Icons.image;
      color = Colors.blue;
    } else if (mimeType.startsWith('video/')) {
      icon = Icons.video_file;
      color = Colors.purple;
    } else if (mimeType.startsWith('audio/')) {
      icon = Icons.audio_file;
      color = Colors.orange;
    } else if (mimeType.contains('pdf')) {
      icon = Icons.picture_as_pdf;
      color = Colors.red;
    } else if (mimeType.contains('text')) {
      icon = Icons.text_snippet;
      color = Colors.green;
    } else {
      icon = Icons.insert_drive_file;
      color = Colors.grey;
    }
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 32, color: color),
    );
  }
  
  Widget _buildStatusBadge(String status, bool isSeeder) {
    Color color;
    IconData icon;
    String label;
    
    if (isSeeder) {
      color = Colors.green;
      icon = Icons.cloud_done;
      label = 'Seeding';
    } else if (status == 'downloading') {
      color = Colors.blue;
      icon = Icons.cloud_download;
      label = 'Downloading';
    } else if (status == 'complete') {
      color = Colors.grey;
      icon = Icons.check_circle;
      label = 'Complete';
    } else {
      color = Colors.grey;
      icon = Icons.info;
      label = status;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }
  
  Widget _buildChunksBadge(int chunkCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$chunkCount chunks',
        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
      ),
    );
  }
  
  Widget _buildDownloadersBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download, size: 14, color: Colors.orange),
          const SizedBox(width: 4),
          Text(
            '$count ${count == 1 ? 'downloader' : 'downloaders'}',
            style: const TextStyle(fontSize: 12, color: Colors.orange),
          ),
        ],
      ),
    );
  }
  
  Widget _buildTransferRateBadge(double rate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.speed, size: 14, color: Colors.green),
          const SizedBox(width: 4),
          Text(
            '${_formatTransferRate(rate)}/s',
            style: const TextStyle(fontSize: 12, color: Colors.green),
          ),
        ],
      ),
    );
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  
  String _formatTransferRate(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  
  // ============================================
  // FILE OPERATIONS
  // ============================================
  
  Future<void> _loadLocalFiles() async {
    setState(() => _isLoading = true);
    
    try {
      final storage = _getStorage();
      final files = await storage.getAllFiles();
      
      // TODO: Load seeding stats from server
      // For now, use mock data
      _seedingStats = {};
      
      setState(() {
        _localFiles = files;
        _isLoading = false;
      });
    } catch (e) {
      _showError('Failed to load files: $e');
      setState(() => _isLoading = false);
    }
  }
  
  void _handleMenuAction(String action, Map<String, dynamic> file) {
    switch (action) {
      case 'share':
        _showShareDialog(file);
        break;
      case 'announce':
        _announceFile(file);
        break;
      case 'unannounce':
        _unannounceFile(file);
        break;
      case 'delete':
        _showDeleteConfirmation(file);
        break;
    }
  }
  
  Future<void> _announceFile(Map<String, dynamic> file) async {
    try {
      final storage = _getStorage();
      final client = _getSocketClient();
      
      final fileId = file['fileId'] as String;
      final availableChunks = await storage.getAvailableChunks(fileId);
      
      if (availableChunks.isEmpty) {
        _showError('No chunks available to seed');
        return;
      }
      
      await client.announceFile(
        fileId: fileId,
        mimeType: file['mimeType'] as String? ?? 'application/octet-stream',
        fileSize: file['fileSize'] as int? ?? 0,
        checksum: file['checksum'] as String? ?? '',
        chunkCount: file['chunkCount'] as int? ?? 0,
        availableChunks: availableChunks,
      );
      
      // Update local storage
      await storage.updateFileMetadata(fileId, {
        'isSeeder': true,
        'status': 'seeding',
        'lastActivity': DateTime.now().toIso8601String(),
      });
      
      _showSuccess('File announced successfully');
      _loadLocalFiles();
      
    } catch (e) {
      _showError('Failed to announce file: $e');
    }
  }
  
  Future<void> _unannounceFile(Map<String, dynamic> file) async {
    try {
      final storage = _getStorage();
      final client = _getSocketClient();
      
      final fileId = file['fileId'] as String;
      
      await client.unannounceFile(fileId);
      
      // Update local storage
      await storage.updateFileMetadata(fileId, {
        'isSeeder': false,
        'status': 'complete',
      });
      
      _showSuccess('Stopped seeding');
      _loadLocalFiles();
      
    } catch (e) {
      _showError('Failed to unannounce file: $e');
    }
  }
  
  void _showDeleteConfirmation(Map<String, dynamic> file) {
    final fileName = file['fileName'] as String? ?? 'this file';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Are you sure you want to delete "$fileName"?\n\nThis will remove the file from local storage and stop seeding.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteFile(file);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _deleteFile(Map<String, dynamic> file) async {
    try {
      final storage = _getStorage();
      final client = _getSocketClient();
      
      final fileId = file['fileId'] as String;
      final isSeeder = file['isSeeder'] as bool? ?? false;
      
      // Unannounce if seeding
      if (isSeeder) {
        await client.unannounceFile(fileId);
      }
      
      // Delete from local storage
      await storage.deleteFile(fileId);
      
      _showSuccess('File deleted successfully');
      _loadLocalFiles();
      
    } catch (e) {
      _showError('Failed to delete file: $e');
    }
  }
  
  void _showShareDialog(Map<String, dynamic> file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share File'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Share to Direct Message'),
              onTap: () {
                Navigator.pop(context);
                _shareToDirectMessage(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.group),
              title: const Text('Share to Channel'),
              onTap: () {
                Navigator.pop(context);
                _shareToChannel(file);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
  
  void _shareToDirectMessage(Map<String, dynamic> file) {
    // TODO: Implement Signal 1:1 message sharing
    _showInfo('Share to Direct Message - Coming soon!');
  }
  
  void _shareToChannel(Map<String, dynamic> file) {
    // TODO: Implement Signal Channel message sharing
    _showInfo('Share to Channel - Coming soon!');
  }
  
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
  
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      ),
    );
  }
  
  void _showInfo(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.blue,
      ),
    );
  }
}
