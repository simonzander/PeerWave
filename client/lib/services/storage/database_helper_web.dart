// Web stub for DatabaseHelperNative
// Web version uses the standard database_helper.dart (single database, no per-server tables)

import 'package:sqflite/sqflite.dart';

class DatabaseHelperNative {
  static Future<Database> get database async =>
      throw UnimplementedError('Native database not available on web');
  static Future<void> ensureServerTables(String serverHash) async {}
  static Future<void> deleteServerTables(String serverHash) async {}
  static String getTableName(String serverHash, String baseTableName) =>
      baseTableName;
  static Future<void> close() async {}
  static Future<void> reset() async {}
}
