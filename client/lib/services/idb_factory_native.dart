import 'package:idb_sqflite/idb_sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:io' show Platform;

IdbFactory? _cachedFactory;
bool _initialized = false;

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
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
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
