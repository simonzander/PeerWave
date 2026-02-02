import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'api_service.dart';
import '../web_config.dart';
import 'server_config_native.dart'
    if (dart.library.html) 'server_config_web.dart';
import 'storage/sqlite_recent_conversations_store.dart';
import 'storage/sqlite_group_message_store.dart';

/// Cached profile with TTL
class _CachedProfile {
  final Map<String, dynamic> data;
  final DateTime loadedAt;
  String? presenceStatus; // 'online', 'busy', or 'offline'
  DateTime? lastSeen;

  _CachedProfile(
    this.data,
    this.loadedAt, {
    this.presenceStatus,
    this.lastSeen,
  });

  bool get isStale {
    return DateTime.now().difference(loadedAt) > const Duration(hours: 24);
  }
}

/// Service for loading and caching user profiles (displayName, picture, atName)
///
/// Smart Loading Strategy:
/// 1. Load own profile + recent conversation partners on init
/// 2. Load profiles on-demand when messages arrive from unknown users
/// 3. Load discover users when People page is opened
///
/// Cache TTL: 24 hours
/// Server Offline: Operations fail with exception instead of showing UUIDs
///
/// Multi-Server Support:
/// - Maintains separate profile caches per server
/// - Automatically switches to current server's cache
/// - No need to clear cache when switching servers
class UserProfileService {
  static final UserProfileService instance = UserProfileService._();
  UserProfileService._();

  // Per-server cache: serverId -> uuid -> {profile data + timestamp}
  final Map<String, Map<String, _CachedProfile>> _cache = {};

  // Track UUIDs currently being loaded per server: serverId -> Set<uuid>
  final Map<String, Set<String>> _loadingUuids = {};

  // Callbacks waiting for profiles to load: serverId -> uuid -> List of callbacks
  final Map<String, Map<String, List<void Function(Map<String, dynamic>?)>>>
  _pendingCallbacks = {};

  bool _isInitialLoading = false;

  /// Get the current active server ID
  String? get _currentServerId {
    if (kIsWeb) {
      return 'web'; // Web uses a fixed server ID
    }
    final activeServer = ServerConfigService.getActiveServer();
    return activeServer?.id;
  }

  /// Get or create the profile cache for a server
  Map<String, _CachedProfile> _getServerCache(String? serverId) {
    serverId ??= 'web'; // Fallback for web
    return _cache.putIfAbsent(serverId, () => {});
  }

  /// Get or create the loading set for a server
  Set<String> _getLoadingSet(String? serverId) {
    serverId ??= 'web'; // Fallback for web
    return _loadingUuids.putIfAbsent(serverId, () => {});
  }

  /// Get or create the pending callbacks map for a server
  Map<String, List<void Function(Map<String, dynamic>?)>> _getPendingCallbacks(
    String? serverId,
  ) {
    serverId ??= 'web'; // Fallback for web
    return _pendingCallbacks.putIfAbsent(serverId, () => {});
  }

  /// Get current user's UUID (from own profile cache for current server)
  /// Returns null if own profile not loaded yet
  String? get currentUserUuid {
    final serverCache = _getServerCache(_currentServerId);
    debugPrint(
      '[UserProfileService] currentUserUuid getter called. Server: $_currentServerId, Cache size: ${serverCache.length}',
    );

    // Find own profile in cache by checking for the profile that matches current user
    // The own profile is cached during loadOwnProfile()
    for (final entry in serverCache.entries) {
      final profile = entry.value.data;
      debugPrint(
        '[UserProfileService] Checking profile UUID: ${entry.key}, isOwnProfile: ${profile['isOwnProfile']}',
      );

      if (profile['isOwnProfile'] == true) {
        debugPrint('[UserProfileService] Found own profile: ${entry.key}');
        return entry.key;
      }
    }

    // Fallback: check if we have exactly one profile cached (likely our own)
    if (serverCache.length == 1) {
      final uuid = serverCache.keys.first;
      debugPrint('[UserProfileService] Using fallback (single profile): $uuid');
      return uuid;
    }

    debugPrint(
      '[UserProfileService] No own profile found in cache for server $_currentServerId',
    );
    return null;
  }

