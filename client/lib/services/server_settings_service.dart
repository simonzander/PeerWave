import 'package:flutter/foundation.dart';
import 'api_service.dart';
import '../web_config.dart';
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';

/// Singleton service to manage server settings
/// Caches settings to minimize API calls
///
/// Multi-Server Support:
/// - Maintains separate settings cache per server
/// - Auto-switches based on active server from ServerConfigService
/// - No manual cache clearing needed when switching servers
class ServerSettingsService {
  static final ServerSettingsService _instance =
      ServerSettingsService._internal();
  static ServerSettingsService get instance => _instance;

  ServerSettingsService._internal();

  // Per-server cache: serverId/serverUrl -> settings
  final Map<String, Map<String, dynamic>> _cachedSettings = {};
  final Map<String, DateTime> _cacheTime = {};
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// Get current server ID (for native) or key (for web)
  String? get _currentServerKey {
    if (kIsWeb) {
      // Web: Use fixed key (no multi-server support)
      return 'web';
    } else {
      // Native: Use server ID from active server
      final activeServer = ServerConfigService.getActiveServer();
      return activeServer?.id;
    }
  }

  /// Get server settings from cache or fetch from server
  Future<Map<String, dynamic>> getSettings() async {
    final serverKey = _currentServerKey;
    if (serverKey == null) {
      debugPrint('[ServerSettings] ⚠️ No active server, returning defaults');
      return _getDefaultSettings();
    }

    // Return cached settings if still valid
    if (_cachedSettings.containsKey(serverKey) &&
        _cacheTime.containsKey(serverKey)) {
      final age = DateTime.now().difference(_cacheTime[serverKey]!);
      if (age < _cacheDuration) {
        debugPrint(
          '[ServerSettings] Using cached settings for $serverKey (age: ${age.inMinutes}min)',
        );
        return _cachedSettings[serverKey]!;
      }
    }

    // Fetch fresh settings
    try {
      String urlString = '';
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      final resp = await ApiService.get('/client/meta');

      if (resp.statusCode == 200) {
        final data = resp.data;
        final settings = {
          'serverName': data['serverName'] ?? 'PeerWave Server',
          'serverPicture': data['serverPicture'],
          'registrationMode': data['registrationMode'] ?? 'open',
          'allowedEmailSuffixes': data['allowedEmailSuffixes'] ?? [],
        };
        _cachedSettings[serverKey] = settings;
        _cacheTime[serverKey] = DateTime.now();
        debugPrint('[ServerSettings] ✓ Cached settings for $serverKey');
        return settings;
      }
    } catch (e) {
      debugPrint('[ServerSettings] Failed to fetch settings: $e');
    }

    // Return default settings on error
    return _getDefaultSettings();
  }

  /// Get default server settings
  Map<String, dynamic> _getDefaultSettings() {
    return {
      'serverName': 'PeerWave Server',
      'serverPicture': null,
      'registrationMode': 'open',
      'allowedEmailSuffixes': [],
    };
  }

  /// Get current registration mode for active server
  String get registrationMode {
    final serverKey = _currentServerKey;
    if (serverKey == null) return 'open';
    return _cachedSettings[serverKey]?['registrationMode'] ?? 'open';
  }

  /// Get allowed email suffixes for active server
  List<String> get allowedEmailSuffixes {
    final serverKey = _currentServerKey;
    if (serverKey == null) return [];

    final suffixes = _cachedSettings[serverKey]?['allowedEmailSuffixes'];
    if (suffixes is List) {
      return suffixes.cast<String>();
    }
    return [];
  }

  /// Validate email against server settings
  bool validateEmail(String email) {
    if (email.isEmpty || !email.contains('@')) {
      return false;
    }

    final mode = registrationMode;

    // Open mode: all emails valid
    if (mode == 'open') {
      return true;
    }

    // Email suffix mode: check domain
    if (mode == 'email_suffix') {
      final suffixes = allowedEmailSuffixes;
      if (suffixes.isEmpty) {
        return true; // No restrictions if no suffixes configured
      }

      final domain = email.split('@').last.toLowerCase();
      return suffixes.any((suffix) => domain.endsWith(suffix.toLowerCase()));
    }

    // Invitation only mode: email format is valid, but needs token
    // This will be checked separately in the invitation flow
    return true;
  }

  /// Clear cached settings for current server (force refresh on next getSettings call)
  void clearCache() {
    final serverKey = _currentServerKey;
    if (serverKey != null) {
      debugPrint('[ServerSettings] Clearing cache for $serverKey');
      _cachedSettings.remove(serverKey);
      _cacheTime.remove(serverKey);
    }
  }

  /// Clear all cached settings (all servers)
  void clearAllCaches() {
    debugPrint('[ServerSettings] Clearing all server caches');
    _cachedSettings.clear();
    _cacheTime.clear();
  }

  /// Get server name for active server
  String get serverName {
    final serverKey = _currentServerKey;
    if (serverKey == null) return 'PeerWave Server';
    return _cachedSettings[serverKey]?['serverName'] ?? 'PeerWave Server';
  }

  /// Get server picture for active server
  String? get serverPicture {
    final serverKey = _currentServerKey;
    if (serverKey == null) return null;
    return _cachedSettings[serverKey]?['serverPicture'];
  }

  /// Get total cache size (number of cached servers)
  int get totalCacheSize => _cachedSettings.length;
}
