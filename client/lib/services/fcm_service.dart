import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'device_identity_service.dart';

/// Firebase Cloud Messaging Service
/// Handles FCM token management, push notifications, and token refresh
class FCMService {
  static final FCMService _instance = FCMService._internal();
  factory FCMService() => _instance;
  FCMService._internal();

  FirebaseMessaging? _messaging;
  StreamSubscription<String>? _tokenRefreshSubscription;
  String? _currentToken;
  bool _initialized = false;

  /// Initialize FCM service
  /// - Request notification permissions (Android 13+)
  /// - Get FCM token
  /// - Register token with server
  /// - Setup token refresh listener
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[FCM] Already initialized');
      return;
    }

    try {
      _messaging = FirebaseMessaging.instance;

      // ========================================
      // 6️⃣ Request Push Notification Permission (Android 13+)
      // ========================================
      debugPrint('[FCM] Requesting notification permissions...');
      final settings = await _messaging!.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        debugPrint('[FCM] ✅ Notification permissions granted');
      } else if (settings.authorizationStatus ==
          AuthorizationStatus.provisional) {
        debugPrint('[FCM] ⚠️ Provisional notification permissions granted');
      } else {
        debugPrint(
          '[FCM] ❌ Notification permissions denied: ${settings.authorizationStatus}',
        );
        // Don't return - continue initialization for token refresh
      }

      // ========================================
      // 7️⃣ Get FCM Token
      // ========================================
      await _getFCMToken();

      // ========================================
      // 9️⃣ Setup Token Refresh Listener (CRITICAL!)
      // ========================================
      _setupTokenRefreshListener();

      _initialized = true;
      debugPrint('[FCM] ✅ Initialization complete');
    } catch (e, stackTrace) {
      debugPrint('[FCM] ❌ Initialization failed: $e');
      debugPrint('[FCM] Stack trace: $stackTrace');
      // Don't rethrow - allow app to continue without FCM
    }
  }

  /// Get FCM token and register with server
  Future<void> _getFCMToken() async {
    try {
      debugPrint('[FCM] Fetching FCM token...');
      final token = await _messaging!.getToken();

      if (token == null) {
        debugPrint('[FCM] ⚠️ FCM token is null');
        return;
      }

      _currentToken = token;
      debugPrint('[FCM] ✅ FCM token received: ${token.substring(0, 20)}...');

      // ========================================
      // 8️⃣ Register Token with Server
      // ========================================
      await _registerTokenWithServer(token);
    } catch (e, stackTrace) {
      debugPrint('[FCM] ❌ Failed to get FCM token: $e');
      debugPrint('[FCM] Stack trace: $stackTrace');
    }
  }

  /// Register FCM token with server
  /// Required for server to send push notifications to this device
  Future<void> _registerTokenWithServer(String token) async {
    try {
      debugPrint('[FCM] Registering token with server...');

      // Get device ID from DeviceIdentityService
      final deviceId = DeviceIdentityService.instance.deviceId;

      // Determine platform
      final platform = defaultTargetPlatform == TargetPlatform.android
          ? 'android'
          : defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'unknown';

      // Get current timestamp
      final lastSeen = DateTime.now().toIso8601String();

      // Register with server via API
      // TODO: Implement this endpoint in your API service
      // For now, we'll use a direct HTTP call
      final response = await ApiService.dio.post(
        '/api/push/register',
        data: {
          'fcm_token': token,
          'device_id': deviceId,
          'platform': platform,
          'last_seen': lastSeen,
        },
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('[FCM] ✅ Token registered with server');
        debugPrint('[FCM]   Device ID: $deviceId');
        debugPrint('[FCM]   Platform: $platform');
      } else {
        debugPrint('[FCM] ⚠️ Unexpected status code: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      debugPrint('[FCM] ❌ Failed to register token with server: $e');
      debugPrint('[FCM] Stack trace: $stackTrace');
      // Don't rethrow - token will be retried on next app start
    }
  }

  /// Setup token refresh listener
  /// CRITICAL: FCM tokens can change after app updates or reinstalls
  /// Without this, push notifications will stop working
  void _setupTokenRefreshListener() {
    debugPrint('[FCM] Setting up token refresh listener...');

    _tokenRefreshSubscription = _messaging!.onTokenRefresh.listen(
      (newToken) {
        debugPrint('[FCM] 🔄 Token refreshed: ${newToken.substring(0, 20)}...');
        _currentToken = newToken;
        _registerTokenWithServer(newToken);
      },
      onError: (error) {
        debugPrint('[FCM] ❌ Token refresh error: $error');
      },
    );

    debugPrint('[FCM] ✅ Token refresh listener active');
  }

  /// Get current FCM token
  String? get currentToken => _currentToken;

  /// Check if FCM is initialized
  bool get isInitialized => _initialized;

  /// Dispose and cleanup
  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _initialized = false;
    debugPrint('[FCM] Disposed');
  }
}
