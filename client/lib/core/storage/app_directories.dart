import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Centralized management of application directories
/// 
/// Structure:
/// Windows: C:\Users\<User>\AppData\Local\PeerWave\
/// macOS:   ~/Library/Application Support/PeerWave/
/// Linux:   ~/.local/share/PeerWave/
/// 
/// Subdirectories:
/// - database/  - SQLite databases
/// - cache/     - Temporary cached data, file chunks
/// - logs/      - Application logs
/// - downloads/ - Downloaded files
/// - config/    - Configuration files
class AppDirectories {
  static const String _appName = 'PeerWave';
  
  static Directory? _appDataDir;
  static Directory? _databaseDir;
  static Directory? _cacheDir;
  static Directory? _logsDir;
  static Directory? _downloadsDir;
  static Directory? _configDir;
  
  /// Initialize all application directories
  /// Creates the directory structure if it doesn't exist
  static Future<void> initialize() async {
    try {
      // Get platform-specific app data directory
      if (Platform.isWindows) {
        // Windows: AppData\Local\PeerWave
        final appData = Platform.environment['LOCALAPPDATA'];
        if (appData != null) {
          _appDataDir = Directory(path.join(appData, _appName));
        } else {
          // Fallback
          final temp = await getApplicationDocumentsDirectory();
          _appDataDir = Directory(path.join(temp.parent.path, 'Local', _appName));
        }
      } else if (Platform.isMacOS) {
        // macOS: ~/Library/Application Support/PeerWave
        final appSupport = await getApplicationSupportDirectory();
        _appDataDir = Directory(path.join(appSupport.path, _appName));
      } else if (Platform.isLinux) {
        // Linux: ~/.local/share/PeerWave
        final appData = await getApplicationDocumentsDirectory();
        _appDataDir = Directory(path.join(appData.parent.path, '.local', 'share', _appName));
      } else {
        // Fallback for other platforms
        final docs = await getApplicationDocumentsDirectory();
        _appDataDir = Directory(path.join(docs.path, _appName));
      }
      
      // Create main directory
      if (!await _appDataDir!.exists()) {
        await _appDataDir!.create(recursive: true);
        debugPrint('[AppDirectories] Created main directory: ${_appDataDir!.path}');
      }
      
      // Initialize subdirectories
      _databaseDir = await _createSubdirectory('database');
      _cacheDir = await _createSubdirectory('cache');
      _logsDir = await _createSubdirectory('logs');
      _downloadsDir = await _createSubdirectory('downloads');
      _configDir = await _createSubdirectory('config');
      
      debugPrint('[AppDirectories] Initialized:');
      debugPrint('  Root:      ${_appDataDir!.path}');
      debugPrint('  Database:  ${_databaseDir!.path}');
      debugPrint('  Cache:     ${_cacheDir!.path}');
      debugPrint('  Logs:      ${_logsDir!.path}');
      debugPrint('  Downloads: ${_downloadsDir!.path}');
      debugPrint('  Config:    ${_configDir!.path}');
      
      // Migrate old data if needed
      await _migrateOldData();
      
    } catch (e, stack) {
      debugPrint('[AppDirectories] Error initializing: $e');
      debugPrint(stack.toString());
      rethrow;
    }
  }
  
