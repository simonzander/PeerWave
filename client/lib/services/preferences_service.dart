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
        debugPrint('[PreferencesService] Error clearing last route from IndexedDB: $e');
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

