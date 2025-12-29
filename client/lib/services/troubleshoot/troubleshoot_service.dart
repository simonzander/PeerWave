import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/metrics/key_management_metrics.dart';
import '../../core/metrics/network_metrics.dart';
import '../../features/troubleshoot/models/key_metrics.dart';
import '../../features/troubleshoot/models/device_info.dart';
import '../../features/troubleshoot/models/server_config.dart' as model;
import '../../features/troubleshoot/models/storage_info.dart';
import '../signal_service.dart';
import '../storage/sqlite_group_message_store.dart';
import '../storage/database_helper.dart';
import '../device_identity_service.dart';
import '../device_scoped_storage_service.dart';
import '../api_service.dart';
import '../socket_service.dart'
    if (dart.library.io) '../socket_service_native.dart';
import '../server_config_web.dart'
    if (dart.library.io) '../server_config_native.dart'
    as config;
import '../../web_config.dart';

/// Service for Signal Protocol troubleshooting and diagnostics.
class TroubleshootService {
  final SignalService signalService;

  const TroubleshootService({required this.signalService});

  /// Retrieves current key management metrics.
  Future<KeyMetrics> getKeyMetrics() async {
    return KeyMetrics(
      identityRegenerations: KeyManagementMetrics.identityRegenerations,
      signedPreKeyRotations: KeyManagementMetrics.signedPreKeyRotations,
      preKeysRegenerated: KeyManagementMetrics.preKeysRegenerated,
      ownPreKeysConsumed: KeyManagementMetrics.ownPreKeysConsumed,
      remotePreKeysConsumed: KeyManagementMetrics.remotePreKeysConsumed,
      sessionsInvalidated: KeyManagementMetrics.sessionsInvalidated,
      decryptionFailures: KeyManagementMetrics.decryptionFailures,
      serverKeyMismatches: KeyManagementMetrics.serverKeyMismatches,
    );
  }

  /// Deletes identity key locally and regenerates.
  Future<void> deleteIdentityKey() async {
    try {
      debugPrint('[Troubleshoot] Requesting identity key regeneration...');

      // Request server to regenerate identity key
      // This requires re-authentication and full key regeneration
      SocketService().emit('regenerateIdentityKey', null);

      debugPrint('[Troubleshoot] ✓ Identity key regeneration requested');
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error regenerating identity key: $e');
      rethrow;
    }
  }

  /// Deletes signed pre-key locally and on server.
  Future<void> deleteSignedPreKey() async {
    try {
      debugPrint('[Troubleshoot] Deleting signed pre-key...');

      // Request deletion and regeneration via server
      SocketService().emit('deleteAndRegenerateSignedPreKey', null);

      debugPrint('[Troubleshoot] ✓ Signed PreKey deletion requested');
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error deleting signed PreKey: $e');
      rethrow;
    }
  }

  /// Deletes all pre-keys locally and on server.
  Future<void> deletePreKeys() async {
    try {
      debugPrint('[Troubleshoot] Deleting all PreKeys...');

      // Get all PreKey IDs for logging
      final preKeyIds = await signalService.preKeyStore.getAllPreKeyIds();

      // Delete from server
      SocketService().emit('deleteAllPreKeys', null);

      // Remove locally
      for (final id in preKeyIds) {
        await signalService.preKeyStore.removePreKey(id);
      }

      // Trigger key regeneration
      SocketService().emit('signalStatus', null);

      debugPrint('[Troubleshoot] ✓ Deleted ${preKeyIds.length} PreKeys');
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error deleting PreKeys: $e');
      rethrow;
    }
  }

  /// Deletes group encryption key for specified channel.
  Future<void> deleteGroupKey(String channelId) async {
    try {
      debugPrint('[Troubleshoot] Deleting group key for channel $channelId...');

      // Get all sender keys for this channel and remove them
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys('senderKeys', 'senderKeys');

      int deletedCount = 0;
      for (final key in keys) {
        if (key.contains(channelId)) {
          await storage.deleteEncrypted('senderKeys', 'senderKeys', key);
          deletedCount++;
        }
      }

      debugPrint(
        '[Troubleshoot] ✓ Deleted $deletedCount sender keys for channel',
      );
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error deleting group key: $e');
      rethrow;
    }
  }

