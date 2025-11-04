import 'api_service.dart';
import '../web_config.dart';

/// Service for loading and caching user profiles (displayName, picture, atName)
class UserProfileService {
  static final UserProfileService instance = UserProfileService._();
  UserProfileService._();

  // Cache: uuid -> profile data
  final Map<String, Map<String, dynamic>> _cache = {};
  bool _isLoading = false;

  /// Load all user profiles from /people/list
  Future<void> loadAllProfiles() async {
    if (_isLoading) return;
    
    _isLoading = true;
    try {
      // First load own profile
      await loadOwnProfile();
      
      // Get API server URL
      final apiServer = await loadWebApiServer();
      if (apiServer == null || apiServer.isEmpty) {
        print('[UserProfileService] No API server configured');
        return;
      }
      
      String urlString = apiServer;
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      
      ApiService.init();
      final resp = await ApiService.get('$urlString/people/list');
      
      if (resp.statusCode == 200) {
        List<dynamic> users = [];
        
        if (resp.data is List) {
          users = resp.data as List<dynamic>;
        } else if (resp.data is Map) {
          final data = resp.data as Map<String, dynamic>;
          if (data.containsKey('users')) {
            users = data['users'] as List<dynamic>;
          } else if (data.containsKey('people')) {
            users = data['people'] as List<dynamic>;
          }
        }
        
        // Cache all profiles
        for (var user in users) {
          if (user is Map && user['uuid'] != null) {
            final uuid = user['uuid'] as String;
            
            // Extract picture as String (handle both direct string and nested objects)
            String? pictureData;
            final picture = user['picture'];
            if (picture is String) {
              pictureData = picture;
            } else if (picture is Map && picture['data'] != null) {
              pictureData = picture['data'] as String?;
            }
            
            _cache[uuid] = {
              'uuid': uuid,
              'displayName': user['displayName'] ?? uuid,
              'atName': user['atName'] ?? user['displayName'] ?? uuid,
              'picture': pictureData, // base64 or URL (always String or null)
            };
          }
        }
        
        print('[UserProfileService] Cached ${_cache.length} user profiles');
      }
    } catch (e) {
      print('[UserProfileService] Error loading profiles: $e');
    } finally {
      _isLoading = false;
    }
  }

  /// Get displayName for a UUID (returns UUID if not found)
  String getDisplayName(String uuid) {
    final cached = _cache[uuid]?['displayName'];
    if (cached != null) return cached;
    
    // If not in cache and cache is empty, try to load profiles
    if (_cache.isEmpty && !_isLoading) {
      print('[UserProfileService] Cache empty, triggering background load for: $uuid');
      loadAllProfiles(); // Fire and forget - won't help this call but will help future ones
    }
    
    return uuid; // Fallback to UUID
  }

  /// Get atName for a UUID
  String? getAtName(String uuid) {
    return _cache[uuid]?['atName'];
  }

  /// Get profile picture (base64 or URL) for a UUID
  String? getPicture(String uuid) {
    return _cache[uuid]?['picture'];
  }

  /// Get full profile data for a UUID
  Map<String, dynamic>? getProfile(String uuid) {
    return _cache[uuid];
  }

  /// Resolve multiple UUIDs to displayNames (used for bulk operations)
  Map<String, String> resolveDisplayNames(List<String> uuids) {
    final result = <String, String>{};
    for (var uuid in uuids) {
      result[uuid] = getDisplayName(uuid);
    }
    return result;
  }

  /// Clear cache (useful when logging out)
  void clearCache() {
    _cache.clear();
  }

  /// Check if profiles are loaded
  bool get isLoaded => _cache.isNotEmpty;
  
  /// Load current user's own profile and cache it
  Future<void> loadOwnProfile() async {
    try {
      // Get API server URL
      final apiServer = await loadWebApiServer();
      if (apiServer == null || apiServer.isEmpty) {
        print('[UserProfileService] No API server configured for own profile');
        return;
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
          // Extract picture as String (handle both direct string and nested objects)
          String? pictureData;
          final picture = data['picture'];
          if (picture is String) {
            pictureData = picture;
          } else if (picture is Map && picture['data'] != null) {
            pictureData = picture['data'] as String?;
          }
          
          _cache[uuid] = {
            'uuid': uuid,
            'displayName': data['displayName'] ?? uuid,
            'atName': data['atName'] ?? data['displayName'] ?? uuid,
            'picture': pictureData,
          };
          
          print('[UserProfileService] Cached own profile: $uuid');
        }
      }
    } catch (e) {
      print('[UserProfileService] Error loading own profile: $e');
    }
  }
}
