import 'package:idb_shim/idb.dart';
import 'package:idb_sqflite/idb_sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

IdbFactory? _cachedFactory;

IdbFactory getIdbFactoryNative() {
  if (_cachedFactory != null) {
    return _cachedFactory!;
  }
  
  // Initialize sqflite FFI for desktop platforms (Windows, Linux, macOS)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  
  _cachedFactory = idbFactorySqflite;
  return _cachedFactory!;
}
