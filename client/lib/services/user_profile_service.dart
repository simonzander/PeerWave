import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import '../web_config.dart';
import 'storage/sqlite_recent_conversations_store.dart';
import 'storage/sqlite_group_message_store.dart';

/// Cached profile with TTL
class _CachedProfile {
  final Map<String, dynamic> data;
  final DateTime loadedAt;
  
  _CachedProfile(this.data, this.loadedAt);
  
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
class UserProfileService {
  static final UserProfileService instance = UserProfileService._();
  UserProfileService._();

  // Cache: uuid -> {profile data + timestamp}
  final Map<String, _CachedProfile> _cache = {};
  
  // Track UUIDs currently being loaded (prevent duplicate requests)
  final Set<String> _loadingUuids = {};
  
  bool _isInitialLoading = false;

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
        final conversationStore = await SqliteRecentConversationsStore.getInstance();
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
        
        debugPrint('[UserProfileService] Found ${uuidsToLoad.length} users from recent conversations');
      } catch (e) {
        debugPrint('[UserProfileService] Error loading UUIDs from database: $e');
      }
      
      // 3. Load profiles for these users
      if (uuidsToLoad.isNotEmpty) {
        await loadProfiles(uuidsToLoad.toList());
      }
      
      debugPrint('[UserProfileService] Initial profile load complete. Cached: ${_cache.length} profiles');
    } catch (e) {
      debugPrint('[UserProfileService] Error during init: $e');
      rethrow;
    } finally {
      _isInitialLoading = false;
    }
  }

  /// Load profiles for a list of UUIDs (batch operation)
  Future<void> loadProfiles(List<String> uuids) async {
    if (uuids.isEmpty) return;
    
    // Filter out already cached (non-stale) UUIDs
    final uuidsToLoad = <String>[];
    for (final uuid in uuids) {
      final cached = _cache[uuid];
      if (cached == null || cached.isStale) {
        if (!_loadingUuids.contains(uuid)) {
          uuidsToLoad.add(uuid);
        }
      }
    }
    
    if (uuidsToLoad.isEmpty) {
      debugPrint('[UserProfileService] All ${uuids.length} profiles already cached');
      return;
    }
    
    // Mark as loading
    _loadingUuids.addAll(uuidsToLoad);
    
    try {
      debugPrint('[UserProfileService] Loading ${uuidsToLoad.length} profiles...');
      
      final apiServer = await loadWebApiServer();
      if (apiServer == null || apiServer.isEmpty) {
        throw Exception('No API server configured');
      }
      
      String urlString = apiServer;
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      
      // Batch request: /people/profiles?uuids=uuid1,uuid2,uuid3
      final uuidsParam = uuidsToLoad.join(',');
      ApiService.init();
      final resp = await ApiService.get('$urlString/people/profiles?uuids=$uuidsParam');
      
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
            _cacheProfile(uuid, Map<String, dynamic>.from(profile));
          }
        }
        
        debugPrint('[UserProfileService] ✓ Loaded ${profiles.length}/${uuidsToLoad.length} profiles');
      } else {
        throw Exception('Failed to load profiles: ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[UserProfileService] ✗ Error loading profiles: $e');
      rethrow;
    } finally {
      _loadingUuids.removeAll(uuidsToLoad);
    }
  }

  /// Load a single profile (convenience method)
  Future<void> loadProfile(String uuid) async {
    return loadProfiles([uuid]);
  }

  /// Ensure a profile is loaded. Throws if server is unavailable.
  /// Use this before displaying messages from a user.
  Future<void> ensureProfileLoaded(String uuid) async {
    final cached = _cache[uuid];
    
    // Already cached and fresh
    if (cached != null && !cached.isStale) {
      return;
    }
    
    // Already loading
    if (_loadingUuids.contains(uuid)) {
      // Wait for it to finish (simple polling, could use Completer for better approach)
      int attempts = 0;
      while (_loadingUuids.contains(uuid) && attempts < 50) {
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
    final uuidsToLoad = <String>[];
    
    for (final uuid in uuids) {
      final cached = _cache[uuid];
      if (cached == null || cached.isStale) {
        if (!_loadingUuids.contains(uuid)) {
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

  /// Cache a profile with current timestamp
  void _cacheProfile(String uuid, Map<String, dynamic> data) {
    // Extract picture as String (handle both direct string and nested objects)
    String? pictureData;
    final picture = data['picture'];
    if (picture is String) {
      pictureData = picture;
    } else if (picture is Map && picture['data'] != null) {
      pictureData = picture['data'] as String?;
    }
    
    final profileData = {
      'uuid': uuid,
      'displayName': data['displayName'] ?? uuid,
      'atName': data['atName'] ?? data['displayName'] ?? uuid,
      'picture': pictureData,
    };
    
    _cache[uuid] = _CachedProfile(profileData, DateTime.now());
  }

  /// Get displayName for a UUID
  /// Returns null if not cached (caller should handle loading)
  String? getDisplayName(String uuid) {
    final cached = _cache[uuid];
    if (cached == null) return null;
    if (cached.isStale) return null; // Don't return stale data
    return cached.data['displayName'] as String?;
  }

  /// Get displayName or fallback to UUID (use only when sure profile is loaded)
  String getDisplayNameOrUuid(String uuid) {
    return getDisplayName(uuid) ?? uuid;
  }

  /// Get atName for a UUID
  String? getAtName(String uuid) {
    final cached = _cache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.data['atName'] as String?;
  }

  /// Get profile picture (base64 or URL) for a UUID
  String? getPicture(String uuid) {
    final cached = _cache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.data['picture'] as String?;
  }

  /// Get full profile data for a UUID
  Map<String, dynamic>? getProfile(String uuid) {
    final cached = _cache[uuid];
    if (cached == null || cached.isStale) return null;
    return cached.data;
  }

  /// Check if profile is cached and fresh
  bool isProfileCached(String uuid) {
    final cached = _cache[uuid];
    return cached != null && !cached.isStale;
  }

  /// Resolve multiple UUIDs to displayNames
  Map<String, String?> resolveDisplayNames(List<String> uuids) {
    final result = <String, String?>{};
    for (var uuid in uuids) {
      result[uuid] = getDisplayName(uuid);
    }
    return result;
  }

  /// Clear cache (useful when logging out)
  void clearCache() {
    _cache.clear();
    _loadingUuids.clear();
  }

  /// Check if initial profiles are loaded
  bool get isLoaded => _cache.isNotEmpty;

  /// Get cache size (for debugging)
  int get cacheSize => _cache.length;
  
  /// Load current user's own profile and cache it
  Future<void> loadOwnProfile() async {
    try {
      final apiServer = await loadWebApiServer();
      if (apiServer == null || apiServer.isEmpty) {
        throw Exception('No API server configured');
      }
      
      String urlString = apiServer;
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      
      ApiService.init();
      final resp = await ApiService.get('$urlString/client/profile');
      
      if (resp.statusCode == 200) {
        final data = resp.data;
        final uuid = data['uuid'] as String?;
        
        if (uuid != null) {
          _cacheProfile(uuid, Map<String, dynamic>.from(data));
          debugPrint('[UserProfileService] ✓ Cached own profile: $uuid');
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
    debugPrint('[UserProfileService] ⚠️ loadAllProfiles() is deprecated, use initProfiles()');
    return initProfiles();
  }
}

