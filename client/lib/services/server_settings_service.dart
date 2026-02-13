import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'signal/signal.dart';
import '../web_config.dart';
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';
import 'user_profile_service.dart';

/// Singleton service to manage per-server resources
///
/// Manages for each server:
/// - Settings cache (server name, registration mode, etc.)
/// - ApiService instance (scoped to server URL)
/// - SocketService instance (scoped to server URL)
/// - SignalClient instance (Signal Protocol orchestration)
///
/// Multi-Server Support:
/// - Maintains separate instances per server
/// - Auto-switches based on active server from ServerConfigService
/// - Proper cleanup on server switch/logout
class ServerSettingsService {
  static final ServerSettingsService _instance =
      ServerSettingsService._internal();
  static ServerSettingsService get instance => _instance;

  ServerSettingsService._internal();

  // Per-server cache: serverId/serverUrl -> settings
  final Map<String, Map<String, dynamic>> _cachedSettings = {};
  final Map<String, DateTime> _cacheTime = {};
  static const Duration _cacheDuration = Duration(minutes: 5);

  // Per-server device IDs (populated from authentication)
  final Map<String, int> _deviceIds = {};

  // Per-server SignalClient instances (only SignalClient is per-server)
  // ApiService and SocketService are singletons with internal multi-server handling
  final Map<String, SignalClient> _signalClients = {};

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

      final resp = await ApiService.instance.get('/client/meta');

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

  // ============================================================================
  // API SERVICE MANAGEMENT
  // ============================================================================

  /// Get singleton ApiService instance
  /// ApiService internally manages multiple servers
  ApiService getApiService() {
    return ApiService.instance;
  }

  // ============================================================================
  // SOCKET SERVICE MANAGEMENT
  // ============================================================================

  /// Get singleton SocketService instance
  /// For native: SocketService internally manages multiple servers
  /// For web: SocketService manages single server (set via setServerUrl)
  SocketService getSocketService() {
    if (kIsWeb) {
      // For web, ensure server URL is set
      final serverUrl = Uri.base.origin;
      SocketService.instance.setServerUrl(serverUrl);
    }
    // For native, SocketService manages all servers internally
    return SocketService.instance;
  }

  // ============================================================================
  // SIGNAL CLIENT MANAGEMENT
  // ============================================================================

  /// Get or create SignalClient for current server
  ///
  /// Parameters:
  /// - [userId]: User ID from authentication response (REQUIRED)
  /// - [deviceId]: Device ID from authentication response (REQUIRED)
  ///
  /// IMPORTANT: userId and deviceId are now mandatory to prevent bugs
  Future<SignalClient> getOrCreateSignalClient({
    required String userId,
    required int deviceId,
  }) async {
    final serverKey = _currentServerKey;
    if (serverKey == null) {
      throw Exception('No active server configured');
    }

    // Return existing if already created
    if (_signalClients.containsKey(serverKey)) {
      return _signalClients[serverKey]!;
    }

    debugPrint('[ServerSettings] Creating SignalClient for $serverKey');
    debugPrint(
      '[ServerSettings] Using provided userId and deviceId from authentication',
    );

    // Store device ID in memory for this server
    _deviceIds[serverKey] = deviceId;
    debugPrint(
      '[ServerSettings] Cached device ID: $deviceId for server: $serverKey',
    );

    // Get server URL
    String? serverUrl;
    if (kIsWeb) {
      serverUrl = Uri.base.origin;
    } else {
      final server = ServerConfigService.getServerById(serverKey);
      serverUrl = server?.serverUrl;
    }

    // Initialize ApiService for this server
    await ApiService.instance.initForServer(serverKey, serverUrl: serverUrl);

    // For web: Set server URL and connect SocketService
    if (kIsWeb && serverUrl != null) {
      SocketService.instance.setServerUrl(serverUrl);
      await SocketService.instance.connect();
    }
    // For native: SocketService connects to all servers via connectAllServers()
    // We just need to ensure this server is in the active server
    else if (!kIsWeb) {
      await SocketService.instance.connect();
    }

    // Create SignalClient with singleton instances
    // Singletons will route to the correct server based on getActiveServer()
    final signalClient = SignalClient(
      apiService: ApiService.instance,
      socketService: SocketService.instance,
      serverKey: serverKey,
      getCurrentUserId: () => userId,
      getCurrentDeviceId: () => deviceId,
    );

    _signalClients[serverKey] = signalClient;
    return signalClient;
  }

  /// Convenience method: Get or create SignalClient using stored credentials
  ///
  /// This method automatically retrieves userId and deviceId from stored values.
  /// Use this ONLY after authentication is complete and credentials are stored.
  ///
  /// Throws StateError if userId or deviceId are not available.
  Future<SignalClient> getOrCreateSignalClientWithStoredCredentials() async {
    final userId = UserProfileService.instance.currentUserUuid;
    final deviceId = getDeviceId();

    if (userId == null || userId.isEmpty) {
      throw StateError(
        'Cannot create SignalClient: User ID not available. '
        'Ensure authentication completes before initializing SignalClient.',
      );
    }

    if (deviceId == null) {
      throw StateError(
        'Cannot create SignalClient: Device ID not available. '
        'Ensure authentication completes and device ID is stored before initializing SignalClient.',
      );
    }

    return getOrCreateSignalClient(userId: userId, deviceId: deviceId);
  }

  /// Set device ID for a server (called after authentication)
  void setDeviceId(String serverKey, int deviceId) {
    debugPrint('[ServerSettings] Setting device ID for $serverKey: $deviceId');
    _deviceIds[serverKey] = deviceId;
  }

  /// Get device ID for current server
  int? getDeviceId() {
    final serverKey = _currentServerKey;
    if (serverKey == null) return null;
    return _deviceIds[serverKey];
  }

  /// Get SignalClient for current server (returns null if not created)
  SignalClient? getSignalClient() {
    final serverKey = _currentServerKey;
    if (serverKey == null) return null;
    return _signalClients[serverKey];
  }

  /// Check if SignalClient exists and is initialized for current server
  bool isSignalClientInitialized() {
    final client = getSignalClient();
    return client != null && client.isInitialized;
  }

  // ============================================================================
  // CLEANUP METHODS
  // ============================================================================

  /// Remove SignalClient for a specific server (on logout/server removal)
  /// Note: ApiService and SocketService are singletons and manage cleanup internally
  Future<void> removeServer(String serverKey) async {
    debugPrint('[ServerSettings] Removing SignalClient for $serverKey');

    // Dispose SignalClient
    final signalClient = _signalClients.remove(serverKey);
    if (signalClient != null) {
      await signalClient.dispose();
    }

    // Clear cached settings
    _cachedSettings.remove(serverKey);
    _cacheTime.remove(serverKey);

    debugPrint('[ServerSettings] ✅ Removed server $serverKey');
  }

  /// Remove all SignalClients for all servers (complete logout)
  /// Note: ApiService and SocketService are singletons
  /// For native: SocketService.disconnectAllServers() should be called separately
  /// For web: SocketService.disconnect() should be called separately
  Future<void> removeAllServers() async {
    debugPrint('[ServerSettings] Removing all SignalClients');

    // Dispose all SignalClients
    for (final client in _signalClients.values) {
      await client.dispose();
    }
    _signalClients.clear();

    // Clear all caches
    clearAllCaches();

    debugPrint('[ServerSettings] ✅ Removed all servers');
  }
}
