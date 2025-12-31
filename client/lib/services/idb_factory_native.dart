import 'package:idb_sqflite/idb_sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io' show Platform, Directory;

IdbFactory? _cachedFactory;
bool _initialized = false;
bool _pathEnsured = false;

/// Ensure the database directory exists before initializing
Future<void> _ensureDatabasePath() async {
  if (_pathEnsured) return;

  try {
    // Get the path that sqflite_common_ffi uses by default
    final appDataDir = await getApplicationSupportDirectory();
    final defaultDbPath = p.join(
      appDataDir.path,
      'sqflite_common_ffi',
      'databases',
    );
    debugPrint('[IDB_FACTORY] Ensuring database directory: $defaultDbPath');

    // Create directory if it doesn't exist
    final dbDir = Directory(defaultDbPath);
    if (!dbDir.existsSync()) {
      dbDir.createSync(recursive: true);
      debugPrint('[IDB_FACTORY] ✓ Created database directory');
    } else {
      debugPrint('[IDB_FACTORY] ✓ Database directory already exists');
    }

    _pathEnsured = true;
  } catch (e) {
    debugPrint('[IDB_FACTORY] ⚠️ Error ensuring database path: $e');
    // Don't throw - let sqflite try with its default behavior
    _pathEnsured = true; // Mark as attempted to avoid repeated failures
  }
}

IdbFactory getIdbFactoryNative() {
  if (_cachedFactory != null) {
    return _cachedFactory!;
  }

  // Initialize sqflite based on platform
  if (!_initialized) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (isDesktop) {
      debugPrint('[IDB_FACTORY] Initializing sqflite FFI for desktop platform');

      // Initialize sqflite FFI
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // Ensure database path exists (async, but don't wait)
      _ensureDatabasePath().catchError((e) {
        debugPrint('[IDB_FACTORY] Background path setup failed: $e');
      });
    } else if (isMobile) {
      debugPrint(
        '[IDB_FACTORY] Initializing standard sqflite for mobile platform',
      );
      databaseFactory = sqflite_mobile.databaseFactory;
    } else {
      throw Exception('[IDB_FACTORY] Unsupported platform');
    }
    _initialized = true;
  }

  debugPrint('[IDB_FACTORY] Creating new idbFactorySqflite instance');
  _cachedFactory = idbFactorySqflite;
  return _cachedFactory!;
}

/// Reset the factory cache (called during hot reload/restart)
/// This prevents "database_closed" errors after hot reload
void resetIdbFactoryNative() {
  debugPrint('[IDB_FACTORY] Resetting native IDB factory cache');
  _cachedFactory = null;
  // Don't reset _initialized - sqfliteFfiInit() should only be called once
}
