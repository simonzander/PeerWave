import 'package:flutter/foundation.dart';
import 'storage/database_helper.dart';

/// Client-side service for managing starred channels
/// 
/// Stores starred channel state in local encrypted SQLite database.
/// Server has no knowledge of which channels are starred - this is purely client-side.
class StarredChannelsService {
  static final StarredChannelsService _instance = StarredChannelsService._internal();
  static StarredChannelsService get instance => _instance;
  
  StarredChannelsService._internal();
  
  // Cache of starred channel UUIDs for fast lookups
  Set<String> _starredChannels = {};
  bool _initialized = false;
  
  /// Initialize the service by loading starred channels from database
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      final db = await DatabaseHelper.database;
      final results = await db.query(
        'starred_channels',
        columns: ['channel_uuid'],
      );
      
      _starredChannels = results.map((row) => row['channel_uuid'] as String).toSet();
      _initialized = true;
      
      debugPrint('[STARRED] Initialized with ${_starredChannels.length} starred channels');
    } catch (e) {
      debugPrint('[STARRED] Error initializing: $e');
      _starredChannels = {};
      _initialized = true;
    }
  }
  
  /// Check if a channel is starred
  bool isStarred(String channelUuid) {
    if (!_initialized) {
      debugPrint('[STARRED] Warning: Service not initialized, returning false');
      return false;
    }
    return _starredChannels.contains(channelUuid);
  }
  
  /// Star a channel
  Future<bool> starChannel(String channelUuid) async {
    try {
      if (!_initialized) {
        await initialize();
      }
      
      if (_starredChannels.contains(channelUuid)) {
        debugPrint('[STARRED] Channel $channelUuid already starred');
        return true;
      }
      
      final db = await DatabaseHelper.database;
      await db.insert(
        'starred_channels',
        {
          'channel_uuid': channelUuid,
          'starred_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
        conflictAlgorithm: null, // Will throw error if duplicate
      );
      
      _starredChannels.add(channelUuid);
      debugPrint('[STARRED] ✓ Starred channel $channelUuid');
      return true;
    } catch (e) {
      debugPrint('[STARRED] Error starring channel: $e');
      return false;
    }
  }
  
  /// Unstar a channel
  Future<bool> unstarChannel(String channelUuid) async {
    try {
      if (!_initialized) {
        await initialize();
      }
      
      if (!_starredChannels.contains(channelUuid)) {
        debugPrint('[STARRED] Channel $channelUuid not starred');
        return true;
      }
      
      final db = await DatabaseHelper.database;
      await db.delete(
        'starred_channels',
        where: 'channel_uuid = ?',
        whereArgs: [channelUuid],
      );
      
      _starredChannels.remove(channelUuid);
      debugPrint('[STARRED] ✓ Unstarred channel $channelUuid');
      return true;
    } catch (e) {
      debugPrint('[STARRED] Error unstarring channel: $e');
      return false;
    }
  }
  
  /// Toggle starred state
  Future<bool> toggleStar(String channelUuid) async {
    if (isStarred(channelUuid)) {
      return await unstarChannel(channelUuid);
    } else {
      return await starChannel(channelUuid);
    }
  }
  
  /// Get all starred channel UUIDs
  List<String> getStarredChannels() {
    if (!_initialized) {
      debugPrint('[STARRED] Warning: Service not initialized, returning empty list');
      return [];
    }
    return _starredChannels.toList();
  }
  
  /// Get count of starred channels
  int getStarredCount() {
    return _starredChannels.length;
  }
  
  /// Clear all starred channels (useful for logout/reset)
  Future<void> clearAll() async {
    try {
      final db = await DatabaseHelper.database;
      await db.delete('starred_channels');
      _starredChannels.clear();
      debugPrint('[STARRED] ✓ Cleared all starred channels');
    } catch (e) {
      debugPrint('[STARRED] Error clearing starred channels: $e');
    }
  }
}
