// Signal Protocol Service - SignalClient for Multi-Server Support
//
// SignalClient orchestrates all Signal Protocol services for a specific server.
// Each server connection gets its own SignalClient instance with isolated state.
//
// Initialization flow (from main.dart):
// 1. DeviceScopedStorageService.instance.init()
// 2. apiService = ApiService(baseUrl: serverUrl); await await ApiService.instance.init()
// 3. socketService = SocketService(serverUrl: serverUrl); await socketService.connect()
// 4. signalClient = SignalClient(apiService: apiService, socketService: socketService)
// 5. await signalClient.initialize()
//
// Usage:
// ```dart
// // Services already initialized in main.dart
// final client = SignalClient(
//   apiService: apiService,
//   socketService: socketService,
// );
// await client.initialize();
//
// // Multiple servers
// final api2 = ApiService(baseUrl: "server2.com");
// await api2.init();
// final socket2 = SocketService(serverUrl: "server2.com");
// await socket2.connect();
// final client2 = SignalClient(apiService: api2, socketService: socket2);
// await client2.initialize();
// ```

import 'dart:async';
import 'package:flutter/foundation.dart';

import '../api_service.dart';
import '../socket_service.dart'
    if (dart.library.io) '../socket_service_native.dart';

// Core services
import 'core/key_manager.dart';
import 'core/session_manager.dart';
import 'core/healing_service.dart';
import 'core/encryption_service.dart';
import 'core/messaging/messaging_service.dart';
import 'core/meeting/meeting_service.dart';
import 'core/offline_queue_processor.dart';

// Listener registry
import 'listeners/listener_registry.dart';

// Callback management
import 'callbacks/callback_manager.dart';

/// SignalClient - Per-server Signal Protocol orchestration
///
/// One instance per server, manages all Signal Protocol operations
/// with complete isolation between servers.
///
/// Services (ApiService, SocketService) are injected from main.dart after
/// being initialized there. SignalClient orchestrates Signal Protocol operations
/// using these already-configured services.
class SignalClient {
  final ApiService apiService;
  final SocketService socketService;
  final String serverKey; // Server this client is bound to

  late final SignalKeyManager keyManager;
  late final SessionManager sessionManager;
  late final SignalHealingService healingService;
  late final EncryptionService encryptionService;
  late final MessagingService messagingService;
  late final MeetingService meetingService;
  late final OfflineQueueProcessor offlineQueueProcessor;
  late final CallbackManager callbackManager;

  // Daily verification timer
  Timer? _dailyVerificationTimer;
  DateTime? _lastDailyVerification;

  // User/device callbacks for services
  String? Function()? _getCurrentUserId;
  int? Function()? _getCurrentDeviceId;

  // Public getters for user/device info
  String? Function()? get getCurrentUserId => _getCurrentUserId;
  int? Function()? get getCurrentDeviceId => _getCurrentDeviceId;

  bool _initialized = false;

  /// Create a new SignalClient bound to a specific server
  ///
  /// IMPORTANT: ApiService and SocketService are singletons that route based on
  /// the currently active server (ServerConfigService.getActiveServer()).
  ///
  /// This means:
  /// - SignalClients are cached per-server but share the routing layer
  /// - When you switch servers: setActiveServer() → singletons route to new server
  /// - Only use the SignalClient for the currently active server
  /// - For multi-server simultaneous operations, call setActiveServer() before each operation
  SignalClient({
    required this.apiService,
    required this.socketService,
    required this.serverKey,
    String? Function()? getCurrentUserId,
    int? Function()? getCurrentDeviceId,
  }) : _getCurrentUserId = getCurrentUserId,
       _getCurrentDeviceId = getCurrentDeviceId;

