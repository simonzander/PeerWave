import 'package:flutter/foundation.dart';
import 'api_service.dart';
import '../web_config.dart';
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';

/// Singleton service to manage server settings
/// Caches settings to minimize API calls
class ServerSettingsService {
  static final ServerSettingsService _instance =
      ServerSettingsService._internal();
  static ServerSettingsService get instance => _instance;

  ServerSettingsService._internal();

  Map<String, dynamic>? _cachedSettings;
  DateTime? _cacheTime;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// Get server settings from cache or fetch from server
  Future<Map<String, dynamic>> getSettings() async {
    // Return cached settings if still valid
    if (_cachedSettings != null && _cacheTime != null) {
      final age = DateTime.now().difference(_cacheTime!);
      if (age < _cacheDuration) {
        return _cachedSettings!;
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
        _cachedSettings = {
          'serverName': data['serverName'] ?? 'PeerWave Server',
          'serverPicture': data['serverPicture'],
          'registrationMode': data['registrationMode'] ?? 'open',
          'allowedEmailSuffixes': data['allowedEmailSuffixes'] ?? [],
        };
        _cacheTime = DateTime.now();
        return _cachedSettings!;
      }
    } catch (e) {
      debugPrint('[ServerSettings] Failed to fetch settings: $e');
    }

    // Return default settings on error
    return {
      'serverName': 'PeerWave Server',
      'serverPicture': null,
      'registrationMode': 'open',
      'allowedEmailSuffixes': [],
    };
  }

  /// Get current registration mode
  String get registrationMode {
    return _cachedSettings?['registrationMode'] ?? 'open';
  }

  /// Get allowed email suffixes
  List<String> get allowedEmailSuffixes {
    final suffixes = _cachedSettings?['allowedEmailSuffixes'];
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

  /// Clear cached settings (force refresh on next getSettings call)
  void clearCache() {
    _cachedSettings = null;
    _cacheTime = null;
  }

  /// Get server name
  String get serverName {
    return _cachedSettings?['serverName'] ?? 'PeerWave Server';
  }

  /// Get server picture
  String? get serverPicture {
    return _cachedSettings?['serverPicture'];
  }
}
