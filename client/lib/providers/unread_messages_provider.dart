import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:idb_shim/idb_browser.dart';

/// Provider for managing unread message counts across channels and direct messages
/// 
/// This provider tracks unread message counts for:
/// - Channel messages (group chats)
/// - Direct messages (1:1 conversations)
/// 
/// Counts are persisted to storage and survive app restarts.
/// Only 'message' and 'file' type messages increment the counters.
class UnreadMessagesProvider extends ChangeNotifier {
  // Channel UUID -> Unread Count
  Map<String, int> _channelUnreadCounts = {};
  
  // User UUID -> Unread Count
  Map<String, int> _directMessageUnreadCounts = {};
  
  // Storage keys for persistence
  static const String _storageKeyChannels = 'unread_channel_counts';
  static const String _storageKeyDirectMessages = 'unread_dm_counts';
  
  /// Whitelisted message types that should increment badge counts
  static const Set<String> BADGE_MESSAGE_TYPES = {'message', 'file'};
  
  // ============================================================================
  // GETTERS
  // ============================================================================
  
  /// Get unread count for a specific channel
  int getChannelUnreadCount(String channelUuid) {
    return _channelUnreadCounts[channelUuid] ?? 0;
  }
  
  /// Get unread count for a specific direct message conversation
  int getDirectMessageUnreadCount(String userUuid) {
    return _directMessageUnreadCounts[userUuid] ?? 0;
  }
  
  /// Get total unread count across all channels
  int get totalChannelUnread {
    final total = _channelUnreadCounts.values.fold(0, (a, b) => a + b);
    return total;
  }
  
  /// Get total unread count across all direct messages
  int get totalDirectMessageUnread {
    final total = _directMessageUnreadCounts.values.fold(0, (a, b) => a + b);
    return total;
  }
  
  /// Get immutable copy of all channel unread counts
  Map<String, int> get channelUnreadCounts {
    return Map.unmodifiable(_channelUnreadCounts);
  }
  
  /// Get immutable copy of all direct message unread counts
  Map<String, int> get directMessageUnreadCounts {
    return Map.unmodifiable(_directMessageUnreadCounts);
  }
  
  // ============================================================================
  // INCREMENT METHODS
  // ============================================================================
  
  /// Increment unread count for a channel
  /// 
  /// [channelUuid] The UUID of the channel
  /// [count] Number to increment by (default: 1)
  void incrementChannelUnread(String channelUuid, {int count = 1}) {
    if (count <= 0) return;
    
    _channelUnreadCounts[channelUuid] = 
        (_channelUnreadCounts[channelUuid] ?? 0) + count;
    
    notifyListeners();
    saveToStorage();
  }
  
  /// Increment unread count for a direct message conversation
  /// 
  /// [userUuid] The UUID of the user
  /// [count] Number to increment by (default: 1)
  void incrementDirectMessageUnread(String userUuid, {int count = 1}) {
    if (count <= 0) return;
    
    _directMessageUnreadCounts[userUuid] = 
        (_directMessageUnreadCounts[userUuid] ?? 0) + count;
    
    notifyListeners();
    saveToStorage();
  }
  
  /// Increment unread count based on message type (with type filtering)
  /// 
  /// Only increments if messageType is in BADGE_MESSAGE_TYPES
  void incrementIfBadgeType(
    String messageType,
    String targetId,
    bool isChannel,
  ) {
    if (!BADGE_MESSAGE_TYPES.contains(messageType)) {
      debugPrint('[UnreadProvider] Ignoring non-badge type: $messageType');
      return;
    }
    
    if (isChannel) {
      incrementChannelUnread(targetId);
    } else {
      incrementDirectMessageUnread(targetId);
    }
  }
  
  // ============================================================================
  // MARK AS READ METHODS
  // ============================================================================
  
  /// Mark all messages in a channel as read (reset count to 0)
  void markChannelAsRead(String channelUuid) {
    if (_channelUnreadCounts.containsKey(channelUuid)) {
      debugPrint('[UnreadProvider] Marking channel $channelUuid as read');
      _channelUnreadCounts.remove(channelUuid);
      notifyListeners();
      saveToStorage();
    }
  }
  
