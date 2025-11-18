import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';
import 'database_encryption_service.dart';

/// SQLite-based store for group messages
/// Uses the same messages table but with channel_id set
/// Message content is encrypted using DatabaseEncryptionService
class SqliteGroupMessageStore {
  static SqliteGroupMessageStore? _instance;
  static final DatabaseEncryptionService _encryption = DatabaseEncryptionService.instance;

  SqliteGroupMessageStore._();

  static Future<SqliteGroupMessageStore> getInstance() async {
    if (_instance != null) return _instance!;
    _instance = SqliteGroupMessageStore._();
    
    // Validate database is ready
    await DatabaseHelper.database;
    final ready = await DatabaseHelper.isDatabaseReady();
    if (!ready) {
      throw Exception('[GROUP STORE] Database not properly initialized');
    }
    
    debugPrint('[GROUP STORE] ✓ Initialized SqliteGroupMessageStore');
    return _instance!;
  }

  /// Store a decrypted group message
  Future<void> storeDecryptedGroupItem({
    required String itemId,
    required String channelId,
    required String sender,
    required int senderDevice,
    required String message,
    required String timestamp,
    String type = 'message',
  }) async {
    try {
      final db = await DatabaseHelper.database;
      
      // Encrypt the message content before storage
      final encryptedMessage = await _encryption.encryptString(message);
      
      await db.insert(
        'messages',
        {
          'item_id': itemId,
          'message': encryptedMessage, // Stored as encrypted BLOB
          'sender': sender,
          'sender_device_id': senderDevice,
          'channel_id': channelId,
          'timestamp': timestamp,
          'type': type,
          'direction': 'received', // Group messages are always received
          'decrypted_at': DateTime.now().toIso8601String(),
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      debugPrint('[GROUP STORE] ✓ Stored encrypted group message $itemId in channel $channelId');
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error storing group message: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Store a sent group message
  Future<void> storeSentGroupItem({
    required String itemId,
    required String channelId,
    required String message,
    required String timestamp,
    String type = 'message',
  }) async {
    try {
      final db = await DatabaseHelper.database;
      
      // Encrypt the message content before storage
      final encryptedMessage = await _encryption.encryptString(message);
      
      await db.insert(
        'messages',
        {
          'item_id': itemId,
          'message': encryptedMessage, // Stored as encrypted BLOB
          'sender': 'me', // Sender for sent messages
          'sender_device_id': null,
          'channel_id': channelId,
          'timestamp': timestamp,
          'type': type,
          'direction': 'sent',
          'decrypted_at': DateTime.now().toIso8601String(),
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      debugPrint('[GROUP STORE] ✓ Stored encrypted sent group message $itemId in channel $channelId');
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error storing sent group message: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Get all messages for a specific channel
  Future<List<Map<String, dynamic>>> getChannelMessages(String channelId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final results = await db.query(
        'messages',
        where: 'channel_id = ?',
        whereArgs: [channelId],
        orderBy: 'timestamp DESC',
      );
      
      // Decrypt message content for each result
      final decryptedResults = <Map<String, dynamic>>[];
      for (var row in results) {
        final decryptedRow = Map<String, dynamic>.from(row);
        if (row['message'] != null) {
          try {
            decryptedRow['message'] = await _encryption.decryptString(row['message']);
          } catch (e) {
            debugPrint('[GROUP STORE] ⚠ Failed to decrypt message ${row['item_id']}: $e');
            decryptedRow['message'] = '[Decryption failed]';
          }
        }
        decryptedResults.add(decryptedRow);
      }
      
      debugPrint('[GROUP STORE] ✓ Retrieved and decrypted ${decryptedResults.length} messages for channel $channelId');
      return decryptedResults;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting channel messages: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Get a specific group message by item ID
  Future<Map<String, dynamic>?> getGroupItem(String channelId, String itemId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final results = await db.query(
        'messages',
        where: 'item_id = ? AND channel_id = ?',
        whereArgs: [itemId, channelId],
        limit: 1,
      );
      
      if (results.isEmpty) {
        debugPrint('[GROUP STORE] ⚠ Message not found: $itemId in channel $channelId');
        return null;
      }
      
      // Decrypt message content
      final row = results.first;
      final decryptedRow = Map<String, dynamic>.from(row);
      if (row['message'] != null) {
        try {
          decryptedRow['message'] = await _encryption.decryptString(row['message']);
        } catch (e) {
          debugPrint('[GROUP STORE] ⚠ Failed to decrypt message $itemId: $e');
          decryptedRow['message'] = '[Decryption failed]';
        }
      }
      
      return decryptedRow;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting group item: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Get all unique channels (groups) the user is part of
  Future<List<String>> getAllChannels() async {
    try {
      final db = await DatabaseHelper.database;
      
      final results = await db.rawQuery('''
        SELECT DISTINCT channel_id
        FROM messages
        WHERE channel_id IS NOT NULL
        ORDER BY timestamp DESC
      ''');
      
      final channels = results
          .map((row) => row['channel_id'] as String)
          .toList();
      
      debugPrint('[GROUP STORE] ✓ Retrieved ${channels.length} unique channels');
      return channels;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting channels: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Get messages by type (e.g., 'message', 'reaction', 'edit')
  Future<List<Map<String, dynamic>>> getMessagesByType(
    String channelId,
    String type,
  ) async {
    try {
      final db = await DatabaseHelper.database;
      
      final results = await db.query(
        'messages',
        where: 'channel_id = ? AND type = ?',
        whereArgs: [channelId, type],
        orderBy: 'timestamp DESC',
      );
      
      // Decrypt message content for each result
      final decryptedResults = <Map<String, dynamic>>[];
      for (var row in results) {
        final decryptedRow = Map<String, dynamic>.from(row);
        if (row['message'] != null) {
          try {
            decryptedRow['message'] = await _encryption.decryptString(row['message']);
          } catch (e) {
            debugPrint('[GROUP STORE] ⚠ Failed to decrypt message ${row['item_id']}: $e');
            decryptedRow['message'] = '[Decryption failed]';
          }
        }
        decryptedResults.add(decryptedRow);
      }
      
      debugPrint('[GROUP STORE] ✓ Retrieved and decrypted ${decryptedResults.length} messages of type $type');
      return decryptedResults;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting messages by type: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Get messages from a specific sender in a channel
  Future<List<Map<String, dynamic>>> getMessagesBySender(
    String channelId,
    String sender,
  ) async {
    try {
      final db = await DatabaseHelper.database;
      
      final results = await db.query(
        'messages',
        where: 'channel_id = ? AND sender = ?',
        whereArgs: [channelId, sender],
        orderBy: 'timestamp DESC',
      );
      
      // Decrypt message content for each result
      final decryptedResults = <Map<String, dynamic>>[];
      for (var row in results) {
        final decryptedRow = Map<String, dynamic>.from(row);
        if (row['message'] != null) {
          try {
            decryptedRow['message'] = await _encryption.decryptString(row['message']);
          } catch (e) {
            debugPrint('[GROUP STORE] ⚠ Failed to decrypt message ${row['item_id']}: $e');
            decryptedRow['message'] = '[Decryption failed]';
          }
        }
        decryptedResults.add(decryptedRow);
      }
      
      debugPrint('[GROUP STORE] ✓ Retrieved and decrypted ${decryptedResults.length} messages from $sender');
      return decryptedResults;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting messages by sender: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Delete a specific message
  Future<void> deleteGroupItem(String channelId, String itemId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final deleted = await db.delete(
        'messages',
        where: 'item_id = ? AND channel_id = ?',
        whereArgs: [itemId, channelId],
      );
      
      if (deleted > 0) {
        debugPrint('[GROUP STORE] ✓ Deleted message $itemId');
      } else {
        debugPrint('[GROUP STORE] ⚠ Message not found: $itemId');
      }
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error deleting message: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Delete all messages from a channel
  Future<void> deleteChannelMessages(String channelId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final deleted = await db.delete(
        'messages',
        where: 'channel_id = ?',
        whereArgs: [channelId],
      );
      
      debugPrint('[GROUP STORE] ✓ Deleted $deleted messages from channel $channelId');
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error deleting channel messages: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Get message count for a channel
  Future<int> getChannelMessageCount(String channelId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final result = await db.rawQuery('''
        SELECT COUNT(*) as count
        FROM messages
        WHERE channel_id = ?
      ''', [channelId]);
      
      final count = result.first['count'] as int;
      debugPrint('[GROUP STORE] ✓ Channel $channelId has $count messages');
      return count;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting message count: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return 0;
    }
  }

  /// Get the last message in a channel
  Future<Map<String, dynamic>?> getLastChannelMessage(String channelId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final results = await db.query(
        'messages',
        where: 'channel_id = ?',
        whereArgs: [channelId],
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      
      if (results.isEmpty) {
        return null;
      }
      
      // Decrypt message content
      final row = results.first;
      final decryptedRow = Map<String, dynamic>.from(row);
      if (row['message'] != null) {
        try {
          decryptedRow['message'] = await _encryption.decryptString(row['message']);
        } catch (e) {
          debugPrint('[GROUP STORE] ⚠ Failed to decrypt last message: $e');
          decryptedRow['message'] = '[Decryption failed]';
        }
      }
      
      return decryptedRow;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error getting last message: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Mark that a read receipt has been sent for this message
  /// Prevents sending duplicate read receipts on page reload
  Future<void> markReadReceiptSent(String itemId) async {
    try {
      final db = await DatabaseHelper.database;
      
      await db.update(
        'messages',
        {'read_receipt_sent': 1},
        where: 'item_id = ?',
        whereArgs: [itemId],
      );
      
      debugPrint('[GROUP STORE] ✓ Marked read receipt sent for itemId: $itemId');
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error marking read receipt sent: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Check if read receipt was already sent for this message
  Future<bool> hasReadReceiptBeenSent(String itemId) async {
    try {
      final db = await DatabaseHelper.database;
      
      final result = await db.query(
        'messages',
        columns: ['read_receipt_sent'],
        where: 'item_id = ?',
        whereArgs: [itemId],
      );
      
      if (result.isEmpty) return false;
      
      final flag = result.first['read_receipt_sent'];
      return flag == 1 || flag == true;
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error checking read receipt: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Mark message as read (updates status field)
  Future<void> markAsRead(String itemId) async {
    try {
      final db = await DatabaseHelper.database;
      
      await db.update(
        'messages',
        {'status': 'read'},
        where: 'item_id = ?',
        whereArgs: [itemId],
      );
      
      debugPrint('[GROUP STORE] ✓ Marked message as read: $itemId');
    } catch (e, stackTrace) {
      debugPrint('[GROUP STORE] ✗ Error marking message as read: $e');
      debugPrint('[GROUP STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }
}

