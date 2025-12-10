import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/user_presence.dart';
import 'api_service.dart';
import 'socket_service.dart';

/// Presence service - tracks online/offline status of users
/// 
/// Features:
/// - Automatic heartbeat every 60 seconds (emits presence:heartbeat)
/// - Real-time presence updates via Socket.IO
/// - Local cache of user presence status
/// - Streams for UI updates
/// 
/// Socket.IO events:
/// - presence:heartbeat (emit) - Send heartbeat every 60s
/// - presence:update (listen) - Receive status updates
/// - presence:user_connected (listen) - User came online
/// - presence:user_disconnected (listen) - User went offline
class PresenceService {
  static final PresenceService _instance = PresenceService._internal();
  factory PresenceService() => _instance;
  PresenceService._internal();

  final _socketService = SocketService();

  // Heartbeat timer
  Timer? _heartbeatTimer;
  static const _heartbeatInterval = Duration(seconds: 60);

  // Local presence cache
  final Map<String, UserPresence> _presenceCache = {};

  // Stream controllers
  final _presenceUpdateController = StreamController<UserPresence>.broadcast();
  final _userConnectedController = StreamController<String>.broadcast();
  final _userDisconnectedController = StreamController<String>.broadcast();

  // Public streams
  Stream<UserPresence> get onPresenceUpdate => _presenceUpdateController.stream;
  Stream<String> get onUserConnected => _userConnectedController.stream;
  Stream<String> get onUserDisconnected => _userDisconnectedController.stream;

  bool _listenersRegistered = false;
  bool _heartbeatStarted = false;

  /// Initialize Socket.IO listeners and start heartbeat
  void initialize() {
    _initializeListeners();
    startHeartbeat();
  }

  /// Initialize Socket.IO listeners for presence updates
  void _initializeListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    _socketService.registerListener('presence:update', (data) {
      debugPrint('[PRESENCE SERVICE] Received presence:update: $data');
      try {
        final map = data as Map<String, dynamic>;
        final userId = map['user_id'] as String;
        final lastHeartbeat = DateTime.parse(map['last_heartbeat'] as String);

        final presence = UserPresence(
          userId: userId,
          lastHeartbeat: lastHeartbeat,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        _presenceCache[userId] = presence;
        _presenceUpdateController.add(presence);
      } catch (e) {
        debugPrint('[PRESENCE SERVICE] Error parsing presence:update: $e');
      }
    });

    _socketService.registerListener('presence:user_connected', (data) {
      debugPrint('[PRESENCE SERVICE] Received presence:user_connected: $data');
      try {
        final map = data as Map<String, dynamic>;
        final userId = map['user_id'] as String;
        final lastSeen = DateTime.parse(map['last_seen'] as String);

        final presence = UserPresence(
          userId: userId,
          lastHeartbeat: lastSeen,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        _presenceCache[userId] = presence;
        _userConnectedController.add(userId);
      } catch (e) {
        debugPrint('[PRESENCE SERVICE] Error parsing presence:user_connected: $e');
      }
    });

    _socketService.registerListener('presence:user_disconnected', (data) {
      debugPrint('[PRESENCE SERVICE] Received presence:user_disconnected: $data');
      try {
        final map = data as Map<String, dynamic>;
        final userId = map['user_id'] as String;
        final lastSeen = DateTime.parse(map['last_seen'] as String);

        final presence = UserPresence(
          userId: userId,
          lastHeartbeat: lastSeen,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        _presenceCache[userId] = presence;
        _userDisconnectedController.add(userId);
      } catch (e) {
        debugPrint('[PRESENCE SERVICE] Error parsing presence:user_disconnected: $e');
      }
    });

    debugPrint('[PRESENCE SERVICE] Socket.IO listeners initialized');
  }

  /// Start heartbeat timer (emits every 60 seconds)
  void startHeartbeat() {
    if (_heartbeatStarted) return;
    _heartbeatStarted = true;

    // Send initial heartbeat immediately
    _sendHeartbeat();

    // Start periodic timer
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _sendHeartbeat();
    });

    debugPrint('[PRESENCE SERVICE] Heartbeat timer started (interval: ${_heartbeatInterval.inSeconds}s)');
  }

  /// Stop heartbeat timer
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatStarted = false;
    debugPrint('[PRESENCE SERVICE] Heartbeat timer stopped');
  }

  /// Send heartbeat to server
  void _sendHeartbeat() {
    if (!_socketService.socket!.connected) {
      debugPrint('[PRESENCE SERVICE] Socket not connected, skipping heartbeat');
      return;
    }

    _socketService.emit('presence:heartbeat', {});
    debugPrint('[PRESENCE SERVICE] Sent heartbeat');
  }

  // ============================================================================
  // HTTP API Methods
  // ============================================================================

  /// Get presence for a specific user
  Future<UserPresence?> getUserPresence(String userId) async {
    // Return cached presence if available and fresh (< 2 minutes old)
    if (_presenceCache.containsKey(userId)) {
      final cached = _presenceCache[userId]!;
      final age = DateTime.now().difference(cached.updatedAt);
      if (age.inMinutes < 2) {
        return cached;
      }
    }

    try {
      final response = await ApiService.get('/api/presence/$userId');
      final presence = UserPresence.fromJson(response.data as Map<String, dynamic>);
      _presenceCache[userId] = presence;
      return presence;
    } catch (e) {
      debugPrint('[PRESENCE SERVICE] Error fetching presence for $userId: $e');
      return null;
    }
  }

  /// Get presence for multiple users
  Future<List<UserPresence>> getBulkPresence(List<String> userIds) async {
    try {
      final response = await ApiService.post('/api/presence/bulk', data: {
        'user_ids': userIds,
      });
      final List<dynamic> data = response.data as List<dynamic>;
      final presences = data
          .map((json) => UserPresence.fromJson(json as Map<String, dynamic>))
          .toList();

      // Update cache
      for (final presence in presences) {
        _presenceCache[presence.userId] = presence;
      }

      return presences;
    } catch (e) {
      debugPrint('[PRESENCE SERVICE] Error fetching bulk presence: $e');
      return [];
    }
  }

  /// Check if a user is online (from cache or fetch)
  Future<bool> isUserOnline(String userId) async {
    final presence = await getUserPresence(userId);
    return presence?.isOnline ?? false;
  }

  /// Get cached presence (synchronous, returns null if not cached)
  UserPresence? getCachedPresence(String userId) {
    return _presenceCache[userId];
  }

  /// Get cached online status (synchronous)
  bool getCachedOnlineStatus(String userId) {
    return _presenceCache[userId]?.isOnline ?? false;
  }

  /// Clear presence cache
  void clearCache() {
    _presenceCache.clear();
    debugPrint('[PRESENCE SERVICE] Cache cleared');
  }

  /// Dispose resources
  void dispose() {
    stopHeartbeat();
    _presenceUpdateController.close();
    _userConnectedController.close();
    _userDisconnectedController.close();
    _presenceCache.clear();
  }
}
