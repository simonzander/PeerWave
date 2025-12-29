import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/color_schemes.dart';
import '../services/preferences_service.dart';

/// Provider für Theme State Management
///
/// Verwaltet:
/// - Theme Mode (light, dark, system)
/// - Color Scheme Auswahl
/// - Theme Persistierung
class ThemeProvider extends ChangeNotifier {
  final PreferencesService _prefsService = PreferencesService();

  // State
  ThemeMode _themeMode = ThemeMode.system;
  String _colorSchemeId = 'peerwave_dark';
  bool _isInitialized = false;

  // Getters
  ThemeMode get themeMode => _themeMode;
  String get colorSchemeId => _colorSchemeId;
  bool get isInitialized => _isInitialized;

  /// Aktuelles Color Scheme Option
  ColorSchemeOption get currentScheme {
    return ColorSchemeOptions.byId(_colorSchemeId) ??
        ColorSchemeOptions.defaultScheme;
  }

  /// Light Theme mit aktuellem Color Scheme
  ThemeData get lightTheme {
    final scheme = currentScheme.light();
    return AppTheme.light(colorScheme: scheme);
  }

  /// Dark Theme mit aktuellem Color Scheme
  ThemeData get darkTheme {
    final scheme = currentScheme.dark();
    return AppTheme.dark(colorScheme: scheme);
  }

  /// Initialisiert Provider mit gespeicherten Präferenzen
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Load saved preferences
      final savedThemeMode = await _prefsService.loadThemeMode();
      final savedSchemeId = await _prefsService.loadColorSchemeId();

      // Parse theme mode
      _themeMode = _parseThemeMode(savedThemeMode);
      _colorSchemeId = savedSchemeId;

      debugPrint(
        '[ThemeProvider] Initialized: mode=$savedThemeMode, scheme=$savedSchemeId',
      );

      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[ThemeProvider] Error initializing: $e');
      // Use defaults
      _themeMode = ThemeMode.system;
      _colorSchemeId = 'peerwave_dark';
      _isInitialized = true;
      notifyListeners();
    }
  }

  /// Ändert den Theme Mode
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;

    _themeMode = mode;
    notifyListeners();

    // Persist
    final modeString = _themeModeToString(mode);
    await _prefsService.saveThemeMode(modeString);

    debugPrint('[ThemeProvider] Theme mode changed to: $modeString');
  }

  /// Ändert das Color Scheme
  Future<void> setColorScheme(String schemeId) async {
    // Validate scheme ID
    final scheme = ColorSchemeOptions.byId(schemeId);
    if (scheme == null) {
      debugPrint('[ThemeProvider] Invalid scheme ID: $schemeId');
      return;
    }

    if (_colorSchemeId == schemeId) return;

    _colorSchemeId = schemeId;
    notifyListeners();

    // Persist
    await _prefsService.saveColorSchemeId(schemeId);

    debugPrint('[ThemeProvider] Color scheme changed to: $schemeId');
  }

  /// Setzt Theme auf Light Mode
  Future<void> setLightMode() => setThemeMode(ThemeMode.light);

  /// Setzt Theme auf Dark Mode
  Future<void> setDarkMode() => setThemeMode(ThemeMode.dark);

  /// Setzt Theme auf System Mode
  Future<void> setSystemMode() => setThemeMode(ThemeMode.system);

  /// Setzt Theme zurück auf Defaults
  Future<void> resetToDefaults() async {
    _themeMode = ThemeMode.system;
    _colorSchemeId = 'peerwave_dark';

    await _prefsService.clearAll();

    notifyListeners();
    debugPrint('[ThemeProvider] Reset to defaults');
  }

  // ============================================================================
  // Helpers
  // ============================================================================

  ThemeMode _parseThemeMode(String value) {
    switch (value.toLowerCase()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  /// Debug Info
  void printDebugInfo() {
    debugPrint('=== ThemeProvider Debug Info ===');
    debugPrint('Initialized: $_isInitialized');
    debugPrint('Theme Mode: ${_themeModeToString(_themeMode)}');
    debugPrint('Color Scheme ID: $_colorSchemeId');
    debugPrint('Color Scheme Name: ${currentScheme.name}');
    debugPrint('================================');
  }
}
