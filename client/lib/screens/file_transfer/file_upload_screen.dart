import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';
import '../../services/file_transfer/chunking_service.dart';
import '../../services/file_transfer/encryption_service.dart';
import '../../services/file_transfer/storage_interface.dart';
import '../../services/file_transfer/socket_file_client.dart';
import '../../services/file_transfer/file_transfer_config.dart';
import '../../services/socket_service.dart';
import '../../widgets/file_size_error_dialog.dart';

/// File Upload Screen - Upload and announce files to P2P network
class FileUploadScreen extends StatefulWidget {
  const FileUploadScreen({Key? key}) : super(key: key);

  @override
  State<FileUploadScreen> createState() => _FileUploadScreenState();
}

class _FileUploadScreenState extends State<FileUploadScreen> {
  // Upload state
  PlatformFile? _selectedFile;
  Uint8List? _fileBytes;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _statusText = '';
  
  // Upload stages
  bool _chunkingComplete = false;
  bool _encryptionComplete = false;
  bool _storageComplete = false;
  bool _announceComplete = false;
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload File'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // File selection
            if (_selectedFile == null && !_isProcessing)
              _buildFileSelector()
            else if (_selectedFile != null && !_isProcessing)
              _buildFilePreview()
            else if (_isProcessing)
              _buildProcessingView(),
            
            const SizedBox(height: 24),
            
            // Action buttons
            if (_selectedFile != null && !_isProcessing)
              _buildActionButtons(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildFileSelector() {
    return Card(
      child: InkWell(
        onTap: _pickFile,
        child: Container(
          height: 200,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.upload_file,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Tap to select a file',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Images, videos, documents, etc.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildFilePreview() {
    final file = _selectedFile!;
    final mimeType = lookupMimeType(file.name) ?? 'application/octet-stream';
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildFileIcon(mimeType),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatFileSize(file.size),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        mimeType,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearFile,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildProcessingView() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            // Overall progress
            Text(
              _statusText,
              style: Theme.of(context).textTheme.titleMedium,
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
            const SizedBox(height: 32),
            
            // Stage indicators
            _buildStageIndicator('Chunking', _chunkingComplete),
            _buildStageIndicator('Encryption', _encryptionComplete),
            _buildStageIndicator('Storage', _storageComplete),
            _buildStageIndicator('Announce', _announceComplete),
          ],
        ),
      ),
    );
  }
  
  Widget _buildStageIndicator(String label, bool complete) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            color: complete ? Colors.green : Colors.grey,
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
  
  Widget _buildActionButtons() {
    return Column(
      children: [
        ElevatedButton.icon(
          onPressed: () {
            final chunkingService = Provider.of<ChunkingService>(context, listen: false);
            final encryptionService = Provider.of<EncryptionService>(context, listen: false);
            final storage = Provider.of<FileStorageInterface>(context, listen: false);
            final socketService = SocketService();
            _uploadFile(chunkingService, encryptionService, storage, socketService);
          },
          icon: const Icon(Icons.cloud_upload),
          label: const Text('Upload & Share'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.all(16),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _clearFile,
          child: const Text('Cancel'),
        ),
      ],
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
    
    return Icon(icon, size: 48, color: color);
  }
  
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  
  // ============================================
  // FILE OPERATIONS
  // ============================================
  
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true, // Load file into memory
      );
      
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        
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
        
        // File size OK - continue
        setState(() {
          _selectedFile = file;
          _fileBytes = file.bytes;
        });
      }
    } catch (e) {
      _showError('Failed to pick file: $e');
    }
  }
  
  void _clearFile() {
    setState(() {
      _selectedFile = null;
      _fileBytes = null;
      _isProcessing = false;
      _progress = 0.0;
      _statusText = '';
      _chunkingComplete = false;
      _encryptionComplete = false;
      _storageComplete = false;
      _announceComplete = false;
    });
  }
  
  Future<void> _uploadFile(
    ChunkingService chunkingService,
    EncryptionService encryptionService,
    FileStorageInterface storage,
    SocketService socketService,
  ) async {
    if (_selectedFile == null || _fileBytes == null) return;
    
    // Check if socket is connected
    if (socketService.socket == null || !socketService.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not connected to server. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    
    final socketClient = SocketFileClient(socket: socketService.socket!);
    
    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _statusText = 'Checking for duplicates...';
    });
    
    try {
      final file = _selectedFile!;
      final fileBytes = _fileBytes!;
      final mimeType = lookupMimeType(file.name) ?? 'application/octet-stream';
      
      // Calculate checksum first to check for duplicates
      final fileChecksum = chunkingService.calculateFileChecksum(fileBytes);
      
      // Check if file already exists in local storage
      final existingFiles = await storage.getAllFiles();
      final duplicate = existingFiles.firstWhere(
        (f) => f['fileName'] == file.name && f['checksum'] == fileChecksum,
        orElse: () => {},
      );
      
      if (duplicate.isNotEmpty) {
        setState(() {
          _isProcessing = false;
          _progress = 0.0;
          _statusText = '';
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File "${file.name}" has already been shared.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }
      
      final fileId = _generateFileId();
      
      // Step 1: Chunking
      setState(() => _statusText = 'Splitting file into chunks...');
      final chunks = await chunkingService.splitIntoChunks(
        fileBytes,
        onProgress: (current, total) {
          setState(() => _progress = 0.2 * (current / total));
        },
      );
      setState(() {
        _chunkingComplete = true;
        _progress = 0.2;
      });
      
      // Step 2: Generate encryption key
      setState(() => _statusText = 'Generating encryption key...');
      final fileKey = encryptionService.generateKey();
      debugPrint('[UPLOAD] Generated AES-256 file key: ${fileKey.length} bytes');
      
      // Step 3: Encrypt and store chunks
      setState(() => _statusText = 'Encrypting and storing chunks...');
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
          _progress = 0.2 + (0.6 * (processedChunks / chunks.length));
        });
      }
      
      setState(() {
        _encryptionComplete = true;
        _storageComplete = true;
        _progress = 0.8;
      });
      
      // Step 4: Save file metadata (use already calculated checksum)
      await storage.saveFileMetadata({
        'fileId': fileId,
        'fileName': file.name,
        'mimeType': mimeType,
        'fileSize': file.size,
        'checksum': fileChecksum,
        'chunkCount': chunks.length,
        'status': 'seeding',
        'isSeeder': true,
        'createdAt': DateTime.now().toIso8601String(),
        'lastActivity': DateTime.now().toIso8601String(),
      });
      
      // Step 5: Save encryption key
      await storage.saveFileKey(fileId, fileKey);
      debugPrint('[UPLOAD] Saved file key to storage: ${fileKey.length} bytes');
      
      // Step 6: Announce to network (fileName is NOT sent for privacy)
      setState(() => _statusText = 'Announcing to network...');
      final availableChunks = List.generate(chunks.length, (i) => i);
      
      await socketClient.announceFile(
        fileId: fileId,
        mimeType: mimeType,
        fileSize: file.size,
        checksum: fileChecksum,
        chunkCount: chunks.length,
        availableChunks: availableChunks,
      );
      
      setState(() {
        _announceComplete = true;
        _progress = 1.0;
        _statusText = 'Upload complete!';
      });
      
      // Show success and navigate back
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        _showSuccess('File uploaded and shared successfully!');
      }
      
    } catch (e) {
      _showError('Upload failed: $e');
      _clearFile();
    }
  }
  
  String _generateFileId() {
    return DateTime.now().millisecondsSinceEpoch.toString() +
           '_' +
           (_selectedFile?.name.hashCode.toString() ?? '');
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
}
