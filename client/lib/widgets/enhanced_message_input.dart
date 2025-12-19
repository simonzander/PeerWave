import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:crypto/crypto.dart';
import 'package:cross_file/cross_file.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../services/file_transfer/storage_interface.dart';
import '../services/file_transfer/file_transfer_service.dart';
import '../services/file_transfer/socket_file_client.dart';
import '../services/socket_service.dart' if (dart.library.io) '../services/socket_service_native.dart';
import '../services/signal_service.dart';

/// Enhanced message input with all features:
/// - Emoji picker with skin tones
/// - @ mention autocomplete
/// - Image compression
/// - Voice recording
/// - P2P file sharing
/// - Enter/Shift+Enter handling
class EnhancedMessageInput extends StatefulWidget {
  final Function(String message, {String? type, Map<String, dynamic>? metadata}) onSendMessage;
  final Function(String itemId)? onFileShare;
  final List<Map<String, String>>? availableUsers; // For @ mentions
  final bool isGroupChat;
  final String? recipientUserId; // Required for P2P file sharing in 1:1 chats

  const EnhancedMessageInput({
    super.key,
    required this.onSendMessage,
    this.onFileShare,
    this.availableUsers,
    this.isGroupChat = false,
    this.recipientUserId,
  });

  @override
  State<EnhancedMessageInput> createState() => _EnhancedMessageInputState();
}

