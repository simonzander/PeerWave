import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../services/file_transfer/p2p_coordinator.dart';
import '../../services/socket_service.dart';

/// File Browser Screen - Browse and download available P2P files
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  SocketFileClient? _socketClient;

  List<Map<String, dynamic>> _files = [];
  bool _isLoading = false;
  bool _hasLoadedOnce = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Don't load files here - will be triggered in build()
  }

  SocketFileClient _getSocketClient() {
    if (_socketClient == null) {
      final socketService = SocketService.instance;
      if (socketService.socket == null) {
        throw Exception('Socket not connected');
      }
      _socketClient = SocketFileClient();
    }
    return _socketClient!;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Load files on first build
    if (!_hasLoadedOnce && !_isLoading) {
      _hasLoadedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadFiles();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Available Files'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFiles),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search files...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                          _loadFiles();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (value) {
                setState(() => _searchQuery = value);
                _searchFiles(value);
              },
            ),
          ),

          // File list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                ? _buildEmptyState()
                : RefreshIndicator(
                    onRefresh: _loadFiles,
                    child: ListView.builder(
                      itemCount: _files.length,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemBuilder: (context, index) {
                        return _buildFileItem(_files[index]);
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.pushNamed(context, '/file-upload');
        },
        child: const Icon(Icons.add),
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
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'No files available',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upload a file to share',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileItem(Map<String, dynamic> file) {
    // Privacy: fileName and mimeType are NOT sent from server
    // They come from the encrypted Signal message (future implementation)
    final fileName = file['fileName'] as String? ?? 'Shared File';
    final fileSize = file['fileSize'] as int? ?? 0;
    final mimeType = file['mimeType'] as String? ?? 'application/octet-stream';
    final seederCount = file['seederCount'] as int? ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _showFileDetails(file),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              // File icon
              _buildFileIcon(mimeType),
              const SizedBox(width: 16),

              // File info
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
                    const SizedBox(height: 4),
                    _buildSeederBadge(seederCount),
                  ],
                ),
              ),

              // Download button
              IconButton(
                icon: const Icon(Icons.download),
                color: Theme.of(context).colorScheme.primary,
                onPressed: () => _startDownload(file),
              ),
            ],
          ),
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
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 32, color: color),
    );
  }

  Widget _buildSeederBadge(int seederCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: seederCount > 0
            ? Colors.green.withValues(alpha: 0.1)
            : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_upload,
            size: 14,
            color: seederCount > 0 ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 4),
          Text(
            '$seederCount ${seederCount == 1 ? 'seeder' : 'seeders'}',
            style: TextStyle(
              fontSize: 12,
              color: seederCount > 0 ? Colors.green : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // ============================================
  // FILE OPERATIONS
  // ============================================

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);

    try {
      final client = _getSocketClient();
      final files = await client.getActiveFiles();
      setState(() {
        _files = files;
        _isLoading = false;
      });
    } catch (e) {
      _showError('Failed to load files: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _searchFiles(String query) async {
    if (query.isEmpty) {
      _loadFiles();
      return;
    }

    setState(() => _isLoading = true);

    try {
      final client = _getSocketClient();
      final results = await client.searchFiles(query);
      setState(() {
        _files = results;
        _isLoading = false;
      });
    } catch (e) {
      _showError('Search failed: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _showFileDetails(Map<String, dynamic> file) async {
    if (_socketClient == null) {
      _showError('Not connected to server');
      return;
    }

    final fileId = file['fileId'] as String? ?? '';

    if (fileId.isEmpty) {
      _showError('Invalid file ID');
      return;
    }

    // Get detailed file info with seeders
    try {
      final client = _getSocketClient();
      final detailedInfo = await client.getFileInfo(fileId);

      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        builder: (context) => _buildFileDetailsSheet(detailedInfo),
      );
    } catch (e) {
      _showError('Failed to load file details: $e');
    }
  }

  Widget _buildFileDetailsSheet(Map<String, dynamic> fileInfo) {
    // Privacy: fileName and mimeType might not be in server response
    final fileName = fileInfo['fileName'] as String? ?? 'Shared File';
    final fileSize = fileInfo['fileSize'] as int? ?? 0;
    final mimeType =
        fileInfo['mimeType'] as String? ?? 'application/octet-stream';
    final chunkCount = fileInfo['chunkCount'] as int? ?? 0;
    final seederCount = fileInfo['seederCount'] as int? ?? 0;

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildFileIcon(mimeType),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  fileName,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          _buildDetailRow('Size', _formatFileSize(fileSize)),
          _buildDetailRow('Type', mimeType),
          _buildDetailRow('Chunks', '$chunkCount'),
          _buildDetailRow('Seeders', '$seederCount'),

          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: seederCount > 0
                  ? () {
                      Navigator.pop(context);
                      _startDownload(fileInfo);
                    }
                  : null,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _startDownload(Map<String, dynamic> file) async {
    final fileId = file['fileId'] as String? ?? '';

    if (fileId.isEmpty) {
      _showError('Invalid file ID');
      return;
    }

    try {
      final client = _getSocketClient();

      // Get detailed file info with seeder chunks
      final fileInfo = await client.getFileInfo(fileId);
      final seederChunks = await client.getAvailableChunks(fileId);

      if (seederChunks.isEmpty) {
        _showError('No seeders available for this file');
        return;
      }

      // Register as leecher
      await client.registerLeecher(fileId);
      if (!mounted) return;

      // Get P2P Coordinator
      final p2pCoordinator = Provider.of<P2PCoordinator?>(
        context,
        listen: false,
      );

      if (p2pCoordinator == null) {
        throw Exception(
          'P2P Coordinator not initialized. Please ensure you are logged in and Socket.IO is connected.',
        );
      }

      debugPrint('[FILE BROWSER] Starting download with automatic key request');

      // Start download with automatic key request
      // This will:
      // 1. Connect to first seeder
      // 2. Request encryption key via WebRTC
      // 3. Start download with received key
      await p2pCoordinator.startDownloadWithKeyRequest(
        fileId: fileId,
        fileName:
            file['fileName'] as String? ?? 'download_${fileId.substring(0, 8)}',
        mimeType: file['mimeType'] as String? ?? 'application/octet-stream',
        fileSize: fileInfo['fileSize'] as int? ?? 0,
        checksum: fileInfo['checksum'] as String? ?? '',
        chunkCount: fileInfo['chunkCount'] as int? ?? 0,
        seederChunks: seederChunks,
        sharedWith: (fileInfo['sharedWith'] as List?)
            ?.cast<String>(), // ✅ NEW: Pass sharedWith from fileInfo
      );

      debugPrint('[FILE BROWSER] Download started for file: $fileId');

      // Navigate to downloads screen
      if (mounted) {
        context.go('/downloads');
      }
    } catch (e) {
      _showError('Failed to start download: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }
}
