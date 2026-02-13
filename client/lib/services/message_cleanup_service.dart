import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'storage/database_helper.dart';

/// Service für automatisches Löschen alter Messages
class MessageCleanupService {
  static final MessageCleanupService instance =
      MessageCleanupService._internal();
  factory MessageCleanupService() => instance;
  MessageCleanupService._internal();

  static const String autoDeleteDaysKey = 'auto_delete_days';
  static const int defaultAutoDeleteDays = 365;

  /// Initialize cleanup service - call on app start
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final days = prefs.getInt(autoDeleteDaysKey) ?? defaultAutoDeleteDays;

    if (days > 0) {
      await cleanupOldMessages(days);
    }
  }

  /// Delete messages older than specified days
  Future<void> cleanupOldMessages(int days) async {
    debugPrint(
      '[CLEANUP] Starting message cleanup for messages older than $days days',
    );

    final cutoffDate = DateTime.now().subtract(Duration(days: days));
    final cutoffTimestamp = cutoffDate.toIso8601String();

    // Clean up SQLite database (all messages are now stored here)
    await _cleanupSqliteMessages(cutoffTimestamp);

    debugPrint('[CLEANUP] Cleanup completed');
  }

  Future<void> _cleanupSqliteMessages(String cutoffTimestamp) async {
    try {
      final db = await DatabaseHelper.database;

      // Check if messages table exists
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='messages'",
      );

      if (tables.isEmpty) {
        debugPrint(
          '[CLEANUP] SQLite messages table does not exist yet, skipping SQLite cleanup',
        );
        return;
      }

      // Delete old messages from SQLite
      final result = await db.delete(
        'messages',
        where: 'timestamp < ?',
        whereArgs: [cutoffTimestamp],
      );

      debugPrint('[CLEANUP] Deleted $result old messages from SQLite database');

      // Cleanup conversations with no messages (only if recent_conversations exists)
      final convTables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='recent_conversations'",
      );

      if (convTables.isNotEmpty) {
        final conversationsWithNoMessages = await db.rawQuery('''
          SELECT user_id FROM recent_conversations
          WHERE user_id NOT IN (
            SELECT DISTINCT sender FROM messages WHERE channel_id IS NULL
          )
        ''');

        for (final conv in conversationsWithNoMessages) {
          await db.delete(
            'recent_conversations',
            where: 'user_id = ?',
            whereArgs: [conv['user_id']],
          );
        }

        debugPrint(
          '[CLEANUP] Cleaned up ${conversationsWithNoMessages.length} empty conversations from SQLite',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[CLEANUP] Error cleaning up SQLite messages: $e');
      debugPrint('[CLEANUP] Stack trace: $stackTrace');
    }
  }
}
