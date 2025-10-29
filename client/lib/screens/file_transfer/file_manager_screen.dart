import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import '../../services/file_transfer/storage_interface.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../services/file_transfer/chunking_service.dart';
import '../../services/file_transfer/encryption_service.dart';
import '../../services/file_transfer/file_transfer_config.dart';
import '../../services/socket_service.dart';
import '../../widgets/file_size_error_dialog.dart';

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
  
  // Filter state
  FileFilter _currentFilter = FileFilter.all;
  
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
      body: Column(
        children: [
          // Filter bar
          _buildFilterBar(),
          const Divider(height: 1),
          
          // File list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _getFilteredFiles().isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadLocalFiles,
                        child: ListView.builder(
                          itemCount: _getFilteredFiles().length,
                          padding: const EdgeInsets.all(16),
                          itemBuilder: (context, index) {
                            return _buildFileCard(_getFilteredFiles()[index]);
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addFile,
        icon: const Icon(Icons.add),
        label: const Text('Add File'),
      ),
    );
  }
  
  Widget _buildEmptyState() {
    String message;
    switch (_currentFilter) {
      case FileFilter.myFiles:
        message = 'No files added yet';
        break;
      case FileFilter.downloads:
        message = 'No downloads in progress';
        break;
      case FileFilter.seeding:
        message = 'No files being seeded';
        break;
      default:
        message = 'No files in storage';
    }
    
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
            message,
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
  
  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildFilterChip('All', FileFilter.all, Icons.folder),
            const SizedBox(width: 8),
            _buildFilterChip('My Files', FileFilter.myFiles, Icons.insert_drive_file),
            const SizedBox(width: 8),
            _buildFilterChip('Downloads', FileFilter.downloads, Icons.download),
            const SizedBox(width: 8),
            _buildFilterChip('Seeding', FileFilter.seeding, Icons.cloud_upload),
          ],
        ),
      ),
    );
  }
  
  Widget _buildFilterChip(String label, FileFilter filter, IconData icon) {
    final isSelected = _currentFilter == filter;
    final count = _getFilterCount(filter);
    
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: isSelected ? Colors.white : null),
          const SizedBox(width: 6),
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.grey[300],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Theme.of(context).colorScheme.primary : Colors.black87,
                ),
              ),
            ),
          ],
        ],
      ),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _currentFilter = filter;
        });
      },
      selectedColor: Theme.of(context).colorScheme.primary,
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : null,
      ),
    );
  }
  
  int _getFilterCount(FileFilter filter) {
    switch (filter) {
      case FileFilter.all:
        return _localFiles.length;
      case FileFilter.myFiles:
        return _localFiles.where((f) => 
          (f['status'] == 'complete' || f['status'] == 'seeding') && 
          (f['isSeeder'] == true || f['progress'] == null || f['progress'] == 1.0)
        ).length;
      case FileFilter.downloads:
        return _localFiles.where((f) => 
          f['status'] == 'downloading' || 
          (f['progress'] != null && f['progress'] < 1.0)
        ).length;
      case FileFilter.seeding:
        return _localFiles.where((f) => f['isSeeder'] == true).length;
    }
  }
  
  List<Map<String, dynamic>> _getFilteredFiles() {
    switch (_currentFilter) {
      case FileFilter.all:
        return _localFiles;
      case FileFilter.myFiles:
        return _localFiles.where((f) => 
          (f['status'] == 'complete' || f['status'] == 'seeding') && 
          (f['isSeeder'] == true || f['progress'] == null || f['progress'] == 1.0)
        ).toList();
      case FileFilter.downloads:
        return _localFiles.where((f) => 
          f['status'] == 'downloading' || 
          (f['progress'] != null && f['progress'] < 1.0)
        ).toList();
      case FileFilter.seeding:
        return _localFiles.where((f) => f['isSeeder'] == true).toList();
    }
  }
  
  Widget _buildFileCard(Map<String, dynamic> file) {
    final fileId = file['fileId'] as String? ?? '';
    final fileName = file['fileName'] as String? ?? 'Unknown';
    final fileSize = file['fileSize'] as int? ?? 0;
    final mimeType = file['mimeType'] as String? ?? 'application/octet-stream';
    final isSeeder = file['isSeeder'] as bool? ?? false;
    final status = file['status'] as String? ?? 'unknown';
    final chunkCount = file['chunkCount'] as int? ?? 0;
    final progress = file['progress'] as double?;
    final downloadedChunks = file['downloadedChunks'] as int? ?? 0;
    
    final seedingStats = _seedingStats[fileId];
    final downloaderCount = seedingStats?['downloaders'] ?? 0;
    final transferRate = seedingStats?['transferRate'] ?? 0.0;
    
    // Check if file is downloading and also seeding partial chunks
    final isPartialSeeder = status == 'downloading' && downloadedChunks > 0 && isSeeder;
    
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
                      // Show download progress if downloading
                      if (status == 'downloading' && progress != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${(progress * 100).toStringAsFixed(1)}% complete',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
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
                    if (!isSeeder && status != 'downloading')
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
                    if (isSeeder && status != 'downloading')
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
            
            // Download progress bar
            if (status == 'downloading' && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
            ],
            
            const SizedBox(height: 12),
            
            // Status badges row
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildStatusBadge(status, isSeeder),
                _buildChunksBadge(chunkCount, downloadedChunks, status == 'downloading'),
                if (isPartialSeeder)
                  _buildPartialSeedingBadge(downloadedChunks, chunkCount),
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
  
  Widget _buildChunksBadge(int chunkCount, [int? downloadedChunks, bool isDownloading = false]) {
    String text;
    if (isDownloading && downloadedChunks != null) {
      text = '$downloadedChunks/$chunkCount chunks';
    } else {
      text = '$chunkCount chunks';
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
      ),
    );
  }
  
  Widget _buildPartialSeedingBadge(int availableChunks, int totalChunks) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.lightGreen.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_upload_outlined, size: 14, color: Colors.lightGreen),
          const SizedBox(width: 4),
          Text(
            'Seeding $availableChunks/$totalChunks',
            style: const TextStyle(fontSize: 12, color: Colors.lightGreen),
          ),
        ],
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
  
  Future<void> _addFile() async {
    try {
      // Pick file
      final result = await FilePicker.platform.pickFiles(
        withData: true, // Load file into memory
      );
      
      if (result == null || result.files.isEmpty) {
        return; // User cancelled
      }
      
      final file = result.files.first;
      final fileBytes = file.bytes;
      
      if (fileBytes == null) {
        _showError('Failed to read file data');
        return;
      }
      
      // ✅ CHECK FILE SIZE
      final maxSize = FileTransferConfig.getMaxFileSize();
      final recommendedSize = FileTransferConfig.getRecommendedSize();
      
      if (file.size > maxSize) {
        // File too large - show error dialog
        if (mounted) {
          await showFileSizeErrorDialog(context, file.size, file.name);
        }
        return;
      } else if (file.size > recommendedSize) {
        // File larger than recommended - show warning
        if (mounted) {
          final shouldContinue = await showFileSizeErrorDialog(
            context,
            file.size,
            file.name,
          );
          
          if (shouldContinue != true) {
            return; // User cancelled
          }
        }
      }
      
      // Show processing dialog
      if (!mounted) return;
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => _AddFileProgressDialog(
          fileName: file.name,
          fileSize: file.size,
          fileBytes: fileBytes,
          onComplete: () {
            Navigator.pop(context);
            _loadLocalFiles();
          },
          onError: (error) {
            Navigator.pop(context);
            _showError(error);
          },
        ),
      );
      
    } catch (e) {
      _showError('Failed to add file: $e');
    }
  }
  
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