  /// Initialize Signal Protocol services
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[SIGNAL_CLIENT] Already initialized for server: $serverKey');
      return;
    }

    debugPrint('[SIGNAL_CLIENT] ========================================');
    debugPrint(
      '[SIGNAL_CLIENT] Starting initialization for server: $serverKey',
    );
    debugPrint('[SIGNAL_CLIENT] ========================================');

    // Initialize KeyManager with injected services
    debugPrint('[SIGNAL_CLIENT] Creating KeyManager...');
    keyManager = await SignalKeyManager.create(
      apiService: apiService,
      socketService: socketService,
    );
    debugPrint('[SIGNAL_CLIENT] ✓ KeyManager created');

    // Initialize SessionManager after KeyManager
    debugPrint('[SIGNAL_CLIENT] Creating SessionManager...');
    sessionManager = await SessionManager.create(
      keyManager: keyManager,
      apiService: apiService,
      socketService: socketService,
    );
    debugPrint('[SIGNAL_CLIENT] ✓ SessionManager created');

    // Initialize HealingService
    debugPrint('[SIGNAL_CLIENT] Creating HealingService...');
    healingService = await SignalHealingService.create(
      keyManager: keyManager,
      sessionManager: sessionManager,
      getCurrentUserId: _getCurrentUserId ?? () => null,
      getCurrentDeviceId: _getCurrentDeviceId ?? () => null,
    );
    debugPrint('[SIGNAL_CLIENT] ✓ HealingService created');

    // Initialize EncryptionService
    debugPrint('[SIGNAL_CLIENT] Creating EncryptionService...');
    encryptionService = await EncryptionService.create(
      keyManager: keyManager,
      sessionManager: sessionManager,
    );
    debugPrint('[SIGNAL_CLIENT] ✓ EncryptionService created');

    // Initialize CallbackManager (must be before MessagingService)
    debugPrint('[SIGNAL_CLIENT] Initializing CallbackManager...');
    callbackManager = CallbackManager.instance;
    debugPrint('[SIGNAL_CLIENT] ✓ CallbackManager initialized');

    // Initialize MessagingService
    debugPrint('[SIGNAL_CLIENT] Creating MessagingService...');
    messagingService = await MessagingService.create(
      encryptionService: encryptionService,
      healingService: healingService,
      apiService: apiService,
      socketService: socketService,
      currentUserId: _getCurrentUserId?.call() ?? '',
      currentDeviceId: _getCurrentDeviceId?.call() ?? 0,
      waitForRegeneration: () async {},
      callbackManager: callbackManager,
      regeneratePreKeyAsync: (int keyId) async {
        debugPrint('[SIGNAL_CLIENT] Regenerating PreKey: $keyId');
      },
    );
    debugPrint('[SIGNAL_CLIENT] ✓ MessagingService created');

    // Initialize MeetingService
    debugPrint('[SIGNAL_CLIENT] Creating MeetingService...');
    meetingService = MeetingService(
      encryptionService: encryptionService,
      apiService: apiService,
      socketService: socketService,
      getCurrentUserId: _getCurrentUserId ?? () => null,
      getCurrentDeviceId: _getCurrentDeviceId ?? () => null,
    );
    debugPrint('[SIGNAL_CLIENT] ✓ MeetingService created');

    // Initialize OfflineQueueProcessor (utility)
    offlineQueueProcessor = OfflineQueueProcessor();
    debugPrint('[SIGNAL_CLIENT] ✓ OfflineQueueProcessor created');

    // Register socket listeners
    debugPrint('[SIGNAL_CLIENT] Registering socket listeners...');
    await ListenerRegistry.instance.registerAll(
      messagingService: messagingService,
      sessionManager: sessionManager,
      keyManager: keyManager,
      healingService: healingService,
      callbackManager: callbackManager,
      currentUserId: _getCurrentUserId?.call(),
      currentDeviceId: _getCurrentDeviceId?.call(),
    );
    debugPrint('[SIGNAL_CLIENT] ✓ Listeners registered & clientReady sent');

    // Start daily verification timer (runs every 24 hours)
    _startDailyVerificationTimer();

    _initialized = true;
    debugPrint('[SIGNAL_CLIENT] ========================================');
    debugPrint(
      '[SIGNAL_CLIENT] ✅ Initialization complete for server: $serverKey',
    );
    debugPrint('[SIGNAL_CLIENT] ========================================');
  }

  /// Start daily verification timer (checks once every 24 hours)
  void _startDailyVerificationTimer() {
    debugPrint('[SIGNAL_CLIENT] Starting daily verification timer...');

    // Check immediately on first initialization if needed
    _performDailyVerificationCheck();

    // Set up timer to check every hour (will only run if 24h passed)
    _dailyVerificationTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _performDailyVerificationCheck(),
    );
  }

  /// Perform daily verification check if 24 hours have passed
  void _performDailyVerificationCheck() async {
    // Only run if 24 hours have passed since last check
    if (_lastDailyVerification != null) {
      final hoursSinceLastCheck = DateTime.now()
          .difference(_lastDailyVerification!)
          .inHours;
      if (hoursSinceLastCheck < 24) {
        return; // Too soon
      }
    }

    final userId = _getCurrentUserId?.call();
    final deviceId = _getCurrentDeviceId?.call();

    if (userId == null || deviceId == null) {
      debugPrint('[SIGNAL_CLIENT] Skipping daily check: user not logged in');
      return;
    }

    debugPrint('[SIGNAL_CLIENT] 🔍 Running daily key verification check...');
    _lastDailyVerification = DateTime.now();

    try {
      await healingService.triggerAsyncSelfVerification(
        reason: 'Daily automatic verification',
        userId: userId,
        deviceId: deviceId,
      );
    } catch (e) {
      debugPrint('[SIGNAL_CLIENT] ⚠️ Daily verification error: $e');
    }
  }

  /// Manually trigger key verification (called after login/setup)
  Future<void> verifyKeys() async {
    final userId = _getCurrentUserId?.call();
    final deviceId = _getCurrentDeviceId?.call();

    if (userId == null || deviceId == null) {
      debugPrint('[SIGNAL_CLIENT] Cannot verify keys: user not logged in');
      return;
    }

    debugPrint('[SIGNAL_CLIENT] 🔍 Running post-login key verification...');
    await healingService.triggerAsyncSelfVerification(
      reason: 'Post-login verification',
      userId: userId,
      deviceId: deviceId,
    );
  }

  /// Clean up resources
  Future<void> dispose() async {
    _dailyVerificationTimer?.cancel();
    _dailyVerificationTimer = null;

    // Clear all callbacks
    callbackManager.clearAll();

    // Unregister listeners
    await ListenerRegistry.instance.unregisterAll();

    _initialized = false;
  }

  bool get isInitialized => _initialized;

  // ============================================================================
  // CALLBACK REGISTRATION METHODS (Convenience wrappers)
  // ============================================================================

  /// Register a callback for receiving 1:1 messages
  void registerReceiveItem(
    String type,
    String senderId,
    Function(Map<String, dynamic>) callback,
  ) {
    if (!_initialized) {
      debugPrint(
        '[SIGNAL_CLIENT] ⚠️ Attempted to register callback before initialization',
      );
      return;
    }
    callbackManager.registerReceiveItem(type, senderId, callback);
  }

  /// Unregister a callback for receiving 1:1 messages
  void unregisterReceiveItem(
    String type,
    String senderId,
    Function(Map<String, dynamic>) callback,
  ) {
    if (!_initialized) return;
    callbackManager.unregisterReceiveItem(type, senderId, callback);
  }

  /// Register a callback for receiving group messages
  void registerReceiveItemChannel(
    String type,
    String channelId,
    Function(Map<String, dynamic>) callback,
  ) {
    if (!_initialized) {
      debugPrint(
        '[SIGNAL_CLIENT] ⚠️ Attempted to register callback before initialization',
      );
      return;
    }
    callbackManager.registerReceiveItemChannel(type, channelId, callback);
  }

  /// Register a callback for receiving messages of a specific type (from any sender)
  ///
  /// Use this for system messages or broadcasts where sender is not known in advance:
  /// - `call_notification` - incoming calls from any user
  /// - `system_message` - system announcements
  /// - Any message type where sender doesn't matter
  ///
  /// Example:
  /// ```dart
  /// signalClient.registerReceiveItemType('call_notification', (data) {
  ///   showIncomingCallNotification(data);
  /// });
  /// ```
  void registerReceiveItemType(
    String type,
    Function(Map<String, dynamic>) callback,
  ) {
    if (!_initialized) {
      debugPrint(
        '[SIGNAL_CLIENT] ⚠️ Attempted to register callback before initialization',
      );
      return;
    }
    callbackManager.registerReceiveItemType(type, callback);
  }

  /// Unregister a callback for receiving group messages
  void unregisterReceiveItemChannel(
    String type,
    String channelId,
    Function(Map<String, dynamic>) callback,
  ) {
    if (!_initialized) return;
    callbackManager.unregisterReceiveItemChannel(type, channelId, callback);
  }

  /// Unregister a callback for receiving messages of a specific type
  void unregisterReceiveItemType(
    String type,
    Function(Map<String, dynamic>) callback,
  ) {
    if (!_initialized) return;
    callbackManager.unregisterReceiveItemType(type, callback);
  }

  /// Register delivery receipt callback
  void onDeliveryReceipt(Function(String itemId) callback) {
    if (!_initialized) {
      debugPrint(
        '[SIGNAL_CLIENT] ⚠️ Attempted to register callback before initialization',
      );
      return;
    }
    callbackManager.registerDeliveryCallback(callback);
  }

  /// Register read receipt callback
  void onReadReceipt(Function(Map<String, dynamic> receiptInfo) callback) {
    if (!_initialized) {
      debugPrint(
        '[SIGNAL_CLIENT] ⚠️ Attempted to register callback before initialization',
      );
      return;
    }
    callbackManager.registerReadCallback(callback);
  }

  /// Clear all delivery callbacks
  void clearDeliveryCallbacks() {
    if (!_initialized) return;
    callbackManager.clearDeliveryCallbacks();
  }

  /// Clear all read callbacks
  void clearReadCallbacks() {
    callbackManager.clearReadCallbacks();
  }

  /// Delete item from server after successful processing
  void deleteItemFromServer(String itemId) {
    socketService.emit("deleteItem", {'itemId': itemId});
  }
}
