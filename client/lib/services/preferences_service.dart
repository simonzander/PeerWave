import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:idb_shim/idb_browser.dart';

/// Service für Persistierung von Theme-Präferenzen
///
/// - Web: IndexedDB (via idb_shim)
/// - Native: SharedPreferences
class PreferencesService {
  static final PreferencesService _instance = PreferencesService._internal();
  factory PreferencesService() => _instance;
  PreferencesService._internal();

  // Storage Keys
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyColorSchemeId = 'color_scheme_id';
  static const String _keyLastRoute = 'last_app_route';

  // Notification Settings Keys
  static const String _keyNotificationsEnabled = 'notifications_enabled';
  static const String _keySoundsEnabled = 'sounds_enabled';
  static const String _keyVideoSoundsEnabled = 'video_sounds_enabled';
  static const String _keyParticipantSoundsEnabled =
      'participant_sounds_enabled';
  static const String _keyScreenShareSoundsEnabled =
      'screen_share_sounds_enabled';
  static const String _keyDirectMessageNotificationsEnabled =
      'dm_notifications_enabled';
  static const String _keyDirectMessageSoundsEnabled = 'dm_sounds_enabled';
  static const String _keyDirectMessagePreviewEnabled = 'dm_preview_enabled';
  static const String _keyGroupMessageNotificationsEnabled =
      'group_notifications_enabled';
  static const String _keyGroupMessageSoundsEnabled = 'group_sounds_enabled';
  static const String _keyGroupMessagePreviewEnabled = 'group_preview_enabled';
  static const String _keyOnlyMentionsInGroups = 'only_mentions_in_groups';
  static const String _keyMentionNotificationsEnabled =
      'mention_notifications_enabled';
  static const String _keyReactionNotificationsEnabled =
      'reaction_notifications_enabled';
  static const String _keyMissedCallNotificationsEnabled =
      'missed_call_notifications_enabled';
  static const String _keyChannelInviteNotificationsEnabled =
      'channel_invite_notifications_enabled';
  static const String _keyPermissionChangeNotificationsEnabled =
      'permission_change_notifications_enabled';
  static const String _keyDndEnabled = 'dnd_enabled';

  // IndexedDB Config (Web)
  static const String _dbName = 'peerwave_preferences';
  static const String _storeName = 'settings';
  static const int _dbVersion = 1;

  // ============================================================================
  // Theme Mode
  // ============================================================================

