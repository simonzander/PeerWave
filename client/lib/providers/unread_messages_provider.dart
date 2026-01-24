import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/device_scoped_storage_service.dart';
import '../services/server_config_native.dart'
    if (dart.library.html) '../services/server_config_web.dart';

/// Provider for managing unread message counts across channels and direct messages
/// Uses device-scoped storage on web for per-device unread tracking
///
/// This provider tracks unread message counts PER SERVER:
/// - Channel messages (group chats)
/// - Direct messages (1:1 conversations)
///
/// Counts are persisted to storage per-server and survive app restarts.
/// Only 'message' and 'file' type messages increment the counters.
class UnreadMessagesProvider extends ChangeNotifier {
  // Server ID -> Channel UUID -> Unread Count
  Map<String, Map<String, int>> _channelUnreadCounts = {};

  // Server ID -> User UUID -> Unread Count
  Map<String, Map<String, int>> _directMessageUnreadCounts = {};

  // Server ID -> Activity Notification Item ID -> Count (always 1 per notification)
  Map<String, Map<String, int>> _activityNotificationCounts = {};

  // Storage keys for persistence (suffixed with serverId at runtime)
  static const String _storageKeyChannels = 'unread_channel_counts';
  static const String _storageKeyDirectMessages = 'unread_dm_counts';
  static const String _storageKeyActivityNotifications =
      'unread_activity_notifications';

  /// Get the current active server ID
  String? get _currentServerId {
    final activeServer = ServerConfigService.getActiveServer();
    return activeServer?.id;
  }

  /// Get or create the channel counts map for a server
  Map<String, int> _getChannelCounts(String? serverId) {
    if (serverId == null) return {};
    return _channelUnreadCounts.putIfAbsent(serverId, () => {});
  }

  /// Get or create the DM counts map for a server
  Map<String, int> _getDirectMessageCounts(String? serverId) {
    if (serverId == null) return {};
    return _directMessageUnreadCounts.putIfAbsent(serverId, () => {});
  }

  /// Get or create the activity notification counts map for a server
  Map<String, int> _getActivityCounts(String? serverId) {
    if (serverId == null) return {};
    return _activityNotificationCounts.putIfAbsent(serverId, () => {});
  }

  /// Whitelisted message types that should increment badge counts
  /// Only includes types that are displayed in channel message lists
  static const Set<String> badgeMessageTypes = {
    'message', // Regular text messages
    'file', // File uploads
  };

  /// Activity notification types (shown in Activities/Notifications tab only)
  /// These do NOT increment channel badge counts as they don't appear in message lists
  static const Set<String> activityNotificationTypes = {
    'emote',
    'mention',
    'missingcall',
    'addtochannel',
    'removefromchannel',
    'permissionchange',
  };

  // ============================================================================
  // GETTERS
  // ============================================================================

  /// Get unread count for a specific channel (uses current active server)
  int getChannelUnreadCount(String channelUuid) {
    final counts = _getChannelCounts(_currentServerId);
    return counts[channelUuid] ?? 0;
  }

  /// Get unread count for a specific direct message conversation (uses current active server)
  int getDirectMessageUnreadCount(String userUuid) {
    final counts = _getDirectMessageCounts(_currentServerId);
    return counts[userUuid] ?? 0;
  }

  /// Get total unread count across all channels (current server only)
  int get totalChannelUnread {
    final counts = _getChannelCounts(_currentServerId);
    return counts.values.fold<int>(0, (a, b) => a + b);
  }

  /// Get total unread count across all direct messages (current server only)
  int get totalDirectMessageUnread {
    final counts = _getDirectMessageCounts(_currentServerId);
    return counts.values.fold<int>(0, (a, b) => a + b);
  }

  /// Get total unread count for activity notifications (current server only)
  /// These are notification-type messages (emote, mention, missingcall, etc.)
  int get totalActivityNotifications {
    final counts = _getActivityCounts(_currentServerId);
    return counts.values.fold<int>(0, (a, b) => a + b);
  }

  /// Get immutable copy of all channel unread counts (current server only)
  Map<String, int> get channelUnreadCounts {
    final counts = _getChannelCounts(_currentServerId);
    return Map.unmodifiable(counts);
  }