  /// Deletes all sessions with specified user.
  Future<void> deleteUserSession(String userId) async {
    debugPrint(
      '[Troubleshoot] User session deletion for $userId - to be implemented',
    );
    throw UnimplementedError(
      'User session deletion requires SignalService extension',
    );
  }

  /// Deletes session with specific device.
  Future<void> deleteDeviceSession(String userId, int deviceId) async {
    debugPrint(
      '[Troubleshoot] Device session deletion for $userId:$deviceId - to be implemented',
    );
    throw UnimplementedError(
      'Device session deletion requires SignalService extension',
    );
  }

  /// Forces signed pre-key rotation.
  Future<void> forceSignedPreKeyRotation() async {
    try {
      debugPrint('[Troubleshoot] Forcing signed PreKey rotation...');

      // Request rotation via server
      SocketService().emit('rotateSignedPreKey', null);

      debugPrint('[Troubleshoot] ✓ Signed PreKey rotation requested');
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error rotating signed PreKey: $e');
      rethrow;
    }
  }

  /// Forces complete pre-key regeneration.
  Future<void> forcePreKeyRegeneration() async {
    try {
      debugPrint('[Troubleshoot] Forcing PreKey regeneration...');

      // Get all existing PreKey IDs for logging
      final existingIds = await signalService.preKeyStore.getAllPreKeyIds();

      // Remove all existing PreKeys locally
      for (final id in existingIds) {
        await signalService.preKeyStore.removePreKey(id);
      }

      // Delete from server and trigger regeneration
      SocketService().emit('deleteAllPreKeys', null);
      SocketService().emit('signalStatus', null);

      debugPrint(
        '[Troubleshoot] ✓ PreKey regeneration requested (${existingIds.length} removed)',
      );
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error regenerating PreKeys: $e');
      rethrow;
    }
  }

  /// Retrieves list of active group channels for key deletion.
  Future<List<Map<String, String>>> getActiveChannels() async {
    try {
      final groupMessageStore = await SqliteGroupMessageStore.getInstance();
      final channelIds = await groupMessageStore.getAllChannels();

      // Fetch channel names from API
      final channelsWithNames = <Map<String, String>>[];

      for (final id in channelIds) {
        try {
          // Get server URL
          String? serverUrl;
          if (kIsWeb) {
            serverUrl = await loadWebApiServer();
          } else {
            final activeServer = config.ServerConfigService.getActiveServer();
            serverUrl = activeServer?.serverUrl;
          }

          if (serverUrl != null) {
            // Fetch channel details
            final response = await ApiService.get(
              '${ApiService.ensureHttpPrefix(serverUrl)}/client/channels/$id',
            );

            if (response.statusCode == 200 && response.data != null) {
              final channelData = response.data as Map<String, dynamic>;
              channelsWithNames.add({
                'id': id,
                'name': channelData['name'] as String? ?? id,
              });
            } else {
              // Fallback to ID if API fails
              channelsWithNames.add({'id': id, 'name': id});
            }
          } else {
            channelsWithNames.add({'id': id, 'name': id});
          }
        } catch (e) {
          debugPrint('[Troubleshoot] Error fetching channel $id name: $e');
          // Fallback to ID on error
          channelsWithNames.add({'id': id, 'name': id});
        }
      }

      return channelsWithNames;
    } catch (e) {
      debugPrint('[Troubleshoot] Error fetching channels: $e');
      return [];
    }
  }

