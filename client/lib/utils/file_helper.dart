import 'dart:typed_data';
import 'dart:io' if (dart.library.html) '';

/// Platform-agnostic file operations wrapper
class FileHelper {
  /// Write bytes to a file path (native only)
  static Future<void> writeBytes(String path, Uint8List bytes) async {
    if (bool.fromEnvironment('dart.library.html')) {
      throw UnsupportedError('File operations not supported on web');
    }
    final file = File(path);
    await file.writeAsBytes(bytes);
  }

  /// Check if file exists (native only)
  static Future<bool> exists(String path) async {
    if (bool.fromEnvironment('dart.library.html')) {
      return false;
    }
    final file = File(path);
    return await file.exists();
  }

  /// Delete a file (native only)
  static Future<void> delete(String path) async {
    if (bool.fromEnvironment('dart.library.html')) {
      return;
    }
    final file = File(path);
    await file.delete();
  }
}