  /// Get immutable copy of all direct message unread counts (current server only)
  Map<String, int> get directMessageUnreadCounts {
    final counts = _getDirectMessageCounts(_currentServerId);
    return Map.unmodifiable(counts);
  }

  /// Get immutable copy of all activity notification counts (current server only)
  Map<String, int> get activityNotificationCounts {
    final counts = _getActivityCounts(_currentServerId);
    return Map.unmodifiable(counts);
  }

  /// Get total unread count for a specific server (all channels + DMs)
  int getTotalUnreadForServer(String serverId) {
    final channelCounts = _channelUnreadCounts[serverId] ?? {};
    final dmCounts = _directMessageUnreadCounts[serverId] ?? {};
    final channelTotal = channelCounts.values.fold<int>(0, (a, b) => a + b);
    final dmTotal = dmCounts.values.fold<int>(0, (a, b) => a + b);
    return channelTotal + dmTotal;
  }

  // ============================================================================
  // INCREMENT METHODS
  // ============================================================================

  /// Increment unread count for a channel (current server)
  ///
  /// [channelUuid] The UUID of the channel
  /// [count] Number to increment by (default: 1)
  void incrementChannelUnread(String channelUuid, {int count = 1}) {
    if (count <= 0 || _currentServerId == null) return;

    final counts = _getChannelCounts(_currentServerId);
    counts[channelUuid] = (counts[channelUuid] ?? 0) + count;

    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  /// Increment unread count for a direct message conversation (current server)
  ///
  /// [userUuid] The UUID of the user
  /// [count] Number to increment by (default: 1)
  void incrementDirectMessageUnread(String userUuid, {int count = 1}) {
    if (count <= 0 || _currentServerId == null) return;

    final counts = _getDirectMessageCounts(_currentServerId);
    counts[userUuid] = (counts[userUuid] ?? 0) + count;

    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  /// Increment unread count for an activity notification (current server)
  ///
  /// [itemId] The item ID of the notification message
  void incrementActivityNotification(String itemId) {
    if (_currentServerId == null) return;

    final counts = _getActivityCounts(_currentServerId);
    counts[itemId] = 1; // Each notification counts as 1

    debugPrint(
      '[UnreadProvider] ✓ Activity notification added: $itemId (server: $_currentServerId, total: $totalActivityNotifications)',
    );
    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  /// Decrement/remove an activity notification when marked as read (current server)
  ///
  /// [itemId] The item ID of the notification message
  void decrementActivityNotification(String itemId) {
    if (_currentServerId == null) return;

    final counts = _getActivityCounts(_currentServerId);
    if (counts.containsKey(itemId)) {
      counts.remove(itemId);

      debugPrint(
        '[UnreadProvider] ✓ Activity notification removed: $itemId (server: $_currentServerId, total: $totalActivityNotifications)',
      );
      notifyListeners();
      saveToStorage(_currentServerId!);
    }
  }

  /// Increment unread count based on message type (with type filtering)
  ///
  /// Only increments if messageType is in badgeMessageTypes
  void incrementIfBadgeType(
    String messageType,
    String targetId,
    bool isChannel,
  ) {
    if (!badgeMessageTypes.contains(messageType)) {
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

  /// Mark all messages in a channel as read (reset count to 0, current server)
  void markChannelAsRead(String channelUuid) {
    if (_currentServerId == null) return;

    final counts = _getChannelCounts(_currentServerId);
    if (counts.containsKey(channelUuid)) {
      debugPrint(
        '[UnreadProvider] Marking channel $channelUuid as read (server: $_currentServerId)',
      );
      counts.remove(channelUuid);
      notifyListeners();
      saveToStorage(_currentServerId!);
    }
  }

  /// Mark all messages in a direct message conversation as read (reset count to 0, current server)
  void markDirectMessageAsRead(String userUuid) {
    if (_currentServerId == null) return;

    final counts = _getDirectMessageCounts(_currentServerId);
    if (counts.containsKey(userUuid)) {
      debugPrint(
        '[UnreadProvider] Marking DM $userUuid as read (server: $_currentServerId)',
      );
      counts.remove(userUuid);
      notifyListeners();
      saveToStorage(_currentServerId!);
    }
  }

  /// Mark a specific activity notification as read (current server)
  void markActivityNotificationAsRead(String itemId) {
    if (_currentServerId == null) return;

    final counts = _getActivityCounts(_currentServerId);
    if (counts.containsKey(itemId)) {
      debugPrint(
        '[UnreadProvider] Marking activity notification as read: $itemId (server: $_currentServerId)',
      );
      counts.remove(itemId);
      notifyListeners();
      saveToStorage(_currentServerId!);
    }
  }

  /// Mark all activity notifications as read (current server)
  void markAllActivityNotificationsAsRead() {
    if (_currentServerId == null) return;

    final counts = _getActivityCounts(_currentServerId);
    if (counts.isNotEmpty) {
      debugPrint(
        '[UnreadProvider] Marking all ${counts.length} activity notifications as read (server: $_currentServerId)',
      );
      counts.clear();
      notifyListeners();
      saveToStorage(_currentServerId!);
    }
  }

  /// Mark multiple activity notifications as read (bulk operation, current server)
  void markMultipleActivityNotificationsAsRead(List<String> itemIds) {
    if (_currentServerId == null) return;

    final counts = _getActivityCounts(_currentServerId);
    bool changed = false;
    for (final itemId in itemIds) {
      if (counts.containsKey(itemId)) {
        counts.remove(itemId);
        changed = true;
      }
    }

    if (changed) {
      debugPrint(
        '[UnreadProvider] Marked ${itemIds.length} activity notifications as read (server: $_currentServerId)',
      );
      notifyListeners();
      saveToStorage(_currentServerId!);
    }
  }

  /// Decrement unread count for a channel (used when reading individual messages, current server)
  void decrementChannelUnread(String channelUuid, {int count = 1}) {
    if (_currentServerId == null) return;

    final counts = _getChannelCounts(_currentServerId);
    if (!counts.containsKey(channelUuid)) return;

    final currentCount = counts[channelUuid]!;
    final newCount = (currentCount - count).clamp(0, double.infinity).toInt();

    if (newCount == 0) {
      counts.remove(channelUuid);
    } else {
      counts[channelUuid] = newCount;
    }

    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  /// Decrement unread count for a direct message (used when reading individual messages, current server)
  void decrementDirectMessageUnread(String userUuid, {int count = 1}) {
    if (_currentServerId == null) return;

    final counts = _getDirectMessageCounts(_currentServerId);
    if (!counts.containsKey(userUuid)) return;

    final currentCount = counts[userUuid]!;
    final newCount = (currentCount - count).clamp(0, double.infinity).toInt();

    if (newCount == 0) {
      counts.remove(userUuid);
    } else {
      counts[userUuid] = newCount;
    }

    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  // ============================================================================
  // RESET METHODS
  // ============================================================================

  /// Reset all unread counts for the current server (both channels and direct messages)
  void resetAll() {
    if (_currentServerId == null) return;

    debugPrint(
      '[UnreadProvider] Resetting all unread counts for server: $_currentServerId',
    );
    _channelUnreadCounts.remove(_currentServerId);
    _directMessageUnreadCounts.remove(_currentServerId);
    _activityNotificationCounts.remove(_currentServerId);
    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  /// Reset all channel unread counts for the current server
  void resetAllChannels() {
    if (_currentServerId == null) return;

    debugPrint(
      '[UnreadProvider] Resetting all channel unread counts for server: $_currentServerId',
    );
    _channelUnreadCounts.remove(_currentServerId);
    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  /// Reset all direct message unread counts for the current server
  void resetAllDirectMessages() {
    if (_currentServerId == null) return;

    debugPrint(
      '[UnreadProvider] Resetting all DM unread counts for server: $_currentServerId',
    );
    _directMessageUnreadCounts.remove(_currentServerId);
    notifyListeners();
    saveToStorage(_currentServerId!);
  }

  // ============================================================================
  // PERSISTENCE METHODS
  // ============================================================================

  /// Load unread counts from persistent storage for all servers
  Future<void> loadAllServersFromStorage() async {
    try {
      final servers = ServerConfigService.getAllServers();
      for (final server in servers) {
        await loadFromStorage(server.id);
      }
      debugPrint(
        '[UnreadProvider] ✓ Loaded unread counts for ${servers.length} servers',
      );
    } catch (e) {
      debugPrint('[UnreadProvider] Error loading all servers: $e');
    }
  }

  /// Load unread counts from persistent storage for a specific server
  Future<void> loadFromStorage(String serverId) async {
    try {
      // Load per-server counts
      if (kIsWeb) {
        // Web: Use IndexedDB via idb_shim
        final channelsKey = '${_storageKeyChannels}_$serverId';
        final dmKey = '${_storageKeyDirectMessages}_$serverId';
        final activityKey = '${_storageKeyActivityNotifications}_$serverId';

        final channelsJson = await _loadFromIndexedDB(channelsKey);
        final dmJson = await _loadFromIndexedDB(dmKey);
        final activityJson = await _loadFromIndexedDB(activityKey);

        if (channelsJson != null && channelsJson.isNotEmpty) {
          final decoded = jsonDecode(channelsJson) as Map<String, dynamic>;
          _channelUnreadCounts[serverId] = decoded.map(
            (k, v) => MapEntry(k, v as int),
          );
          debugPrint(
            '[UnreadProvider] Loaded ${_channelUnreadCounts[serverId]!.length} channel counts for server $serverId',
          );
        }

        if (dmJson != null && dmJson.isNotEmpty) {
          final decoded = jsonDecode(dmJson) as Map<String, dynamic>;
          _directMessageUnreadCounts[serverId] = decoded.map(
            (k, v) => MapEntry(k, v as int),
          );
          debugPrint(
            '[UnreadProvider] Loaded ${_directMessageUnreadCounts[serverId]!.length} DM counts for server $serverId',
          );
        }

        if (activityJson != null && activityJson.isNotEmpty) {
          final decoded = jsonDecode(activityJson) as Map<String, dynamic>;
          _activityNotificationCounts[serverId] = decoded.map(
            (k, v) => MapEntry(k, v as int),
          );
          debugPrint(
            '[UnreadProvider] Loaded ${_activityNotificationCounts[serverId]!.length} activity notifications for server $serverId',
          );
        }
      } else {
        // Native: Use SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final channelsKey = '${_storageKeyChannels}_$serverId';
        final dmKey = '${_storageKeyDirectMessages}_$serverId';
        final activityKey = '${_storageKeyActivityNotifications}_$serverId';

        final channelsJson = prefs.getString(channelsKey);
        final dmJson = prefs.getString(dmKey);
        final activityJson = prefs.getString(activityKey);

        if (channelsJson != null && channelsJson.isNotEmpty) {
          final decoded = jsonDecode(channelsJson) as Map<String, dynamic>;
          _channelUnreadCounts[serverId] = decoded.map(
            (k, v) => MapEntry(k, v as int),
          );
          debugPrint(
            '[UnreadProvider] Loaded ${_channelUnreadCounts[serverId]!.length} channel counts for server $serverId',
          );
        }

        if (dmJson != null && dmJson.isNotEmpty) {
          final decoded = jsonDecode(dmJson) as Map<String, dynamic>;
          _directMessageUnreadCounts[serverId] = decoded.map(
            (k, v) => MapEntry(k, v as int),
          );
          debugPrint(
            '[UnreadProvider] Loaded ${_directMessageUnreadCounts[serverId]!.length} DM counts for server $serverId',
          );
        }

        if (activityJson != null && activityJson.isNotEmpty) {
          final decoded = jsonDecode(activityJson) as Map<String, dynamic>;
          _activityNotificationCounts[serverId] = decoded.map(
            (k, v) => MapEntry(k, v as int),
          );
          debugPrint(
            '[UnreadProvider] Loaded ${_activityNotificationCounts[serverId]!.length} activity notifications for server $serverId',
          );
        }
      }

      notifyListeners();
    } catch (e) {
      debugPrint(
        '[UnreadProvider] Error loading from storage for server $serverId: $e',
      );
      // Don't throw - continue with empty state
    }
  }

  /// Save unread counts to persistent storage for a specific server
  Future<void> saveToStorage(String serverId) async {
    try {
      final channelCounts = _channelUnreadCounts[serverId] ?? {};
      final dmCounts = _directMessageUnreadCounts[serverId] ?? {};
      final activityCounts = _activityNotificationCounts[serverId] ?? {};

      if (kIsWeb) {
        // Web: Use IndexedDB
        final channelsKey = '${_storageKeyChannels}_$serverId';
        final dmKey = '${_storageKeyDirectMessages}_$serverId';
        final activityKey = '${_storageKeyActivityNotifications}_$serverId';

        await _saveToIndexedDB(channelsKey, jsonEncode(channelCounts));
        await _saveToIndexedDB(dmKey, jsonEncode(dmCounts));
        await _saveToIndexedDB(activityKey, jsonEncode(activityCounts));
      } else {
        // Native: Use SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final channelsKey = '${_storageKeyChannels}_$serverId';
        final dmKey = '${_storageKeyDirectMessages}_$serverId';
        final activityKey = '${_storageKeyActivityNotifications}_$serverId';

        await prefs.setString(channelsKey, jsonEncode(channelCounts));
        await prefs.setString(dmKey, jsonEncode(dmCounts));
        await prefs.setString(activityKey, jsonEncode(activityCounts));
      }
    } catch (e) {
      debugPrint(
        '[UnreadProvider] Error saving to storage for server $serverId: $e',
      );
      // Don't throw - storage failure shouldn't crash the app
    }
  }

  // ============================================================================
  // DEVICE-SCOPED STORAGE HELPERS (Web)
  // ============================================================================
  // ============================================================================

  static const String _dbName = 'peerwave_unread_badges';
  static const String _storeName = 'counts';

  /// Save to device-scoped storage (Web only)
  Future<void> _saveToIndexedDB(String key, String value) async {
    try {
      if (!kIsWeb) return;

      final storage = DeviceScopedStorageService.instance;
      await storage.storeEncrypted(_dbName, _storeName, key, value);

      debugPrint('[UnreadProvider] ✓ Saved to device-scoped storage: $key');
    } catch (e) {
      debugPrint('[UnreadProvider] Error saving to storage: $e');
    }
  }

  /// Load from device-scoped storage (Web only)
  Future<String?> _loadFromIndexedDB(String key) async {
    try {
      if (!kIsWeb) return null;

      final storage = DeviceScopedStorageService.instance;
      final value = await storage.getDecrypted(_dbName, _storeName, key);

      return value as String?;
    } catch (e) {
      debugPrint('[UnreadProvider] Error loading from storage: $e');
      return null;
    }
  }

  // ============================================================================
  // UTILITY METHODS
  // ============================================================================

  /// Check if a specific channel has unread messages (current server)
  bool hasChannelUnread(String channelUuid) {
    final counts = _getChannelCounts(_currentServerId);
    return (counts[channelUuid] ?? 0) > 0;
  }

  /// Check if a specific direct message has unread messages (current server)
  bool hasDirectMessageUnread(String userUuid) {
    final counts = _getDirectMessageCounts(_currentServerId);
    return (counts[userUuid] ?? 0) > 0;
  }

  /// Get list of all channel UUIDs with unread messages (current server)
  List<String> getChannelsWithUnread() {
    final counts = _getChannelCounts(_currentServerId);
    return counts.keys.toList();
  }

  /// Get list of all user UUIDs with unread direct messages (current server)
  List<String> getUsersWithUnread() {
    final counts = _getDirectMessageCounts(_currentServerId);
    return counts.keys.toList();
  }

  /// Debug method to print current state (current server)
  void debugPrintState() {
    debugPrint('[UnreadProvider] ========== STATE DUMP ==========');
    debugPrint('[UnreadProvider] Current Server: $_currentServerId');
    debugPrint('[UnreadProvider] Total Channel Unread: $totalChannelUnread');
    debugPrint('[UnreadProvider] Total DM Unread: $totalDirectMessageUnread');
    final channelCounts = _getChannelCounts(_currentServerId);
    final dmCounts = _getDirectMessageCounts(_currentServerId);
    debugPrint('[UnreadProvider] Channel Counts: $channelCounts');
    debugPrint('[UnreadProvider] DM Counts: $dmCounts');
    debugPrint(
      '[UnreadProvider] All Servers: ${_channelUnreadCounts.keys.toList()}',
    );
    debugPrint('[UnreadProvider] ================================');
  }
}