  /// Retrieves device and identity information.
  Future<DeviceInfo> getDeviceInfo() async {
    try {
      final deviceIdentity = DeviceIdentityService.instance;
      final deviceId = deviceIdentity.deviceId;
      final clientId = deviceIdentity.clientId;
      final userId = signalService.currentUserId ?? 'N/A';

      // Get identity key fingerprint (first 16 chars of public key)
      String identityKeyFingerprint = 'N/A';
      try {
        final identityData = await signalService.identityStore
            .getIdentityKeyPairData();
        final publicKey = identityData['publicKey'];
        if (publicKey is String && publicKey.length >= 16) {
          identityKeyFingerprint =
              '${publicKey.substring(0, 8)}...${publicKey.substring(publicKey.length - 8)}';
        }
      } catch (e) {
        debugPrint('[Troubleshoot] Error getting identity key: $e');
      }

      return DeviceInfo(
        userId: userId,
        deviceId: deviceId.isNotEmpty ? deviceId : 'N/A',
        clientId: clientId.isNotEmpty ? clientId : 'N/A',
        identityKeyFingerprint: identityKeyFingerprint,
      );
    } catch (e) {
      debugPrint('[Troubleshoot] Error getting device info: $e');
      return DeviceInfo.empty;
    }
  }

  /// Retrieves server configuration and connection status.
  Future<model.ServerConfig> getServerConfig() async {
    try {
      String serverUrl = 'N/A';
      String socketUrl = 'N/A';

      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        if (apiServer != null && apiServer.isNotEmpty) {
          serverUrl = apiServer;
          socketUrl = apiServer.startsWith('http')
              ? apiServer
              : 'https://$apiServer';
        }
      } else {
        final activeServer = config.ServerConfigService.getActiveServer();
        if (activeServer != null) {
          serverUrl = activeServer.serverUrl;
          socketUrl = serverUrl;
        }
      }

      // Use SocketService().isConnected getter for reliable connection status
      final isConnected = SocketService().isConnected;
      final connectionStatus = isConnected ? 'Connected' : 'Disconnected';

      return model.ServerConfig(
        serverUrl: serverUrl,
        socketUrl: socketUrl,
        isConnected: isConnected,
        connectionStatus: connectionStatus,
      );
    } catch (e) {
      debugPrint('[Troubleshoot] Error getting server config: $e');
      return model.ServerConfig.empty;
    }
  }

  /// Retrieves storage database names.
  Future<StorageInfo> getStorageInfo() async {
    try {
      final deviceId = DeviceIdentityService.instance.deviceId;
      final suffix = deviceId.isNotEmpty ? '_$deviceId' : '';

      // SQLite database is also device-scoped: peerwave_{deviceId}.db
      final messageStoreName = deviceId.isNotEmpty
          ? 'peerwave$suffix.db'
          : 'peerwave.db';

      return StorageInfo(
        sessionStore: 'sessions$suffix',
        identityStore: 'identity$suffix',
        preKeyStore: 'prekeys$suffix',
        signedPreKeyStore: 'signedprekeys$suffix',
        messageStore: messageStoreName,
      );
    } catch (e) {
      debugPrint('[Troubleshoot] Error getting storage info: $e');
      return StorageInfo.empty;
    }
  }

  /// Retrieves network metrics.
  Map<String, dynamic> getNetworkMetrics() {
    return NetworkMetrics.toJson();
  }

  /// Retrieves Signal Protocol session and key counts.
  Future<Map<String, int>> getSignalProtocolCounts() async {
    try {
      int activeSessions = 0;
      int preKeysCount = 0;

      try {
        // Count sessions by getting all keys from session store
        final storage = DeviceScopedStorageService.instance;
        final keys = await storage.getAllKeys(
          'peerwaveSignalSessions',
          'peerwaveSignalSessions',
        );
        activeSessions = keys.where((k) => k.startsWith('session_')).length;
      } catch (e) {
        debugPrint('[Troubleshoot] Error counting sessions: $e');
      }

      try {
        // Count PreKeys
        final preKeyIds = await signalService.preKeyStore.getAllPreKeyIds();
        preKeysCount = preKeyIds.length;
      } catch (e) {
        debugPrint('[Troubleshoot] Error counting PreKeys: $e');
      }

      return {'activeSessions': activeSessions, 'preKeysCount': preKeysCount};
    } catch (e) {
      debugPrint('[Troubleshoot] Error getting Signal Protocol counts: $e');
      return {'activeSessions': 0, 'preKeysCount': 0};
    }
  }

  // ========== Maintenance Operations ==========

  /// 1. Reset Network Metrics - Clear API/socket counters
  void resetNetworkMetrics() {
    NetworkMetrics.reset();
    debugPrint('[Troubleshoot] ✓ Network metrics reset');
  }

  /// 2. Force Socket Reconnect - Disconnect and reconnect socket
  Future<void> forceSocketReconnect() async {
    try {
      final socketService = SocketService();
      debugPrint('[Troubleshoot] Forcing socket reconnect...');

      // Disconnect existing socket
      socketService.socket?.disconnect();

      // Wait briefly for clean disconnect
      await Future.delayed(Duration(milliseconds: 500));

      // Reconnect
      await socketService.connect();
      debugPrint('[Troubleshoot] ✓ Socket reconnect initiated');
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error reconnecting socket: $e');
      rethrow;
    }
  }

  /// 3. Test Server Connection - Send ping to verify server is responding
  Future<bool> testServerConnection() async {
    try {
      final socketService = SocketService();

      if (!socketService.isConnected) {
        debugPrint('[Troubleshoot] Cannot test - socket not connected');
        return false;
      }

      debugPrint('[Troubleshoot] Testing server connection...');

      // Create a completer to wait for pong response
      final completer = Completer<bool>();

      // Listen for pong response (with timeout)
      void pongHandler(dynamic data) {
        if (!completer.isCompleted) {
          completer.complete(true);
          debugPrint('[Troubleshoot] ✓ Server responded to ping');
        }
      }

      socketService.registerListener('pong', pongHandler);

      // Send ping
      socketService.emit('ping', {
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Wait for response with timeout
      final result = await completer.future.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[Troubleshoot] ✗ Server ping timeout');
          return false;
        },
      );

      // Clean up listener
      socketService.unregisterListener('pong', pongHandler);

      return result;
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error testing connection: $e');
      return false;
    }
  }

  /// 5. Clear Signal Protocol Sessions - Remove all sessions, forces re-key exchange
  Future<void> clearSignalSessions() async {
    try {
      debugPrint('[Troubleshoot] Clearing all Signal Protocol sessions...');
      final storage = DeviceScopedStorageService.instance;
      final keys = await storage.getAllKeys(
        'peerwaveSignalSessions',
        'peerwaveSignalSessions',
      );

      int deletedCount = 0;
      for (final key in keys) {
        if (key.startsWith('session_')) {
          await storage.deleteEncrypted(
            'peerwaveSignalSessions',
            'peerwaveSignalSessions',
            key,
          );
          deletedCount++;
        }
      }

      debugPrint(
        '[Troubleshoot] ✓ Cleared $deletedCount Signal Protocol sessions',
      );
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error clearing sessions: $e');
      rethrow;
    }
  }

  /// 7. Sync Keys with Server - Re-upload identity/PreKeys to server
  Future<void> syncKeysWithServer() async {
    try {
      debugPrint('[Troubleshoot] Syncing keys with server...');

      // Trigger key upload via signalStatus
      SocketService().emit('signalStatus', null);

      debugPrint('[Troubleshoot] ✓ Key sync initiated (signalStatus sent)');
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error syncing keys: $e');
      rethrow;
    }
  }

  /// Clear Message Storage - Delete all locally stored messages
  Future<void> clearMessageStorage() async {
    try {
      debugPrint('[Troubleshoot] Clearing all message storage...');
      final db = await DatabaseHelper.database;

      // Delete all messages from the messages table
      final deletedCount = await db.delete('messages');

      debugPrint(
        '[Troubleshoot] ✓ Cleared $deletedCount messages from local storage',
      );
    } catch (e) {
      debugPrint('[Troubleshoot] ✗ Error clearing message storage: $e');
      rethrow;
    }
  }
}