  /// Initialize profiles: Load own profile + recent conversation partners
  Future<void> initProfiles() async {
    if (_isInitialLoading) return;

    _isInitialLoading = true;
    try {
      debugPrint('[UserProfileService] Starting initial profile load...');

      // 1. Load own profile
      await loadOwnProfile();

      // 2. Get UUIDs from recent conversations
      final uuidsToLoad = <String>{};

      try {
        // Get 1:1 conversation partners
        final conversationStore =
            await SqliteRecentConversationsStore.getInstance();
        final conversations = await conversationStore.getRecentConversations();
        for (final conv in conversations) {
          final userId = conv['user_id'] as String?;
          if (userId != null) uuidsToLoad.add(userId);
        }

        // Get group message senders
        final groupStore = await SqliteGroupMessageStore.getInstance();
        final channels = await groupStore.getAllChannels();
        for (final channelId in channels) {
          final messages = await groupStore.getChannelMessages(channelId);
          for (final msg in messages) {
            final sender = msg['sender'] as String?;
            if (sender != null && sender != 'me') {
              uuidsToLoad.add(sender);
            }
          }
        }

        debugPrint(
          '[UserProfileService] Found ${uuidsToLoad.length} users from recent conversations',
        );
      } catch (e) {
        debugPrint(
          '[UserProfileService] Error loading UUIDs from database: $e',
        );
      }

      // 3. Load profiles for these users
      if (uuidsToLoad.isNotEmpty) {
        await loadProfiles(uuidsToLoad.toList());
      }

      debugPrint(
        '[UserProfileService] Initial profile load complete. Cached: ${_cache.length} profiles',
      );
    } catch (e) {
      debugPrint('[UserProfileService] Error during init: $e');
      rethrow;
    } finally {
      _isInitialLoading = false;
    }
  }

  /// Load profiles for a list of UUIDs (batch operation) for current server
  Future<void> loadProfiles(List<String> uuids) async {
    if (uuids.isEmpty) return;

    final serverId = _currentServerId;
    final serverCache = _getServerCache(serverId);
    final loadingSet = _getLoadingSet(serverId);

    // Filter out already cached (non-stale) UUIDs
    final uuidsToLoad = <String>[];
    for (final uuid in uuids) {
      final cached = serverCache[uuid];
      if (cached == null || cached.isStale) {
        if (!loadingSet.contains(uuid)) {
          uuidsToLoad.add(uuid);
        }
      }
    }

    if (uuidsToLoad.isEmpty) {
      debugPrint(
        '[UserProfileService] All ${uuids.length} profiles already cached for server $serverId',
      );
      return;
    }

    // Mark as loading
    loadingSet.addAll(uuidsToLoad);

    try {
      debugPrint(
        '[UserProfileService] Loading ${uuidsToLoad.length} profiles...',
      );

      // Get server URL from appropriate source
      String? apiServer;
      if (kIsWeb) {
        // Web: Load from web config
        apiServer = await loadWebApiServer();
      } else {
        // Native: Get from ServerConfigService
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          apiServer = activeServer.serverUrl;
        }
      }

      if (apiServer == null || apiServer.isEmpty) {
        throw Exception('No API server configured');
      }

      // Batch request: /people/profiles?uuids=uuid1,uuid2,uuid3
      final uuidsParam = uuidsToLoad.join(',');
      await ApiService.instance.init();
      final resp = await ApiService.instance.get(
        ApiService.instance.buildUrl('/people/profiles?uuids=$uuidsParam'),
      );

      if (resp.statusCode == 200) {
        List<dynamic> profiles = [];

        if (resp.data is List) {
          profiles = resp.data as List<dynamic>;
        } else if (resp.data is Map) {
          final data = resp.data as Map<String, dynamic>;
          if (data.containsKey('profiles')) {
            profiles = data['profiles'] as List<dynamic>;
          } else if (data.containsKey('users')) {
            profiles = data['users'] as List<dynamic>;
          }
        }

        // Cache all loaded profiles
        for (final profile in profiles) {
          if (profile is Map && profile['uuid'] != null) {
            final uuid = profile['uuid'] as String;
            _cacheProfile(uuid, Map<String, dynamic>.from(profile), serverId);
          }
        }

        debugPrint(
          '[UserProfileService] ✓ Loaded ${profiles.length}/${uuidsToLoad.length} profiles for server $serverId',
        );
      } else {
        throw Exception('Failed to load profiles: ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint(
        '[UserProfileService] ✗ Error loading profiles for server $serverId: $e',
      );
      rethrow;
    } finally {
      loadingSet.removeAll(uuidsToLoad);
    }
  }

