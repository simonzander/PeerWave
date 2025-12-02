import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'clientid_native.dart';
import 'session_auth_service.dart';
import 'api_service.dart';

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
  String? serverPicture;        // Base64 server picture from /client/meta
  String? serverName;           // Server name from /client/meta

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
    this.serverPicture,
    this.serverName,
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
      'serverPicture': serverPicture,
      'serverName': serverName,
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
      serverPicture: json['serverPicture'] as String?,
      serverName: json['serverName'] as String?,
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
    // Priority: 1. displayName, 2. serverName, 3. hostname
    if (displayName != null && displayName!.isNotEmpty) {
      return displayName![0].toUpperCase();
    }
    if (serverName != null && serverName!.isNotEmpty) {
      return serverName![0].toUpperCase();
    }
    // Fallback to hostname (only until we fetch server metadata)
    final name = getDisplayName();
    return name.isNotEmpty ? name[0].toUpperCase() : 'S';
  }

  ServerConfig copyWith({
    String? iconPath,
    DateTime? lastActive,
    int? unreadCount,
    String? displayName,
    String? credentials,
    String? serverPicture,
    String? serverName,
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
      serverPicture: serverPicture ?? this.serverPicture,
      serverName: serverName ?? this.serverName,
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
    await _cleanupStaleServers(); // Remove servers without valid sessions
    print('[ServerConfig] Initialized with ${_servers.length} servers');
  }

  /// Remove servers that don't have valid HMAC sessions
  static Future<void> _cleanupStaleServers() async {
    if (_servers.isEmpty) return;

    final clientId = await ClientIdService.getClientId();
    final hasSession = await SessionAuthService().hasSession(clientId);

    if (!hasSession && _servers.isNotEmpty) {
      print('[ServerConfig] No valid session found - clearing all servers');
      _servers.clear();
      await _saveServers();
      _activeServerId = null;
      await _storage.delete(key: _storageKeyActiveServer);
    }
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

  /// Delete server and all associated data (SQLite databases, secure storage)
  static Future<bool> deleteServerWithData(String serverId) async {
    final server = _servers.firstWhere(
      (s) => s.id == serverId,
      orElse: () => ServerConfig(
        id: '',
        serverUrl: '',
        serverHash: '',
        credentials: '',
        lastActive: DateTime.now(),
        createdAt: DateTime.now(),
      ),
    );

    if (server.id.isEmpty) {
      print('[ServerConfig] Server not found: $serverId');
      return false;
    }

    print('[ServerConfig] Deleting server and all data: ${server.getDisplayName()} ($serverId)');

    try {
      // 1. Delete SQLite databases for this server's device
      // Note: For native, we can't easily determine which databases belong to which server
      // because device ID is based on email+credentialId+clientId (shared across servers)
      // So we'll just delete databases if this is the ONLY server being deleted
      final documentsDir = await getApplicationDocumentsDirectory();
      final directory = Directory(documentsDir.path);
      
      // Check if this is the last server
      final isLastServer = _servers.length == 1;
      
      if (isLastServer && await directory.exists()) {
        print('[ServerConfig] This is the last server - deleting all SQLite databases');
        final files = await directory.list().toList();
        // Look for peerwave_*.db files
        for (final file in files) {
          final fileName = path.basename(file.path);
          if (fileName.startsWith('peerwave_') && fileName.endsWith('.db')) {
            try {
              await file.delete();
              print('[ServerConfig] Deleted database: ${file.path}');
            } catch (e) {
              print('[ServerConfig] Error deleting database ${file.path}: $e');
            }
          }
        }
        
        // 2. Delete secure storage keys (only if last server)
        print('[ServerConfig] Deleting all secure storage keys');
        final allKeys = await _storage.readAll();
        final keysToDelete = [
          'session_secret_',
          'session_metadata_',
          'peerwave_encryption_key_',
          'device_identity',
          'server_list',
          'active_server_id',
        ];
        
        for (final entry in allKeys.entries) {
          final key = entry.key;
          
          // Check if key should be deleted
          if (keysToDelete.any((prefix) => key.contains(prefix) || key == prefix)) {
            try {
              await _storage.delete(key: key);
              print('[ServerConfig] Deleted secure storage key: $key');
            } catch (e) {
              print('[ServerConfig] Error deleting key $key: $e');
            }
          }
        }
      } else {
        print('[ServerConfig] Multiple servers exist - keeping shared data (device identity, encryption keys)');
      }

      // 3. Remove server from config list
      await removeServer(serverId);

      print('[ServerConfig] ✓ Server and all associated data deleted: $serverId');
      return true;
    } catch (e) {
      print('[ServerConfig] Error deleting server data: $e');
      rethrow;
    }
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

  /// Fetch and update server metadata (name and picture) from /client/meta
  static Future<void> updateServerMetadata(String serverId) async {
    try {
      final index = _servers.indexWhere((s) => s.id == serverId);
      if (index == -1) {
        print('[ServerConfig] Server not found: $serverId');
        return;
      }

      final server = _servers[index];
      
      // Fetch /client/meta
      final response = await ApiService.get('${server.serverUrl}/client/meta');
      
      if (response.statusCode == 200) {
        final data = response.data;
        final serverName = data['serverName'] as String?;
        final serverPicture = data['serverPicture'] as String?;
        
        // Update server config
        _servers[index] = server.copyWith(
          serverName: serverName,
          serverPicture: serverPicture,
          displayName: server.displayName ?? serverName, // Use server name as default if no custom name
        );
        
        await _saveServers();
        print('[ServerConfig] Updated metadata for ${server.getDisplayName()}: name=$serverName, hasPicture=${serverPicture != null}');
      }
    } catch (e) {
      print('[ServerConfig] Failed to fetch server metadata for $serverId: $e');
    }
  }

  /// Update unread count from UnreadMessagesProvider (for active server)
  static Future<void> updateUnreadCountFromProvider(
    String serverId,
    int totalChannelUnread,
    int totalDirectMessageUnread,
    int totalActivityNotifications,
  ) async {
    final total = totalChannelUnread + totalDirectMessageUnread + totalActivityNotifications;
    await updateUnreadCount(serverId, total);
  }

  /// Save current server's unread count before switching (called by ServerPanel)
  static Future<void> saveCurrentServerUnreadCount(
    int totalChannelUnread,
    int totalDirectMessageUnread,
    int totalActivityNotifications,
  ) async {
    final activeServer = getActiveServer();
    if (activeServer != null) {
      await updateUnreadCountFromProvider(
        activeServer.id,
        totalChannelUnread,
        totalDirectMessageUnread,
        totalActivityNotifications,
      );
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
