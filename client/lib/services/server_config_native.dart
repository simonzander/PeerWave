import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';

/// Configuration for a single server connection
class ServerConfig {
  final String id;              // Unique ID (hash of URL + timestamp)
  final String serverUrl;       // Full server URL
  final String serverHash;      // Hash for database table prefixes
  final String credentials;     // Encrypted session/auth data
  final String? iconPath;       // Custom server icon path (optional)
  final DateTime lastActive;    // Last time this server was used
  final DateTime createdAt;     // When this server was added
  int unreadCount;              // Unread message count for badge
  String? displayName;          // Custom display name (default: extract from URL)

  ServerConfig({
    required this.id,
    required this.serverUrl,
    required this.serverHash,
    required this.credentials,
    this.iconPath,
    required this.lastActive,
    required this.createdAt,
    this.unreadCount = 0,
    this.displayName,
  });

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'serverUrl': serverUrl,
      'serverHash': serverHash,
      'credentials': credentials,
      'iconPath': iconPath,
      'lastActive': lastActive.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
      'unreadCount': unreadCount,
      'displayName': displayName,
    };
  }

  /// Create from JSON
  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      id: json['id'] as String,
      serverUrl: json['serverUrl'] as String,
      serverHash: json['serverHash'] as String,
      credentials: json['credentials'] as String,
      iconPath: json['iconPath'] as String?,
      lastActive: DateTime.parse(json['lastActive'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      unreadCount: json['unreadCount'] as int? ?? 0,
      displayName: json['displayName'] as String?,
    );
  }

  /// Get display name (custom or extracted from URL)
  String getDisplayName() {
    if (displayName != null && displayName!.isNotEmpty) {
      return displayName!;
    }
    // Extract domain from URL
    try {
      final uri = Uri.parse(serverUrl);
      return uri.host;
    } catch (e) {
      return serverUrl;
    }
  }

  /// Get short name for icon (first letter of display name)
  String getShortName() {
    final name = getDisplayName();
    return name.isNotEmpty ? name[0].toUpperCase() : 'S';
  }

  ServerConfig copyWith({
    String? iconPath,
    DateTime? lastActive,
    int? unreadCount,
    String? displayName,
    String? credentials,
  }) {
    return ServerConfig(
      id: this.id,
      serverUrl: serverUrl,
      serverHash: serverHash,
      credentials: credentials ?? this.credentials,
      iconPath: iconPath ?? this.iconPath,
      lastActive: lastActive ?? this.lastActive,
      createdAt: createdAt,
      unreadCount: unreadCount ?? this.unreadCount,
      displayName: displayName ?? this.displayName,
    );
  }
}

/// Service for managing multiple server configurations (Native only)
class ServerConfigService {
  static const String _storageKeyServerList = 'server_list';
  static const String _storageKeyActiveServer = 'active_server_id';
  static const _storage = FlutterSecureStorage();

  static List<ServerConfig> _servers = [];
  static String? _activeServerId;

  /// Initialize service - load servers from secure storage
  static Future<void> init() async {
    await _loadServers();
    await _loadActiveServerId();
    print('[ServerConfig] Initialized with ${_servers.length} servers');
  }

  /// Load servers from secure storage
  static Future<void> _loadServers() async {
    try {
      final json = await _storage.read(key: _storageKeyServerList);
      if (json != null) {
        final List<dynamic> decoded = jsonDecode(json);
        _servers = decoded.map((e) => ServerConfig.fromJson(e)).toList();
        
        // Sort by lastActive (most recent first)
        _servers.sort((a, b) => b.lastActive.compareTo(a.lastActive));
        
        print('[ServerConfig] Loaded ${_servers.length} servers');
      }
    } catch (e) {
      print('[ServerConfig] Error loading servers: $e');
      _servers = [];
    }
  }

  /// Load active server ID
  static Future<void> _loadActiveServerId() async {
    _activeServerId = await _storage.read(key: _storageKeyActiveServer);
    print('[ServerConfig] Active server: $_activeServerId');
  }

  /// Save servers to secure storage
  static Future<void> _saveServers() async {
    try {
      final json = jsonEncode(_servers.map((e) => e.toJson()).toList());
      await _storage.write(key: _storageKeyServerList, value: json);
      print('[ServerConfig] Saved ${_servers.length} servers');
    } catch (e) {
      print('[ServerConfig] Error saving servers: $e');
    }
  }

  /// Save active server ID
  static Future<void> _saveActiveServerId() async {
    if (_activeServerId != null) {
      await _storage.write(key: _storageKeyActiveServer, value: _activeServerId!);
      print('[ServerConfig] Saved active server: $_activeServerId');
    }
  }