/// Progress Dialog for Adding Files
class _AddFileProgressDialog extends StatefulWidget {
  final String fileName;
  final int fileSize;
  final Uint8List fileBytes;
  final VoidCallback onComplete;
  final Function(String) onError;
  
  const _AddFileProgressDialog({
    Key? key,
    required this.fileName,
    required this.fileSize,
    required this.fileBytes,
    required this.onComplete,
    required this.onError,
  }) : super(key: key);

  @override
  State<_AddFileProgressDialog> createState() => _AddFileProgressDialogState();
}

class _AddFileProgressDialogState extends State<_AddFileProgressDialog> {
  double _progress = 0.0;
  String _statusText = 'Preparing...';
  bool _chunkingComplete = false;
  bool _encryptionComplete = false;
  bool _storageComplete = false;
  
  @override
  void initState() {
    super.initState();
    _processFile();
  }
  
  Future<void> _processFile() async {
    try {
      final chunkingService = Provider.of<ChunkingService>(context, listen: false);
      final encryptionService = Provider.of<EncryptionService>(context, listen: false);
      final storage = Provider.of<FileStorageInterface>(context, listen: false);
      
      final mimeType = lookupMimeType(widget.fileName) ?? 'application/octet-stream';
      
      // Calculate checksum to check for duplicates
      setState(() => _statusText = 'Checking for duplicates...');
      final fileChecksum = chunkingService.calculateFileChecksum(widget.fileBytes);
      
      // Check if file already exists
      final existingFiles = await storage.getAllFiles();
      final duplicate = existingFiles.firstWhere(
        (f) => f['fileName'] == widget.fileName && f['checksum'] == fileChecksum,
        orElse: () => {},
      );
      
      if (duplicate.isNotEmpty) {
        widget.onError('File "${widget.fileName}" already exists in storage.');
        return;
      }
      
      final fileId = _generateFileId();
      
      // Step 1: Chunking
      setState(() => _statusText = 'Splitting into chunks...');
      final chunks = await chunkingService.splitIntoChunks(
        widget.fileBytes,
        onProgress: (current, total) {
          setState(() => _progress = 0.3 * (current / total));
        },
      );
      setState(() {
        _chunkingComplete = true;
        _progress = 0.3;
      });
      
      // Step 2: Generate encryption key
      setState(() => _statusText = 'Generating encryption key...');
      final fileKey = encryptionService.generateKey();
      debugPrint('[ADD_FILE] Generated AES-256 file key: ${fileKey.length} bytes');
      
      // Step 3: Encrypt and store chunks
      setState(() => _statusText = 'Encrypting and storing...');
      int processedChunks = 0;
      for (final chunk in chunks) {
        // Encrypt chunk
        final encryptionResult = await encryptionService.encryptChunk(
          chunk.data,
          fileKey,
        );
        
        // Store chunk
        await storage.saveChunk(
          fileId,
          chunk.chunkIndex,
          encryptionResult.ciphertext,
          iv: encryptionResult.iv,
          chunkHash: chunk.hash,
        );
        
        processedChunks++;
        setState(() {
          _progress = 0.3 + (0.6 * (processedChunks / chunks.length));
        });
      }
      
      setState(() {
        _encryptionComplete = true;
        _progress = 0.9;
      });
      
      // Step 4: Save file metadata (NOT announced, isSeeder = false)
      await storage.saveFileMetadata({
        'fileId': fileId,
        'fileName': widget.fileName,
        'mimeType': mimeType,
        'fileSize': widget.fileSize,
        'checksum': fileChecksum,
        'chunkCount': chunks.length,
        'status': 'complete',
        'isSeeder': false, // Not announced yet
        'createdAt': DateTime.now().toIso8601String(),
        'lastActivity': DateTime.now().toIso8601String(),
      });
      
      // Step 5: Save encryption key
      await storage.saveFileKey(fileId, fileKey);
      debugPrint('[ADD_FILE] Saved file key to storage: ${fileKey.length} bytes');
      
      setState(() {
        _storageComplete = true;
        _progress = 1.0;
        _statusText = 'File added successfully!';
      });
      
      // Wait a moment to show completion
      await Future.delayed(const Duration(milliseconds: 500));
      
      widget.onComplete();
      
    } catch (e) {
      widget.onError('Failed to process file: $e');
    }
  }
  
  String _generateFileId() {
    return DateTime.now().millisecondsSinceEpoch.toString() +
           '_' +
           widget.fileName.hashCode.toString();
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adding File'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _statusText,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _progress,
              minHeight: 8,
            ),
            const SizedBox(height: 8),
            Text(
              '${(_progress * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            
            // Stage indicators
            _buildStageIndicator('Chunking', _chunkingComplete),
            _buildStageIndicator('Encryption', _encryptionComplete),
            _buildStageIndicator('Storage', _storageComplete),
          ],
        ),
      ),
    );
  }
  
  Widget _buildStageIndicator(String label, bool complete) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            color: complete ? Colors.green : Colors.grey,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: complete ? Colors.green : Colors.grey,
              fontWeight: complete ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// File Filter Options
enum FileFilter {
  all,
  myFiles,
  downloads,
  seeding,
}