  /// Create a subdirectory within the app data directory
  static Future<Directory> _createSubdirectory(String name) async {
    final dir = Directory(path.join(_appDataDir!.path, name));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
  
  /// Migrate old data from Documents directory to new structure
  static Future<void> _migrateOldData() async {
    try {
      final oldDocsDir = await getApplicationDocumentsDirectory();
      
      // Migrate database file
      final oldDbPath = path.join(oldDocsDir.path, 'peerwave.db');
      final oldDbFile = File(oldDbPath);
      if (await oldDbFile.exists()) {
        final newDbPath = path.join(_databaseDir!.path, 'peerwave.db');
        final newDbFile = File(newDbPath);
        
        if (!await newDbFile.exists()) {
          debugPrint('[AppDirectories] Migrating database from $oldDbPath to $newDbPath');
          await oldDbFile.copy(newDbPath);
          
          // Also migrate -shm and -wal files if they exist
          final shmFile = File('$oldDbPath-shm');
          if (await shmFile.exists()) {
            await shmFile.copy('$newDbPath-shm');
          }
          final walFile = File('$oldDbPath-wal');
          if (await walFile.exists()) {
            await walFile.copy('$newDbPath-wal');
          }
          
          debugPrint('[AppDirectories] Database migration complete');
          
          // Delete old files after successful migration
          await oldDbFile.delete();
          if (await shmFile.exists()) await shmFile.delete();
          if (await walFile.exists()) await walFile.delete();
        }
      }
      
      // Migrate file_chunks directory
      final oldChunksDir = Directory(path.join(oldDocsDir.path, 'file_chunks'));
      if (await oldChunksDir.exists()) {
        final newChunksDir = Directory(path.join(_cacheDir!.path, 'file_chunks'));
        if (!await newChunksDir.exists()) {
          debugPrint('[AppDirectories] Migrating file_chunks from ${oldChunksDir.path} to ${newChunksDir.path}');
          
          // Copy directory contents
          await for (final entity in oldChunksDir.list(recursive: true)) {
            if (entity is File) {
              final relativePath = path.relative(entity.path, from: oldChunksDir.path);
              final newPath = path.join(newChunksDir.path, relativePath);
              final newFile = File(newPath);
              await newFile.parent.create(recursive: true);
              await entity.copy(newPath);
            }
          }
          
          debugPrint('[AppDirectories] file_chunks migration complete');
          
          // Delete old directory after successful migration
          await oldChunksDir.delete(recursive: true);
        }
      }
      
    } catch (e) {
      debugPrint('[AppDirectories] Error during migration: $e');
      // Don't rethrow - migration is optional
    }
  }
  
  // Getters for directory paths
  
  /// Root application data directory
  /// Windows: C:\Users\<User>\AppData\Local\PeerWave
  static Directory get appDataDirectory {
    if (_appDataDir == null) {
      throw StateError('AppDirectories not initialized. Call initialize() first.');
    }
    return _appDataDir!;
  }
  
  /// Database directory for SQLite files
  static Directory get databaseDirectory {
    if (_databaseDir == null) {
      throw StateError('AppDirectories not initialized. Call initialize() first.');
    }
    return _databaseDir!;
  }
  
  /// Cache directory for temporary data and file chunks
  static Directory get cacheDirectory {
    if (_cacheDir == null) {
      throw StateError('AppDirectories not initialized. Call initialize() first.');
    }
    return _cacheDir!;
  }
  
  /// Logs directory for application logs
  static Directory get logsDirectory {
    if (_logsDir == null) {
      throw StateError('AppDirectories not initialized. Call initialize() first.');
    }
    return _logsDir!;
  }
  
  /// Downloads directory for user downloads
  static Directory get downloadsDirectory {
    if (_downloadsDir == null) {
      throw StateError('AppDirectories not initialized. Call initialize() first.');
    }
    return _downloadsDir!;
  }
  
  /// Config directory for configuration files
  static Directory get configDirectory {
    if (_configDir == null) {
      throw StateError('AppDirectories not initialized. Call initialize() first.');
    }
    return _configDir!;
  }
  
  /// Get the full path for a database file
  static String getDatabasePath(String filename) {
    return path.join(databaseDirectory.path, filename);
  }
  
  /// Get the full path for a cache file
  static String getCachePath(String filename) {
    return path.join(cacheDirectory.path, filename);
  }
  
  /// Get the full path for a log file
  static String getLogPath(String filename) {
    return path.join(logsDirectory.path, filename);
  }
  
  /// Get the full path for a download file
  static String getDownloadPath(String filename) {
    return path.join(downloadsDirectory.path, filename);
  }
  
  /// Get the full path for a config file
  static String getConfigPath(String filename) {
    return path.join(configDirectory.path, filename);
  }
  
  /// Clear cache directory (preserve file_chunks if active)
  static Future<void> clearCache({bool preserveChunks = true}) async {
    try {
      final chunksDir = Directory(path.join(_cacheDir!.path, 'file_chunks'));
      
      await for (final entity in _cacheDir!.list()) {
        if (entity is Directory) {
          if (preserveChunks && entity.path == chunksDir.path) {
            continue; // Skip file_chunks
          }
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.delete();
        }
      }
      
      debugPrint('[AppDirectories] Cache cleared');
    } catch (e) {
      debugPrint('[AppDirectories] Error clearing cache: $e');
    }
  }
  
  /// Get directory size in bytes
  static Future<int> getDirectorySize(Directory dir) async {
    int totalSize = 0;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
    } catch (e) {
      debugPrint('[AppDirectories] Error calculating size: $e');
    }
    return totalSize;
  }
  
  /// Format bytes to human-readable string
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