  /// Load a single profile (convenience method)
  Future<void> loadProfile(String uuid) async {
    return loadProfiles([uuid]);
  }

  /// Ensure a profile is loaded. Throws if server is unavailable.
  /// Use this before displaying messages from a user.
  Future<void> ensureProfileLoaded(String uuid) async {
    final serverId = _currentServerId;
    final serverCache = _getServerCache(serverId);
    final loadingSet = _getLoadingSet(serverId);
    final cached = serverCache[uuid];

    // Already cached and fresh
    if (cached != null && !cached.isStale) {
      return;
    }

    // Already loading
    if (loadingSet.contains(uuid)) {
      // Wait for it to finish (simple polling, could use Completer for better approach)
      int attempts = 0;
      while (loadingSet.contains(uuid) && attempts < 50) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }
      return;
    }

    // Load it
    try {
      await loadProfile(uuid);
    } catch (e) {
      // Server unavailable
      throw Exception('Server unavailable - cannot load user profile');
    }
  }

  /// Ensure multiple profiles are loaded. Throws if server is unavailable.
  Future<void> ensureProfilesLoaded(List<String> uuids) async {
    final serverId = _currentServerId;
    final serverCache = _getServerCache(serverId);
    final loadingSet = _getLoadingSet(serverId);
    final uuidsToLoad = <String>[];

    for (final uuid in uuids) {
      final cached = serverCache[uuid];
      if (cached == null || cached.isStale) {
        if (!loadingSet.contains(uuid)) {
          uuidsToLoad.add(uuid);
        }
      }
    }

    if (uuidsToLoad.isEmpty) return;

    try {
      await loadProfiles(uuidsToLoad);
    } catch (e) {
      throw Exception('Server unavailable - cannot load user profiles');
    }
  }

  /// Cache a profile with current timestamp for a specific server
  void _cacheProfile(String uuid, Map<String, dynamic> data, String? serverId) {
    if (serverId == null) return;

    final serverCache = _getServerCache(serverId);
    final pendingCallbacks = _getPendingCallbacks(serverId);

    // Extract picture as String (handle both direct string and nested objects)
    String? pictureData;
    final picture = data['picture'];
    if (picture is String) {
      pictureData = picture;
    } else if (picture is Map && picture['data'] != null) {
      pictureData = picture['data'] as String?;
    }

    // Extract presence data
    String? presenceStatus;
    DateTime? lastSeen;
    if (data['presence'] != null && data['presence'] is Map) {
      final presence = data['presence'] as Map<String, dynamic>;
      presenceStatus = presence['status'] as String?;
      final lastSeenStr = presence['last_seen'] as String?;
      if (lastSeenStr != null) {
        try {
          lastSeen = DateTime.parse(lastSeenStr);
        } catch (e) {
          debugPrint('[UserProfileService] Error parsing last_seen: $e');
        }
      }
    }

    final profileData = {
      'uuid': uuid,
      'displayName': data['displayName'] ?? uuid,
      'atName': data['atName'] ?? data['displayName'] ?? uuid,
      'picture': pictureData,
      'isOwnProfile': data['isOwnProfile'], // Preserve isOwnProfile marker
    };

    serverCache[uuid] = _CachedProfile(
      profileData,
      DateTime.now(),
      presenceStatus: presenceStatus,
      lastSeen: lastSeen,
    );

    // Notify any pending callbacks
    final callbacks = pendingCallbacks.remove(uuid);
    if (callbacks != null) {
      for (final callback in callbacks) {
        try {
          callback(profileData);
        } catch (e) {
          debugPrint('[UserProfileService] Error in callback for $uuid: $e');
        }
      }
    }
  }

  /// Get displayName for a UUID (current server)
  /// Returns null if not cached (caller should handle loading)
  String? getDisplayName(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached == null) return null;
    if (cached.isStale) return null; // Don't return stale data
    return cached.data['displayName'] as String?;
  }

  /// Get displayName or fallback to UUID (use only when sure profile is loaded)
  String getDisplayNameOrUuid(String uuid) {
    return getDisplayName(uuid) ?? uuid;
  }

  /// Get profile with automatic loading and callback when ready
  ///
  /// Returns cached profile immediately if available.
  /// If not cached, triggers async load and calls onLoaded when ready.
  ///
  /// Usage:
  /// ```dart
  /// String displayName = 'Loading...';
  ///
  /// final profile = UserProfileService.instance.getProfileOrLoad(
  ///   userId,
  ///   onLoaded: (profile) {
  ///     setState(() {
  ///       displayName = profile?['displayName'] ?? userId;
  ///     });
  ///   },
  /// );
  ///
  /// if (profile != null) {
  ///   displayName = profile['displayName'] ?? userId;
  /// }
  /// ```
  Map<String, dynamic>? getProfileOrLoad(
    String uuid, {
    void Function(Map<String, dynamic>?)? onLoaded,
  }) {
    final serverId = _currentServerId;
    final serverCache = _getServerCache(serverId);
    final loadingSet = _getLoadingSet(serverId);
    final pendingCallbacks = _getPendingCallbacks(serverId);

    // Check cache first
    final cached = serverCache[uuid];
    if (cached != null && !cached.isStale) {
      // Already cached - return immediately
      return cached.data;
    }

    // Not cached - register callback and trigger load
    if (onLoaded != null) {
      pendingCallbacks.putIfAbsent(uuid, () => []).add(onLoaded);
    }

    // Trigger load if not already loading
    if (!loadingSet.contains(uuid)) {
      loadProfile(uuid).catchError((e) {
        debugPrint('[UserProfileService] Failed to load profile $uuid: $e');
        // Call callbacks with null on error
        final callbacks = pendingCallbacks.remove(uuid);
        if (callbacks != null) {
          for (final callback in callbacks) {
            try {
              callback(null);
            } catch (e) {
              debugPrint('[UserProfileService] Error in error callback: $e');
            }
          }
        }
      });
    }

    return null; // Will call onLoaded when ready
  }

  /// Get atName for a UUID (current server)
  String? getAtName(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.data['atName'] as String?;
  }

  /// Get profile picture (base64 or URL) for a UUID (current server)
  String? getPicture(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.data['picture'] as String?;
  }

  /// Get full profile data for a UUID (current server)
  Map<String, dynamic>? getProfile(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.data;
  }

  /// Check if profile is cached and fresh (current server)
  bool isProfileCached(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    return cached != null && !cached.isStale;
  }

  /// Resolve multiple UUIDs to displayNames (current server)
  Map<String, String?> resolveDisplayNames(List<String> uuids) {
    final result = <String, String?>{};
    for (var uuid in uuids) {
      result[uuid] = getDisplayName(uuid);
    }
    return result;
  }

  /// Clear cache for current server only
  void clearCache() {
    final serverId = _currentServerId;
    if (serverId != null) {
      _cache.remove(serverId);
      _loadingUuids.remove(serverId);
      _pendingCallbacks.remove(serverId);
      debugPrint('[UserProfileService] ✓ Cache cleared for server $serverId');
    }
  }

  /// Clear cache for all servers (useful when logging out)
  void clearAllCaches() {
    _cache.clear();
    _loadingUuids.clear();
    _pendingCallbacks.clear();
    debugPrint('[UserProfileService] ✓ All server caches cleared');
  }

  /// Check if initial profiles are loaded for current server
  bool get isLoaded {
    final serverCache = _getServerCache(_currentServerId);
    return serverCache.isNotEmpty;
  }

  /// Get cache size for current server (for debugging)
  int get cacheSize {
    final serverCache = _getServerCache(_currentServerId);
    return serverCache.length;
  }

  /// Get total cache size across all servers (for debugging)
  int get totalCacheSize {
    return _cache.values.fold(0, (sum, cache) => sum + cache.length);
  }

  /// Find user UUID by atName (searches cache for current server)
  String? findUuidByAtName(String atName) {
    final serverCache = _getServerCache(_currentServerId);
    for (final entry in serverCache.entries) {
      final profile = entry.value;
      if (!profile.isStale) {
        final profileAtName = profile.data['atName'] as String?;
        if (profileAtName?.toLowerCase() == atName.toLowerCase()) {
          return entry.key; // Return the UUID
        }
      }
    }
    return null;
  }

  /// Get profile by atName (searches cache for current server)
  Map<String, dynamic>? getProfileByAtName(String atName) {
    final uuid = findUuidByAtName(atName);
    if (uuid != null) {
      return getProfile(uuid);
    }
    return null;
  }

  /// Get presence status for a UUID ('online', 'busy', 'offline') for current server
  /// Returns cached presence if available, null otherwise
  String? getPresenceStatus(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.presenceStatus ?? 'offline';
  }

  /// Get last seen timestamp for a UUID (current server)
  /// Returns null if not available or user is currently online
  DateTime? getLastSeen(String uuid) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.lastSeen;
  }

  /// Check if a user is online (online or busy) on current server
  /// Returns false if not cached or offline
  bool isUserOnline(String uuid) {
    final status = getPresenceStatus(uuid);
    return status == 'online' || status == 'busy';
  }

  /// Check if a user is busy (in a call) on current server
  /// Returns false if not cached or not busy
  bool isUserBusy(String uuid) {
    final status = getPresenceStatus(uuid);
    return status == 'busy';
  }

  /// Update presence status for a user on current server (called from PresenceService real-time updates)
  void updatePresenceStatus(String uuid, String status, DateTime? lastSeen) {
    final serverCache = _getServerCache(_currentServerId);
    final cached = serverCache[uuid];
    if (cached != null) {
      cached.presenceStatus = status;
      cached.lastSeen = lastSeen;
      debugPrint(
        '[UserProfileService] Updated presence for $uuid: $status (server: $_currentServerId)',
      );
    }
  }

  /// Load current user's own profile and cache it
  Future<void> loadOwnProfile() async {
    try {
      // Get server URL from appropriate source
      String? apiServer;
      if (kIsWeb) {
        // Web: Load from web config
        apiServer = await loadWebApiServer();
      } else {
        // Native: Get from ServerConfigService
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          apiServer = activeServer.serverUrl;
        }
      }

      if (apiServer == null || apiServer.isEmpty) {
        throw Exception('No API server configured');
      }

      String urlString = apiServer;
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }

      await ApiService.instance.init();
      final resp = await ApiService.instance.get(
        ApiService.instance.buildUrl('/client/profile'),
      );

      if (resp.statusCode == 200) {
        final data = resp.data;
        final uuid = data['uuid'] as String?;

        debugPrint('[UserProfileService] loadOwnProfile response: uuid=$uuid');

        if (uuid != null) {
          // Mark as own profile for currentUserUuid getter
          final profileData = Map<String, dynamic>.from(data);
          profileData['isOwnProfile'] = true;
          debugPrint(
            '[UserProfileService] Setting isOwnProfile=true for uuid=$uuid',
          );
          _cacheProfile(uuid, profileData, _currentServerId);
          debugPrint(
            '[UserProfileService] ✓ Cached own profile: $uuid with isOwnProfile=${profileData['isOwnProfile']} (server: $_currentServerId)',
          );
        } else {
          debugPrint('[UserProfileService] ✗ No uuid in profile response');
        }
      } else {
        throw Exception('Failed to load own profile: ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[UserProfileService] ✗ Error loading own profile: $e');
      rethrow;
    }
  }

  /// DEPRECATED: Old method for backward compatibility
  /// New code should use initProfiles() instead
  @Deprecated('Use initProfiles() instead')
  Future<void> loadAllProfiles() async {
    debugPrint(
      '[UserProfileService] ⚠️ loadAllProfiles() is deprecated, use initProfiles()',
    );
    return initProfiles();
  }
}
