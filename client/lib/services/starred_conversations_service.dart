import 'package:flutter/foundation.dart';
import 'storage/database_helper.dart';

/// Client-side service for managing starred conversations (1:1 chats)
/// 
/// Stores starred conversation state in local encrypted SQLite database.
/// Server has no knowledge of which conversations are starred - this is purely client-side.
class StarredConversationsService {
  static final StarredConversationsService _instance = StarredConversationsService._internal();
  static StarredConversationsService get instance => _instance;
  
  StarredConversationsService._internal();
  
  // Cache of starred user UUIDs for fast lookups
  Set<String> _starredConversations = {};
  bool _initialized = false;
  
  /// Initialize the service by loading starred conversations from database
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      final db = await DatabaseHelper.database;
      
      // Check if table exists, create if not
      final tables = await db.query(
        'sqlite_master',
        where: 'type = ? AND name = ?',
        whereArgs: ['table', 'starred_conversations'],
      );
      
      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE starred_conversations (
            user_uuid TEXT PRIMARY KEY,
            starred_at INTEGER NOT NULL
          )
        ''');
        debugPrint('[STARRED_CONV] Created starred_conversations table');
      }
      
      final results = await db.query(
        'starred_conversations',
        columns: ['user_uuid'],
      );
      
      _starredConversations = results.map((row) => row['user_uuid'] as String).toSet();
      _initialized = true;
      
      debugPrint('[STARRED_CONV] Initialized with ${_starredConversations.length} starred conversations');
    } catch (e) {
      debugPrint('[STARRED_CONV] Error initializing: $e');
      _starredConversations = {};
      _initialized = true;
    }
  }
  
  /// Check if a conversation is starred
  bool isStarred(String userUuid) {
    if (!_initialized) {
      debugPrint('[STARRED_CONV] Warning: Service not initialized, returning false');
      return false;
    }
    return _starredConversations.contains(userUuid);
  }
  
  /// Star a conversation
  Future<bool> starConversation(String userUuid) async {
    try {
      if (!_initialized) {
        await initialize();
      }
      
      if (_starredConversations.contains(userUuid)) {
        debugPrint('[STARRED_CONV] Conversation $userUuid already starred');
        return true;
      }
      
      final db = await DatabaseHelper.database;
      await db.insert(
        'starred_conversations',
        {
          'user_uuid': userUuid,
          'starred_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
      );
      
      _starredConversations.add(userUuid);
      debugPrint('[STARRED_CONV] ✓ Starred conversation $userUuid');
      return true;
    } catch (e) {
      debugPrint('[STARRED_CONV] Error starring conversation: $e');
      return false;
    }
  }
  
  /// Unstar a conversation
  Future<bool> unstarConversation(String userUuid) async {
    try {
      if (!_initialized) {
        await initialize();
      }
      
      if (!_starredConversations.contains(userUuid)) {
        debugPrint('[STARRED_CONV] Conversation $userUuid not starred');
        return true;
      }
      
      final db = await DatabaseHelper.database;
      await db.delete(
        'starred_conversations',
        where: 'user_uuid = ?',
        whereArgs: [userUuid],
      );
      
      _starredConversations.remove(userUuid);
      debugPrint('[STARRED_CONV] ✓ Unstarred conversation $userUuid');
      return true;
    } catch (e) {
      debugPrint('[STARRED_CONV] Error unstarring conversation: $e');
      return false;
    }
  }
  
  /// Toggle starred state
  Future<bool> toggleStar(String userUuid) async {
    if (isStarred(userUuid)) {
      return await unstarConversation(userUuid);
    } else {
      return await starConversation(userUuid);
    }
  }
  
  /// Get all starred conversation user UUIDs
  List<String> getStarredConversations() {
    if (!_initialized) {
      debugPrint('[STARRED_CONV] Warning: Service not initialized, returning empty list');
      return [];
    }
    return _starredConversations.toList();
  }
  
  /// Get count of starred conversations
  int getStarredCount() {
    return _starredConversations.length;
  }
  
  /// Clear all starred conversations (useful for logout/reset)
  Future<void> clearAll() async {
    try {
      final db = await DatabaseHelper.database;
      await db.delete('starred_conversations');
      _starredConversations.clear();
      debugPrint('[STARRED_CONV] ✓ Cleared all starred conversations');
    } catch (e) {
      debugPrint('[STARRED_CONV] Error clearing starred conversations: $e');
    }
  }
}