  /// Generate hash from server URL (for database table prefixes)
  /// Uses first 12 chars of SHA-256 hash for reasonable uniqueness
  static String generateServerHash(String serverUrl) {
    final bytes = utf8.encode(serverUrl);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 12);
  }

  /// Generate unique server ID (hash + timestamp for uniqueness on re-login)
  static String generateServerId(String serverUrl) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final combined = '$serverUrl:$timestamp';
    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  /// Add a new server
  static Future<ServerConfig> addServer({
    required String serverUrl,
    required String credentials,
    String? displayName,
    String? iconPath,
  }) async {
    // Check if server already exists
    final existingServer = _servers.firstWhere(
      (s) => s.serverUrl == serverUrl,
      orElse: () => ServerConfig(
        id: '',
        serverUrl: '',
        serverHash: '',
        credentials: '',
        lastActive: DateTime.now(),
        createdAt: DateTime.now(),
      ),
    );
    
    if (existingServer.serverUrl.isNotEmpty) {
      print('[ServerConfig] Server already exists, updating credentials for: ${existingServer.getDisplayName()} (${existingServer.id})');
      // Update credentials (HMAC session) for existing server
      await updateCredentials(existingServer.id, credentials);
      await setActiveServer(existingServer.id);
      return existingServer;
    }

    final now = DateTime.now();
    final serverHash = generateServerHash(serverUrl);
    final id = generateServerId(serverUrl);

    final config = ServerConfig(
      id: id,
      serverUrl: serverUrl,
      serverHash: serverHash,
      credentials: credentials,
      iconPath: iconPath,
      lastActive: now,
      createdAt: now,
      displayName: displayName,
    );

    _servers.add(config);
    await _saveServers();

    // Set as active server if it's the only one
    if (_servers.length == 1) {
      await setActiveServer(id);
    }

    print('[ServerConfig] Added server: ${config.getDisplayName()} ($id)');
    return config;
  }

  /// Remove a server
  static Future<bool> removeServer(String serverId) async {
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index == -1) {
      print('[ServerConfig] Server not found: $serverId');
      return false;
    }

    _servers.removeAt(index);
    await _saveServers();

    // If removing active server, switch to another
    if (_activeServerId == serverId) {
      if (_servers.isNotEmpty) {
        await setActiveServer(_servers.first.id);
      } else {
        _activeServerId = null;
        await _storage.delete(key: _storageKeyActiveServer);
      }
    }

    print('[ServerConfig] Removed server: $serverId');
    return true;
  }

  /// Get all servers
  static List<ServerConfig> getAllServers() {
    return List.unmodifiable(_servers);
  }

  /// Get active server
  static ServerConfig? getActiveServer() {
    if (_activeServerId == null) return null;
    return _servers.firstWhere((s) => s.id == _activeServerId, orElse: () => _servers.first);
  }

  /// Set active server
  static Future<void> setActiveServer(String serverId) async {
    final server = _servers.firstWhere((s) => s.id == serverId);
    _activeServerId = serverId;
    
    // Update lastActive timestamp
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index != -1) {
      _servers[index] = server.copyWith(lastActive: DateTime.now());
      
      // Re-sort by lastActive
      _servers.sort((a, b) => b.lastActive.compareTo(a.lastActive));
      
      await _saveServers();
    }
    
    await _saveActiveServerId();
    print('[ServerConfig] Set active server: $serverId');
  }

  /// Get server by ID
  static ServerConfig? getServerById(String serverId) {
    try {
      return _servers.firstWhere((s) => s.id == serverId);
    } catch (e) {
      return null;
    }
  }

  /// Update server icon
  static Future<void> updateServerIcon(String serverId, String iconPath) async {
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index != -1) {
      _servers[index] = _servers[index].copyWith(iconPath: iconPath);
      await _saveServers();
      print('[ServerConfig] Updated icon for $serverId: $iconPath');
    }
  }

  /// Update server unread count
  static Future<void> updateUnreadCount(String serverId, int count) async {
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index != -1) {
      _servers[index] = _servers[index].copyWith(unreadCount: count);
      await _saveServers();
      print('[ServerConfig] Updated unread count for $serverId: $count');
    }
  }

  /// Increment unread count
  static Future<void> incrementUnreadCount(String serverId, [int amount = 1]) async {
    final server = getServerById(serverId);
    if (server != null) {
      await updateUnreadCount(serverId, server.unreadCount + amount);
    }
  }

  /// Reset unread count (when user switches to server)
  static Future<void> resetUnreadCount(String serverId) async {
    await updateUnreadCount(serverId, 0);
  }

  /// Check if any servers exist
  static bool hasServers() {
    return _servers.isNotEmpty;
  }

  /// Get last active server (for auto-open on app start)
  static ServerConfig? getLastActiveServer() {
    if (_servers.isEmpty) return null;
    // Servers are already sorted by lastActive
    return _servers.first;
  }

  /// Update server display name
  static Future<void> updateDisplayName(String serverId, String displayName) async {
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index != -1) {
      _servers[index] = _servers[index].copyWith(displayName: displayName);
      await _saveServers();
      print('[ServerConfig] Updated display name for $serverId: $displayName');
    }
  }

  /// Update server credentials (HMAC session data)
  static Future<void> updateCredentials(String serverId, String credentials) async {
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index != -1) {
      _servers[index] = _servers[index].copyWith(credentials: credentials);
      await _saveServers();
      print('[ServerConfig] Updated credentials for $serverId');
    }
  }

  /// Clear all servers (for testing or logout all)
  static Future<void> clearAll() async {
    _servers.clear();
    _activeServerId = null;
    await _storage.delete(key: _storageKeyServerList);
    await _storage.delete(key: _storageKeyActiveServer);
    print('[ServerConfig] Cleared all servers');
  }
}
