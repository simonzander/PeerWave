import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'permanent_sent_messages_store.dart';
import 'permanent_decrypted_messages_store.dart';
import 'sent_group_items_store.dart';
import 'decrypted_group_items_store.dart';
import 'storage/database_helper.dart';

/// Service für automatisches Löschen alter Messages
class MessageCleanupService {
  static final MessageCleanupService instance = MessageCleanupService._internal();
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
    debugPrint('[CLEANUP] Starting message cleanup for messages older than $days days');
    
    final cutoffDate = DateTime.now().subtract(Duration(days: days));
    final cutoffTimestamp = cutoffDate.toIso8601String();
    
    // Clean up SQLite database (new storage)
    await _cleanupSqliteMessages(cutoffTimestamp);
    
    // Clean up old storage (for backward compatibility during migration)
    // 1. Cleanup sent 1:1 messages
    await _cleanupSentMessages(cutoffTimestamp);
    
    // 2. Cleanup received 1:1 messages
    await _cleanupDecryptedMessages(cutoffTimestamp);
    
    // 3. Cleanup sent group messages
    await _cleanupSentGroupMessages(cutoffTimestamp);
    
    // 4. Cleanup received group messages
    await _cleanupDecryptedGroupMessages(cutoffTimestamp);
    
    debugPrint('[CLEANUP] Cleanup completed');
  }

  Future<void> _cleanupSqliteMessages(String cutoffTimestamp) async {
    try {
      final db = await DatabaseHelper.database;
      
      // Check if messages table exists
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='messages'"
      );
      
      if (tables.isEmpty) {
        debugPrint('[CLEANUP] SQLite messages table does not exist yet, skipping SQLite cleanup');
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
        "SELECT name FROM sqlite_master WHERE type='table' AND name='recent_conversations'"
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
        
        debugPrint('[CLEANUP] Cleaned up ${conversationsWithNoMessages.length} empty conversations from SQLite');
      }
    } catch (e, stackTrace) {
      debugPrint('[CLEANUP] Error cleaning up SQLite messages: $e');
      debugPrint('[CLEANUP] Stack trace: $stackTrace');
    }
  }

  Future<void> _cleanupSentMessages(String cutoffTimestamp) async {
    try {
      final store = await PermanentSentMessagesStore.create();
      final allMessages = await store.loadAllSentMessages();
      
      int deleted = 0;
      for (var msg in allMessages) {
        final timestamp = msg['timestamp'] as String?;
        if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
          await store.deleteSentMessage(msg['itemId'], recipientUserId: msg['recipientUserId']);
          deleted++;
        }
      }
      
      debugPrint('[CLEANUP] Deleted $deleted old sent 1:1 messages');
    } catch (e) {
      debugPrint('[CLEANUP] Error cleaning up sent messages: $e');
    }
  }

  Future<void> _cleanupDecryptedMessages(String cutoffTimestamp) async {
    try {
      final store = await PermanentDecryptedMessagesStore.create();
      final senders = await store.getAllUniqueSenders();
      
      int deleted = 0;
      for (var sender in senders) {
        final messages = await store.getMessagesFromSender(sender);
        for (var msg in messages) {
          final timestamp = msg['timestamp'] as String?;
          if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
            await store.deleteDecryptedMessage(msg['itemId']);
            deleted++;
          }
        }
      }
      
      debugPrint('[CLEANUP] Deleted $deleted old received 1:1 messages');
    } catch (e) {
      debugPrint('[CLEANUP] Error cleaning up decrypted messages: $e');
    }
  }

  Future<void> _cleanupSentGroupMessages(String cutoffTimestamp) async {
    try {
      final store = await SentGroupItemsStore.getInstance();
      final channels = await store.getAllChannels();
      
      int deleted = 0;
      for (var channelId in channels) {
        final messages = await store.loadSentItems(channelId);
        for (var msg in messages) {
          final timestamp = msg['timestamp'] as String?;
          if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
            await store.clearChannelItem(msg['itemId'], channelId);
            deleted++;
          }
        }
      }
      
      debugPrint('[CLEANUP] Deleted $deleted old sent group messages');
    } catch (e) {
      debugPrint('[CLEANUP] Error cleaning up sent group messages: $e');
    }
  }

  Future<void> _cleanupDecryptedGroupMessages(String cutoffTimestamp) async {
    try {
      final store = await DecryptedGroupItemsStore.getInstance();
      final channels = await store.getAllChannels();
      
      int deleted = 0;
      for (var channelId in channels) {
        final messages = await store.getChannelItems(channelId);
        for (var msg in messages) {
          final timestamp = msg['timestamp'] as String?;
          if (timestamp != null && timestamp.compareTo(cutoffTimestamp) < 0) {
            await store.clearItem(msg['itemId'], channelId);
            deleted++;
          }
        }
      }
      
      debugPrint('[CLEANUP] Deleted $deleted old received group messages');
    } catch (e) {
      debugPrint('[CLEANUP] Error cleaning up decrypted group messages: $e');
    }
  }
}

