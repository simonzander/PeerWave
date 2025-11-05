/// File Message Payload Model
/// 
/// Used for sharing P2P files via Signal group chats.
/// This model is encrypted with SenderKey and sent as GroupItem.payload.
/// 
/// Security:
/// - fileId: Public UUID (identifies file in fileRegistry)
/// - fileName: Encrypted in Signal message (user sees original name)
/// - encryptedFileKey: AES-256 key for decrypting file chunks (encrypted with SenderKey)
/// - checksum: SHA-256 hash for integrity verification
/// 
/// Privacy:
/// - Only users in the channel can decrypt this message
/// - File key is encrypted end-to-end
/// - fileRegistry only stores fileId (no file name for privacy)

class FileMessage {
  /// Unique file identifier (from fileRegistry)
  final String fileId;
  
  /// Original file name (visible to recipients)
  final String fileName;
  
  /// MIME type (e.g., 'application/pdf', 'image/png')
  final String mimeType;
  
  /// File size in bytes
  final int fileSize;
  
  /// SHA-256 checksum for integrity verification
  final String checksum;
  
  /// Number of chunks (for download progress tracking)
  final int chunkCount;
  
  /// AES-256 key for decrypting file chunks (base64 encoded)
  /// This is encrypted with SenderKey when sent in GroupItem
  final String encryptedFileKey;
  
  /// Uploader's user ID
  final String uploaderId;
  
  /// Upload timestamp (milliseconds since epoch)
  final int timestamp;
  
  /// Optional message text (e.g., "Here's the document we discussed")
  final String? message;

  FileMessage({
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.checksum,
    required this.chunkCount,
    required this.encryptedFileKey,
    required this.uploaderId,
    required this.timestamp,
    this.message,
  });

  /// Create from JSON (after decrypting GroupItem.payload)
  factory FileMessage.fromJson(Map<String, dynamic> json) {
    return FileMessage(
      fileId: json['fileId'] as String,
      fileName: json['fileName'] as String,
      mimeType: json['mimeType'] as String,
      fileSize: json['fileSize'] as int,
      checksum: json['checksum'] as String,
      chunkCount: json['chunkCount'] as int,
      encryptedFileKey: json['encryptedFileKey'] as String,
      uploaderId: json['uploaderId'] as String,
      timestamp: json['timestamp'] as int,
      message: json['message'] as String?,
    );
  }

  /// Convert to JSON (before encrypting with SenderKey)
  Map<String, dynamic> toJson() {
    return {
      'fileId': fileId,
      'fileName': fileName,
      'mimeType': mimeType,
      'fileSize': fileSize,
      'checksum': checksum,
      'chunkCount': chunkCount,
      'encryptedFileKey': encryptedFileKey,
      'uploaderId': uploaderId,
      'timestamp': timestamp,
      if (message != null) 'message': message,
    };
  }

  /// Human-readable file size (e.g., "1.5 MB")
  String get fileSizeFormatted {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Get file icon based on MIME type
  String get fileIcon {
    if (mimeType.startsWith('image/')) {
      return '🖼️';
    } else if (mimeType.startsWith('video/')) {
      return '🎥';
    } else if (mimeType.startsWith('audio/')) {
      return '🎵';
    } else if (mimeType == 'application/pdf') {
      return '📄';
    } else if (mimeType.contains('document') || mimeType.contains('word')) {
      return '📝';
    } else if (mimeType.contains('spreadsheet') || mimeType.contains('excel')) {
      return '📊';
    } else if (mimeType.contains('presentation') || mimeType.contains('powerpoint')) {
      return '📽️';
    } else if (mimeType.contains('zip') || mimeType.contains('archive')) {
      return '📦';
    } else {
      return '📎';
    }
  }

  @override
  String toString() {
    return 'FileMessage(fileId: $fileId, fileName: $fileName, size: $fileSizeFormatted)';
  }
}

