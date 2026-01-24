import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/device_identity_service.dart';
import 'services/session_auth_service.dart';
import 'services/native_crypto_service.dart';
import 'services/clientid_native.dart';
import 'services/server_config_web.dart'
    if (dart.library.io) 'services/server_config_native.dart';

/// Debug utility to inspect secure storage contents
class DebugStorage {
  static Future<void> printAllStoredKeys() async {
    if (kIsWeb) {
      debugPrint(
        '[DEBUG_STORAGE] Web platform - skipping secure storage inspection',
      );
      return;
    }

    debugPrint('========================================');
    debugPrint('🔍 SECURE STORAGE DEBUG INFO');
    debugPrint('========================================');

    const storage = FlutterSecureStorage(
      wOptions: WindowsOptions(useBackwardCompatibility: false),
    );

    try {
      // List all keys
      final allKeys = await storage.readAll();
      debugPrint('📦 Total stored keys: ${allKeys.length}');
      debugPrint('');

      if (allKeys.isEmpty) {
        debugPrint('⚠️  No keys found in secure storage!');
      } else {
        for (var entry in allKeys.entries) {
          final key = entry.key;
          final value = entry.value;

          // Don't print full values for security
          final preview = value.length > 20
              ? '${value.substring(0, 20)}...'
              : value;
          debugPrint('🔑 $key');
          debugPrint('   Value length: ${value.length} chars');
          debugPrint('   Preview: $preview');
          debugPrint('');
        }
      }

      // Check specific services
      debugPrint('========================================');
      debugPrint('🔍 SERVICE-SPECIFIC CHECKS');
      debugPrint('========================================');

      // Client ID
      try {
        final clientId = await ClientIdService.getClientId();
        debugPrint('✅ Client ID: $clientId');
      } catch (e) {
        debugPrint('❌ Client ID error: $e');
      }

      // Session Auth
      try {
        final clientId = await ClientIdService.getClientId();
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          final serverUrl = activeServer.serverUrl;
          final hasSession = await SessionAuthService().hasSession(
            clientId: clientId,
            serverUrl: serverUrl,
          );
          debugPrint(
            '${hasSession ? '✅' : '❌'} HMAC Session exists: $hasSession @ $serverUrl',
          );
          if (hasSession) {
            final secret = await SessionAuthService().getSessionSecret(
              clientId,
              serverUrl: serverUrl,
            );
            debugPrint(
              '   Session secret length: ${secret?.length ?? 0} chars',
            );
          }
        } else {
          debugPrint('❌ No active server configured');
        }
      } catch (e) {
        debugPrint('❌ Session Auth error: $e');
      }

      // Device Identity
      try {
        final isInit = DeviceIdentityService.instance.isInitialized;
        debugPrint(
          '${isInit ? '✅' : '❌'} Device Identity initialized: $isInit',
        );

        if (!isInit) {
          final restored = await DeviceIdentityService.instance
              .tryRestoreFromSession();
          debugPrint('   Restore attempt: ${restored ? 'SUCCESS' : 'FAILED'}');
          if (restored) {
            debugPrint(
              '   Device ID: ${DeviceIdentityService.instance.deviceId}',
            );
            debugPrint('   Email: ${DeviceIdentityService.instance.email}');
          }
        } else {
          debugPrint(
            '   Device ID: ${DeviceIdentityService.instance.deviceId}',
          );
          debugPrint('   Email: ${DeviceIdentityService.instance.email}');
        }
      } catch (e) {
        debugPrint('❌ Device Identity error: $e');
      }

      // Encryption Key
      try {
        if (DeviceIdentityService.instance.isInitialized) {
          final deviceId = DeviceIdentityService.instance.deviceId;
          final key = await NativeCryptoService.instance.getKey(deviceId);
          debugPrint(
            '${key != null ? '✅' : '❌'} Encryption key exists: ${key != null}',
          );
          if (key != null) {
            debugPrint('   Key length: ${key.length} bytes');
          }
        } else {
          debugPrint(
            '⚠️  Cannot check encryption key - device identity not initialized',
          );
        }
      } catch (e) {
        debugPrint('❌ Encryption key error: $e');
      }

      debugPrint('========================================');
    } catch (e) {
      debugPrint('❌ Error reading secure storage: $e');
      debugPrint('========================================');
    }
  }

  /// Clear all secure storage (for testing)
  static Future<void> clearAllStorage() async {
    if (kIsWeb) {
      debugPrint('[DEBUG_STORAGE] Web platform - skipping');
      return;
    }

    debugPrint('🗑️  Clearing all secure storage...');
    const storage = FlutterSecureStorage(
      wOptions: WindowsOptions(useBackwardCompatibility: false),
    );

    try {
      await storage.deleteAll();
      debugPrint('✅ All secure storage cleared');
    } catch (e) {
      debugPrint('❌ Error clearing storage: $e');
    }
  }
}
