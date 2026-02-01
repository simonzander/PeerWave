// Signal Protocol Service - SignalClient for Multi-Server Support
//
// SignalClient orchestrates all Signal Protocol services for a specific server.
// Each server connection gets its own SignalClient instance with isolated state.
//
// Initialization flow (from main.dart):
// 1. DeviceScopedStorageService.instance.init()
// 2. apiService = ApiService(baseUrl: serverUrl); await apiService.init()
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

import '../api_service.dart';
import '../socket_service.dart'
    if (dart.library.io) '../socket_service_native.dart';

// Core services
import 'core/key_manager.dart';
import 'core/session_manager.dart';

// TODO: Add imports as services are refactored
// import 'core/healing_service.dart';
// import 'core/encryption_service.dart';
// import 'core/message_sender.dart';
// import 'core/message_receiver.dart';
// import 'core/group_message_sender.dart';
// import 'core/group_message_receiver.dart';
// import 'listeners/listener_registry.dart';
// import 'callbacks/callback_manager.dart';

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

  // TODO: Add other services as they're refactored
  // late final HealingService healingService;
  // late final EncryptionService encryptionService;
  // late final MessageSender messageSender;
  // late final MessageReceiver messageReceiver;
  // late final GroupMessageSender groupMessageSender;
  // late final GroupMessageReceiver groupMessageReceiver;
  // late final ListenerRegistry listenerRegistry;
  // late final CallbackManager callbackManager;

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
  });

  /// Initialize Signal Protocol services
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    // Initialize KeyManager with injected services
    keyManager = await SignalKeyManager.create(
      apiService: apiService,
      socketService: socketService,
    );

    // Initialize SessionManager after KeyManager
    sessionManager = await SessionManager.create(
      keyManager: keyManager,
      apiService: apiService,
      socketService: socketService,
    );

    // TODO: Initialize other services
    // healingService = HealingService(keyManager: keyManager);
    // etc.

    _initialized = true;
  }

  /// Clean up resources
  Future<void> dispose() async {
    _initialized = false;
  }

  bool get isInitialized => _initialized;
}
