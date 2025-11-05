import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// File Transfer Configuration
/// 
/// Central place for file transfer limits and settings
class FileTransferConfig {
  // Maximum file size limits (in bytes)
  static const int MAX_FILE_SIZE_WEB = 200 * 1024 * 1024;        // 200 MB for web
  static const int MAX_FILE_SIZE_MOBILE = 200 * 1024 * 1024;     // 200 MB for mobile
  static const int MAX_FILE_SIZE_DESKTOP = 200 * 1024 * 1024;    // 200 MB for desktop
  
  // Recommended file sizes for good performance
  static const int RECOMMENDED_SIZE_WEB = 100 * 1024 * 1024;     // 100 MB
  static const int RECOMMENDED_SIZE_MOBILE = 100 * 1024 * 1024;  // 100 MB
  
  /// Get the maximum file size for current platform
  static int getMaxFileSize() {
    if (kIsWeb) {
      return MAX_FILE_SIZE_WEB;
    }
    
    // Platform detection only works on non-web
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return MAX_FILE_SIZE_MOBILE;
      }
      
      // Desktop (Windows, macOS, Linux)
      return MAX_FILE_SIZE_DESKTOP;
    } catch (e) {
      // Fallback to web limit if platform detection fails
      return MAX_FILE_SIZE_WEB;
    }
  }
  
  /// Get the recommended file size for current platform
  static int getRecommendedSize() {
    if (kIsWeb) {
      return RECOMMENDED_SIZE_WEB;
    }
    
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return RECOMMENDED_SIZE_MOBILE;
      }
      
      // Desktop can handle more
      return RECOMMENDED_SIZE_WEB;
    } catch (e) {
      return RECOMMENDED_SIZE_WEB;
    }
  }
  
  /// Get platform name for display
  static String getPlatformName() {
    if (kIsWeb) {
      return 'Web';
    }
    
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iOS';
      if (Platform.isWindows) return 'Windows';
      if (Platform.isMacOS) return 'macOS';
      if (Platform.isLinux) return 'Linux';
    } catch (e) {
      // Ignore
    }
    
    return 'Unknown';
  }
  
  /// Format bytes to human-readable size
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  
  /// Check if file size is within limits
  static bool isFileSizeValid(int fileSize) {
    return fileSize <= getMaxFileSize();
  }
  
  /// Check if file size is recommended
  static bool isFileSizeRecommended(int fileSize) {
    return fileSize <= getRecommendedSize();
  }
}

