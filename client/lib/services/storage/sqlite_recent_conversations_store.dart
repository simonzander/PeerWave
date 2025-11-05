import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

/// SQLite-based recent conversations store
/// Replaces SharedPreferences-based RecentConversationsService
/// Provides atomic updates, proper sorting, and additional features
class SqliteRecentConversationsStore {
  static SqliteRecentConversationsStore? _instance;
  
  SqliteRecentConversationsStore._();
  
  static Future<SqliteRecentConversationsStore> getInstance() async {
    if (_instance == null) {
      _instance = SqliteRecentConversationsStore._();
      await _instance!._initialize();
    }
    return _instance!;
  }
  
  Future<void> _initialize() async {
    await DatabaseHelper.database;
    
    // Verify tables exist
    final isReady = await DatabaseHelper.isDatabaseReady();
    if (!isReady) {
      throw Exception('[SQLITE_CONVERSATIONS_STORE] Database tables not ready!');
    }
    
    debugPrint('[SQLITE_CONVERSATIONS_STORE] Initialized - Database ready');
  }

  /// Add or update a conversation (moves to top if exists)
  Future<void> addOrUpdateConversation({
    required String userId,
    required String displayName,
    String? picture,
    int unreadCount = 0,
    bool pinned = false,
  }) async {
    final db = await DatabaseHelper.database;
    
    await db.insert(
      'recent_conversations',
      {
        'user_id': userId,
        'display_name': displayName,
        'picture': picture,
        'last_message_at': DateTime.now().toIso8601String(),
        'unread_count': unreadCount,
        'pinned': pinned ? 1 : 0,
        'archived': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    debugPrint('[SQLITE_CONVERSATIONS_STORE] Updated conversation: $userId');
  }

  /// Get all recent conversations (sorted: pinned first, then by timestamp)
  Future<List<Map<String, dynamic>>> getRecentConversations({
    int? limit = 20,
    bool includeArchived = false,
  }) async {
    final db = await DatabaseHelper.database;
    
    String whereClause = includeArchived ? '' : 'archived = 0';
    
    final result = await db.query(
      'recent_conversations',
      where: whereClause.isEmpty ? null : whereClause,
      orderBy: 'pinned DESC, last_message_at DESC',
      limit: limit,
    );
    
    return result.map(_convertFromDb).toList();
  }

  /// Get a specific conversation
  Future<Map<String, dynamic>?> getConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    final result = await db.query(
      'recent_conversations',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    
    if (result.isEmpty) return null;
    return _convertFromDb(result.first);
  }

  /// Update conversation timestamp (when new message arrives)
  Future<void> updateTimestamp(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.update(
      'recent_conversations',
      {
        'last_message_at': DateTime.now().toIso8601String(),
      },
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  /// Increment unread count
  Future<void> incrementUnreadCount(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.rawUpdate('''
      UPDATE recent_conversations 
      SET unread_count = unread_count + 1,
          last_message_at = ?
      WHERE user_id = ?
    ''', [DateTime.now().toIso8601String(), userId]);
  }

  /// Reset unread count (when user opens conversation)
  Future<void> resetUnreadCount(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.update(
      'recent_conversations',
      {'unread_count': 0},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  /// Get total unread count across all conversations
  Future<int> getTotalUnreadCount() async {
    final db = await DatabaseHelper.database;
    
    final result = await db.rawQuery('''
      SELECT SUM(unread_count) as total 
      FROM recent_conversations 
      WHERE archived = 0
    ''');
    
    return (result.first['total'] as int?) ?? 0;
  }

  /// Pin a conversation
  Future<void> pinConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.update(
      'recent_conversations',
      {'pinned': 1},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  /// Unpin a conversation
  Future<void> unpinConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.update(
      'recent_conversations',
      {'pinned': 0},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  /// Archive a conversation
  Future<void> archiveConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.update(
      'recent_conversations',
      {'archived': 1},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  /// Unarchive a conversation
  Future<void> unarchiveConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.update(
      'recent_conversations',
      {'archived': 0},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  /// Remove a conversation
  Future<void> removeConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    await db.delete(
      'recent_conversations',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    
    debugPrint('[SQLITE_CONVERSATIONS_STORE] Removed conversation: $userId');
  }

  /// Clear all conversations
  Future<void> clearAll() async {
    final db = await DatabaseHelper.database;
    
    await db.delete('recent_conversations');
    
    debugPrint('[SQLITE_CONVERSATIONS_STORE] Cleared all conversations');
  }

  /// Get conversation statistics
  Future<Map<String, dynamic>> getStatistics() async {
    final db = await DatabaseHelper.database;
    
    final totalResult = await db.rawQuery('SELECT COUNT(*) as count FROM recent_conversations');
    final pinnedResult = await db.rawQuery('SELECT COUNT(*) as count FROM recent_conversations WHERE pinned = 1');
    final archivedResult = await db.rawQuery('SELECT COUNT(*) as count FROM recent_conversations WHERE archived = 1');
    final unreadResult = await db.rawQuery('SELECT SUM(unread_count) as total FROM recent_conversations');
    
    return {
      'total': totalResult.first['count'],
      'pinned': pinnedResult.first['count'],
      'archived': archivedResult.first['count'],
      'total_unread': unreadResult.first['total'] ?? 0,
    };
  }

  /// Convert database row to app format
  Map<String, dynamic> _convertFromDb(Map<String, dynamic> row) {
    return {
      'uuid': row['user_id'],
      'userId': row['user_id'],
      'displayName': row['display_name'],
      'picture': row['picture'],
      'lastMessageAt': row['last_message_at'],
      'unreadCount': row['unread_count'],
      'pinned': row['pinned'] == 1,
      'archived': row['archived'] == 1,
    };
  }
}

