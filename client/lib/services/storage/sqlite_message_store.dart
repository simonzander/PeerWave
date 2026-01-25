import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'database_helper.dart';
import 'database_encryption_service.dart';
import '../user_profile_service.dart';

/// SQLite-based message store for both 1:1 and group messages
/// Replaces PermanentDecryptedMessagesStore and DecryptedGroupItemsStore
/// Provides fast queries with proper indexing
/// Messages are encrypted at rest using WebAuthn-derived keys
class SqliteMessageStore {
  static SqliteMessageStore? _instance;
  final DatabaseEncryptionService _encryption =
      DatabaseEncryptionService.instance;

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

    // Clean up legacy system messages that were stored before filtering was added
    await _cleanupLegacySystemMessages();

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Initialized - Database ready with encryption',
    );
  }

  /// Remove system messages from database (one-time cleanup)
  /// These messages were stored before the isSystemMessage filter was added
  Future<void> _cleanupLegacySystemMessages() async {
    try {
      final db = await DatabaseHelper.database;

      // Delete read receipts, delivery receipts, and key request messages
      final deletedCount = await db.delete(
        'messages',
        where: 'type IN (?, ?, ?, ?)',
        whereArgs: [
          'read_receipt',
          'delivery_receipt',
          'senderKeyRequest',
          'fileKeyRequest',
        ],
      );

      if (deletedCount > 0) {
        debugPrint(
          '[SQLITE_MESSAGE_STORE] 🧹 Cleaned up $deletedCount legacy system messages',
        );
      }
    } catch (e) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ⚠️ Error cleaning up system messages: $e',
      );
      // Non-critical, don't throw
    }
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

    final converted = await _convertFromDb(result.first);
    if (converted == null) {
      // Failed to decrypt, delete it
      await deleteMessage(itemId);
    }
    return converted;
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
    String? status, // Optional status (e.g., 'decrypt_failed')
    Map<String, dynamic>? metadata,
  }) async {
    final db = await DatabaseHelper.database;

    // Log which database we're saving to
    final dbName = DatabaseHelper.getDatabaseName();
    debugPrint(
      '[SQLITE_MESSAGE_STORE] 💾 Storing RECEIVED message to: $dbName',
    );
    debugPrint(
      '[SQLITE_MESSAGE_STORE] 📥 ItemId: $itemId, Sender: $sender, Type: $type',
    );

    // Encrypt the message content
    final encryptedMessage = await _encryption.encryptString(message);

    await db.insert('messages', {
      'item_id': itemId,
      'message': encryptedMessage, // BLOB - encrypted
      'sender': sender,
      'sender_device_id': senderDeviceId,
      'channel_id': channelId,
      'timestamp': timestamp,
      'type': type,
      'direction': 'received',
      if (status != null) 'status': status, // Add status if provided
      'metadata': metadata != null ? jsonEncode(metadata) : null,
      'decrypted_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Stored received message: $itemId (type: $type, sender: $sender, channel: $channelId) [ENCRYPTED]',
    );
  }

  /// Store a sent message (1:1 or group)
  Future<void> storeSentMessage({
    required String itemId,
    required String message,
    required String recipientId,
    String? channelId,
    required String timestamp,
    required String type,
    String status = 'sent', // Default status for sent messages
    Map<String, dynamic>? metadata,
  }) async {
    final db = await DatabaseHelper.database;

    // Log which database we're saving to
    final dbName = DatabaseHelper.getDatabaseName();
    debugPrint('[SQLITE_MESSAGE_STORE] 💾 Storing SENT message to: $dbName');
    debugPrint(
      '[SQLITE_MESSAGE_STORE] 📤 ItemId: $itemId, Recipient: $recipientId, Type: $type',
    );

    // Validate message size (2MB limit)
    final messageBytes = utf8.encode(message).length;
    if (messageBytes > 2 * 1024 * 1024) {
      throw Exception(
        'Message too large (${(messageBytes / 1024 / 1024).toStringAsFixed(2)}MB, max 2MB)',
      );
    }

    // Encrypt the message content
    final encryptedMessage = await _encryption.encryptString(message);

    await db.insert('messages', {
      'item_id': itemId,
      'message': encryptedMessage, // BLOB - encrypted
      'sender': recipientId, // Store recipient as sender for query consistency
      'sender_device_id': null,
      'channel_id': channelId,
      'timestamp': timestamp,
      'type': type,
      'direction': 'sent',
      'status': status, // Store message status
      'metadata': metadata != null ? jsonEncode(metadata) : null,
      'decrypted_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Stored sent message: $itemId (type: $type, status: $status, recipient: $recipientId, channel: $channelId) [ENCRYPTED]',
    );
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

    // Decrypt all messages and delete those that fail
    final decryptedMessages = <Map<String, dynamic>>[];
    final messagesToDelete = <String>[];

    for (final row in result) {
      final converted = await _convertFromDb(row);
      if (converted != null) {
        decryptedMessages.add(converted);
      } else {
        // Mark for deletion
        messagesToDelete.add(row['item_id'] as String);
      }
    }

    // Delete messages that couldn't be decrypted
    if (messagesToDelete.isNotEmpty) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] 🗑️ Deleting ${messagesToDelete.length} 1:1 messages that failed decryption',
      );
      for (final itemId in messagesToDelete) {
        await deleteMessage(itemId);
      }
    }

    return decryptedMessages;
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

    // Decrypt all messages and delete those that fail
    final decryptedMessages = <Map<String, dynamic>>[];
    final messagesToDelete = <String>[];

    for (final row in result) {
      final converted = await _convertFromDb(row);
      if (converted != null) {
        decryptedMessages.add(converted);
      } else {
        // Mark for deletion
        messagesToDelete.add(row['item_id'] as String);
      }
    }

    // Delete messages that couldn't be decrypted
    if (messagesToDelete.isNotEmpty) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] 🗑️ Deleting ${messagesToDelete.length} channel messages that failed decryption',
      );
      for (final itemId in messagesToDelete) {
        await deleteMessage(itemId);
      }
    }

    return decryptedMessages;
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

    final converted = await _convertFromDb(result.first);
    if (converted == null) {
      // Failed to decrypt, delete it
      await deleteMessage(result.first['item_id'] as String);
    }
    return converted;
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

    final converted = await _convertFromDb(result.first);
    if (converted == null) {
      // Failed to decrypt, delete it
      await deleteMessage(result.first['item_id'] as String);
    }
    return converted;
  }

  /// Count messages in a conversation
  Future<int> countConversationMessages(String userId) async {
    final db = await DatabaseHelper.database;

    final result = await db.rawQuery(
      '''
      SELECT COUNT(*) as count 
      FROM messages 
      WHERE sender = ? AND channel_id IS NULL
    ''',
      [userId],
    );

    return result.first['count'] as int;
  }

  /// Count messages in a channel
  Future<int> countChannelMessages(String channelId) async {
    final db = await DatabaseHelper.database;

    final result = await db.rawQuery(
      '''
      SELECT COUNT(*) as count 
      FROM messages 
      WHERE channel_id = ?
    ''',
      [channelId],
    );

    return result.first['count'] as int;
  }

  /// Delete a specific message
  Future<void> deleteMessage(String itemId) async {
    final db = await DatabaseHelper.database;

    await db.delete('messages', where: 'item_id = ?', whereArgs: [itemId]);

    debugPrint('[SQLITE_MESSAGE_STORE] Deleted message: $itemId');
  }

  /// Update message status (for sent messages)
  Future<void> updateMessageStatus(String itemId, String status) async {
    final db = await DatabaseHelper.database;

    final count = await db.update(
      'messages',
      {'status': status},
      where: 'item_id = ? AND direction = ?',
      whereArgs: [itemId, 'sent'],
    );

    if (count > 0) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] Updated message status: $itemId → $status',
      );
    } else {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ⚠️ Message not found for status update: $itemId',
      );
    }
  }

  /// Mark message as delivered
  Future<void> markAsDelivered(String itemId) async {
    await updateMessageStatus(itemId, 'delivered');
  }

  /// Mark message as read
  Future<void> markAsRead(String itemId) async {
    await updateMessageStatus(itemId, 'read');
  }

  /// Mark that a read receipt has been sent for this message
  /// Prevents sending duplicate read receipts on page reload
  Future<void> markReadReceiptSent(String itemId) async {
    final db = await DatabaseHelper.database;

    await db.update(
      'messages',
      {'read_receipt_sent': 1},
      where: 'item_id = ?',
      whereArgs: [itemId],
    );

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Marked read receipt sent for itemId: $itemId',
    );
  }

  /// Check if read receipt was already sent for this message
  Future<bool> hasReadReceiptBeenSent(String itemId) async {
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
  }

  /// Delete all messages from a conversation
  Future<void> deleteConversation(String userId) async {
    final db = await DatabaseHelper.database;
    final currentUserId = UserProfileService.instance.currentUserUuid;

    if (currentUserId == null) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] Cannot delete conversation: current user ID not available',
      );
      return;
    }

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Deleting conversation: currentUser=$currentUserId, otherUser=$userId',
    );

    // Check sent vs received breakdown
    final sentCount = await db.rawQuery(
      '''
      SELECT COUNT(*) as count FROM messages 
      WHERE sender = ? AND direction = 'sent' AND channel_id IS NULL
    ''',
      [userId],
    );

    final receivedCount = await db.rawQuery(
      '''
      SELECT COUNT(*) as count FROM messages 
      WHERE sender = ? AND direction = 'received' AND channel_id IS NULL
    ''',
      [userId],
    );

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Found ${sentCount.first['count']} sent messages to $userId',
    );
    debugPrint(
      '[SQLITE_MESSAGE_STORE] Found ${receivedCount.first['count']} received messages from $userId',
    );

    // Delete all messages in this conversation (both sent and received)
    // Since sent messages store recipient as sender, both have sender = userId
    final count = await db.delete(
      'messages',
      where: 'sender = ? AND channel_id IS NULL',
      whereArgs: [userId],
    );

    // Verify deletion
    final countAfter = await db.rawQuery(
      '''
      SELECT COUNT(*) as count FROM messages 
      WHERE sender = ? AND channel_id IS NULL
    ''',
      [userId],
    );

    debugPrint(
      '[SQLITE_MESSAGE_STORE] ✓ Deleted $count messages from conversation with: $userId',
    );
    debugPrint(
      '[SQLITE_MESSAGE_STORE] Remaining messages: ${countAfter.first['count']}',
    );
  }

  /// Delete all messages from a channel
  Future<void> deleteChannel(String channelId) async {
    final db = await DatabaseHelper.database;

    final count = await db.delete(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );

    debugPrint(
      '[SQLITE_MESSAGE_STORE] Deleted $count messages from channel: $channelId',
    );
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

    final totalResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages',
    );
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
  /// Returns null if decryption fails (message should be deleted)
  Future<Map<String, dynamic>?> _convertFromDb(Map<String, dynamic> row) async {
    // Decrypt the message content (stored as BLOB)
    final encryptedMessage = row['message'];
    String? decryptedMessage;

    try {
      decryptedMessage = await _encryption.decryptString(encryptedMessage);
    } catch (e) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ⚠️ Decryption failed for message ${row['item_id']}: $e',
      );
      debugPrint(
        '[SQLITE_MESSAGE_STORE] 🗑️ Message will be deleted (cannot decrypt)',
      );
      return null; // Signal that this message should be deleted
    }

    // Parse metadata if present
    Map<String, dynamic>? metadata;
    if (row['metadata'] != null) {
      try {
        metadata = jsonDecode(row['metadata']);
      } catch (e) {
        debugPrint('[SQLITE_MESSAGE_STORE] Failed to parse metadata: $e');
      }
    }

    return {
      'itemId': row['item_id'],
      'item_id': row['item_id'], // Keep snake_case for compatibility
      'message': decryptedMessage, // Decrypted string
      'sender': row['sender'],
      'senderDeviceId': row['sender_device_id'],
      'channelId': row['channel_id'],
      'timestamp': row['timestamp'],
      'type': row['type'],
      'direction': row['direction'],
      'status': row['status'], // Include status for sent messages
      'decryptedAt': row['decrypted_at'],
      'metadata': metadata, // Include parsed metadata for image/voice messages
      'reactions': row['reactions'] ?? '{}', // Include reactions
    };
  }

  /// Get notification messages for DMs (emote, mention, missingcall, etc.)
  /// These are stored in same messages table but filtered by type and channel_id IS NULL
  Future<List<Map<String, dynamic>>> getNotificationMessages({
    List<String>? types,
    bool unreadOnly = false,
    int limit = 100,
  }) async {
    try {
      final db = await DatabaseHelper.database;

      final notificationTypes =
          types ??
          [
            'emote',
            'mention',
            'missingcall',
            'addtochannel',
            'removefromchannel',
            'permissionchange',
          ];

      final placeholders = List.filled(notificationTypes.length, '?').join(',');
      String whereClause =
          'type IN ($placeholders) AND channel_id IS NULL AND direction = ?';
      List<dynamic> whereArgs = [...notificationTypes, 'received'];

      if (unreadOnly) {
        whereClause += ' AND (status IS NULL OR status != ?)';
        whereArgs.add('read');
      }

      final results = await db.query(
        'messages',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
      );

      // Decrypt and convert each result
      final decryptedResults = <Map<String, dynamic>>[];
      final messagesToDelete = <String>[];

      for (var row in results) {
        final converted = await _convertFromDb(row);
        if (converted != null) {
          decryptedResults.add(converted);
        } else {
          // Mark for deletion
          messagesToDelete.add(row['item_id'] as String);
        }
      }

      // Delete messages that couldn't be decrypted
      if (messagesToDelete.isNotEmpty) {
        debugPrint(
          '[SQLITE_MESSAGE_STORE] 🗑️ Deleting ${messagesToDelete.length} notification messages that failed decryption',
        );
        for (final itemId in messagesToDelete) {
          await deleteMessage(itemId);
        }
      }

      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✓ Retrieved ${decryptedResults.length} DM notification messages',
      );
      return decryptedResults;
    } catch (e, stackTrace) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✗ Error getting DM notification messages: $e',
      );
      debugPrint('[SQLITE_MESSAGE_STORE] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Mark a specific notification as read
  Future<void> markNotificationAsRead(String itemId) async {
    try {
      final db = await DatabaseHelper.database;

      await db.update(
        'messages',
        {'status': 'read'},
        where: 'item_id = ?',
        whereArgs: [itemId],
      );

      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✓ Marked notification as read: $itemId',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✗ Error marking notification as read: $e',
      );
      debugPrint('[SQLITE_MESSAGE_STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Mark all notifications as read for DMs
  Future<void> markAllNotificationsAsRead({List<String>? types}) async {
    try {
      final db = await DatabaseHelper.database;

      final notificationTypes =
          types ??
          [
            'emote',
            'mention',
            'missingcall',
            'addtochannel',
            'removefromchannel',
            'permissionchange',
          ];

      final placeholders = List.filled(notificationTypes.length, '?').join(',');
      final whereClause = 'type IN ($placeholders) AND channel_id IS NULL';

      await db.update(
        'messages',
        {'status': 'read'},
        where: whereClause,
        whereArgs: notificationTypes,
      );

      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✓ Marked all DM notifications as read',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✗ Error marking all DM notifications as read: $e',
      );
      debugPrint('[SQLITE_MESSAGE_STORE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Get unread notification messages for a specific user (for auto-mark when opening conversation)
  Future<List<Map<String, dynamic>>> getUnreadNotificationsForUser(
    String userId,
  ) async {
    try {
      final db = await DatabaseHelper.database;

      final notificationTypes = [
        'emote',
        'mention',
        'missingcall',
        'addtochannel',
        'removefromchannel',
        'permissionchange',
      ];

      final placeholders = List.filled(notificationTypes.length, '?').join(',');
      final whereClause =
          'type IN ($placeholders) AND sender = ? AND channel_id IS NULL AND (status IS NULL OR status != ?)';
      final whereArgs = [...notificationTypes, userId, 'read'];

      final results = await db.query(
        'messages',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
      );

      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✓ Found ${results.length} unread notifications for user $userId',
      );
      return results;
    } catch (e, stackTrace) {
      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✗ Error getting unread notifications for user: $e',
      );
      debugPrint('[SQLITE_MESSAGE_STORE] Stack trace: $stackTrace');
      return [];
    }
  }

  // =========================================================================
  // EMOJI REACTIONS
  // =========================================================================

  /// Add a reaction to a message
  Future<void> addReaction(
    String messageId,
    String emoji,
    String userId,
  ) async {
    try {
      final db = await DatabaseHelper.database;

      // Get current reactions
      final reactions = await getReactions(messageId);

      // Add user to emoji list (using Set to prevent duplicates)
      if (reactions.containsKey(emoji)) {
        final users = Set<String>.from(reactions[emoji] as List);
        users.add(userId);
        reactions[emoji] = users.toList();
      } else {
        reactions[emoji] = [userId];
      }

      // Update in database
      await db.update(
        'messages',
        {'reactions': jsonEncode(reactions)},
        where: 'item_id = ?',
        whereArgs: [messageId],
      );

      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✓ Added reaction $emoji from $userId to message $messageId',
      );
    } catch (e) {
      debugPrint('[SQLITE_MESSAGE_STORE] ✗ Error adding reaction: $e');
    }
  }

  /// Remove a reaction from a message
  Future<void> removeReaction(
    String messageId,
    String emoji,
    String userId,
  ) async {
    try {
      final db = await DatabaseHelper.database;

      // Get current reactions
      final reactions = await getReactions(messageId);

      // Remove user from emoji list
      if (reactions.containsKey(emoji)) {
        final users = Set<String>.from(reactions[emoji] as List);
        users.remove(userId);

        if (users.isEmpty) {
          // Remove emoji entirely if no users left
          reactions.remove(emoji);
        } else {
          reactions[emoji] = users.toList();
        }

        // Update in database
        await db.update(
          'messages',
          {'reactions': jsonEncode(reactions)},
          where: 'item_id = ?',
          whereArgs: [messageId],
        );

        debugPrint(
          '[SQLITE_MESSAGE_STORE] ✓ Removed reaction $emoji from $userId from message $messageId',
        );
      }
    } catch (e) {
      debugPrint('[SQLITE_MESSAGE_STORE] ✗ Error removing reaction: $e');
    }
  }

  /// Get all reactions for a message
  /// Returns: `Map<emoji, List<userId>>`
  Future<Map<String, dynamic>> getReactions(String messageId) async {
    try {
      final db = await DatabaseHelper.database;

      final result = await db.query(
        'messages',
        columns: ['reactions'],
        where: 'item_id = ?',
        whereArgs: [messageId],
        limit: 1,
      );

      if (result.isEmpty) {
        return {};
      }

      final reactionsJson = result.first['reactions'] as String?;
      if (reactionsJson == null ||
          reactionsJson.isEmpty ||
          reactionsJson == '{}') {
        return {};
      }

      return jsonDecode(reactionsJson) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[SQLITE_MESSAGE_STORE] ✗ Error getting reactions: $e');
      return {};
    }
  }

  /// Update reactions for a message (bulk update)
  Future<void> updateReactions(
    String messageId,
    Map<String, dynamic> reactions,
  ) async {
    try {
      final db = await DatabaseHelper.database;

      await db.update(
        'messages',
        {'reactions': jsonEncode(reactions)},
        where: 'item_id = ?',
        whereArgs: [messageId],
      );

      debugPrint(
        '[SQLITE_MESSAGE_STORE] ✓ Updated reactions for message $messageId',
      );
    } catch (e) {
      debugPrint('[SQLITE_MESSAGE_STORE] ✗ Error updating reactions: $e');
    }
  }
}