  /// Mark all messages in a direct message conversation as read (reset count to 0)
  void markDirectMessageAsRead(String userUuid) {
    if (_directMessageUnreadCounts.containsKey(userUuid)) {
      debugPrint('[UnreadProvider] Marking DM $userUuid as read');
      _directMessageUnreadCounts.remove(userUuid);
      notifyListeners();
      saveToStorage();
    }
  }
  
  /// Decrement unread count for a channel (used when reading individual messages)
  void decrementChannelUnread(String channelUuid, {int count = 1}) {
    if (!_channelUnreadCounts.containsKey(channelUuid)) return;
    
    final currentCount = _channelUnreadCounts[channelUuid]!;
    final newCount = (currentCount - count).clamp(0, double.infinity).toInt();
    
    if (newCount == 0) {
      _channelUnreadCounts.remove(channelUuid);
    } else {
      _channelUnreadCounts[channelUuid] = newCount;
    }
    
    notifyListeners();
    saveToStorage();
  }
  
  /// Decrement unread count for a direct message (used when reading individual messages)
  void decrementDirectMessageUnread(String userUuid, {int count = 1}) {
    if (!_directMessageUnreadCounts.containsKey(userUuid)) return;
    
    final currentCount = _directMessageUnreadCounts[userUuid]!;
    final newCount = (currentCount - count).clamp(0, double.infinity).toInt();
    
    if (newCount == 0) {
      _directMessageUnreadCounts.remove(userUuid);
    } else {
      _directMessageUnreadCounts[userUuid] = newCount;
    }
    
    notifyListeners();
    saveToStorage();
  }
  
  // ============================================================================
  // RESET METHODS
  // ============================================================================
  
  /// Reset all unread counts (both channels and direct messages)
  void resetAll() {
    debugPrint('[UnreadProvider] Resetting all unread counts');
    _channelUnreadCounts.clear();
    _directMessageUnreadCounts.clear();
    notifyListeners();
    saveToStorage();
  }
  
  /// Reset all channel unread counts
  void resetAllChannels() {
    debugPrint('[UnreadProvider] Resetting all channel unread counts');
    _channelUnreadCounts.clear();
    notifyListeners();
    saveToStorage();
  }
  
  /// Reset all direct message unread counts
  void resetAllDirectMessages() {
    debugPrint('[UnreadProvider] Resetting all DM unread counts');
    _directMessageUnreadCounts.clear();
    notifyListeners();
    saveToStorage();
  }
  
  // ============================================================================
  // PERSISTENCE METHODS
  // ============================================================================
  
