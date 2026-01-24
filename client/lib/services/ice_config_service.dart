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
///
/// Multi-Server Support:
/// - Maintains separate ICE config cache per server
/// - Auto-switches based on active server from ServerConfigService
/// - No manual cache clearing needed when switching servers
class IceConfigService extends ChangeNotifier {
  static final IceConfigService _instance = IceConfigService._internal();
  factory IceConfigService() => _instance;
  IceConfigService._internal();

  // Per-server cache: serverId/serverUrl -> ClientMetaResponse
  final Map<String, ClientMetaResponse?> _clientMetaCache = {};
  final Map<String, bool> _isLoadedCache = {};
  final Map<String, DateTime?> _lastLoadedCache = {};

  // Cache TTL: Reload config after 12 hours (half of TURN credential lifetime)
  static const Duration _cacheTtl = Duration(hours: 12);

  /// Get current server ID (for native) or URL (for web)
  String? get _currentServerKey {
    if (kIsWeb) {
      // Web: Use server URL as key (no multi-server support)
      return 'web';
    } else {
      // Native: Use server ID from active server
      final activeServer = ServerConfigService.getActiveServer();
      return activeServer?.id;
    }
  }

  /// Get cached client meta response for current server
  ClientMetaResponse? get clientMeta {
    final key = _currentServerKey;
    return key != null ? _clientMetaCache[key] : null;
  }

  /// Check if config is loaded for current server
  bool get isLoaded {
    final key = _currentServerKey;
    return key != null ? (_isLoadedCache[key] ?? false) : false;
  }

  /// Get ICE servers in WebRTC-compatible format for current server
  Map<String, dynamic> getIceServers() {
    final meta = clientMeta;
    if (meta != null) {
      return meta.toWebRtcConfig();
    }

    // Fallback to Google STUN
    debugPrint('[ICE CONFIG] No config loaded, using fallback STUN');
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
  }

  /// Load ICE server configuration from LiveKit for current server
  Future<void> loadConfig({bool force = false, String? serverUrl}) async {
    final serverKey = _currentServerKey;
    if (serverKey == null) {
      debugPrint('[ICE CONFIG] ⚠️ No active server, cannot load config');
      return;
    }

    // Get actual server URL for API calls
    String? actualServerUrl = serverUrl;
    if (actualServerUrl == null || actualServerUrl.isEmpty) {
      if (kIsWeb) {
        // Web: Load from web config
        actualServerUrl = await loadWebApiServer();
      } else {
        // Native: Get from ServerConfigService
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          actualServerUrl = activeServer.serverUrl;
          debugPrint('[ICE CONFIG] Using active server: $actualServerUrl');
        }
      }
    }

    // Ensure we have a valid server URL
    if (actualServerUrl == null || actualServerUrl.isEmpty) {
      debugPrint('[ICE CONFIG] ⚠️ No server URL available, using fallback');
      actualServerUrl = 'http://localhost:3000'; // Fallback
    }

    // Ensure server URL has protocol (only add if doesn't have one)
    if (!actualServerUrl.startsWith('http://') &&
        !actualServerUrl.startsWith('https://')) {
      actualServerUrl = 'https://$actualServerUrl';
    }

    debugPrint('[ICE CONFIG] Loading config for server key: $serverKey');
    debugPrint('[ICE CONFIG] Server URL: $actualServerUrl');

    // Check if we need to reload (cache expired or forced)
    final lastLoaded = _lastLoadedCache[serverKey];
    if (!force && (_isLoadedCache[serverKey] ?? false) && lastLoaded != null) {
      final age = DateTime.now().difference(lastLoaded);
      if (age < _cacheTtl) {
        debugPrint(
          '[ICE CONFIG] Using cached config for $serverKey (age: ${age.inMinutes}min)',
        );
        return;
      }
      debugPrint(
        '[ICE CONFIG] Cache expired for $serverKey (age: ${age.inHours}h), reloading...',
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

        final config = ClientMetaResponse(
          name: 'PeerWave',
          version: '1.0.0',
          iceServers: servers,
        );

        _clientMetaCache[serverKey] = config;
        _isLoadedCache[serverKey] = true;
        _lastLoadedCache[serverKey] = DateTime.now();

        debugPrint('[ICE CONFIG] ✅ LiveKit ICE config loaded for $serverKey');
        debugPrint('[ICE CONFIG] ICE Servers: ${config.iceServers.length}');
        debugPrint(
          '[ICE CONFIG] TTL: ${data['ttl']}s, Expires: ${data['expiresAt']}',
        );

        for (var i = 0; i < config.iceServers.length; i++) {
          final server = config.iceServers[i];
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
    final serverKey = _currentServerKey;
    if (serverKey == null) return;

    debugPrint(
      '[ICE CONFIG] Using fallback configuration for $serverKey (public STUN only)',
    );
    _clientMetaCache[serverKey] = ClientMetaResponse(
      name: 'PeerWave',
      version: 'unknown',
      iceServers: [
        IceServer(urls: ['stun:stun.l.google.com:19302']),
      ],
    );
    _isLoadedCache[serverKey] = true;
    _lastLoadedCache[serverKey] = DateTime.now();
    notifyListeners();
  }

  /// Reload configuration (force refresh)
  Future<void> reload() async {
    debugPrint('[ICE CONFIG] Force reloading configuration...');
    await loadConfig(force: true);
  }

  /// Clear cached configuration for current server
  void clearCache() {
    final serverKey = _currentServerKey;
    if (serverKey != null) {
      debugPrint('[ICE CONFIG] Clearing cache for $serverKey');
      _clientMetaCache.remove(serverKey);
      _isLoadedCache.remove(serverKey);
      _lastLoadedCache.remove(serverKey);
      notifyListeners();
    }
  }

  /// Clear all cached configurations (all servers)
  void clearAllCaches() {
    debugPrint('[ICE CONFIG] Clearing all server caches');
    _clientMetaCache.clear();
    _isLoadedCache.clear();
    _lastLoadedCache.clear();
    notifyListeners();
  }

  /// Check if configuration should be reloaded (cache expired) for current server
  bool shouldReload() {
    final serverKey = _currentServerKey;
    if (serverKey == null) return true;

    final isLoaded = _isLoadedCache[serverKey] ?? false;
    final lastLoaded = _lastLoadedCache[serverKey];

    if (!isLoaded || lastLoaded == null) return true;
    final age = DateTime.now().difference(lastLoaded);
    return age >= _cacheTtl;
  }

  /// Get cache age in minutes for current server
  int? getCacheAgeMinutes() {
    final serverKey = _currentServerKey;
    if (serverKey == null) return null;

    final lastLoaded = _lastLoadedCache[serverKey];
    if (lastLoaded == null) return null;
    return DateTime.now().difference(lastLoaded).inMinutes;
  }

  /// Get total cache size (number of cached servers)
  int get totalCacheSize => _clientMetaCache.length;
}
