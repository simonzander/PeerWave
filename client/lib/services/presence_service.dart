import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/user_presence.dart';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'user_profile_service.dart';

/// Presence service - tracks online/busy/offline status of users
///
/// Features:
/// - Socket connection-based presence (no heartbeat polling)
/// - Real-time presence updates via Socket.IO
/// - Integration with UserProfileService for cached presence
/// - Streams for UI updates
/// - Pre-call online status validation
///
/// Socket.IO events:
/// - presence:update (listen) - Receive status updates (online/busy/offline)
/// - presence:user_connected (listen) - User came online
/// - presence:user_disconnected (listen) - User went offline
///
/// Status values:
/// - 'online': User has at least one socket connection
/// - 'busy': User is in a LiveKit room (call/meeting)
/// - 'offline': User has no socket connections
class PresenceService {
  static final PresenceService _instance = PresenceService._internal();
  factory PresenceService() => _instance;
  PresenceService._internal();

  final _socketService = SocketService();

  // Stream controllers
  final _presenceUpdateController = StreamController<UserPresence>.broadcast();
  final _userConnectedController = StreamController<String>.broadcast();
  final _userDisconnectedController = StreamController<String>.broadcast();

  // Public streams
  Stream<UserPresence> get onPresenceUpdate => _presenceUpdateController.stream;
  Stream<String> get onUserConnected => _userConnectedController.stream;
  Stream<String> get onUserDisconnected => _userDisconnectedController.stream;

  bool _listenersRegistered = false;

  /// Initialize Socket.IO listeners and start heartbeat
  void initialize() {
    _initializeListeners();
  }

  /// Initialize Socket.IO listeners for presence updates
  void _initializeListeners() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    _socketService.registerListener('presence:update', (data) {
      debugPrint(
        '[PRESENCE SERVICE] ========== Received presence:update ==========',
      );
      debugPrint('[PRESENCE SERVICE] Raw data: $data');
      try {
        final map = data as Map<String, dynamic>;
        final userId = map['user_id'] as String;
        final status = map['status'] as String?;
        final lastSeenStr = map['last_seen'] as String?;

        debugPrint(
          '[PRESENCE SERVICE] Parsed: user_id=$userId, status=$status',
        );

        DateTime? lastSeen;
        if (lastSeenStr != null) {
          try {
            lastSeen = DateTime.parse(lastSeenStr);
          } catch (e) {
            debugPrint('[PRESENCE SERVICE] Error parsing last_seen: $e');
          }
        }

        // Update UserProfileService cache
        UserProfileService.instance.updatePresenceStatus(
          userId,
          status ?? 'offline',
          lastSeen,
        );
        debugPrint(
          '[PRESENCE SERVICE] Updated UserProfileService cache for $userId',
        );

        final presence = UserPresence(
          userId: userId,
          lastHeartbeat: lastSeen ?? DateTime.now(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

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
        final lastSeenStr = map['last_seen'] as String?;

        DateTime? lastSeen;
        if (lastSeenStr != null) {
          try {
            lastSeen = DateTime.parse(lastSeenStr);
          } catch (e) {
            debugPrint('[PRESENCE SERVICE] Error parsing last_seen: $e');
          }
        }

        // Update UserProfileService cache
        UserProfileService.instance.updatePresenceStatus(
          userId,
          'online',
          lastSeen,
        );

        UserPresence(
          userId: userId,
          lastHeartbeat: lastSeen ?? DateTime.now(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        _userConnectedController.add(userId);
      } catch (e) {
        debugPrint(
          '[PRESENCE SERVICE] Error parsing presence:user_connected: $e',
        );
      }
    });

    _socketService.registerListener('presence:user_disconnected', (data) {
      debugPrint(
        '[PRESENCE SERVICE] Received presence:user_disconnected: $data',
      );
      try {
        final map = data as Map<String, dynamic>;
        final userId = map['user_id'] as String;
        final lastSeenStr = map['last_seen'] as String?;

        DateTime? lastSeen;
        if (lastSeenStr != null) {
          try {
            lastSeen = DateTime.parse(lastSeenStr);
          } catch (e) {
            debugPrint('[PRESENCE SERVICE] Error parsing last_seen: $e');
          }
        }

        // Update UserProfileService cache
        UserProfileService.instance.updatePresenceStatus(
          userId,
          'offline',
          lastSeen,
        );

        _userDisconnectedController.add(userId);
      } catch (e) {
        debugPrint(
          '[PRESENCE SERVICE] Error parsing presence:user_disconnected: $e',
        );
      }
    });

    debugPrint('[PRESENCE SERVICE] Socket.IO listeners initialized');
  }

  // ============================================================================
  // HTTP API Methods
  // ============================================================================

  /// Check online status for multiple users (bulk check via API)
  /// Returns Map&lt;userId, status&gt; where status is 'online', 'busy', or 'offline'
  ///
  /// Use this before initiating instant calls to verify recipients are online
  Future<Map<String, String>> checkOnlineStatus(List<String> userIds) async {
    if (userIds.isEmpty) return {};

    try {
      final userIdsParam = userIds.join(',');
      debugPrint(
        '[PRESENCE SERVICE] Calling /api/presence/bulk?user_ids=$userIdsParam',
      );
      final response = await ApiService.get(
        '/api/presence/bulk?user_ids=$userIdsParam',
      );
      debugPrint('[PRESENCE SERVICE] Response: ${response.data}');

      final List<dynamic> data = response.data as List<dynamic>;
      final statusMap = <String, String>{};

      for (final item in data) {
        if (item is Map<String, dynamic>) {
          final userId = item['user_id'] as String?;
          final status = item['status'] as String?;
          if (userId != null) {
            statusMap[userId] = status ?? 'offline';

            // Update UserProfileService cache
            final lastSeenStr =
                item['last_heartbeat'] as String? ??
                item['updated_at'] as String?;
            DateTime? lastSeen;
            if (lastSeenStr != null) {
              try {
                lastSeen = DateTime.parse(lastSeenStr);
              } catch (e) {
                debugPrint('[PRESENCE SERVICE] Error parsing timestamp: $e');
              }
            }
            UserProfileService.instance.updatePresenceStatus(
              userId,
              status ?? 'offline',
              lastSeen,
            );
          }
        }
      }

      return statusMap;
    } catch (e) {
      debugPrint('[PRESENCE SERVICE] Error checking online status: $e');
      return {};
    }
  }

  /// Check if specific user is online via API
  Future<bool> isUserOnline(String userId) async {
    debugPrint('[PRESENCE SERVICE] Checking if user $userId is online...');
    final result = await checkOnlineStatus([userId]);
    final status = result[userId];
    final isOnline = status == 'online' || status == 'busy';
    debugPrint(
      '[PRESENCE SERVICE] User $userId status: $status, isOnline: $isOnline',
    );
    return isOnline;
  }

  /// Get cached online status from UserProfileService (synchronous)
  bool getCachedOnlineStatus(String userId) {
    return UserProfileService.instance.isUserOnline(userId);
  }

  /// Dispose resources
  void dispose() {
    _presenceUpdateController.close();
    _userConnectedController.close();
    _userDisconnectedController.close();
  }
}
