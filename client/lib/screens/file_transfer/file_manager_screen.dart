import 'dart:typed_data';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import '../../services/file_transfer/storage_interface.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../services/file_transfer/chunking_service.dart';
import '../../services/file_transfer/encryption_service.dart';
import '../../services/file_transfer/file_transfer_config.dart';
import '../../services/file_transfer/file_transfer_service.dart';
import '../../services/socket_service.dart';
import '../../services/signal_service.dart';
import '../../services/api_service.dart';
import '../../providers/role_provider.dart';
import '../../web_config.dart';
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
      final storage = Provider.of<FileStorageInterface?>(context, listen: false);
      if (storage == null) {
        throw Exception('FileStorageInterface not initialized. Please login first.');
      }
      _storage = storage;
    }
    return _storage!;
  }
  
  @override
  void dispose() {
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    // Listen to storage changes so widget rebuilds when storage becomes available
    final storageAvailable = Provider.of<FileStorageInterface?>(context, listen: true) != null;
    
    // Load files when storage becomes available
    if (!_hasLoadedOnce && !_isLoading && storageAvailable) {
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
                : !storageAvailable
                    ? _buildStorageNotInitializedState()
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
    final colorScheme = Theme.of(context).colorScheme;
    
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
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upload a file to get started',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildStorageNotInitializedState() {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.hourglass_empty,
            size: 64,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'File storage initializing...',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Please wait a moment',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),
          const CircularProgressIndicator(),
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
    final colorScheme = Theme.of(context).colorScheme;
    
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: isSelected ? colorScheme.onPrimary : null),
          const SizedBox(width: 6),
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected ? colorScheme.onPrimary : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? colorScheme.primary : colorScheme.onSurface,
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
      selectedColor: colorScheme.primary,
      labelStyle: TextStyle(
        color: isSelected ? colorScheme.onPrimary : null,
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
    
    // downloadedChunks can be either List<int> or int, handle both cases
    final downloadedChunksRaw = file['downloadedChunks'];
    final downloadedChunksCount = downloadedChunksRaw is List 
        ? downloadedChunksRaw.length 
        : (downloadedChunksRaw as int? ?? 0);
    
    // For uploaded files (status: 'complete' or 'seeding'), assume all chunks are available
    final isComplete = status == 'complete' || status == 'seeding' || downloadedChunksCount == chunkCount;
    
    final seedingStats = _seedingStats[fileId];
    final downloaderCount = seedingStats?['downloaders'] ?? 0;
    final transferRate = seedingStats?['transferRate'] ?? 0.0;
    
    // Check if file is downloading and also seeding partial chunks
    final isPartialSeeder = status == 'downloading' && downloadedChunksCount > 0 && isSeeder;
    
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
                    // Download file to disk (only if file is complete - all chunks available)
                    if (isComplete && chunkCount > 0)
                      const PopupMenuItem(
                        value: 'download',
                        child: Row(
                          children: [
                            Icon(Icons.file_download),
                            SizedBox(width: 8),
                            Text('Download to Disk'),
                          ],
                        ),
                      ),
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
                    // Start Seeding - for files that are NOT seeding (including downloads)
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
                    // Stop Seeding - for files that ARE seeding (including downloads)
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
            
            // Download progress bar
            if (status == 'downloading' && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
              ),
            ],
            
            const SizedBox(height: 12),
            
            // Status badges row
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildStatusBadge(status, isSeeder),
                _buildChunksBadge(chunkCount, downloadedChunksCount, status == 'downloading'),
                if (isPartialSeeder)
                  _buildPartialSeedingBadge(downloadedChunksCount, chunkCount),
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
    final colorScheme = Theme.of(context).colorScheme;
    IconData icon;
    Color color;
    
    if (mimeType.startsWith('image/')) {
      icon = Icons.image;
      color = colorScheme.primary;
    } else if (mimeType.startsWith('video/')) {
      icon = Icons.video_file;
      color = colorScheme.tertiary;
    } else if (mimeType.startsWith('audio/')) {
      icon = Icons.audio_file;
      color = colorScheme.secondary;
    } else if (mimeType.contains('pdf')) {
      icon = Icons.picture_as_pdf;
      color = colorScheme.error;
    } else if (mimeType.contains('text')) {
      icon = Icons.text_snippet;
      color = colorScheme.primary;
    } else {
      icon = Icons.insert_drive_file;
      color = colorScheme.onSurfaceVariant;
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
    final colorScheme = Theme.of(context).colorScheme;
    Color color;
    IconData icon;
    String label;
    
    if (isSeeder) {
      color = colorScheme.primary;
      icon = Icons.cloud_done;
      label = 'Seeding';
    } else if (status == 'downloading') {
      color = colorScheme.secondary;
      icon = Icons.cloud_download;
      label = 'Downloading';
    } else if (status == 'complete') {
      color = colorScheme.onSurfaceVariant;
      icon = Icons.check_circle;
      label = 'Complete';
    } else {
      color = colorScheme.onSurfaceVariant;
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
    
    final colorScheme = Theme.of(context).colorScheme;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
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
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    try {
      final storage = _getStorage();
      final files = await storage.getAllFiles();
      
      // ========================================
      // NOTE: Checksum verification is now handled by FileTransferService
      // after download completion. No need to verify here.
      // ========================================
      
      // TODO: Load seeding stats from server
      // For now, use mock data
      _seedingStats = {};
      
      if (!mounted) return;
      setState(() {
        _localFiles = files;
        _isLoading = false;
      });
    } catch (e) {
      _showError('Failed to load files: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }
  
  void _handleMenuAction(String action, Map<String, dynamic> file) {
    switch (action) {
      case 'download':
        _downloadFileToDisk(file);
        break;
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
      
      // Get sharedWith list from metadata
      final sharedWith = (file['sharedWith'] as List?)?.cast<String>();
      
      await client.announceFile(
        fileId: fileId,
        mimeType: file['mimeType'] as String? ?? 'application/octet-stream',
        fileSize: file['fileSize'] as int? ?? 0,
        checksum: file['checksum'] as String? ?? '',
        chunkCount: file['chunkCount'] as int? ?? 0,
        availableChunks: availableChunks,
        sharedWith: sharedWith, // ← WICHTIG: sharedWith mit announced!
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
  
  Future<void> _downloadFileToDisk(Map<String, dynamic> file) async {
    try {
      final storage = _getStorage();
      final encryptionService = Provider.of<EncryptionService>(context, listen: false);
      final chunkingService = Provider.of<ChunkingService>(context, listen: false);
      
      final fileId = file['fileId'] as String;
      final fileName = file['fileName'] as String? ?? 'download';
      final chunkCount = file['chunkCount'] as int? ?? 0;
      
      // Check if we have all chunks
      final availableChunks = await storage.getAvailableChunks(fileId);
      final downloadedChunks = (file['downloadedChunks'] as List?)?.cast<int>() ?? availableChunks;
      
      if (downloadedChunks.isEmpty) {
        _showError('No chunks available to download');
        return;
      }
      
      // Show progress dialog
      if (!mounted) return;
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => _DownloadFileProgressDialog(
          storage: storage,
          encryptionService: encryptionService,
          chunkingService: chunkingService,
          fileId: fileId,
          fileName: fileName,
          chunkCount: chunkCount,
          downloadedChunks: downloadedChunks,
          onComplete: () {
            Navigator.pop(context);
            _showSuccess('File downloaded to disk successfully');
          },
          onError: (error) {
            Navigator.pop(context);
            _showError(error);
          },
        ),
      );
      
    } catch (e) {
      _showError('Failed to download file: $e');
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
      builder: (context) => _ShareFileDialog(file: file),
    );
  }
  
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
  
  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
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
      
      // Step 4: Save file metadata with sharedWith field
      await storage.saveFileMetadata({
        'fileId': fileId,
        'fileName': widget.fileName,
        'mimeType': mimeType,
        'fileSize': widget.fileSize,
        'checksum': fileChecksum,
        'chunkCount': chunks.length,
        'sharedWith': <String>[], // ✅ WICHTIG: sharedWith field initialisieren
        'status': 'seeding', // Directly mark as seeding (will announce next)
        'isSeeder': true, // Will be announced automatically
        'createdAt': DateTime.now().toIso8601String(),
        'lastActivity': DateTime.now().toIso8601String(),
      });
      
      // Step 5: Save encryption key
      await storage.saveFileKey(fileId, fileKey);
      debugPrint('[ADD_FILE] Saved file key to storage: ${fileKey.length} bytes');
      
      // Step 6: Auto-announce file to server
      setState(() => _statusText = 'Announcing to network...');
      try {
        final socketService = SocketService();
        if (socketService.socket != null) {
          final client = SocketFileClient(socket: socketService.socket!);
          
          // Get all chunk indices
          final allChunks = List<int>.generate(chunks.length, (i) => i);
          
          await client.announceFile(
            fileId: fileId,
            mimeType: mimeType,
            fileSize: widget.fileSize,
            checksum: fileChecksum,
            chunkCount: chunks.length,
            availableChunks: allChunks,
            sharedWith: <String>[], // ✅ WICHTIG: leere sharedWith Liste
          );
          
          debugPrint('[ADD_FILE] File announced: $fileId with ${chunks.length} chunks');
        } else {
          debugPrint('[ADD_FILE] WARNING: Socket not connected, file not announced');
        }
      } catch (e) {
        debugPrint('[ADD_FILE] Failed to announce file: $e');
        // Don't fail the whole operation, just log
      }
      
      setState(() {
        _storageComplete = true;
        _progress = 1.0;
        _statusText = 'File added and announced!';
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

/// Share File Dialog - Search and select users or channels
class _ShareFileDialog extends StatefulWidget {
  final Map<String, dynamic> file;

  const _ShareFileDialog({Key? key, required this.file}) : super(key: key);

  @override
  State<_ShareFileDialog> createState() => _ShareFileDialogState();
}

class _ShareFileDialogState extends State<_ShareFileDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearching = false;
  
  List<Map<String, dynamic>> _searchResults = [];
  Map<String, dynamic>? _selectedItem;
  String? _selectedType; // 'user' or 'channel'
  
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
  
  Future<void> _searchUsersAndChannels(String query) async {
    if (query.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }
    
    setState(() => _isSearching = true);
    
    try {
      final results = <Map<String, dynamic>>[];
      
      // Search users
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      
      // Get all users (excluding self)
      final usersResp = await ApiService.get('$urlString/people/list');
      if (usersResp.statusCode == 200) {
        final users = usersResp.data is List ? usersResp.data as List : [];
        for (final user in users) {
          final displayName = user['displayName'] ?? '';
          final email = user['email'] ?? '';
          if (displayName.toLowerCase().contains(query.toLowerCase()) ||
              email.toLowerCase().contains(query.toLowerCase())) {
            results.add({
              'type': 'user',
              'id': user['uuid'],
              'name': displayName,
              'subtitle': email,
              'icon': Icons.person,
            });
          }
        }
      }
      
      // Get Signal channels (where I'm a member/owner)
      final channelsResp = await ApiService.get('$urlString/client/channels?type=signal&limit=50');
      if (channelsResp.statusCode == 200) {
        // Parse response (could be direct list or wrapped in 'channels' key)
        final responseData = channelsResp.data is String 
            ? json.decode(channelsResp.data) 
            : channelsResp.data;
        
        final channels = responseData is List 
            ? responseData 
            : (responseData['channels'] as List? ?? []);
        
        for (final channel in channels) {
          final name = channel['name'] ?? '';
          final description = channel['description'] ?? '';
          final type = channel['type'] ?? '';
          
          // Only show Signal channels
          if (type == 'signal' && 
              (name.toLowerCase().contains(query.toLowerCase()) ||
               description.toLowerCase().contains(query.toLowerCase()))) {
            results.add({
              'type': 'channel',
              'id': channel['uuid'],
              'name': name,
              'subtitle': description.isNotEmpty ? description : 'Signal Channel',
              'icon': Icons.tag,
            });
          }
        }
      }
      
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } catch (e) {
      debugPrint('[SHARE_DIALOG] Search error: $e');
      setState(() => _isSearching = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Search failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  Future<void> _shareFile() async {
    if (_selectedItem == null || _selectedType == null) return;
    
    try {
      final fileId = widget.file['fileId'] as String;
      
      // Get file encryption key from storage
      final storage = Provider.of<FileStorageInterface>(context, listen: false);
      final fileKey = await storage.getFileKey(fileId);
      
      if (fileKey == null) {
        throw Exception('File encryption key not found');
      }
      
      // Encrypt file key with base64 (will be re-encrypted by Signal Protocol)
      final encryptedFileKey = base64Encode(fileKey);
      
      final signalService = SignalService();
      final socketService = SocketService();
      final fileTransferService = FileTransferService(
        storage: storage,
        socketFileClient: SocketFileClient(socket: socketService.socket!),
        signalService: signalService,
      );
      
      if (_selectedType == 'user') {
        // Share to 1:1 chat (use direct user ID)
        final userId = _selectedItem!['id'];
        
        // Use FileTransferService.addUsersToShare() for proper workflow
        // This handles:
        // 1. Server update (updateFileShare)
        // 2. Signal broadcast to ALL seeders (file_share_update)
        // 3. Local metadata update
        // 4. Re-announce with updated sharedWith
        await fileTransferService.addUsersToShare(
          fileId: fileId,
          chatId: userId, // Direct chat uses userId
          chatType: 'direct',
          userIds: [userId],
          encryptedFileKey: encryptedFileKey,
        );
        
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File shared with ${_selectedItem!['name']}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else if (_selectedType == 'channel') {
        // Share to channel/group chat
        final channelId = _selectedItem!['id'];
        
        // Get all channel members (excluding self)
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        final members = await roleProvider.getChannelMembers(channelId);
        
        // Get own userId from SignalService
        final ownUserId = signalService.currentUserId;
        
        // Extract member userIds (excluding self)
        final channelMembers = members
            .map((m) => m.userId)
            .where((userId) => userId != ownUserId)
            .toList();
        
        // Always call addUsersToShare() even if channelMembers is empty
        // This ensures the file message is sent to the channel chat
        await fileTransferService.addUsersToShare(
          fileId: fileId,
          chatId: channelId,
          chatType: 'group',
          userIds: channelMembers,
          encryptedFileKey: encryptedFileKey,
        );
        
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File shared to #${_selectedItem!['name']}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[SHARE_DIALOG] Share error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to share file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.share),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Share: ${widget.file['fileName']}'),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search users or channels',
                hintText: 'Type to search...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _searchResults = [];
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
                _searchUsersAndChannels(value);
              },
            ),
            const SizedBox(height: 16),
            
            // Search results
            if (_isSearching)
              const Padding(
                padding: EdgeInsets.all(24.0),
                child: CircularProgressIndicator(),
              )
            else if (_searchQuery.length < 2)
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  'Type at least 2 characters to search',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              )
            else if (_searchResults.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(
                      'No users or channels found',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _searchResults.length,
                  itemBuilder: (context, index) {
                    final item = _searchResults[index];
                    final isSelected = _selectedItem?['id'] == item['id'];
                    
                    return ListTile(
                      selected: isSelected,
                      leading: CircleAvatar(
                        backgroundColor: item['type'] == 'user'
                            ? Colors.blue
                            : Colors.green,
                        child: Icon(
                          item['icon'] as IconData,
                          color: Colors.white,
                        ),
                      ),
                      title: Row(
                        children: [
                          if (item['type'] == 'channel')
                            const Text(
                              '# ',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          Expanded(
                            child: Text(
                              item['name'] as String,
                              style: const TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(item['subtitle'] as String),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : null,
                      onTap: () {
                        setState(() {
                          _selectedItem = item;
                          _selectedType = item['type'] as String;
                        });
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: _selectedItem == null ? null : _shareFile,
          icon: const Icon(Icons.send),
          label: const Text('Share'),
        ),
      ],
    );
  }
}

/// Download File Progress Dialog - Decrypt and download file from localStorage to disk
class _DownloadFileProgressDialog extends StatefulWidget {
  final FileStorageInterface storage;
  final EncryptionService encryptionService;
  final ChunkingService chunkingService;
  final String fileId;
  final String fileName;
  final int chunkCount;
  final List<int> downloadedChunks;
  final VoidCallback onComplete;
  final Function(String) onError;
  
  const _DownloadFileProgressDialog({
    Key? key,
    required this.storage,
    required this.encryptionService,
    required this.chunkingService,
    required this.fileId,
    required this.fileName,
    required this.chunkCount,
    required this.downloadedChunks,
    required this.onComplete,
    required this.onError,
  }) : super(key: key);

  @override
  State<_DownloadFileProgressDialog> createState() => _DownloadFileProgressDialogState();
}

class _DownloadFileProgressDialogState extends State<_DownloadFileProgressDialog> {
  double _progress = 0.0;
  String _statusText = 'Preparing...';
  bool _decryptionComplete = false;
  bool _assemblyComplete = false;
  
  @override
  void initState() {
    super.initState();
    _downloadFile();
  }
  
  Future<void> _downloadFile() async {
    try {
      // Step 1: Get file encryption key
      setState(() => _statusText = 'Loading encryption key...');
      final fileKey = await widget.storage.getFileKey(widget.fileId);
      
      if (fileKey == null) {
        widget.onError('File encryption key not found');
        return;
      }
      
      // Step 2: Decrypt chunks
      setState(() => _statusText = 'Decrypting chunks...');
      final decryptedChunks = <ChunkData>[];
      
      for (int i = 0; i < widget.downloadedChunks.length; i++) {
        final chunkIndex = widget.downloadedChunks[i];
        
        // Load encrypted chunk data and metadata
        final encryptedBytes = await widget.storage.getChunk(widget.fileId, chunkIndex);
        final chunkMetadata = await widget.storage.getChunkMetadata(widget.fileId, chunkIndex);
        
        if (encryptedBytes == null || chunkMetadata == null) {
          widget.onError('Chunk $chunkIndex not found in storage');
          return;
        }
        
        // Get IV from metadata
        final iv = chunkMetadata['iv'] as Uint8List?;
        if (iv == null) {
          widget.onError('IV not found for chunk $chunkIndex');
          return;
        }
        
        // Decrypt chunk
        final decryptedBytes = await widget.encryptionService.decryptChunk(
          encryptedBytes,
          fileKey,
          iv,
        );
        
        if (decryptedBytes == null) {
          widget.onError('Failed to decrypt chunk $chunkIndex');
          return;
        }
        
        // Create ChunkData for assembly
        final chunkHash = chunkMetadata['chunkHash'] as String? ?? '';
        decryptedChunks.add(ChunkData(
          chunkIndex: chunkIndex,
          data: decryptedBytes,
          hash: chunkHash,
          size: decryptedBytes.length,
        ));
        
        setState(() {
          _progress = 0.7 * ((i + 1) / widget.downloadedChunks.length);
        });
      }
      
      setState(() {
        _decryptionComplete = true;
        _progress = 0.7;
      });
      
      // Step 3: Assemble file
      setState(() => _statusText = 'Assembling file...');
      final fileBytes = await widget.chunkingService.assembleChunks(
        decryptedChunks,
        verifyHashes: false, // Already verified during download
      );
      
      if (fileBytes == null) {
        widget.onError('Failed to assemble file');
        return;
      }
      
      setState(() {
        _assemblyComplete = true;
        _progress = 0.9;
      });
      
      // Step 4: Trigger browser download
      setState(() => _statusText = 'Downloading to disk...');
      
      // Use web download mechanism
      await _triggerBrowserDownload(fileBytes, widget.fileName);
      
      setState(() {
        _progress = 1.0;
        _statusText = 'Download complete!';
      });
      
      // Wait a moment to show completion
      await Future.delayed(const Duration(milliseconds: 500));
      
      widget.onComplete();
      
    } catch (e) {
      widget.onError('Failed to download file: $e');
    }
  }
  
  Future<void> _triggerBrowserDownload(Uint8List bytes, String fileName) async {
    // Create blob URL and trigger download (web-specific)
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Downloading File'),
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
            _buildStageIndicator('Decryption', _decryptionComplete),
            _buildStageIndicator('Assembly', _assemblyComplete),
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

