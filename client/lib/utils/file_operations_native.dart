// Native file operations
import 'dart:io';

class FileOperations {
  static Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.writeAsBytes(bytes);
  }

  static Future<bool> exists(String path) async {
    final file = File(path);
    return await file.exists();
  }

  static Future<void> delete(String path) async {
    final file = File(path);
    await file.delete();
  }
}