  /// Load unread counts from persistent storage
  Future<void> loadFromStorage() async {
    try {
      // Use private methods via reflection or create custom storage
      // For now, we'll use a simple approach with shared_preferences directly
      if (kIsWeb) {
        // Web: Use IndexedDB via idb_shim
        final channelsJson = await _loadFromIndexedDB(_storageKeyChannels);
        final dmJson = await _loadFromIndexedDB(_storageKeyDirectMessages);
        
        if (channelsJson != null && channelsJson.isNotEmpty) {
          final decoded = jsonDecode(channelsJson) as Map<String, dynamic>;
          _channelUnreadCounts = decoded.map((k, v) => MapEntry(k, v as int));
          debugPrint('[UnreadProvider] Loaded ${_channelUnreadCounts.length} channel counts from storage');
        }
        
        if (dmJson != null && dmJson.isNotEmpty) {
          final decoded = jsonDecode(dmJson) as Map<String, dynamic>;
          _directMessageUnreadCounts = decoded.map((k, v) => MapEntry(k, v as int));
          debugPrint('[UnreadProvider] Loaded ${_directMessageUnreadCounts.length} DM counts from storage');
        }
      } else {
        // Native: Use SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final channelsJson = prefs.getString(_storageKeyChannels);
        final dmJson = prefs.getString(_storageKeyDirectMessages);
        
        if (channelsJson != null && channelsJson.isNotEmpty) {
          final decoded = jsonDecode(channelsJson) as Map<String, dynamic>;
          _channelUnreadCounts = decoded.map((k, v) => MapEntry(k, v as int));
          debugPrint('[UnreadProvider] Loaded ${_channelUnreadCounts.length} channel counts from storage');
        }
        
        if (dmJson != null && dmJson.isNotEmpty) {
          final decoded = jsonDecode(dmJson) as Map<String, dynamic>;
          _directMessageUnreadCounts = decoded.map((k, v) => MapEntry(k, v as int));
          debugPrint('[UnreadProvider] Loaded ${_directMessageUnreadCounts.length} DM counts from storage');
        }
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[UnreadProvider] Error loading from storage: $e');
      // Don't throw - continue with empty state
    }
  }
  
  /// Save unread counts to persistent storage
  Future<void> saveToStorage() async {
    try {
      if (kIsWeb) {
        // Web: Use IndexedDB
        await _saveToIndexedDB(_storageKeyChannels, jsonEncode(_channelUnreadCounts));
        await _saveToIndexedDB(_storageKeyDirectMessages, jsonEncode(_directMessageUnreadCounts));
      } else {
        // Native: Use SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_storageKeyChannels, jsonEncode(_channelUnreadCounts));
        await prefs.setString(_storageKeyDirectMessages, jsonEncode(_directMessageUnreadCounts));
      }
    } catch (e) {
      debugPrint('[UnreadProvider] Error saving to storage: $e');
      // Don't throw - storage failure shouldn't crash the app
    }
  }
  
  // ============================================================================
  // INDEXEDDB HELPERS (Web)
  // ============================================================================
  
  static const String _dbName = 'peerwave_unread_badges';
  static const String _storeName = 'counts';
  static const int _dbVersion = 1;
  
  /// Save to IndexedDB (Web only)
  Future<void> _saveToIndexedDB(String key, String value) async {
    try {
      final idbFactory = getIdbFactory()!;
      final db = await idbFactory.open(
        _dbName,
        version: _dbVersion,
        onUpgradeNeeded: (event) {
          final db = event.database;
          if (!db.objectStoreNames.contains(_storeName)) {
            db.createObjectStore(_storeName);
          }
        },
      );

      final txn = db.transaction(_storeName, idbModeReadWrite);
      final store = txn.objectStore(_storeName);
      await store.put(value, key);
      await txn.completed;
      db.close();
    } catch (e) {
      debugPrint('[UnreadProvider] Error saving to IndexedDB: $e');
    }
  }
  
  /// Load from IndexedDB (Web only)
  Future<String?> _loadFromIndexedDB(String key) async {
    try {
      final idbFactory = getIdbFactory()!;
      final db = await idbFactory.open(
        _dbName,
        version: _dbVersion,
        onUpgradeNeeded: (event) {
          final db = event.database;
          if (!db.objectStoreNames.contains(_storeName)) {
            db.createObjectStore(_storeName);
          }
        },
      );

      final txn = db.transaction(_storeName, idbModeReadOnly);
      final store = txn.objectStore(_storeName);
      final value = await store.getObject(key);
      await txn.completed;
      db.close();

      return value as String?;
    } catch (e) {
      debugPrint('[UnreadProvider] Error loading from IndexedDB: $e');
      return null;
    }
  }
  
  // ============================================================================
  // UTILITY METHODS
  // ============================================================================
  
  /// Check if a specific channel has unread messages
  bool hasChannelUnread(String channelUuid) {
    return (_channelUnreadCounts[channelUuid] ?? 0) > 0;
  }
  
  /// Check if a specific direct message has unread messages
  bool hasDirectMessageUnread(String userUuid) {
    return (_directMessageUnreadCounts[userUuid] ?? 0) > 0;
  }
  
  /// Get list of all channel UUIDs with unread messages
  List<String> getChannelsWithUnread() {
    return _channelUnreadCounts.keys.toList();
  }
  
  /// Get list of all user UUIDs with unread direct messages
  List<String> getUsersWithUnread() {
    return _directMessageUnreadCounts.keys.toList();
  }
  
  /// Debug method to print current state
  void debugPrintState() {
    debugPrint('[UnreadProvider] ========== STATE DUMP ==========');
    debugPrint('[UnreadProvider] Total Channel Unread: $totalChannelUnread');
    debugPrint('[UnreadProvider] Total DM Unread: $totalDirectMessageUnread');
    debugPrint('[UnreadProvider] Channel Counts: $_channelUnreadCounts');
    debugPrint('[UnreadProvider] DM Counts: $_directMessageUnreadCounts');
    debugPrint('[UnreadProvider] ================================');
  }
}