  /// Speichert den Theme Mode (light, dark, system)
  Future<void> saveThemeMode(String themeMode) async {
    if (kIsWeb) {
      await _saveToIndexedDB(_keyThemeMode, themeMode);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyThemeMode, themeMode);
    }
  }

  /// Lädt den Theme Mode
  /// Returns: 'light', 'dark', oder 'system' (default)
  Future<String> loadThemeMode() async {
    if (kIsWeb) {
      final value = await _loadFromIndexedDB(_keyThemeMode);
      return value ?? 'system';
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyThemeMode) ?? 'system';
    }
  }

  // ============================================================================
  // Color Scheme
  // ============================================================================

  /// Speichert die Color Scheme ID
  Future<void> saveColorSchemeId(String schemeId) async {
    if (kIsWeb) {
      await _saveToIndexedDB(_keyColorSchemeId, schemeId);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyColorSchemeId, schemeId);
    }
  }

  /// Lädt die Color Scheme ID
  /// Returns: Scheme ID oder 'peerwave_dark' (default)
  Future<String> loadColorSchemeId() async {
    if (kIsWeb) {
      final value = await _loadFromIndexedDB(_keyColorSchemeId);
      return value ?? 'peerwave_dark';
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyColorSchemeId) ?? 'peerwave_dark';
    }
  }

  // ============================================================================
  // Last Route (for restoration after signal-setup)
  // ============================================================================

  /// Saves the last visited /app/* route for restoration
  Future<void> saveLastRoute(String route) async {
    if (kIsWeb) {
      await _saveToIndexedDB(_keyLastRoute, route);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastRoute, route);
    }
    debugPrint('[PreferencesService] Saved last route: $route');
  }

  /// Loads the last visited /app/* route
  /// Returns: Last route or null if none saved
  Future<String?> loadLastRoute() async {
    if (kIsWeb) {
      final value = await _loadFromIndexedDB(_keyLastRoute);
      debugPrint('[PreferencesService] Loaded last route: $value');
      return value;
    } else {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyLastRoute);
      debugPrint('[PreferencesService] Loaded last route: $value');
      return value;
    }
  }

  /// Clears the saved last route
  Future<void> clearLastRoute() async {
    if (kIsWeb) {
      try {
        final idbFactory = getIdbFactory()!;
        final db = await idbFactory.open(_dbName, version: _dbVersion);
        final txn = db.transaction(_storeName, idbModeReadWrite);
        final store = txn.objectStore(_storeName);
        await store.delete(_keyLastRoute);
        await txn.completed;
        db.close();
      } catch (e) {
        debugPrint(
          '[PreferencesService] Error clearing last route from IndexedDB: $e',
        );
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastRoute);
    }
    debugPrint('[PreferencesService] Cleared last route');
  }

  // ============================================================================
  // IndexedDB Implementation (Web)
  // ============================================================================

  /// Speichert einen Wert in IndexedDB
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
      debugPrint('[PreferencesService] Error saving to IndexedDB: $e');
      rethrow;
    }
  }

  /// Lädt einen Wert aus IndexedDB
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
      debugPrint('[PreferencesService] Error loading from IndexedDB: $e');
      return null;
    }
  }

  // ============================================================================
  // Notification Settings
  // ============================================================================

  Future<void> saveBoolPref(String key, bool value) async {
    if (kIsWeb) {
      await _saveToIndexedDB(key, value.toString());
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    }
  }

  Future<bool> loadBoolPref(String key, {bool defaultValue = true}) async {
    if (kIsWeb) {
      final value = await _loadFromIndexedDB(key);
      if (value == null) return defaultValue;
      return value.toLowerCase() == 'true';
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? defaultValue;
    }
  }

  // Notification Master Controls
  Future<void> saveNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyNotificationsEnabled, enabled);
  Future<bool> loadNotificationsEnabled() =>
      loadBoolPref(_keyNotificationsEnabled, defaultValue: true);

  Future<void> saveSoundsEnabled(bool enabled) =>
      saveBoolPref(_keySoundsEnabled, enabled);
  Future<bool> loadSoundsEnabled() =>
      loadBoolPref(_keySoundsEnabled, defaultValue: true);

  // Video Conference Sounds
  Future<void> saveVideoSoundsEnabled(bool enabled) =>
      saveBoolPref(_keyVideoSoundsEnabled, enabled);
  Future<bool> loadVideoSoundsEnabled() =>
      loadBoolPref(_keyVideoSoundsEnabled, defaultValue: true);

  Future<void> saveParticipantSoundsEnabled(bool enabled) =>
      saveBoolPref(_keyParticipantSoundsEnabled, enabled);
  Future<bool> loadParticipantSoundsEnabled() =>
      loadBoolPref(_keyParticipantSoundsEnabled, defaultValue: true);

  Future<void> saveScreenShareSoundsEnabled(bool enabled) =>
      saveBoolPref(_keyScreenShareSoundsEnabled, enabled);
  Future<bool> loadScreenShareSoundsEnabled() =>
      loadBoolPref(_keyScreenShareSoundsEnabled, defaultValue: true);

  // Direct Message Notifications
  Future<void> saveDirectMessageNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyDirectMessageNotificationsEnabled, enabled);
  Future<bool> loadDirectMessageNotificationsEnabled() =>
      loadBoolPref(_keyDirectMessageNotificationsEnabled, defaultValue: true);

  Future<void> saveDirectMessageSoundsEnabled(bool enabled) =>
      saveBoolPref(_keyDirectMessageSoundsEnabled, enabled);
  Future<bool> loadDirectMessageSoundsEnabled() =>
      loadBoolPref(_keyDirectMessageSoundsEnabled, defaultValue: true);

  Future<void> saveDirectMessagePreviewEnabled(bool enabled) =>
      saveBoolPref(_keyDirectMessagePreviewEnabled, enabled);
  Future<bool> loadDirectMessagePreviewEnabled() =>
      loadBoolPref(_keyDirectMessagePreviewEnabled, defaultValue: true);

  // Group Message Notifications
  Future<void> saveGroupMessageNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyGroupMessageNotificationsEnabled, enabled);
  Future<bool> loadGroupMessageNotificationsEnabled() =>
      loadBoolPref(_keyGroupMessageNotificationsEnabled, defaultValue: true);

  Future<void> saveGroupMessageSoundsEnabled(bool enabled) =>
      saveBoolPref(_keyGroupMessageSoundsEnabled, enabled);
  Future<bool> loadGroupMessageSoundsEnabled() =>
      loadBoolPref(_keyGroupMessageSoundsEnabled, defaultValue: true);

  Future<void> saveGroupMessagePreviewEnabled(bool enabled) =>
      saveBoolPref(_keyGroupMessagePreviewEnabled, enabled);
  Future<bool> loadGroupMessagePreviewEnabled() =>
      loadBoolPref(_keyGroupMessagePreviewEnabled, defaultValue: true);

  Future<void> saveOnlyMentionsInGroups(bool enabled) =>
      saveBoolPref(_keyOnlyMentionsInGroups, enabled);
  Future<bool> loadOnlyMentionsInGroups() =>
      loadBoolPref(_keyOnlyMentionsInGroups, defaultValue: false);

  // Activity Notifications
  Future<void> saveMentionNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyMentionNotificationsEnabled, enabled);
  Future<bool> loadMentionNotificationsEnabled() =>
      loadBoolPref(_keyMentionNotificationsEnabled, defaultValue: true);

  Future<void> saveReactionNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyReactionNotificationsEnabled, enabled);
  Future<bool> loadReactionNotificationsEnabled() =>
      loadBoolPref(_keyReactionNotificationsEnabled, defaultValue: true);

  Future<void> saveMissedCallNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyMissedCallNotificationsEnabled, enabled);
  Future<bool> loadMissedCallNotificationsEnabled() =>
      loadBoolPref(_keyMissedCallNotificationsEnabled, defaultValue: true);

  Future<void> saveChannelInviteNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyChannelInviteNotificationsEnabled, enabled);
  Future<bool> loadChannelInviteNotificationsEnabled() =>
      loadBoolPref(_keyChannelInviteNotificationsEnabled, defaultValue: true);

  Future<void> savePermissionChangeNotificationsEnabled(bool enabled) =>
      saveBoolPref(_keyPermissionChangeNotificationsEnabled, enabled);
  Future<bool> loadPermissionChangeNotificationsEnabled() => loadBoolPref(
    _keyPermissionChangeNotificationsEnabled,
    defaultValue: true,
  );

  // Do Not Disturb
  Future<void> saveDndEnabled(bool enabled) =>
      saveBoolPref(_keyDndEnabled, enabled);
  Future<bool> loadDndEnabled() =>
      loadBoolPref(_keyDndEnabled, defaultValue: false);

  // ============================================================================
  // Clear All
  // ============================================================================

  /// Löscht alle gespeicherten Präferenzen
  Future<void> clearAll() async {
    if (kIsWeb) {
      try {
        final idbFactory = getIdbFactory()!;
        final db = await idbFactory.open(_dbName, version: _dbVersion);
        final txn = db.transaction(_storeName, idbModeReadWrite);
        final store = txn.objectStore(_storeName);
        await store.clear();
        await txn.completed;
        db.close();
      } catch (e) {
        debugPrint('[PreferencesService] Error clearing IndexedDB: $e');
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyThemeMode);
      await prefs.remove(_keyColorSchemeId);
      await prefs.remove(_keyLastRoute);
    }
  }
}
