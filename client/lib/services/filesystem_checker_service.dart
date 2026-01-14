import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as path;

/// Service to check file system accessibility for desktop autostart scenarios
/// Handles Windows-specific file locking issues
class FileSystemCheckerService {
  /// Wait for file system to become accessible
  /// Returns true if accessible, false if timeout reached
  static Future<bool> waitForFileSystemAccess({
    required String testPath,
    Duration timeout = const Duration(minutes: 1),
  }) async {
    final startTime = DateTime.now();
    int attemptCount = 0;
    int delayMs = 500; // Start with 500ms delay

    debugPrint(
      '[FileSystemChecker] Waiting for file system access (timeout: ${timeout.inSeconds}s)',
    );
    debugPrint('[FileSystemChecker] Test path: $testPath');

    while (DateTime.now().difference(startTime) < timeout) {
      attemptCount++;

      try {
        final isAccessible = await isFileSystemAccessible(testPath);

        if (isAccessible) {
          debugPrint(
            '[FileSystemChecker] File system accessible after $attemptCount attempts',
          );
          return true;
        }

        debugPrint(
          '[FileSystemChecker] Attempt $attemptCount: Not accessible yet, '
          'retrying in ${delayMs}ms...',
        );

        await Future.delayed(Duration(milliseconds: delayMs));

        // Exponential backoff (max 5 seconds)
        delayMs = min(delayMs * 2, 5000);
      } catch (e) {
        debugPrint('[FileSystemChecker] Error: $e');
        await Future.delayed(Duration(milliseconds: delayMs));
        delayMs = min(delayMs * 2, 5000);
      }
    }

    debugPrint(
      '[FileSystemChecker] Timeout reached after $attemptCount attempts',
    );
    return false; // Timeout reached
  }

  /// Check if file system is accessible by attempting read/write operations
  static Future<bool> isFileSystemAccessible(String testPath) async {
    try {
      // Ensure directory exists
      final dir = Directory(testPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // Create test file path
      final testFilePath = path.join(
        testPath,
        '.fs_test_${DateTime.now().millisecondsSinceEpoch}',
      );
      final testFile = File(testFilePath);

      // Test: Create file
      await testFile.writeAsString('test', flush: true);

      // Test: Read file
      final content = await testFile.readAsString();
      if (content != 'test') {
        debugPrint('[FileSystemChecker] Read verification failed');
        return false;
      }

      // Test: Delete file
      await testFile.delete();

      debugPrint('[FileSystemChecker] File system is accessible');
      return true;
    } on FileSystemException catch (e) {
      // Handle Windows-specific errors
      if (e.message.contains('database is locked') ||
          e.message.contains('SQLITE_BUSY') ||
          e.message.contains('being used by another process') ||
          e.message.contains('Access is denied')) {
        debugPrint('[FileSystemChecker] File system locked: ${e.message}');
        return false;
      }

      debugPrint('[FileSystemChecker] FileSystemException: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[FileSystemChecker] Unexpected error: $e');
      return false;
    }
  }
}
