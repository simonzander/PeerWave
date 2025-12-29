// Stub for web - native file operations not available
class FileOperations {
  static Future<void> writeBytes(String path, List<int> bytes) async {
    throw UnsupportedError('File operations not available on web');
  }

  static Future<bool> exists(String path) async {
    return false;
  }

  static Future<void> delete(String path) async {
    // No-op on web
  }
}
