import 'package:flutter/foundation.dart';
import '../models/ice_server_config.dart';
import '../services/api_service.dart';
import '../web_config.dart';
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';

/// ICE Server Configuration Service
///
/// Singleton service that fetches and caches ICE server configuration
/// from the server's /client/meta endpoint.
class IceConfigService extends ChangeNotifier {
  static final IceConfigService _instance = IceConfigService._internal();
  factory IceConfigService() => _instance;
  IceConfigService._internal();

  ClientMetaResponse? _clientMeta;
  bool _isLoaded = false;
  DateTime? _lastLoaded;
  String? _serverUrl;

  // Cache TTL: Reload config after 12 hours (half of TURN credential lifetime)
  static const Duration _cacheTtl = Duration(hours: 12);

  /// Get cached client meta response
  ClientMetaResponse? get clientMeta => _clientMeta;

  /// Check if config is loaded
  bool get isLoaded => _isLoaded;

  /// Get ICE servers in WebRTC-compatible format
  Map<String, dynamic> getIceServers() {
    if (_clientMeta != null) {
      return _clientMeta!.toWebRtcConfig();
    }

    // Fallback to Google STUN
    debugPrint('[ICE CONFIG] No config loaded, using fallback STUN');
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
  }

  /// Load ICE server configuration from LiveKit
  Future<void> loadConfig({bool force = false, String? serverUrl}) async {
    // Update server URL if provided
    if (serverUrl != null) {
      _serverUrl = serverUrl;
    }

    // Get server URL from appropriate source
    if (_serverUrl == null || _serverUrl!.isEmpty) {
      if (kIsWeb) {
        // Web: Load from web config
        _serverUrl = await loadWebApiServer();
      } else {
        // Native: Get from ServerConfigService
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          _serverUrl = activeServer.serverUrl;
          debugPrint('[ICE CONFIG] Using active server: $_serverUrl');
        }
      }
    }

    // Ensure we have a valid server URL
    if (_serverUrl == null || _serverUrl!.isEmpty) {
      debugPrint('[ICE CONFIG] ⚠️ No server URL available, using fallback');
      _serverUrl = 'http://localhost:3000'; // Fallback
    }

    // Ensure server URL has protocol (only add if doesn't have one)
    if (!_serverUrl!.startsWith('http://') &&
        !_serverUrl!.startsWith('https://')) {
      _serverUrl = 'https://$_serverUrl';
    }

    debugPrint('[ICE CONFIG] Using server URL: $_serverUrl');

    // Check if we need to reload (cache expired or forced)
    if (!force && _isLoaded && _lastLoaded != null) {
      final age = DateTime.now().difference(_lastLoaded!);
      if (age < _cacheTtl) {
        debugPrint(
          '[ICE CONFIG] Using cached config (age: ${age.inMinutes}min)',
        );
        return;
      }
      debugPrint(
        '[ICE CONFIG] Cache expired (age: ${age.inHours}h), reloading...',
      );
    }

    try {
      debugPrint('[ICE CONFIG] Loading ICE config from LiveKit...');

      // ✅ NEW: Fetch from LiveKit ICE endpoint instead of /client/meta
      final response = await ApiService.get('/api/livekit/ice-config');

      if (response.statusCode == 200) {
        final data = response.data;

        // Parse ICE servers from LiveKit response
        final List<IceServer> servers = [];
        if (data['iceServers'] != null) {
          for (var server in data['iceServers']) {
            servers.add(
              IceServer(
                urls: List<String>.from(server['urls']),
                username: server['username'],
                credential: server['credential'],
              ),
            );
          }
        }

        _clientMeta = ClientMetaResponse(
          name: 'PeerWave',
          version: '1.0.0',
          iceServers: servers,
        );

        _isLoaded = true;
        _lastLoaded = DateTime.now();

        debugPrint('[ICE CONFIG] ✅ LiveKit ICE config loaded successfully');
        debugPrint(
          '[ICE CONFIG] ICE Servers: ${_clientMeta!.iceServers.length}',
        );
        debugPrint(
          '[ICE CONFIG] TTL: ${data['ttl']}s, Expires: ${data['expiresAt']}',
        );

        for (var i = 0; i < _clientMeta!.iceServers.length; i++) {
          final server = _clientMeta!.iceServers[i];
          debugPrint('[ICE CONFIG]   [$i] ${server.urls.join(", ")}');
          if (server.username != null) {
            debugPrint('[ICE CONFIG]       Auth: JWT-based (LiveKit)');
          }
        }

        notifyListeners();
      } else {
        debugPrint(
          '[ICE CONFIG] ❌ Failed to load config: ${response.statusCode}',
        );
        _useFallback();
      }
    } catch (e) {
      debugPrint('[ICE CONFIG] ❌ Error loading config: $e');
      _useFallback();
    }
  }

  /// Use fallback configuration (public STUN only)
  void _useFallback() {
    debugPrint('[ICE CONFIG] Using fallback configuration (public STUN only)');
    _clientMeta = ClientMetaResponse(
      name: 'PeerWave',
      version: 'unknown',
      iceServers: [
        IceServer(urls: ['stun:stun.l.google.com:19302']),
      ],
    );
    _isLoaded = true;
    _lastLoaded = DateTime.now();
    notifyListeners();
  }

  /// Reload configuration (force refresh)
  Future<void> reload() async {
    debugPrint('[ICE CONFIG] Force reloading configuration...');
    await loadConfig(force: true);
  }

  /// Clear cached configuration
  void clearCache() {
    debugPrint('[ICE CONFIG] Clearing cache');
    _clientMeta = null;
    _isLoaded = false;
    _lastLoaded = null;
    notifyListeners();
  }

  /// Check if configuration should be reloaded (cache expired)
  bool shouldReload() {
    if (!_isLoaded || _lastLoaded == null) return true;
    final age = DateTime.now().difference(_lastLoaded!);
    return age >= _cacheTtl;
  }

  /// Get cache age in minutes
  int? getCacheAgeMinutes() {
    if (_lastLoaded == null) return null;
    return DateTime.now().difference(_lastLoaded!).inMinutes;
  }
}