class _EnhancedMessageInputState extends State<EnhancedMessageInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  
  // Emoji picker state
  OverlayEntry? _emojiOverlay;
  bool _showEmojiPicker = false;
  
  // Mention autocomplete state
  OverlayEntry? _mentionOverlay;
  List<Map<String, String>> _filteredUsers = [];
  int _selectedMentionIndex = 0;
  int? _mentionStartIndex;
  
  // Voice recording state
  final AudioRecorder _audioRecorder = AudioRecorder();
  RecorderController? _recorderController;
  bool _isRecording = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  
  // Text empty state for dynamic button
  bool _isTextEmpty = true;
  
  // Attachment menu state
  OverlayEntry? _attachmentOverlay;
  
  // Formatting toolbar state
  bool _showFormatting = false;
  
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _emojiOverlay?.remove();
    _mentionOverlay?.remove();
    _attachmentOverlay?.remove();
    _controller.dispose();
    _focusNode.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _recorderController?.dispose();
    super.dispose();
  }

  /// Handle text changes for @ mention detection
  void _onTextChanged() {
    final text = _controller.text;
    final cursorPos = _controller.selection.baseOffset;
    
    // Update text empty state
    final isEmpty = text.trim().isEmpty;
    if (isEmpty != _isTextEmpty) {
      setState(() {
        _isTextEmpty = isEmpty;
      });
    }
    
    if (cursorPos < 0) return;
    
    // Find @ symbol before cursor
    int? atIndex;
    for (int i = cursorPos - 1; i >= 0; i--) {
      if (text[i] == '@') {
        atIndex = i;
        break;
      } else if (text[i] == ' ' || text[i] == '\n') {
        break; // Stop if we hit whitespace
      }
    }
    
    if (atIndex != null && widget.availableUsers != null) {
      final query = text.substring(atIndex + 1, cursorPos).toLowerCase();
      
      setState(() {
        _mentionStartIndex = atIndex;
        _filteredUsers = widget.availableUsers!.where((user) {
          final displayName = user['displayName']?.toLowerCase() ?? '';
          final atName = user['atName']?.toLowerCase() ?? '';
          return displayName.contains(query) || atName.contains(query);
        }).toList();
        _selectedMentionIndex = 0;
      });
      
      if (_filteredUsers.isNotEmpty) {
        _showMentionAutocomplete();
      } else {
        _hideMentionAutocomplete();
      }
    } else {
      _hideMentionAutocomplete();
    }
  }

  /// Show mention autocomplete overlay
  void _showMentionAutocomplete() {
    _mentionOverlay?.remove();
    
    _mentionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: 300,
        child: CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.topLeft, // Attach to top of input
          followerAnchor: Alignment.bottomLeft, // Place bottom of menu at top of input
          offset: const Offset(0, -10), // 10px above input
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: Theme.of(context).colorScheme.surface,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filteredUsers.length,
                itemBuilder: (context, index) {
                  final user = _filteredUsers[index];
                  final isSelected = index == _selectedMentionIndex;
                  
                  return ListTile(
                    selected: isSelected,
                    leading: CircleAvatar(
                      child: Text(user['displayName']?[0].toUpperCase() ?? '?'),
                    ),
                    title: Text(user['displayName'] ?? 'Unknown'),
                    subtitle: user['atName'] != null ? Text('@${user['atName']}') : null,
                    onTap: () => _insertMention(user),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    
    Overlay.of(context).insert(_mentionOverlay!);
  }

  /// Hide mention autocomplete
  void _hideMentionAutocomplete() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _mentionStartIndex = null;
    _filteredUsers = [];
  }

  /// Insert selected mention
  void _insertMention(Map<String, String> user) {
    if (_mentionStartIndex == null) return;
    
    final text = _controller.text;
    final cursorPos = _controller.selection.baseOffset;
    final mentionText = '@${user['atName'] ?? user['displayName']}';
    
    final newText = text.substring(0, _mentionStartIndex!) +
                    mentionText +
                    ' ' +
                    text.substring(cursorPos);
    
    _controller.text = newText;
    _controller.selection = TextSelection.collapsed(
      offset: _mentionStartIndex! + mentionText.length + 1,
    );
    
    _hideMentionAutocomplete();
    _focusNode.requestFocus();
  }

  /// Insert markdown/formatting at cursor position
  void _insertFormatting(String prefix, String suffix) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start;
    final end = selection.end;

    if (start < 0) {
      // No selection, insert at end
      _controller.text = text + prefix + suffix;
      _controller.selection = TextSelection.collapsed(offset: text.length + prefix.length);
    } else if (start == end) {
      // Cursor position, no selection
      final newText = text.substring(0, start) + prefix + suffix + text.substring(end);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: start + prefix.length);
    } else {
      // Text selected
      final selectedText = text.substring(start, end);
      final newText = text.substring(0, start) + prefix + selectedText + suffix + text.substring(end);
      _controller.text = newText;
      _controller.selection = TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selectedText.length,
      );
    }

    _focusNode.requestFocus();
  }

  /// Show emoji picker
  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      _hideEmojiPicker();
    } else {
      _showEmojiPickerOverlay();
    }
  }

  void _showEmojiPickerOverlay() {
    setState(() => _showEmojiPicker = true);
    
    _emojiOverlay?.remove();
    
    // Calculate bottom position considering formatting toolbar
    final bottomPosition = _showFormatting ? 116.0 : 68.0; // 68 for input, +48 for formatting toolbar
    
    _emojiOverlay = OverlayEntry(
      builder: (context) => Positioned(
        bottom: bottomPosition, // Position above input and formatting toolbar
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 450,
              height: 400,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  // Custom header with close button
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        topRight: Radius.circular(12),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Text(
                              'Emoji',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: _hideEmojiPicker,
                          tooltip: 'Close',
                          iconSize: 20,
                        ),
                      ],
                    ),
                  ),
                  // Emoji picker
                  Expanded(
                    child: EmojiPicker(
                      onEmojiSelected: (category, emoji) {
                        _insertText(emoji.emoji);
                      },
                      onBackspacePressed: null, // Remove backspace button
                      config: Config(
                        height: 352, // Reduced to fit with header (400 - 48)
                        checkPlatformCompatibility: true,
                        emojiViewConfig: EmojiViewConfig(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          columns: 9,
                          emojiSizeMax: 28.0,
                          verticalSpacing: 0,
                          horizontalSpacing: 0,
                          gridPadding: EdgeInsets.zero,
                          recentsLimit: 28,
                        ),
                        skinToneConfig: SkinToneConfig(
                          enabled: true,
                          dialogBackgroundColor: Theme.of(context).colorScheme.surface,
                        ),
                        categoryViewConfig: CategoryViewConfig(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          iconColor: Theme.of(context).colorScheme.onSurface,
                          indicatorColor: Theme.of(context).colorScheme.primary,
                          iconColorSelected: Theme.of(context).colorScheme.primary,
                          backspaceColor: Theme.of(context).colorScheme.primary,
                          categoryIcons: const CategoryIcons(),
                        ),
                        bottomActionBarConfig: BottomActionBarConfig(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          buttonColor: Theme.of(context).colorScheme.primary,
                          buttonIconColor: Theme.of(context).colorScheme.onPrimary,
                          showSearchViewButton: true, // Enable search
                        ),
                        searchViewConfig: SearchViewConfig(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          buttonIconColor: Theme.of(context).colorScheme.primary,
                          hintText: 'Search emoji',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    
    Overlay.of(context).insert(_emojiOverlay!);
  }

  void _hideEmojiPicker() {
    _emojiOverlay?.remove();
    _emojiOverlay = null;
    setState(() => _showEmojiPicker = false);
  }

  /// Insert text at cursor
  void _insertText(String text) {
    final currentText = _controller.text;
    final selection = _controller.selection;
    
    setState(() {
      // Handle invalid selection
      if (!selection.isValid || selection.start < 0) {
        // Insert at end if selection is invalid
        _controller.text = currentText + text;
        _controller.selection = TextSelection.collapsed(
          offset: currentText.length + text.length,
        );
      } else {
        // Insert at selection position
        final newText = currentText.substring(0, selection.start) +
                        text +
                        currentText.substring(selection.end);
        
        _controller.text = newText;
        _controller.selection = TextSelection.collapsed(
          offset: selection.start + text.length,
        );
      }
    });
    
    // Don't request focus when emoji picker is open - allows multiple emoji selection
    if (!_showEmojiPicker) {
      _focusNode.requestFocus();
    }
  }

  /// Show attachment menu
  void _showAttachmentMenu() {
    _attachmentOverlay?.remove();
    
    _attachmentOverlay = OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: () {
          _attachmentOverlay?.remove();
          _attachmentOverlay = null;
        },
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                bottom: 80,
                right: 16,
                child: Container(
                  width: 200, // Fixed width
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: IntrinsicHeight( // Properly constrain height
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          dense: true, // More compact
                          leading: const Icon(Icons.image),
                          title: const Text('Image'),
                          onTap: () {
                            _attachmentOverlay?.remove();
                            _attachmentOverlay = null;
                            _pickImage();
                          },
                        ),
                        ListTile(
                          dense: true, // More compact
                          leading: const Icon(Icons.insert_drive_file),
                          title: const Text('File (P2P)'),
                          onTap: () {
                            _attachmentOverlay?.remove();
                            _attachmentOverlay = null;
                            _pickFileForP2P();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    
    Overlay.of(context).insert(_attachmentOverlay!);
  }

  /// Pick and compress image
  Future<void> _pickImage() async {
    bool isLoadingShown = false;
    try {
      // Use file_picker on Windows (image_picker not supported)
      // Use image_picker on other platforms for better UX
      XFile? pickedFile;
      
      debugPrint('[MESSAGE_INPUT] Picking image, platform: $defaultTargetPlatform');
      
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        // Windows: Use file_picker
        debugPrint('[MESSAGE_INPUT] Using file_picker for Windows');
        try {
          final result = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
          );
          
          debugPrint('[MESSAGE_INPUT] FilePicker result: ${result?.files.length ?? 0} files');
          
          if (result == null || result.files.isEmpty) {
            debugPrint('[MESSAGE_INPUT] No file selected');
            return;
          }
          
          final file = result.files.first;
          if (file.path == null) {
            debugPrint('[MESSAGE_INPUT] File path is null');
            return;
          }
          
          debugPrint('[MESSAGE_INPUT] Selected file: ${file.path}');
          // Convert PlatformFile to XFile for consistency
          pickedFile = XFile(file.path!);
        } catch (e) {
          debugPrint('[MESSAGE_INPUT] FilePicker error: $e');
          rethrow;
        }
      } else {
        // Other platforms: Use image_picker
        debugPrint('[MESSAGE_INPUT] Using image_picker');
        final picker = ImagePicker();
        pickedFile = await picker.pickImage(source: ImageSource.gallery);
      }
      
      if (pickedFile == null) {
        debugPrint('[MESSAGE_INPUT] pickedFile is null');
        return;
      }
      
      debugPrint('[MESSAGE_INPUT] Reading image bytes from: ${pickedFile.path}');
      
      if (!mounted) return;
      
      // Show loading indicator with proper context management
      try {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(child: CircularProgressIndicator()),
        );
        isLoadingShown = true;
      } catch (e) {
        debugPrint('[MESSAGE_INPUT] Could not show loading dialog: $e');
      }
      
      // Read image bytes
      final imageBytes = await pickedFile.readAsBytes();
      
      // Compress image
      final compressedBytes = await _compressImage(imageBytes);
      
      // Check size
      if (compressedBytes.length > 2 * 1024 * 1024) {
        if (mounted && isLoadingShown) {
          Navigator.of(context, rootNavigator: true).pop(); // Close loading
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image too large (max 2MB)')),
          );
        }
        return;
      }
      
      // Convert to base64
      final base64Image = base64Encode(compressedBytes);
      
      // Close loading dialog
      if (mounted && isLoadingShown) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      
      // Send image message
      widget.onSendMessage(
        base64Image,
        type: 'image',
        metadata: {
          'filename': pickedFile.name,
          'originalSize': imageBytes.length,
          'compressedSize': compressedBytes.length,
        },
      );
      
      debugPrint('[MESSAGE_INPUT] Image sent: ${compressedBytes.length} bytes');
    } catch (e) {
      debugPrint('[MESSAGE_INPUT] Error picking image: $e');
      if (mounted && isLoadingShown) {
        try {
          Navigator.of(context, rootNavigator: true).pop(); // Close loading if open
        } catch (navError) {
          debugPrint('[MESSAGE_INPUT] Error closing dialog: $navError');
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// Compress image with progressive quality reduction
  Future<Uint8List> _compressImage(Uint8List imageBytes) async {
    // flutter_image_compress doesn't support Windows
    // On Windows, just resize if too large, no compression
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      debugPrint('[MESSAGE_INPUT] Windows: Skipping compression (not supported)');
      // Just check size and warn if too large
      if (imageBytes.length > 2 * 1024 * 1024) {
        debugPrint('[MESSAGE_INPUT] Warning: Image is ${imageBytes.length} bytes (>2MB)');
      }
      return imageBytes;
    }
    
    // Other platforms: Use flutter_image_compress
    const maxLongSide = 1920;
    const targetSize = 800 * 1024; // 800KB
    
    // Try quality 85%
    var result = await FlutterImageCompress.compressWithList(
      imageBytes,
      minWidth: maxLongSide,
      minHeight: maxLongSide,
      quality: 85,
    );
    
    if (result.length <= targetSize) return result;
    
    // Try quality 75%
    result = await FlutterImageCompress.compressWithList(
      imageBytes,
      minWidth: maxLongSide,
      minHeight: maxLongSide,
      quality: 75,
    );
    
    if (result.length <= targetSize) return result;
    
    // Try quality 65%
    result = await FlutterImageCompress.compressWithList(
      imageBytes,
      minWidth: maxLongSide,
      minHeight: maxLongSide,
      quality: 65,
    );
    
    if (result.length <= targetSize) return result;
    
    // Last resort: resize to 1280px with quality 80%
    result = await FlutterImageCompress.compressWithList(
      imageBytes,
      minWidth: 1280,
      minHeight: 1280,
      quality: 80,
    );
    
    return result;
  }

  /// Pick file for P2P sharing
  Future<void> _pickFileForP2P() async {
    bool isLoadingShown = false;
    try {
      if (widget.recipientUserId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recipient not specified for file sharing')),
        );
        return;
      }

      // Pick file
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        type: FileType.any,
      );
      
      if (result == null || result.files.isEmpty) return;
      
      final file = result.files.first;
      final fileBytes = file.bytes;
      
      if (fileBytes == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to read file data')),
        );
        return;
      }
      
      // Check file size (max 100MB)
      if (fileBytes.length > 100 * 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File too large. Maximum size is 100MB')),
        );
        return;
      }
      
      if (!mounted) return;
      
      // Show loading dialog with proper context management
      try {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('Uploading file...'),
              ],
            ),
          ),
        );
        isLoadingShown = true;
      } catch (e) {
        debugPrint('[MESSAGE_INPUT] Could not show loading dialog: $e');
      }
      
      // Upload and announce file using FileTransferService
      try {
        final storage = await _getStorage();
        final socketService = await _getSocketService();
        final signalService = SignalService.instance;
        
        final fileTransferService = FileTransferService(
          socketFileClient: SocketFileClient(socket: socketService.socket!),
          storage: storage,
          signalService: signalService,
        );
        
        // Upload and announce with recipient in sharedWith
        final fileId = await fileTransferService.uploadAndAnnounceFile(
          fileBytes: fileBytes,
          fileName: file.name,
          mimeType: _getMimeType(file.name),
          sharedWith: [widget.recipientUserId!], // Share with recipient
        );
        
        // Get file key for encryption
        final fileKey = await storage.getFileKey(fileId);
        if (fileKey == null) {
          throw Exception('File key not found after upload');
        }
        
        final encryptedFileKey = base64Encode(fileKey);
        
        // Calculate checksum
        final checksum = sha256.convert(fileBytes).toString();
        final chunkCount = (fileBytes.length / (256 * 1024)).ceil();
        
        // Send file via Signal Protocol
        await signalService.sendFileItem(
          recipientUserId: widget.recipientUserId!,
          fileId: fileId,
          fileName: file.name,
          mimeType: _getMimeType(file.name),
          fileSize: fileBytes.length,
          checksum: checksum,
          chunkCount: chunkCount,
          encryptedFileKey: encryptedFileKey,
        );
        
        if (mounted && isLoadingShown) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        
        // Call the onFileShare callback if provided
        widget.onFileShare?.call(fileId);
        
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File "${file.name}" shared successfully')),
        );
        
        debugPrint('[MESSAGE_INPUT] P2P file shared: $fileId');
      } catch (uploadError) {
        if (mounted && isLoadingShown) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        throw uploadError;
      }
      
    } catch (e) {
      if (mounted && isLoadingShown) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (navError) {
          debugPrint('[MESSAGE_INPUT] Error closing dialog: $navError');
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sharing file: $e')),
      );
      debugPrint('[MESSAGE_INPUT] Error in P2P file sharing: $e');
    }
  }
  
  /// Get storage instance
  Future<FileStorageInterface> _getStorage() async {
    // Try to get from Provider
    try {
      return Provider.of<FileStorageInterface>(context, listen: false);
    } catch (e) {
      throw Exception('FileStorageInterface not available in context');
    }
  }
  
  /// Get socket service
  Future<SocketService> _getSocketService() async {
    final socketService = SocketService();
    if (socketService.socket == null) {
      throw Exception('Socket not connected');
    }
    return socketService;
  }
  
  /// Get MIME type from filename
  String _getMimeType(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
      case 'docx':
        return 'application/msword';
      case 'xls':
      case 'xlsx':
        return 'application/vnd.ms-excel';
      case 'ppt':
      case 'pptx':
        return 'application/vnd.ms-powerpoint';
      case 'zip':
        return 'application/zip';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Start voice recording
  Future<void> _startRecording() async {
    debugPrint('[MESSAGE_INPUT] _startRecording called');
    try {
      // Request microphone permission
      debugPrint('[MESSAGE_INPUT] Requesting microphone permission');
      final status = await Permission.microphone.request();
      debugPrint('[MESSAGE_INPUT] Permission status: $status');
      if (!status.isGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
        return;
      }
      
      // Check if already recording
      if (await _audioRecorder.isRecording()) {
        return;
      }
      
      // Initialize waveform recorder controller (only on native platforms)
      // Note: audio_waveforms 2.x uses RecorderController() without encoder config
      // Encoder configuration is done via the record package's AudioRecorder
      if (!kIsWeb) {
        try {
          _recorderController = RecorderController();
        } catch (e) {
          debugPrint('[MESSAGE_INPUT] Could not initialize waveform controller: $e');
          // Continue without waveform visualization
        }
      }
      
      // Start recording with audio recorder
      // Use platform-specific encoder for cross-platform compatibility
      // Windows MediaFoundation supports: aacLc, flac, pcm16bits, wav (NOT opus)
      // Solution: Use aacLc on Windows for compressed format with broad playback support
      final encoder = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
          ? AudioEncoder.aacLc  // Windows: AAC-LC (compressed, widely supported)
          : AudioEncoder.opus;   // Other platforms: Opus
      
      debugPrint('[MESSAGE_INPUT] Starting recording with encoder: $encoder on platform: $defaultTargetPlatform');
      
      try {
        // AAC and Opus both support bitRate and sampleRate
        final config = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
            ? const RecordConfig(
                encoder: AudioEncoder.aacLc,
                bitRate: 128000,
                sampleRate: 44100,
                numChannels: 1,  // Mono to reduce file size
              )
            : const RecordConfig(
                encoder: AudioEncoder.opus,
                bitRate: 128000,
                sampleRate: 44100,
              );
        
        // Get temporary directory and create a file path
        // Windows requires a valid file path, empty string doesn't work
        String? recordingPath;
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
          final tempDir = await getTemporaryDirectory();
          final fileName = 'recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
          recordingPath = path.join(tempDir.path, fileName);
          debugPrint('[MESSAGE_INPUT] Windows recording path: $recordingPath');
        }
        
        debugPrint('[MESSAGE_INPUT] Recording config: $config');
        await _audioRecorder.start(config, path: recordingPath ?? '');
        
        debugPrint('[MESSAGE_INPUT] Recording started successfully');
        
        setState(() {
          _isRecording = true;
          _recordingDuration = Duration.zero;
        });
      } catch (e, stackTrace) {
        debugPrint('[MESSAGE_INPUT] Failed to start recording: $e');
        debugPrint('[MESSAGE_INPUT] Stack trace: $stackTrace');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
        return;
      }
      
      // Start timer
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _recordingDuration += const Duration(seconds: 1);
          
          // Auto-stop at 5 minutes
          if (_recordingDuration.inMinutes >= 5) {
            _stopRecording();
          }
        });
      });
      
      debugPrint('[MESSAGE_INPUT] Recording started');
    } catch (e) {
      debugPrint('[MESSAGE_INPUT] Error starting recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recording error: $e')),
        );
      }
    }
  }

  /// Stop voice recording and send
  Future<void> _stopRecording() async {
    try {
      _recordingTimer?.cancel();
      
      final path = await _audioRecorder.stop();
      
      setState(() {
        _isRecording = false;
      });
      
      if (path == null) {
        debugPrint('[MESSAGE_INPUT] Recording stopped but no file');
        return;
      }
      
      if (!mounted) return;
      
      // Show loading with proper context management
      bool isLoadingShown = false;
      try {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(child: CircularProgressIndicator()),
        );
        isLoadingShown = true;
      } catch (e) {
        debugPrint('[MESSAGE_INPUT] Could not show loading dialog: $e');
      }
      
      try {
        // Read audio file bytes - platform agnostic approach
        Uint8List audioBytes;
        
        // Use XFile for platform-agnostic file reading
        // Works with blob URLs on web and file paths on native
        final xFile = XFile(path);
        audioBytes = await xFile.readAsBytes();
        
        // Check size (max 2MB)
        if (audioBytes.length > 2 * 1024 * 1024) {
          if (mounted && isLoadingShown) {
            Navigator.of(context, rootNavigator: true).pop(); // Close loading
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Recording too large (max 2MB)')),
            );
          }
          return;
        }
        
        // Convert to base64
        final base64Audio = base64Encode(audioBytes);
        
        // Close loading dialog
        if (mounted && isLoadingShown) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        
        // Send voice message
        final duration = _recordingDuration;
        widget.onSendMessage(
          base64Audio,
          type: 'voice',
          metadata: {
            'duration': duration.inSeconds,
            'format': 'opus',
            'size': audioBytes.length,
          },
        );
        
        debugPrint('[MESSAGE_INPUT] Voice message sent: ${audioBytes.length} bytes, ${duration.inSeconds}s');
      } catch (e) {
        if (mounted && isLoadingShown) {
          Navigator.of(context, rootNavigator: true).pop(); // Close loading
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error processing recording: $e')),
          );
        }
        debugPrint('[MESSAGE_INPUT] Error processing recording: $e');
      }
    } catch (e) {
      debugPrint('[MESSAGE_INPUT] Error stopping recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// Cancel voice recording
  void _cancelRecording() async {
    _recordingTimer?.cancel();
    await _audioRecorder.stop();
    _recorderController?.dispose();
    _recorderController = null;
    
    setState(() {
      _isRecording = false;
      _recordingDuration = Duration.zero;
    });
    
    debugPrint('[MESSAGE_INPUT] Recording cancelled');
  }

  /// Send message
  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    
    // Extract mentions
    final mentions = <Map<String, dynamic>>[];
    final mentionPattern = RegExp(r'@(\w+)');
    final matches = mentionPattern.allMatches(text);
    
    for (final match in matches) {
      final atName = match.group(1);
      final user = widget.availableUsers?.firstWhere(
        (u) => u['atName'] == atName || u['displayName'] == atName,
        orElse: () => {},
      );
      
      if (user != null && user.isNotEmpty) {
        mentions.add({
          'userId': user['userId'],
          'displayName': user['displayName'],
          'start': match.start,
          'length': match.end - match.start,
        });
      }
    }
    
    widget.onSendMessage(
      text,
      type: 'message',
      metadata: mentions.isNotEmpty ? {'mentions': mentions} : null,
    );
    
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // Voice recording overlay
    if (_isRecording) {
      return _buildRecordingOverlay(theme);
    }
    
    return CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: theme.dividerColor,
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Formatting toolbar
            if (_showFormatting)
              Container(
                height: 48,
                margin: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.format_bold),
                      tooltip: 'Bold',
                      onPressed: () => _insertFormatting('**', '**'),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.format_italic),
                      tooltip: 'Italic',
                      onPressed: () => _insertFormatting('_', '_'),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.format_strikethrough),
                      tooltip: 'Strikethrough',
                      onPressed: () => _insertFormatting('~~', '~~'),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.link),
                      tooltip: 'Link',
                      onPressed: () => _insertFormatting('[', '](url)'),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.format_list_bulleted),
                      tooltip: 'Bullet List',
                      onPressed: () => _insertFormatting('- ', ''),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.format_list_numbered),
                      tooltip: 'Numbered List',
                      onPressed: () => _insertFormatting('1. ', ''),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.code),
                      tooltip: 'Inline Code',
                      onPressed: () => _insertFormatting('`', '`'),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    IconButton(
                      icon: const Icon(Icons.code_rounded),
                      tooltip: 'Code Block',
                      onPressed: () => _insertFormatting('```\n', '\n```'),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            
            // Main input row
            Row(
          children: [
            // Emoji button
            IconButton(
              icon: Icon(
                _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions_outlined,
                color: theme.colorScheme.primary,
              ),
              onPressed: _toggleEmojiPicker,
              tooltip: 'Emoji',
            ),
            
            // Input field
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        style: TextStyle(color: theme.colorScheme.onSurface),
                        decoration: InputDecoration(
                          hintText: 'Type message...',
                          hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                          border: InputBorder.none,
                          filled: false,
                          fillColor: Colors.transparent,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                        ),
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        onSubmitted: (_) => _sendMessage(),
                        onChanged: (_) {
                          // Handled by listener
                        },
                        // Don't auto-hide emoji picker on tap outside
                        // User must explicitly close it via emoji button
                      ),
                    ),
                    
                    // Formatting toggle button
                    IconButton(
                      icon: Icon(
                        _showFormatting ? Icons.format_clear : Icons.format_size,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () {
                        setState(() {
                          _showFormatting = !_showFormatting;
                        });
                      },
                      tooltip: _showFormatting ? 'Hide Formatting' : 'Show Formatting',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    
                    // Attach button
                    IconButton(
                      icon: Icon(
                        Icons.attach_file,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: _showAttachmentMenu,
                      tooltip: 'Attach',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(width: 8),
            
            // Dynamic button: Voice or Send
            _isTextEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.mic_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    onPressed: _startRecording,
                    tooltip: 'Voice message',
                  )
                : IconButton(
                    icon: Icon(
                      Icons.send,
                      color: theme.colorScheme.primary,
                    ),
                    onPressed: _sendMessage,
                    tooltip: 'Send',
                  ),
          ],
        ),
          ],
        ),
      ),
    );
  }

  /// Build voice recording overlay
  Widget _buildRecordingOverlay(ThemeData theme) {
    final minutes = _recordingDuration.inMinutes.toString().padLeft(2, '0');
    final seconds = (_recordingDuration.inSeconds % 60).toString().padLeft(2, '0');
    
    return Container(
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.fiber_manual_record,
            color: theme.colorScheme.error,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            '$minutes:$seconds',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 16),
          // Waveform visualization
          Expanded(
            child: _recorderController != null
                ? AudioWaveforms(
                    size: Size(MediaQuery.of(context).size.width * 0.4, 40),
                    recorderController: _recorderController!,
                    waveStyle: WaveStyle(
                      waveColor: theme.colorScheme.error,
                      showDurationLabel: false,
                      spacing: 4.0,
                      showBottom: false,
                      extendWaveform: true,
                      showMiddleLine: false,
                    ),
                    enableGesture: false,
                  )
                : LinearProgressIndicator(
                    value: _recordingDuration.inSeconds / 300, // 5 minutes max
                    backgroundColor: theme.colorScheme.errorContainer,
                    valueColor: AlwaysStoppedAnimation(theme.colorScheme.error),
                  ),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: _cancelRecording,
            icon: const Icon(Icons.close),
            label: const Text('Cancel'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _stopRecording,
            icon: const Icon(Icons.send),
            label: const Text('Send'),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
