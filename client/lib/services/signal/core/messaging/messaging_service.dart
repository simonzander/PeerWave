import 'package:flutter/foundation.dart';

import '../../../api_service.dart';
import '../../../socket_service.dart';
import '../../../storage/sqlite_group_message_store.dart';
import '../healing_service.dart';
import '../encryption_service.dart';
import '../key_manager.dart';
import '../session_manager.dart';
import '../../callbacks/callback_manager.dart';

// Import mixins
import 'mixins/one_to_one_messaging_mixin.dart';
import 'mixins/group_messaging_mixin.dart';
import 'mixins/file_messaging_mixin.dart';
import 'mixins/message_receiving_mixin.dart';
import 'mixins/message_caching_mixin.dart';

/// Unified Messaging Service
///
/// Handles ALL message operations using mixin-based architecture:
/// - OneToOneMessagingMixin: 1-to-1 message sending
/// - GroupMessagingMixin: Group message sending and sender key management
/// - FileMessagingMixin: File message sending (both 1-to-1 and group)
/// - MessageReceivingMixin: Unified message receiving and decryption
/// - MessageCachingMixin: Message caching and local storage
///
/// Dependencies:
/// - EncryptionService: For encryption/decryption operations
/// - HealingService: For automatic error recovery
/// - ApiService: For HTTP API calls (server-scoped)
/// - SocketService: For WebSocket operations (server-scoped)
///
/// Usage:
/// ```dart
/// final messagingService = await MessagingService.create(
///   encryptionService: encryptionService,
///   healingService: healingService,
///   apiService: apiService,
///   socketService: socketService,
///   currentUserId: userId,
///   currentDeviceId: deviceId,
///   waitForRegeneration: () async {},
///   itemTypeCallbacks: {},
///   receiveItemCallbacks: {},
/// );
/// ```
class MessagingService
    with
        OneToOneMessagingMixin,
        GroupMessagingMixin,
        FileMessagingMixin,
        MessageReceivingMixin,
        MessageCachingMixin {
  final EncryptionService encryptionService;
  final SignalHealingService healingService;
  final ApiService apiService;
  final SocketService socketService;
  final String currentUserId;
  final int currentDeviceId;
  final Function() waitForRegeneration;
  final CallbackManager callbackManager;
  final Function(int) regeneratePreKeyAsync;

  SqliteGroupMessageStore? _groupMessageStore;

  bool _initialized = false;

  // Delegate to EncryptionService for stores
  @override
  SessionManager get sessionStore => encryptionService.sessionStore;

  @override
  SignalKeyManager get preKeyStore => encryptionService.preKeyStore;

  @override
  SignalKeyManager get signedPreKeyStore => encryptionService.signedPreKeyStore;

  @override
  SignalKeyManager get identityStore => encryptionService.identityStore;

  @override
  SignalKeyManager get senderKeyStore => encryptionService.senderKeyStore;

  @override
  SqliteGroupMessageStore get groupMessageStore {
    if (_groupMessageStore == null) {
      throw StateError('MessagingService not initialized');
    }
    return _groupMessageStore!;
  }

  bool get isInitialized => _initialized;

  // Private constructor
  MessagingService._({
    required this.encryptionService,
    required this.healingService,
    required this.apiService,
    required this.socketService,
    required this.currentUserId,
    required this.currentDeviceId,
    required this.waitForRegeneration,
    required this.callbackManager,
    required this.regeneratePreKeyAsync,
  });

  /// Factory constructor with async initialization
  static Future<MessagingService> create({
    required EncryptionService encryptionService,
    required SignalHealingService healingService,
    required ApiService apiService,
    required SocketService socketService,
    required String currentUserId,
    required int currentDeviceId,
    required Function() waitForRegeneration,
    required CallbackManager callbackManager,
    required Function(int) regeneratePreKeyAsync,
  }) async {
    final service = MessagingService._(
      encryptionService: encryptionService,
      healingService: healingService,
      apiService: apiService,
      socketService: socketService,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      waitForRegeneration: waitForRegeneration,
      callbackManager: callbackManager,
      regeneratePreKeyAsync: regeneratePreKeyAsync,
    );

    await service.init();
    return service;
  }

  /// Initialize messaging service
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[MESSAGING_SERVICE] Already initialized');
      return;
    }

    debugPrint('[MESSAGING_SERVICE] Initializing...');

    try {
      // Initialize stores
      _groupMessageStore = await SqliteGroupMessageStore.getInstance();

      _initialized = true;
      debugPrint('[MESSAGING_SERVICE] ✓ Initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('[MESSAGING_SERVICE] ❌ Initialization failed: $e');
      debugPrint('[MESSAGING_SERVICE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Dispose resources
  void dispose() {
    _initialized = false;
    debugPrint('[MESSAGING_SERVICE] Disposed');
  }
}
