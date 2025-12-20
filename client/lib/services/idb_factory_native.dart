import 'package:idb_sqflite/idb_sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

IdbFactory? _cachedFactory;
bool _initialized = false;

IdbFactory getIdbFactoryNative() {
  if (_cachedFactory != null) {
    return _cachedFactory!;
  }
  
  // Initialize sqflite FFI for desktop platforms (Windows, Linux, macOS)
  if (!_initialized) {
    debugPrint('[IDB_FACTORY] Initializing sqflite FFI for native platform');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
