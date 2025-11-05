import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

/// SQLite-based message store for both 1:1 and group messages
/// Replaces PermanentDecryptedMessagesStore and DecryptedGroupItemsStore
/// Provides fast queries with proper indexing
class SqliteMessageStore {
  static SqliteMessageStore? _instance;
  
  SqliteMessageStore._();
  
  static Future<SqliteMessageStore> getInstance() async {
    if (_instance == null) {
      _instance = SqliteMessageStore._();
      await _instance!._initialize();
    }
    return _instance!;
  }
  
  Future<void> _initialize() async {
    // Ensure database is created
    await DatabaseHelper.database;
    
    // Verify tables exist
    final isReady = await DatabaseHelper.isDatabaseReady();
    if (!isReady) {
      throw Exception('[SQLITE_MESSAGE_STORE] Database tables not ready!');
    }
    
    debugPrint('[SQLITE_MESSAGE_STORE] Initialized - Database ready');
  }

  /// Check if a message exists
  Future<bool> hasMessage(String itemId) async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'messages',
      where: 'item_id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  /// Get a specific message
  Future<Map<String, dynamic>?> getMessage(String itemId) async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'messages',
      where: 'item_id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    
    if (result.isEmpty) return null;
    return _convertFromDb(result.first);
  }

  /// Store a received message (1:1 or group)
  Future<void> storeReceivedMessage({
    required String itemId,
    required String message,
    required String sender,
    int? senderDeviceId,
    String? channelId,
    required String timestamp,
    required String type,
  }) async {
    final db = await DatabaseHelper.database;
    
    await db.insert(
      'messages',
      {
        'item_id': itemId,
        'message': message,
        'sender': sender,
        'sender_device_id': senderDeviceId,
        'channel_id': channelId,
        'timestamp': timestamp,
        'type': type,
        'direction': 'received',
        'decrypted_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    debugPrint('[SQLITE_MESSAGE_STORE] Stored received message: $itemId (type: $type, sender: $sender, channel: $channelId)');
  }

  /// Store a sent message (1:1 or group)
  Future<void> storeSentMessage({
    required String itemId,
    required String message,
    required String recipientId,
    String? channelId,
    required String timestamp,
    required String type,
  }) async {
    final db = await DatabaseHelper.database;
    
    await db.insert(
      'messages',
      {
        'item_id': itemId,
        'message': message,
        'sender': recipientId, // Store recipient as sender for query consistency
        'sender_device_id': null,
        'channel_id': channelId,
        'timestamp': timestamp,
        'type': type,
        'direction': 'sent',
        'decrypted_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    debugPrint('[SQLITE_MESSAGE_STORE] Stored sent message: $itemId (type: $type, recipient: $recipientId, channel: $channelId)');
  }

  /// Get all messages from a 1:1 conversation (both directions)
  Future<List<Map<String, dynamic>>> getMessagesFromConversation(
    String userId, {
    int? limit,
    int? offset,
    List<String>? types,
  }) async {
    final db = await DatabaseHelper.database;
    
    String whereClause = 'sender = ? AND channel_id IS NULL';
    List<dynamic> whereArgs = [userId];
    
    if (types != null && types.isNotEmpty) {
      final placeholders = types.map((_) => '?').join(',');
      whereClause += ' AND type IN ($placeholders)';
      whereArgs.addAll(types);
    }
    
    final result = await db.query(
      'messages',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    
    return result.map(_convertFromDb).toList();
  }

  /// Get all messages from a group/channel
  Future<List<Map<String, dynamic>>> getMessagesFromChannel(
    String channelId, {
    int? limit,
    int? offset,
    List<String>? types,
  }) async {
    final db = await DatabaseHelper.database;
    
    String whereClause = 'channel_id = ?';
    List<dynamic> whereArgs = [channelId];
    
    if (types != null && types.isNotEmpty) {
      final placeholders = types.map((_) => '?').join(',');
      whereClause += ' AND type IN ($placeholders)';
      whereArgs.addAll(types);
    }
    
    final result = await db.query(
      'messages',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    
    return result.map(_convertFromDb).toList();
  }

  /// Get all unique conversation partners (1:1 only)
  Future<Set<String>> getAllUniqueConversationPartners() async {
    final db = await DatabaseHelper.database;
    
    final result = await db.rawQuery('''
      SELECT DISTINCT sender 
      FROM messages 
      WHERE channel_id IS NULL 
        AND sender != 'self'
        AND type != 'read_receipt'
      ORDER BY timestamp DESC
    ''');
    
    return result.map((row) => row['sender'] as String).toSet();
  }

  /// Get all unique channels
  Future<Set<String>> getAllUniqueChannels() async {
    final db = await DatabaseHelper.database;
    
    final result = await db.rawQuery('''
      SELECT DISTINCT channel_id 
      FROM messages 
      WHERE channel_id IS NOT NULL
      ORDER BY timestamp DESC
    ''');
    
    return result
        .map((row) => row['channel_id'] as String?)
        .where((id) => id != null)
        .cast<String>()
        .toSet();
  }

  /// Get last message from a conversation
  Future<Map<String, dynamic>?> getLastMessage(String userId) async {
    final db = await DatabaseHelper.database;
    
    final result = await db.query(
      'messages',
      where: 'sender = ? AND channel_id IS NULL',
      whereArgs: [userId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    
    if (result.isEmpty) return null;
    return _convertFromDb(result.first);
  }

  /// Get last message from a channel
  Future<Map<String, dynamic>?> getLastChannelMessage(String channelId) async {
    final db = await DatabaseHelper.database;
    
    final result = await db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    
    if (result.isEmpty) return null;
    return _convertFromDb(result.first);
  }

  /// Count messages in a conversation
  Future<int> countConversationMessages(String userId) async {
    final db = await DatabaseHelper.database;
    
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count 
      FROM messages 
      WHERE sender = ? AND channel_id IS NULL
    ''', [userId]);
    
    return result.first['count'] as int;
  }

  /// Count messages in a channel
  Future<int> countChannelMessages(String channelId) async {
    final db = await DatabaseHelper.database;
    
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count 
      FROM messages 
      WHERE channel_id = ?
    ''', [channelId]);
    
    return result.first['count'] as int;
  }

  /// Delete a specific message
  Future<void> deleteMessage(String itemId) async {
    final db = await DatabaseHelper.database;
    
    await db.delete(
      'messages',
      where: 'item_id = ?',
      whereArgs: [itemId],
    );
    
    debugPrint('[SQLITE_MESSAGE_STORE] Deleted message: $itemId');
  }

  /// Delete all messages from a conversation
  Future<void> deleteConversation(String userId) async {
    final db = await DatabaseHelper.database;
    
    final count = await db.delete(
      'messages',
      where: 'sender = ? AND channel_id IS NULL',
      whereArgs: [userId],
    );
    
    debugPrint('[SQLITE_MESSAGE_STORE] Deleted $count messages from conversation: $userId');
  }

  /// Delete all messages from a channel
  Future<void> deleteChannel(String channelId) async {
    final db = await DatabaseHelper.database;
    
    final count = await db.delete(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    
    debugPrint('[SQLITE_MESSAGE_STORE] Deleted $count messages from channel: $channelId');
  }

  /// Clear all messages
  Future<void> clearAll() async {
    final db = await DatabaseHelper.database;
    
    await db.delete('messages');
    
    debugPrint('[SQLITE_MESSAGE_STORE] Cleared all messages');
  }

  /// Get database statistics
  Future<Map<String, dynamic>> getStatistics() async {
    final db = await DatabaseHelper.database;
    
    final totalResult = await db.rawQuery('SELECT COUNT(*) as count FROM messages');
    final conversationsResult = await db.rawQuery('''
      SELECT COUNT(DISTINCT sender) as count 
      FROM messages 
      WHERE channel_id IS NULL AND sender != 'self'
    ''');
    final channelsResult = await db.rawQuery('''
      SELECT COUNT(DISTINCT channel_id) as count 
      FROM messages 
      WHERE channel_id IS NOT NULL
    ''');
    
    return {
      'total_messages': totalResult.first['count'],
      'conversations': conversationsResult.first['count'],
      'channels': channelsResult.first['count'],
    };
  }

  /// Convert database row to app format
  Map<String, dynamic> _convertFromDb(Map<String, dynamic> row) {
    return {
      'itemId': row['item_id'],
      'message': row['message'],
      'sender': row['sender'],
      'senderDeviceId': row['sender_device_id'],
      'channelId': row['channel_id'],
      'timestamp': row['timestamp'],
      'type': row['type'],
      'direction': row['direction'],
      'decryptedAt': row['decrypted_at'],
    };
  }
}

