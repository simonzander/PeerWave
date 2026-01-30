import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'api_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'offline_message_queue.dart';
import 'package:uuid/uuid.dart';
import 'permanent_session_store.dart';
import 'permanent_pre_key_store.dart';
import 'permanent_signed_pre_key_store.dart';
import 'permanent_identity_key_store.dart';
import 'sender_key_store.dart';
import 'decrypted_group_items_store.dart';
import 'sent_group_items_store.dart';
import '../providers/unread_messages_provider.dart';
import 'storage/sqlite_message_store.dart';
import 'storage/sqlite_group_message_store.dart';
import 'storage/database_helper.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';
import 'native_crypto_service.dart';
import 'event_bus.dart';
import '../core/metrics/key_management_metrics.dart';
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// 🆕 Modular Signal Services
import 'signal/core/key_manager.dart';
import 'signal/core/healing_service.dart';
import 'signal/core/session_manager.dart';
import 'signal/core/encryption_service.dart';
import 'signal/core/message_sender.dart';
import 'signal/core/message_receiver.dart';
import 'signal/core/message_cache_service.dart';
import 'signal/core/offline_queue_processor.dart';
import 'signal/core/meeting_key_handler.dart';
import 'signal/core/incoming_message_processor.dart';
import 'signal/core/guest_session_manager.dart';
import 'signal/core/file_message_service.dart';
import 'signal/core/group_message_sender.dart';
import 'signal/core/group_message_receiver.dart';
import 'signal/listeners/listener_registry.dart';

class SignalService {
  static final SignalService instance = SignalService._internal();
  factory SignalService() => instance;
  SignalService._internal();

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// 🔒 Guard to prevent store re-creation (which would re-register Socket listeners)
  bool _storesCreated = false;

  /// 🔒 Guard to prevent duplicate Socket.IO listener registrations
  bool _listenersRegistered = false;

  final Map<String, List<Function(dynamic)>> _itemTypeCallbacks = {};
  final Map<String, List<Function(String)>> _deliveryCallbacks = {};
  final Map<String, List<Function(Map<String, dynamic>)>> _readCallbacks = {};

  // NEW: Callbacks for received items (1:1 messages)
  // Key format: "type:sender" (e.g., "message:user-uuid-123")
  final Map<String, List<Function(Map<String, dynamic>)>>
  _receiveItemCallbacks = {};

  // NEW: Callbacks for received group items (group messages)
  // Key format: "type:channel" (e.g., "message:channel-uuid-456")
  final Map<String, List<Function(Map<String, dynamic>)>>
  _receiveItemChannelCallbacks = {};

  late PermanentIdentityKeyStore identityStore;
  late PermanentSessionStore sessionStore;
  late PermanentPreKeyStore preKeyStore;
  late PermanentSignedPreKeyStore signedPreKeyStore;
  late PermanentSenderKeyStore senderKeyStore;
  late DecryptedGroupItemsStore decryptedGroupItemsStore;
  late SentGroupItemsStore sentGroupItemsStore;

  // 🆕 Modular Signal Services
  late SignalKeyManager keyManager;
  late SignalHealingService healingService;
  late SessionManager sessionManager;
  late EncryptionService encryptionService;
  late MessageSender messageSender;
  late MessageReceiver messageReceiver;
  late MessageCacheService messageCacheService;
  late OfflineQueueProcessor offlineQueueProcessor;
  late MeetingKeyHandler meetingKeyHandler;
  late IncomingMessageProcessor incomingMessageProcessor;
  late GuestSessionManager guestSessionManager;
  late FileMessageService fileMessageService;
  late GroupMessageSender groupMessageSender;
  late GroupMessageReceiver groupMessageReceiver;

  String? _currentUserId; // Store current user's UUID
  int? _currentDeviceId; // Store current device ID

  // Message processing lock to prevent concurrent processing of same message
  final Set<String> _processingMessages = {};

  // Sender-level locks to ensure messages from same sender are processed in order
  final Map<String, Future<void>> _senderProcessingLocks = {};

  // UnreadMessagesProvider reference (injected from outside)
  UnreadMessagesProvider? _unreadMessagesProvider;

  // Getters for current user and device info
  String? get currentUserId => _currentUserId;
  int? get currentDeviceId => _currentDeviceId;

  // Set current user and device info (call this after authentication)
  void setCurrentUserInfo(String userId, int deviceId) {
    _currentUserId = userId;
    _currentDeviceId = deviceId;
    debugPrint(
      '[SIGNAL SERVICE] Current user set: userId=$userId, deviceId=$deviceId',
    );
  }

  /// Set the UnreadMessagesProvider for badge updates
  void setUnreadMessagesProvider(UnreadMessagesProvider? provider) {
    _unreadMessagesProvider = provider;
    debugPrint(
      '[SIGNAL SERVICE] UnreadMessagesProvider ${provider != null ? 'connected' : 'disconnected'}',
    );
  }

  /// 🔒 SYNC-LOCK: Wait if identity key regeneration is in progress
  /// This prevents race conditions during key operations
  Future<void> _waitForRegenerationIfNeeded() async {
    if (identityStore.isRegenerating) {
      debugPrint(
        '[SIGNAL SERVICE] 🔒 Identity regeneration in progress - waiting...',
      );
      // The acquire lock will wait until regeneration completes
      await identityStore.acquireLock();
      identityStore.releaseLock();
      debugPrint(
        '[SIGNAL SERVICE] ✓ Identity regeneration completed - proceeding',
      );
    }
  }

  /// Retry operation with exponential backoff (default: 3 attempts, 1s-10s delays)
  Future<T> retryWithBackoff<T>({
    required Future<T> Function() operation,
    int maxAttempts = 3,
    int initialDelay = 1000,
    int maxDelay = 10000,
    bool Function(dynamic error)? shouldRetry,
  }) async {
    int attempt = 0;
    int delay = initialDelay;

    while (true) {
      try {
        attempt++;
        debugPrint('[SIGNAL SERVICE] Retry attempt $attempt/$maxAttempts');
        return await operation();
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] Attempt $attempt failed: $e');

        // Check if we should retry this error
        if (shouldRetry != null && !shouldRetry(e)) {
          debugPrint(
            '[SIGNAL SERVICE] Error is not retryable, throwing immediately',
          );
          rethrow;
        }

        // Check if we've exhausted attempts
        if (attempt >= maxAttempts) {
          debugPrint('[SIGNAL SERVICE] Max attempts reached, giving up');
          rethrow;
        }

        // Calculate delay with exponential backoff
        final currentDelay = (delay * (1 << (attempt - 1))).clamp(
          initialDelay,
          maxDelay,
        );
        debugPrint(
          '[SIGNAL SERVICE] Waiting ${currentDelay}ms before retry...',
        );
        await Future.delayed(Duration(milliseconds: currentDelay));
      }
    }
  }

  /// Helper: Determine if an error is network-related and retryable
  bool isRetryableError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('network') ||
        errorStr.contains('connection') ||
        errorStr.contains('timeout') ||
        errorStr.contains('socket') ||
        errorStr.contains('http');
  }

  /// Helper: Handle key sync requirements from server validation
  Future<void> _handleKeySyncRequired(
    Map<String, dynamic> validationResult,
  ) async {
    final missingKeys = validationResult['missingKeys'] as List?;

    // Handle identity mismatch - needs full re-setup
    if (missingKeys?.contains('identity') == true) {
      debugPrint('[SIGNAL SERVICE] Identity mismatch - clearing all keys');
      await clearAllSignalData(reason: 'Identity mismatch with server');
      return;
    }

    // Handle SignedPreKey out of sync
    if (missingKeys?.contains('signedPreKey') == true) {
      debugPrint('[SIGNAL SERVICE] SignedPreKey out of sync - rotating');
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      await signedPreKeyStore.rotateSignedPreKey(identityKeyPair);
      return;
    }

    // Handle consumed PreKeys
    final preKeyIdsToDelete = validationResult['preKeyIdsToDelete'] as List?;
    if (preKeyIdsToDelete != null && preKeyIdsToDelete.isNotEmpty) {
      debugPrint(
        '[SIGNAL SERVICE] Deleting ${preKeyIdsToDelete.length} consumed PreKeys',
      );
      for (final id in preKeyIdsToDelete) {
        await preKeyStore.removePreKey(id as int);
      }
      debugPrint(
        '[SIGNAL SERVICE] Consumed PreKeys deleted, triggering regeneration...',
      );

      // ✅ FIX: Immediately trigger prekey regeneration after deletion
      try {
        await preKeyStore.checkPreKeys();
        debugPrint(
          '[SIGNAL SERVICE] ✓ PreKey regeneration triggered successfully',
        );
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] ✗ PreKey regeneration failed: $e');
      }
    }
  }

  /// Process offline message queue - called automatically on socket reconnect
  ///
  /// Delegates to OfflineQueueProcessor for the actual processing logic.
  Future<void> _processOfflineQueue() async {
    await offlineQueueProcessor.processQueue(
      sendDirectMessage: (recipientId, payload, itemId) async {
        await sendItem(
          recipientUserId: recipientId,
          type: 'message',
          payload: payload,
          itemId: itemId,
        );
      },
      sendGroupMessage: (channelId, message, itemId) async {
        await sendGroupItem(
          channelId: channelId,
          message: message,
          itemId: itemId,
          type: 'message',
        );
      },
    );
  }

  /// Create stores and initialize modular services
  /// Extracted to avoid duplication across init methods
  Future<void> _createStoresAndServices() async {
    // 🆕 Self-initializing services with proper dependency chain
    // 1. KeyManager creates all crypto stores (base layer)
    keyManager = await SignalKeyManager.create();

    // 2. SessionManager depends on KeyManager
    sessionManager = await SessionManager.create(keyManager: keyManager);

    // 3. EncryptionService depends on KeyManager + SessionManager
    encryptionService = await EncryptionService.create(
      keyManager: keyManager,
      sessionManager: sessionManager,
    );

    // 4. HealingService depends on KeyManager + SessionManager
    healingService = await SignalHealingService.create(
      keyManager: keyManager,
      sessionManager: sessionManager,
      getCurrentUserId: () => _currentUserId,
      getCurrentDeviceId: () => _currentDeviceId,
    );

    // 5. MessageSender depends on EncryptionService + HealingService
    messageSender = await MessageSender.create(
      encryptionService: encryptionService,
      healingService: healingService,
      currentUserId: _currentUserId!,
      currentDeviceId: _currentDeviceId!,
      waitForRegeneration: _waitForRegenerationIfNeeded,
      itemTypeCallbacks: _itemTypeCallbacks,
      receiveItemCallbacks: _receiveItemCallbacks,
    );

    // 6. MessageReceiver depends on EncryptionService + MessageSender
    messageReceiver = await MessageReceiver.create(
      encryptionService: encryptionService,
      messageSender: messageSender,
      receiveItemCallbacks: _receiveItemCallbacks,
      regeneratePreKeyAsync: _regeneratePreKeyAsync,
    );

    // 7. MessageCacheService for SQLite caching
    messageCacheService = MessageCacheService(currentUserId: _currentUserId);

    // 8. OfflineQueueProcessor - Process queued messages on reconnect
    offlineQueueProcessor = OfflineQueueProcessor();

    // 9. MeetingKeyHandler - Handle meeting E2EE key exchange
    meetingKeyHandler = MeetingKeyHandler();

    // 10. IncomingMessageProcessor - Process incoming messages
    incomingMessageProcessor = IncomingMessageProcessor(
      decryptMessage: decryptItemFromData,
      handleReadReceipt: _handleReadReceipt,
      handleEmoteMessage: _handleEmoteMessage,
      notifyDecryptionFailure: _notifyDecryptionFailure,
      receiveItemCallbacks: _receiveItemCallbacks,
      itemTypeCallbacks: _itemTypeCallbacks,
      getCurrentUserId: () => _currentUserId,
    );

    // 11. GuestSessionManager - Manage guest sessions for meetings
    guestSessionManager = GuestSessionManager(
      sessionStore: sessionManager.sessionStore,
      preKeyStore: keyManager.preKeyStore,
      signedPreKeyStore: keyManager.signedPreKeyStore,
      identityStore: keyManager.identityStore,
      senderKeyStore: keyManager.senderKeyStore,
      getCurrentUserId: () => _currentUserId,
      getCurrentDeviceId: () => _currentDeviceId,
    );

    // 12. FileMessageService - Handle file-related messages
    fileMessageService = FileMessageService(
      encryptGroupMessage: encryptGroupMessage,
      sendItem: sendItem,
      sentGroupItemsStore: sentGroupItemsStore,
      getCurrentUserId: () => _currentUserId,
      getCurrentDeviceId: () => _currentDeviceId,
    );

    // 13. GroupMessageSender depends on EncryptionService
    groupMessageSender = await GroupMessageSender.create(
      encryptionService: encryptionService,
      getCurrentUserId: () => _currentUserId,
      getCurrentDeviceId: () => _currentDeviceId,
      waitForRegenerationIfNeeded: _waitForRegenerationIfNeeded,
    );

    // 14. GroupMessageReceiver depends on EncryptionService
    groupMessageReceiver = await GroupMessageReceiver.create(
      encryptionService: encryptionService,
      getCurrentUserId: () => _currentUserId,
      getCurrentDeviceId: () => _currentDeviceId,
    );

    // Legacy stores for backward compatibility (accessed directly by SignalService)
    identityStore = keyManager.identityStore;
    sessionStore = sessionManager.sessionStore;
    preKeyStore = keyManager.preKeyStore;
    signedPreKeyStore = keyManager.signedPreKeyStore;
    senderKeyStore = keyManager.senderKeyStore;
    decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
    sentGroupItemsStore = await SentGroupItemsStore.getInstance();
  }

  Future<void> init() async {
    debugPrint('[SIGNAL INIT] 🔍 init() called');
    debugPrint(
      '[SIGNAL INIT] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered',
    );

    // Initialize stores (create only if not already created)
    if (!_storesCreated) {
      debugPrint('[SIGNAL INIT] Creating stores for the first time...');
      await _createStoresAndServices();
      _storesCreated = true;
      debugPrint('[SIGNAL INIT] ✅ Stores and services created');
    } else {
      debugPrint('[SIGNAL INIT] ℹ️  Stores already exist, reusing...');
    }

    await _registerSocketListeners();

    // Load offline message queue
    await OfflineMessageQueue.instance.loadQueue();
    debugPrint(
      '[SIGNAL SERVICE] Offline queue loaded: ${OfflineMessageQueue.instance.queueSize} messages',
    );

    // 🚀 CRITICAL: Notify server that client is ready to receive events
    SocketService().notifyClientReady();
    debugPrint('[SIGNAL INIT] ✓ Server notified: Client ready for events');

    // --- Signal status check and conditional upload ---
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    //await test();
  }

  /// Initialize stores and listeners without generating keys
  /// Used when keys already exist (after successful setup or on returning user)
  Future<void> initStoresAndListeners() async {
    debugPrint('[SIGNAL SERVICE] 🔍 initStoresAndListeners() called');
    debugPrint(
      '[SIGNAL SERVICE] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered',
    );

    // 🔒 CRITICAL: Check if device identity is initialized (required for encryption)
    if (!DeviceIdentityService.instance.isInitialized) {
      debugPrint(
        '[SIGNAL INIT] Device identity not initialized, attempting restore...',
      );

      // For native, get the active server URL
      String? serverUrl;
      if (!kIsWeb) {
        final activeServer = ServerConfigService.getActiveServer();
        serverUrl = activeServer?.serverUrl;
        if (serverUrl != null) {
          debugPrint('[SIGNAL INIT] Active server: $serverUrl');
        }
      }

      if (!await DeviceIdentityService.instance.tryRestoreFromSession(
        serverUrl: serverUrl,
      )) {
        throw Exception(
          'Device identity not initialized. Please log in first.',
        );
      }
      debugPrint('[SIGNAL INIT] Device identity restored from storage');
    }

    // Initialize stores (create only if not already created)
    if (!_storesCreated) {
      debugPrint('[SIGNAL SERVICE] Creating stores for the first time...');
      await _createStoresAndServices();
      _storesCreated = true;
      debugPrint('[SIGNAL INIT] ✅ Stores created');

      // ✅ Check and regenerate prekeys if needed after store creation
      try {
        await preKeyStore.checkPreKeys();
        debugPrint('[SIGNAL INIT] ✓ PreKey validation completed');
      } catch (e) {
        debugPrint('[SIGNAL INIT] ⚠️ PreKey check failed: $e');
      }
    } else {
      debugPrint('[SIGNAL INIT] ℹ️  Stores already exist, reusing...');
    }

    // Register socket listeners
    await _registerSocketListeners();

    // ✅ NEW: Validate keys with server BEFORE sending clientReady
    debugPrint('[SIGNAL INIT] Validating keys before clientReady...');

    try {
      // Get local prekey fingerprints for validation
      final preKeyFingerprints = await keyManager.getPreKeyFingerprints();

      // HTTP request to validate/sync keys (blocking, with response code)
      final response = await ApiService.post(
        '/signal/validate-and-sync',
        data: {
          'localIdentityKey': await keyManager.getLocalIdentityPublicKey(),
          'localSignedPreKeyId': await keyManager.getLatestSignedPreKeyId(),
          'localPreKeyCount': await keyManager.getLocalPreKeyCount(),
          'preKeyFingerprints':
              preKeyFingerprints, // NEW: Send hashes for validation
        },
      );

      if (response.statusCode == 200) {
        final validationResult = response.data as Map<String, dynamic>;

        if (validationResult['keysValid'] == true) {
          debugPrint('[SIGNAL INIT] ✓ Keys validated by server');
        } else {
          // Server detected mismatch - handle sync
          debugPrint(
            '[SIGNAL INIT] ⚠ Key mismatch detected: ${validationResult['reason']}',
          );
          await _handleKeySyncRequired(validationResult);
        }
      } else {
        debugPrint(
          '[SIGNAL INIT] ⚠ Key validation failed: ${response.statusCode}',
        );
      }
    } catch (e) {
      // Network error - will trigger server unreachable flow
      debugPrint('[SIGNAL INIT] Could not validate keys: $e');
      rethrow;
    }

    // 🚀 CRITICAL: Notify server that client is ready to receive events
    SocketService().notifyClientReady();
    debugPrint('[SIGNAL INIT] ✓ Server notified: Client ready for events');

    // Check status with server (server will only respond if client is ready)
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    debugPrint(
      '[SIGNAL SERVICE] Stores and listeners initialized successfully',
    );
  }

  /// Progressive initialization with progress callbacks (112 steps: 1 KeyPair + 1 SignedPreKey + 110 PreKeys)
  /// onProgress: (statusText, current, total, percentage)
  Future<void> initWithProgress(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
  ) async {
    debugPrint('[SIGNAL INIT] 🔍 initWithProgress() called');
    debugPrint(
      '[SIGNAL INIT] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered',
    );

    // Check if initialization is needed
    if (_isInitialized) {
      debugPrint(
        '[SIGNAL INIT] Already initialized, checking if PreKeys need regeneration...',
      );

      // Even if initialized, check if PreKeys are missing
      final preKeyIds = await preKeyStore.getAllPreKeyIds();
      debugPrint('[SIGNAL INIT] Current PreKey count: ${preKeyIds.length}');

      const int targetPrekeys = 110; // Signal Protocol recommendation
      const int minPrekeys = 20; // Regenerate threshold

      if (preKeyIds.length >= minPrekeys) {
        debugPrint(
          '[SIGNAL INIT] PreKeys sufficient (${preKeyIds.length}/$targetPrekeys), skipping...',
        );
        onProgress('Signal Protocol ready', 112, 112, 100.0);
        return;
      }

      debugPrint(
        '[SIGNAL INIT] ⚠️ PreKeys insufficient (${preKeyIds.length}/$targetPrekeys), regenerating...',
      );

      // Just regenerate PreKeys without full initialization
      await _regeneratePreKeysOnly(onProgress, preKeyIds);

      debugPrint('[SIGNAL INIT] ✅ PreKey regeneration complete');
      return;
    }

    // Continue with full initialization for first-time setup...

    const int totalSteps = 112; // 1 KeyPair + 1 SignedPreKey + 110 PreKeys
    int currentStep = 0;

    // Helper to update progress
    void updateProgress(String status, int step) {
      final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
      onProgress(status, step, totalSteps, percentage);
    }

    // 🔒 CRITICAL: Check if device identity is initialized (required for encryption)
    if (DeviceIdentityService.instance.deviceId.isEmpty) {
      // Try to restore from storage first
      debugPrint(
        '[SIGNAL INIT] Device identity not in memory, checking storage...',
      );

      // For native, get the active server URL
      String? serverUrl;
      if (!kIsWeb) {
        final activeServer = ServerConfigService.getActiveServer();
        serverUrl = activeServer?.serverUrl;
        if (serverUrl != null) {
          debugPrint('[SIGNAL INIT] Active server: $serverUrl');
        }
      }

      if (!await DeviceIdentityService.instance.tryRestoreFromSession(
        serverUrl: serverUrl,
      )) {
        throw Exception(
          'Device identity not initialized. Please log in first.',
        );
      }
      debugPrint('[SIGNAL INIT] Device identity restored from storage');
    }

    // 🔑 CRITICAL: Check if encryption key exists (platform-specific)
    final deviceId = DeviceIdentityService.instance.deviceId;
    Uint8List? encryptionKey;

    if (kIsWeb) {
      // Web: Use WebAuthn encryption key from SessionStorage
      encryptionKey = WebAuthnCryptoService.instance.getKeyFromSession(
        deviceId,
      );
    } else {
      // Native: Use secure storage encryption key
      encryptionKey = await NativeCryptoService.instance.getKey(deviceId);
    }

    if (encryptionKey == null) {
      throw Exception(
        'Encryption key not found. Please log in again to re-authenticate.',
      );
    }
    debugPrint(
      '[SIGNAL INIT] ✓ Encryption key verified (${encryptionKey.length} bytes)',
    );

    // Initialize stores (create only if not already created)
    // Since stores are declared as `late`, they can only be safely accessed after creation
    // We must avoid re-creating stores as this would re-register Socket listeners
    if (!_storesCreated) {
      debugPrint('[SIGNAL INIT] Creating stores for the first time...');
      await _createStoresAndServices();
      _storesCreated = true;
      debugPrint(
        '[SIGNAL INIT] ✅ Stores and services created for the first time',
      );
    } else {
      debugPrint('[SIGNAL INIT] ℹ️  Stores already exist, reusing...');
    }

    // Step 1: Generate Identity Key Pair (if needed)
    updateProgress('Generating identity key pair...', currentStep);
    try {
      await identityStore.getIdentityKeyPair();
      debugPrint('[SIGNAL INIT] Identity key pair exists');
    } catch (e) {
      debugPrint('[SIGNAL INIT] Identity key pair will be generated: $e');
    }
    final identityKeyPair = await identityStore.getIdentityKeyPair();
    signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
    currentStep++;
    updateProgress('Identity key pair ready', currentStep);
    await Future.delayed(const Duration(milliseconds: 50));

    // Step 2: Generate Signed PreKey (if needed)
    updateProgress('Generating signed pre key...', currentStep);
    final existingSignedKeys = await signedPreKeyStore.loadSignedPreKeys();
    if (existingSignedKeys.isEmpty) {
      final signedPreKey = generateSignedPreKey(identityKeyPair, 0);
      await signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);
      debugPrint('[SIGNAL INIT] Signed pre key generated');
    } else {
      debugPrint('[SIGNAL INIT] Signed pre key already exists');
    }
    currentStep++;
    updateProgress('Signed pre key ready', currentStep);
    await Future.delayed(const Duration(milliseconds: 50));

    // Step 3: Generate PreKeys in batches (110 keys, 10 per batch)
    var existingPreKeyIds = await preKeyStore.getAllPreKeyIds();

    // CLEANUP: Remove excess PreKeys if > 110 (keep incrementing IDs)
    const int targetPrekeys = 110;
    final hasExcessKeys = existingPreKeyIds.length > targetPrekeys;

    if (hasExcessKeys) {
      debugPrint(
        '[SIGNAL INIT] Found ${existingPreKeyIds.length} PreKeys (expected $targetPrekeys)',
      );
      debugPrint('[SIGNAL INIT] Deleting excess PreKeys...');

      // Delete excess PreKeys (keep lowest IDs)
      final sortedIds = List<int>.from(existingPreKeyIds)..sort();
      final toDelete = sortedIds.skip(targetPrekeys).toList();
      for (final id in toDelete) {
        await preKeyStore.removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = sortedIds.take(targetPrekeys).toList();
      debugPrint(
        '[SIGNAL INIT] Cleanup complete, now have ${existingPreKeyIds.length} PreKeys',
      );
    }

    final neededPreKeys = targetPrekeys - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[SIGNAL INIT] Need to generate $neededPreKeys pre keys');

      // ✅ Delegate to preKeyStore.checkPreKeys() which handles incrementing IDs correctly
      // This ensures consistency between initialization and normal operation
      debugPrint(
        '[SIGNAL INIT] Delegating to preKeyStore.checkPreKeys() for proper ID allocation',
      );

      // Use preKeyStore's logic which correctly handles incrementing IDs
      int keysGeneratedInSession = 0;
      final startCount = existingPreKeyIds.length;

      // Call preKeyStore.checkPreKeys() which handles generation with proper ID allocation
      try {
        await preKeyStore.checkPreKeys();

        // Get updated count
        final updatedIds = await preKeyStore.getAllPreKeyIds();
        keysGeneratedInSession = updatedIds.length - startCount;

        debugPrint(
          '[SIGNAL INIT] ✓ Generated $keysGeneratedInSession PreKeys via checkPreKeys()',
        );

        // Update progress
        final totalKeysNow = updatedIds.length;
        updateProgress(
          'Pre keys ready ($totalKeysNow/110)',
          currentStep + keysGeneratedInSession,
        );
      } catch (e) {
        debugPrint('[SIGNAL INIT] ⚠️ PreKey generation failed: $e');
      }

      // Update currentStep by total keys generated
      currentStep += keysGeneratedInSession;

      // Track metrics for diagnostics (if any keys were generated)
      if (keysGeneratedInSession > 0) {
        KeyManagementMetrics.recordPreKeyRegeneration(
          keysGeneratedInSession,
          reason: 'Signal initialization',
        );
      }
    } else {
      const int targetPrekeys = 110; // Define constant locally for this scope
      debugPrint(
        '[SIGNAL INIT] Pre keys already sufficient (${existingPreKeyIds.length}/$targetPrekeys)',
      );
      // Skip to end
      currentStep = totalSteps;
      updateProgress('Pre keys already ready', currentStep);
    }

    // Register socket listeners
    await _registerSocketListeners();

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    // 🚀 Notify server that client is ready (keys uploaded, listeners registered)
    SocketService().notifyClientReady();
    debugPrint('[SIGNAL INIT] ✓ Server notified: Client ready for events');

    // Check status with server (server will only respond if client is ready)
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    debugPrint('[SIGNAL INIT] Progressive initialization complete');

    // 🔍 SELF-VERIFICATION: Verify our own keys are uploaded to server
    debugPrint('[SIGNAL INIT] ========================================');
    debugPrint(
      '[SIGNAL INIT] Starting post-initialization self-verification...',
    );

    // Wait a moment for server to process signalStatus response
    await Future.delayed(Duration(seconds: 2));

    final keysValid = await keyManager.verifyOwnKeysOnServer(
      _currentUserId ?? '',
      _currentDeviceId ?? 0,
    );
    if (!keysValid) {
      // 🔧 FIX: Check if failure is due to socket not being connected yet
      // If _currentUserId is null, it means socket hasn't authenticated yet
      // In this case, skip re-upload - verification will retry when socket connects
      if (_currentUserId == null) {
        debugPrint(
          '[SIGNAL INIT] ⚠️ Self-verification skipped - socket not connected yet',
        );
        debugPrint(
          '[SIGNAL INIT] → Verification will retry automatically after socket authentication',
        );
      } else {
        // Socket is connected but verification failed - this is a real problem
        debugPrint(
          '[SIGNAL INIT] ⚠️ Self-verification failed - keys may not be uploaded properly',
        );
        debugPrint('[SIGNAL INIT] → Attempting to re-upload keys...');

        try {
          // Re-upload all keys
          await keyManager.uploadSignedPreKeyAndPreKeys();
          await Future.delayed(Duration(milliseconds: 1000));

          // Verify again
          final retryValid = await keyManager.verifyOwnKeysOnServer(
            _currentUserId ?? '',
            _currentDeviceId ?? 0,
          );
          if (!retryValid) {
            debugPrint('[SIGNAL INIT] ❌ Keys still not valid after retry');
            debugPrint(
              '[SIGNAL INIT] → User may need to logout and login again',
            );
            // Don't throw - allow app to continue, but user will see errors when sending
          } else {
            debugPrint('[SIGNAL INIT] ✅ Keys uploaded and verified on retry');
          }
        } catch (e) {
          debugPrint('[SIGNAL INIT] ❌ Key upload retry failed: $e');
          // Don't rethrow - allow app to continue
        }
      }
    } else {
      debugPrint(
        '[SIGNAL INIT] ✅ Self-verification passed - all keys valid on server',
      );
    }
    debugPrint('[SIGNAL INIT] ========================================');
  }

  /// Regenerate PreKeys when already initialized but PreKeys are missing
  /// This is called when initWithProgress() detects missing PreKeys on an already-initialized system
  Future<void> _regeneratePreKeysOnly(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
    List<int> existingPreKeyIds,
  ) async {
    const int totalSteps = 110;
    int currentStep = existingPreKeyIds.length; // Start from existing count

    // Helper to update progress
    void updateProgress(String status, int step) {
      final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
      onProgress(status, step, totalSteps, percentage);
    }

    debugPrint('[SIGNAL INIT] Starting PreKey regeneration...');
    debugPrint(
      '[SIGNAL INIT] Existing PreKeys: ${existingPreKeyIds.length}/110',
    );

    // Check for invalid IDs (>= 110)
    final hasInvalidIds = existingPreKeyIds.any((id) => id >= 110);
    if (hasInvalidIds) {
      final invalidIds = existingPreKeyIds.where((id) => id >= 110).toList();
      debugPrint(
        '[SIGNAL INIT] ⚠️ Found invalid PreKey IDs (>= 110): $invalidIds',
      );
      debugPrint(
        '[SIGNAL INIT] 🔧 Deleting ALL PreKeys and regenerating fresh set...',
      );

      // Delete ALL existing PreKeys
      for (final id in existingPreKeyIds) {
        await preKeyStore.removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = [];
      debugPrint(
        '[SIGNAL INIT] ✓ Cleanup complete, will generate fresh 110 PreKeys',
      );
    }

    final neededPreKeys = 110 - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[SIGNAL INIT] Need to generate $neededPreKeys pre keys');

      // ✅ Delegate to preKeyStore.checkPreKeys() which handles incrementing IDs correctly
      debugPrint(
        '[SIGNAL INIT] Delegating to preKeyStore.checkPreKeys() for proper ID allocation',
      );

      // Use preKeyStore's logic which correctly handles incrementing IDs
      int keysGeneratedInSession = 0;
      final startCount = existingPreKeyIds.length;

      try {
        await preKeyStore.checkPreKeys();

        // Get updated count
        final updatedIds = await preKeyStore.getAllPreKeyIds();
        keysGeneratedInSession = updatedIds.length - startCount;

        debugPrint(
          '[SIGNAL INIT] ✓ Generated $keysGeneratedInSession PreKeys via checkPreKeys()',
        );

        // Update progress
        final totalKeysNow = updatedIds.length;
        updateProgress(
          'Pre keys ready ($totalKeysNow/110)',
          currentStep + keysGeneratedInSession,
        );
      } catch (e) {
        debugPrint('[SIGNAL INIT] ⚠️ PreKey generation failed: $e');
      }

      debugPrint(
        '[SIGNAL INIT] ✅ PreKey regeneration complete: generated $keysGeneratedInSession keys',
      );
    }

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    // Notify server that keys are updated
    SocketService().emit("signalStatus", null);

    debugPrint('[SIGNAL INIT] ✓ PreKey regeneration successful');
  }

  /// Register all Socket.IO listeners (extracted for reuse)
  Future<void> _registerSocketListeners() async {
    // 🔒 Prevent duplicate listener registrations
    if (_listenersRegistered) {
      debugPrint(
        '[SIGNAL SERVICE] Socket listeners already registered, skipping...',
      );
      return;
    }

    debugPrint('[SIGNAL SERVICE] Registering Socket.IO listeners...');

    try {
      // 🆕 Register modular signal listeners via ListenerRegistry
      await ListenerRegistry.instance.registerAll(
        messageReceiver: messageReceiver,
        groupReceiver: groupMessageReceiver,
        sessionManager: sessionManager,
        keyManager: keyManager,
        healingService: healingService,
        unreadMessagesProvider: _unreadMessagesProvider,
        currentUserId: _currentUserId,
        currentDeviceId: _currentDeviceId,
      );

      // ⚠️ Signal service-specific listeners that can't be modularized:

      // Setup offline queue processing on reconnect
      // (Requires access to sendItem/sendGroupItem methods)
      SocketService().registerListener("connect", (_) {
        debugPrint(
          '[SIGNAL SERVICE] Socket reconnected, processing offline queue...',
        );
        _processOfflineQueue();
      }, registrationName: 'SignalService');

      // Legacy groupMessage callback system (deprecated)
      SocketService().registerListener("groupMessage", (data) {
        final dataMap = Map<String, dynamic>.from(data as Map);
        // Handle group message via callback system
        if (_itemTypeCallbacks.containsKey('groupMessage')) {
          for (final callback in _itemTypeCallbacks['groupMessage']!) {
            callback(dataMap);
          }
        }
      }, registrationName: 'SignalService');

      // Setup Event Bus forwarding for user/channel events
      _setupEventBusForwarding();

      _listenersRegistered = true;
      debugPrint(
        '[SIGNAL SERVICE] ✅ All signal listeners registered successfully',
      );
    } catch (e, stackTrace) {
      // Rollback: Reset flag so retry is possible
      debugPrint('[SIGNAL SERVICE] ⚠️ Error during listener registration: $e');
      debugPrint('[SIGNAL SERVICE] Stack trace: $stackTrace');

      _listenersRegistered = false;
      debugPrint(
        '[SIGNAL SERVICE] ❌ Listener registration failed - will retry on next init',
      );
      rethrow;
    }
  }

  /// Setup Event Bus forwarding for user and channel events
  /// These events may come from socket or can be manually triggered
  void _setupEventBusForwarding() {
    debugPrint('[SIGNAL SERVICE] Setting up Event Bus forwarding...');

    // Forward user status events (if server sends them)
    SocketService().registerListener('user:status', (data) {
      debugPrint('[SIGNAL SERVICE] → EVENT_BUS: userStatusChanged');
      EventBus.instance.emit(
        AppEvent.userStatusChanged,
        Map<String, dynamic>.from(data as Map),
      );
    }, registrationName: 'SignalService');

    debugPrint('[SIGNAL SERVICE] ✓ Event Bus forwarding active');
  }

  /// Register a callback for a specific item type
  void registerItemCallback(String type, Function(dynamic) callback) {
    _itemTypeCallbacks.putIfAbsent(type, () => []).add(callback);
  }

  /// Register callback for delivery receipts
  void onDeliveryReceipt(Function(String itemId) callback) {
    _deliveryCallbacks.putIfAbsent('default', () => []).add(callback);
  }

  /// Register callback for read receipts
  /// Callback receives a Map with: itemId, readByDeviceId, readByUserId
  void onReadReceipt(Function(Map<String, dynamic> receiptInfo) callback) {
    _readCallbacks.putIfAbsent('default', () => []).add(callback);
  }

  /// Register callback for received 1:1 items (type+sender combination)
  void registerReceiveItem(
    String type,
    String sender,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$sender';
    _receiveItemCallbacks.putIfAbsent(key, () => []).add(callback);
    debugPrint('[SIGNAL SERVICE] Registered receiveItem callback for $key');
  }

  /// Register callback for received group items (type+channel combination)
  void registerReceiveItemChannel(
    String type,
    String channel,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$channel';
    _receiveItemChannelCallbacks.putIfAbsent(key, () => []).add(callback);
    debugPrint(
      '[SIGNAL SERVICE] Registered receiveItemChannel callback for $key',
    );
  }

  /// Unregister delivery receipt callbacks
  void clearDeliveryCallbacks() {
    _deliveryCallbacks.remove('default');
  }

  /// Unregister read receipt callbacks
  void clearReadCallbacks() {
    _readCallbacks.remove('default');
  }

  /// NEW: Unregister callback for received 1:1 items
  void unregisterReceiveItem(
    String type,
    String sender,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$sender';
    _receiveItemCallbacks[key]?.remove(callback);
    if (_receiveItemCallbacks[key]?.isEmpty ?? false) {
      _receiveItemCallbacks.remove(key);
      debugPrint('[SIGNAL SERVICE] Removed all receiveItem callbacks for $key');
    }
  }

  /// NEW: Unregister callback for received group items
  void unregisterReceiveItemChannel(
    String type,
    String channel,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$channel';
    _receiveItemChannelCallbacks[key]?.remove(callback);
    if (_receiveItemChannelCallbacks[key]?.isEmpty ?? false) {
      _receiveItemChannelCallbacks.remove(key);
      debugPrint(
        '[SIGNAL SERVICE] Removed all receiveItemChannel callbacks for $key',
      );
    }
  }

  /// Register callback for meeting E2EE key requests (via 1-to-1 Signal messages)
  /// Called when someone in the meeting requests the E2EE key
  void registerMeetingE2EEKeyRequestCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    meetingKeyHandler.registerRequestCallback(meetingId, callback);
  }

  /// Register callback for meeting E2EE key responses (via 1-to-1 Signal messages)
  /// Called when someone sends us the E2EE key
  void registerMeetingE2EEKeyResponseCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    meetingKeyHandler.registerResponseCallback(meetingId, callback);
  }

  /// Unregister meeting E2EE callbacks (call when leaving meeting)
  void unregisterMeetingE2EECallbacks(String meetingId) {
    meetingKeyHandler.unregisterCallbacks(meetingId);
  }

  /// Reset service state on logout
  /// Allows fresh initialization on next login
  void resetOnLogout() {
    debugPrint('[SIGNAL SERVICE] Resetting state on logout...');
    _isInitialized = false;
    _storesCreated = false;
    _listenersRegistered = false;
    debugPrint('[SIGNAL SERVICE] ✓ State reset complete');
  }

  /// 🚨 Clear ALL Signal Protocol data (local + server). Requires full re-initialization after.
  Future<void> clearAllSignalData({String reason = 'Manual reset'}) async {
    debugPrint('[SIGNAL SERVICE] 🚨 CLEARING ALL SIGNAL DATA...');
    debugPrint('[SIGNAL SERVICE] Reason: $reason');

    try {
      // 1. Delete server-side keys first
      SocketService().emit("deleteAllSignalKeys", {
        'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
      });
      debugPrint('[SIGNAL SERVICE] ✓ Server keys deletion requested');

      // 2. Clear local IndexedDB databases (web) or SecureStorage (native)
      final deviceId = DeviceIdentityService.instance.deviceId;

      if (deviceId.isNotEmpty) {
        if (kIsWeb) {
          // Web: Clear IndexedDB databases
          debugPrint('[SIGNAL SERVICE] Clearing IndexedDB databases...');
          debugPrint(
            '[SIGNAL SERVICE] NOTE: Full IndexedDB deletion requires page reload',
          );
          debugPrint('[SIGNAL SERVICE] Keys will be regenerated on next init');

          // Mark for regeneration - the actual IndexedDB clear happens via browser dev tools
          // or by clearing browser data. The identity mismatch check will trigger deletion.
        } else {
          // Native: Clear from SecureStorage
          const secureStorage = FlutterSecureStorage();

          // Delete identity keys
          try {
            await secureStorage.delete(key: 'identity_keyPair_$deviceId');
            await secureStorage.delete(
              key: 'identity_registrationId_$deviceId',
            );
            debugPrint(
              '[SIGNAL SERVICE] ✓ Deleted identity keys from SecureStorage',
            );
          } catch (e) {
            debugPrint('[SIGNAL SERVICE] ⚠️ Error deleting identity: $e');
          }

          // Note: PreKeys, SignedPreKeys, Sessions, SenderKeys stored in SQLite
          // They will be cleared by database table drops if needed
        }
      }

      // 3. Delete all sessions (local cleanup)
      // Sessions are bound to Identity Keys - when Identity changes, sessions are invalid
      if (_storesCreated) {
        try {
          await sessionStore.deleteAllSessionsCompletely();
          debugPrint('[SIGNAL SERVICE] ✓ Deleted all local sessions');
        } catch (e) {
          debugPrint('[SIGNAL SERVICE] ⚠️ Error deleting sessions: $e');
        }

        // Delete all SenderKeys - they are signed with Identity Key
        try {
          await senderKeyStore.deleteAllSenderKeys();
          debugPrint('[SIGNAL SERVICE] ✓ Deleted all SenderKeys');
        } catch (e) {
          debugPrint('[SIGNAL SERVICE] ⚠️ Error deleting SenderKeys: $e');
        }
      }

      // 4. Reset initialization state
      _isInitialized = false;
      _storesCreated = false;

      debugPrint('[SIGNAL SERVICE] ✅ ALL SIGNAL DATA CLEARED');
      debugPrint(
        '[SIGNAL SERVICE] → Please call initWithProgress() to regenerate keys',
      );
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL SERVICE] ❌ Error during cleanup: $e');
      debugPrint('[SIGNAL SERVICE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Unregister a callback for a specific item type
  void unregisterItemCallback(String type, Function(dynamic) callback) {
    _itemTypeCallbacks[type]?.remove(callback);
    if (_itemTypeCallbacks[type]?.isEmpty ?? false) {
      _itemTypeCallbacks.remove(type);
    }
  }

  /// Load sent messages for a specific recipient from local storage
  /// This is used after page refresh to restore sent messages
  /// MIGRATED: Now uses SQLite for better performance
  Future<List<Map<String, dynamic>>> loadSentMessages(
    String recipientUserId,
  ) async {
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final messages = await messageStore.getMessagesFromConversation(
        recipientUserId,
        types: ['message', 'file'],
      );

      // Filter only sent messages and convert to expected format
      return messages
          .where((msg) => msg['direction'] == 'sent')
          .map(
            (msg) => {
              'itemId': msg['item_id'],
              'message': msg['message'],
              'timestamp': msg['timestamp'],
              'recipientId': recipientUserId,
              'type': msg['type'],
              'status': msg['status'], // Include status
            },
          )
          .toList();
    } catch (e) {
      debugPrint(
        '[SIGNAL_SERVICE] ✗ Error loading sent messages from SQLite: $e',
      );
      return [];
    }
  }

  /// Load all sent messages from local storage
  /// Uses SQLite for better performance
  Future<List<Map<String, dynamic>>> loadAllSentMessages() async {
    try {
      final db = await DatabaseHelper.database;

      final result = await db.query(
        'messages',
        where: 'direction = ? AND channel_id IS NULL',
        whereArgs: ['sent'],
        orderBy: 'timestamp DESC',
      );

      return result
          .map(
            (msg) => {
              'itemId': msg['item_id'],
              'message': msg['message'],
              'timestamp': msg['timestamp'],
              // ⚠️ SCHEMA QUIRK: SQLite 'sender' column stores different data based on direction:
              // - For RECEIVED messages: 'sender' = who sent it (their userId)
              // - For SENT messages: 'sender' = who we sent TO (the recipientId)
              // This is confusing but avoiding it would require schema migration.
              'recipientId': msg['sender'],
              'type': msg['type'],
              'status': msg['status'], // Include status
            },
          )
          .toList();
    } catch (e) {
      debugPrint(
        '[SIGNAL_SERVICE] ✗ Error loading all sent messages from SQLite: $e',
      );
      return [];
    }
  }

  /// Entschlüsselt ein Item-Objekt (wie receiveItem), gibt aber nur die entschlüsselte Nachricht zurück
  /// Prüft zuerst den lokalen Cache, um DuplicateMessageException zu vermeiden
  Future<String> decryptItemFromData(Map<String, dynamic> data) async {
    final sender = data['sender'];
    final senderDeviceId = data['senderDeviceId'] is int
        ? data['senderDeviceId'] as int
        : int.parse(data['senderDeviceId'].toString());
    final payload = data['payload'];
    final cipherType = data['cipherType'];
    final itemId = data['itemId'];

    // Check cache first (prevents DuplicateMessageException)
    if (itemId != null) {
      final cachedMessage = await messageCacheService.getCachedMessage(itemId);
      if (cachedMessage != null) {
        return cachedMessage;
      }
    }

    debugPrint(
      "[SIGNAL SERVICE] Decrypting new message: itemId=$itemId, sender=$sender, deviceId=$senderDeviceId",
    );

    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);

    String message;
    try {
      // Decrypt the message
      message = await decryptItem(
        senderAddress: senderAddress,
        payload: payload,
        cipherType: cipherType,
        itemId: itemId,
      );
    } on UntrustedIdentityException catch (e) {
      debugPrint(
        '[SIGNAL SERVICE] UntrustedIdentityException during decryption - sender changed identity',
      );
      // Auto-trust the new identity and retry decryption
      message = await handleUntrustedIdentity(e, senderAddress, () async {
        return await decryptItem(
          senderAddress: senderAddress,
          payload: payload,
          cipherType: cipherType,
          itemId: itemId,
        );
      }, sendNotification: true);
      debugPrint('[SIGNAL SERVICE] ✓ Message decrypted after identity update');
    }

    // Cache the decrypted message
    if (itemId != null && message != 'Decryption failed') {
      try {
        await messageCacheService.cacheDecryptedMessage(
          itemId: itemId,
          message: message,
          data: data,
          sender: sender,
          senderDeviceId: senderDeviceId,
        );
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] ⚠️ Failed to cache message: $e');
        // Continue processing even if caching fails
      }
    }

    // Handle decryption failures
    if (message == 'Decryption failed' && itemId != null) {
      await _handleDecryptionFailure(itemId, data, sender, senderDeviceId);
    }

    return message;
  }

  /// Handle failed decryption by storing and emitting events
  Future<void> _handleDecryptionFailure(
    String itemId,
    Map<String, dynamic> data,
    String sender,
    int senderDeviceId,
  ) async {
    // Cache the failed decryption
    await messageCacheService.cacheFailedDecryption(
      itemId: itemId,
      data: data,
      sender: sender,
      senderDeviceId: senderDeviceId,
    );

    // Emit EventBus events so UI shows the failure
    final isOwnMessage = sender == _currentUserId;
    final recipient = data['recipient'] as String?;
    final originalRecipient = data['originalRecipient'] as String?;
    final messageType = data['type'] as String?;
    final messageTimestamp =
        data['timestamp'] ??
        data['createdAt'] ??
        DateTime.now().toIso8601String();

    final conversationWith = isOwnMessage
        ? (originalRecipient ?? recipient ?? sender)
        : sender;

    debugPrint(
      '[SIGNAL SERVICE] → EVENT_BUS: newMessage (decrypt_failed) - conversationWith=$conversationWith',
    );

    final decryptFailedItem = {
      'itemId': itemId,
      'type': messageType ?? 'message',
      'sender': sender,
      'senderDeviceId': senderDeviceId,
      'message': 'Decryption failed',
      'timestamp': messageTimestamp,
      'status': 'decrypt_failed',
      'isOwnMessage': isOwnMessage,
      'conversationWith': conversationWith,
    };

    EventBus.instance.emit(AppEvent.newMessage, decryptFailedItem);

    EventBus.instance.emit(AppEvent.newConversation, {
      'conversationId': conversationWith,
      'isChannel': false,
      'isOwnMessage': isOwnMessage,
    });

    // Trigger receiveItem callbacks
    final callbackType = messageType ?? 'message';
    final key = '$callbackType:$conversationWith';
    if (_receiveItemCallbacks.containsKey(key)) {
      debugPrint(
        '[SIGNAL SERVICE] Triggering ${_receiveItemCallbacks[key]!.length} receiveItem callbacks for decrypt_failed message ($key)',
      );
      for (final callback in _receiveItemCallbacks[key]!) {
        try {
          callback(decryptFailedItem);
        } catch (callbackError) {
          debugPrint(
            '[SIGNAL SERVICE] ⚠️ Callback error for decrypt_failed: $callbackError',
          );
        }
      }
    }
  }

  /// Empfängt eine verschlüsselte Nachricht vom Socket.IO Server
  ///
  /// Das Backend filtert bereits und sendet nur Nachrichten, die für DIESES Gerät
  /// (deviceId) verschlüsselt wurden. Die Nachricht wird dann mit dem Session-Schlüssel
  /// dieses Geräts entschlüsselt.
  Future<void> receiveItem(dynamic data) async {
    // Get current deviceId and database info
    final currentDeviceId = DeviceIdentityService.instance.deviceId;
    final dbName = DatabaseHelper.getDatabaseName();

    debugPrint(
      "[SIGNAL SERVICE] ===============================================",
    );
    debugPrint("[SIGNAL SERVICE] receiveItem called for this device");
    debugPrint("[SIGNAL SERVICE] 🔑 Current DeviceId: $currentDeviceId");
    debugPrint("[SIGNAL SERVICE] 💾 Database: $dbName");
    debugPrint(
      "[SIGNAL SERVICE] ===============================================",
    );
    debugPrint("[SIGNAL SERVICE] receiveItem: $data");

    // Cast to Map<String, dynamic> - handle both socket events and direct calls
    final dataMap = data is Map<String, dynamic>
        ? data
        : Map<String, dynamic>.from(data as Map);

    final type = dataMap['type'];
    final sender = dataMap['sender']; // z.B. Absender-UUID
    final senderDeviceId = dataMap['senderDeviceId'];
    final cipherType = dataMap['cipherType'];
    final itemId = dataMap['itemId'];

    // 🔒 Check if this message is already being processed
    if (_processingMessages.contains(itemId)) {
      debugPrint(
        "[SIGNAL SERVICE] ⚠️ Message $itemId is already being processed, skipping duplicate",
      );
      return;
    }

    // Mark message as being processed
    _processingMessages.add(itemId);

    // 🔒 CRITICAL: Ensure messages from same sender are processed sequentially
    // Signal Protocol requires in-order message processing for session state
    final senderKey = '$sender:$senderDeviceId';

    // Wait for previous message from this sender to complete
    if (_senderProcessingLocks.containsKey(senderKey)) {
      debugPrint(
        "[SIGNAL SERVICE] ⏳ Waiting for previous message from $senderKey to complete",
      );
      try {
        await _senderProcessingLocks[senderKey];
      } catch (e) {
        // Previous message failed, but we should still process this one
        debugPrint(
          "[SIGNAL SERVICE] ⚠️ Previous message from $senderKey failed: $e",
        );
      }
    }

    // Create a completer to track this message's processing
    final completer = Completer<void>();
    _senderProcessingLocks[senderKey] = completer.future;

    try {
      await _receiveItemLocked(
        dataMap,
        type,
        sender,
        senderDeviceId,
        cipherType,
        itemId,
      );
      completer.complete();
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      // Remove from processing set when done
      _processingMessages.remove(itemId);
      // Clean up sender lock if we're the current one
      if (_senderProcessingLocks[senderKey] == completer.future) {
        _senderProcessingLocks.remove(senderKey);
      }
    }
  }

  Future<void> _receiveItemLocked(
    Map<String, dynamic> dataMap,
    dynamic type,
    dynamic sender,
    dynamic senderDeviceId,
    dynamic cipherType,
    String itemId,
  ) async {
    await incomingMessageProcessor.processMessage(
      dataMap: dataMap,
      type: type,
      sender: sender,
      senderDeviceId: senderDeviceId,
      cipherType: cipherType,
      itemId: itemId,
    );
  }

  void deleteItemFromServer(String itemId) {
    debugPrint("[SIGNAL SERVICE] Deleting item with itemId: $itemId");
    SocketService().emit("deleteItem", <String, dynamic>{'itemId': itemId});
  }

  void deleteItem(String itemId) async {
    debugPrint("[SIGNAL SERVICE] Deleting item locally with itemId: $itemId");

    // Delete from SQLite
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.deleteMessage(itemId);
    } catch (e) {
      debugPrint("[SIGNAL SERVICE] ⚠️ Failed to delete from SQLite: $e");
    }
  }

  void deleteGroupItemFromServer(String itemId) async {
    debugPrint("[SIGNAL SERVICE] Deleting group item with itemId: $itemId");
    SocketService().emit("deleteGroupItem", <String, dynamic>{
      'itemId': itemId,
    });
  }

  void deleteGroupItem(String itemId, String channelId) async {
    debugPrint(
      "[SIGNAL SERVICE] Deleting group item locally with itemId: $itemId",
    );
    await decryptedGroupItemsStore.clearItem(itemId, channelId);
    await sentGroupItemsStore.clearChannelItem(itemId, channelId);
  }

  /// Handle delivery receipt from server
  Future<void> _handleDeliveryReceipt(Map<String, dynamic> data) async {
    final itemId = data['itemId'];
    debugPrint(
      '[SIGNAL SERVICE] Delivery receipt received for itemId: $itemId',
    );

    // Update SQLite store
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.markAsDelivered(itemId);
    } catch (e) {
      debugPrint(
        '[SIGNAL SERVICE] ⚠️ Failed to update delivery status in SQLite: $e',
      );
    }

    // Trigger callbacks
    if (_deliveryCallbacks.containsKey('default')) {
      for (final callback in _deliveryCallbacks['default']!) {
        callback(itemId);
      }
    }
  }

  /// Handle read receipt (encrypted Signal message)
  Future<void> _handleReadReceipt(Map<String, dynamic> item) async {
    debugPrint('[SIGNAL_SERVICE] _handleReadReceipt called with item: $item');
    try {
      final receiptData = jsonDecode(item['message']);
      final itemId = receiptData['itemId'];
      final readByDeviceId = receiptData['readByDeviceId'] as int?;
      final readByUserId = item['sender']; // The user who sent the read receipt
      debugPrint(
        '[SIGNAL_SERVICE] Processing read receipt for itemId: $itemId, readByDeviceId: $readByDeviceId, readByUserId: $readByUserId',
      );

      // Update SQLite store
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.markAsRead(itemId);
      } catch (e) {
        debugPrint(
          '[SIGNAL_SERVICE] ⚠️ Failed to update read status in SQLite: $e',
        );
      }

      // Trigger callbacks with itemId, deviceId, and userId
      if (_readCallbacks.containsKey('default')) {
        debugPrint(
          '[SIGNAL_SERVICE] Triggering ${_readCallbacks['default']!.length} read receipt callbacks',
        );
        for (final callback in _readCallbacks['default']!) {
          // Pass all three parameters: itemId, readByDeviceId, readByUserId
          callback({
            'itemId': itemId,
            'readByDeviceId': readByDeviceId,
            'readByUserId': readByUserId,
          });
        }
        debugPrint('[SIGNAL_SERVICE] ✓ All read receipt callbacks executed');
      } else {
        debugPrint('[SIGNAL_SERVICE] ⚠ No read receipt callbacks registered');
      }
    } catch (e, stack) {
      debugPrint('[SIGNAL_SERVICE] ❌ Error handling read receipt: $e');
      debugPrint('[SIGNAL_SERVICE] Stack trace: $stack');
    }
  }

  /// 🔄 Handle session recovery request - resend last message to recipient
  /// This is called when the recipient detects a corrupted or missing session
  // Note: _handleSessionRecoveryRequested removed - Signal Protocol's double-ratchet handles session recovery
  // When receiver detects corrupted session, they fetch sender's PreKeyBundle and establish new session

  Future<List<Map<String, dynamic>>> fetchPreKeyBundleForUser(
    String userId,
  ) async {
    // Use retry mechanism for network-related failures
    return await retryWithBackoff(
      operation: () => _fetchPreKeyBundleForUserInternal(userId),
      maxAttempts: 3,
      initialDelay: 1000,
      shouldRetry: isRetryableError,
    );
  }

  Future<List<Map<String, dynamic>>> _fetchPreKeyBundleForUserInternal(
    String userId,
  ) async {
    final response = await ApiService.get('/signal/prekey_bundle/$userId');
    if (response.statusCode == 200) {
      try {
        final devices = response.data is String
            ? jsonDecode(response.data)
            : response.data;
        final List<Map<String, dynamic>> result = [];
        int skippedDevices = 0;

        for (final data in devices) {
          final hasAllFields =
              data['public_key'] != null &&
              data['registration_id'] != null &&
              data['preKey'] != null &&
              data['signedPreKey'] != null &&
              data['preKey']['prekey_data'] != null &&
              data['signedPreKey']['signed_prekey_data'] != null &&
              data['signedPreKey']['signed_prekey_signature'] != null &&
              data['signedPreKey']['signed_prekey_signature']
                  .toString()
                  .isNotEmpty;
          if (!hasAllFields) {
            debugPrint(
              '[SIGNAL SERVICE][MULTI-DEVICE] Device ${data['clientid']} skipped: missing Signal keys (this is OK - will try other devices)',
            );
            skippedDevices++;
            continue;
          }

          // Parse ALL numeric IDs as int (SQLite INTEGER fields returned as String)
          final deviceId = data['device_id'] is int
              ? data['device_id'] as int
              : int.parse(data['device_id'].toString());

          final registrationId = data['registration_id'] is int
              ? data['registration_id'] as int
              : int.parse(data['registration_id'].toString());

          final preKeyId = data['preKey']['prekey_id'] is int
              ? data['preKey']['prekey_id'] as int
              : int.parse(data['preKey']['prekey_id'].toString());

          final signedPreKeyId = data['signedPreKey']['signed_prekey_id'] is int
              ? data['signedPreKey']['signed_prekey_id'] as int
              : int.parse(data['signedPreKey']['signed_prekey_id'].toString());

          final identityKeyBytes = base64Decode(data['public_key']);
          final identityKey = IdentityKey.fromBytes(identityKeyBytes, 0);

          result.add({
            'clientid': data['clientid'],
            'userId': data['userId'],
            'deviceId': deviceId,
            'publicKey': data['public_key'],
            'registrationId': registrationId,
            'preKeyId': preKeyId,
            'preKeyPublic': Curve.decodePoint(
              base64Decode(data['preKey']['prekey_data']),
              0,
            ),
            'signedPreKeyId': signedPreKeyId,
            'signedPreKeyPublic': Curve.decodePoint(
              base64Decode(data['signedPreKey']['signed_prekey_data']),
              0,
            ),
            'signedPreKeySignature': base64Decode(
              data['signedPreKey']['signed_prekey_signature'],
            ),
            'identityKey': identityKey,
          });
        }

        // Multi-Device Logic:
        // - If NO devices have keys → Show error
        // - If SOME devices have keys → Success (skip devices without keys)
        // - Skipped devices will not receive messages, but that's expected behavior
        if (result.isEmpty) {
          if (skippedDevices > 0) {
            debugPrint(
              '[SIGNAL SERVICE][ERROR] ❌ User $userId has $skippedDevices devices but NONE have valid Signal keys!',
            );
            debugPrint(
              '[SIGNAL SERVICE][ERROR] User needs to register Signal keys on at least one device.',
            );
          } else {
            debugPrint(
              '[SIGNAL SERVICE][ERROR] ❌ User $userId has no devices at all.',
            );
          }
        } else {
          if (skippedDevices > 0) {
            debugPrint(
              '[SIGNAL SERVICE][MULTI-DEVICE] ✓ Found ${result.length} devices with keys, $skippedDevices devices without keys',
            );
            debugPrint(
              '[SIGNAL SERVICE][MULTI-DEVICE] Messages will be sent to devices with keys only.',
            );
          } else {
            debugPrint(
              '[SIGNAL SERVICE][MULTI-DEVICE] ✓ All ${result.length} devices have valid keys',
            );
          }
        }

        return result;
      } catch (e, st) {
        debugPrint('[ERROR] Exception while decoding response: $e\n$st');
        rethrow;
      }
    } else {
      debugPrint(
        '[SIGNAL SERVICE] ❌ Failed to load PreKeyBundle - HTTP ${response.statusCode}',
      );
      debugPrint('[SIGNAL SERVICE] Response: ${response.data}');
      throw Exception(
        'Failed to load PreKeyBundle for user (HTTP ${response.statusCode}). '
        'User may not have Signal keys registered or server may be unreachable.',
      );
    }
  }

  /// Notify UI about decryption failure
  /// Sends system message to inform user that message couldn't be decrypted
  void _notifyDecryptionFailure(
    SignalProtocolAddress sender, {
    required String reason,
    String? itemId,
  }) {
    debugPrint(
      '[SIGNAL] \u26a0\ufe0f Notifying UI about decryption failure from ${sender.getName()}:${sender.getDeviceId()}',
    );

    // Emit system message event
    if (_itemTypeCallbacks.containsKey('system')) {
      for (final callback in _itemTypeCallbacks['system']!) {
        callback({
          'type': 'decryptionFailure',
          'sender': sender.getName(),
          'senderDeviceId': sender.getDeviceId(),
          'itemId': itemId,
          'message':
              'Could not decrypt message. Requesting sender to resend...',
          'reason': reason,
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
      debugPrint('[SIGNAL] ✓ Decryption failure notification sent to UI');
    }
  }

  /// Check if recipient has available PreKeys
  /// Returns true if at least one valid device with PreKeys exists
  /// On API error: returns null to allow caller to decide (don't assume success)
  Future<bool?> hasPreKeysForRecipient(String recipientUserId) async {
    try {
      final bundles = await fetchPreKeyBundleForUser(recipientUserId);
      // Filter for recipient's devices only (not our own devices)
      final recipientDevices = bundles
          .where((bundle) => bundle['userId'] == recipientUserId)
          .toList();
      return recipientDevices.isNotEmpty;
    } catch (e) {
      debugPrint(
        '[SIGNAL SERVICE][ERROR] Failed to check PreKeys for $recipientUserId: $e',
      );
      // Return null to indicate check failed (not true/false)
      return null;
    }
  }

  /// Send encrypted file metadata to 1:1 chat (file transferred P2P via WebRTC)
  Future<void> sendFileItem({
    required String recipientUserId,
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required String encryptedFileKey,
    String? message,
    String? itemId,
  }) async {
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final messageItemId = itemId ?? const Uuid().v4();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Create file message payload
      final fileMessagePayload = {
        'fileId': fileId,
        'fileName': fileName,
        'mimeType': mimeType,
        'fileSize': fileSize,
        'checksum': checksum,
        'chunkCount': chunkCount,
        'encryptedFileKey': encryptedFileKey,
        'uploaderId': _currentUserId,
        'timestamp': timestamp,
        if (message != null && message.isNotEmpty) 'message': message,
      };

      final payloadJson = jsonEncode(fileMessagePayload);

      // Send as Signal Item with type='file'
      // This will encrypt for all devices of both sender and recipient
      await sendItem(
        recipientUserId: recipientUserId,
        type: 'file',
        payload: payloadJson,
        itemId: messageItemId,
      );

      debugPrint(
        '[SIGNAL_SERVICE] Sent file item $messageItemId ($fileName) to $recipientUserId',
      );
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending file item: $e');
      rethrow;
    }
  }

  /// Send a file message to a group chat
  ///
  /// Encrypts file metadata with Sender Key and sends as GroupItem with type='file'.
  /// The file itself is transferred P2P via WebRTC DataChannels.
  Future<void> sendFileGroupItem({
    required String channelId,
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required String encryptedFileKey,
    String? message,
    String? itemId,
  }) async {
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final messageItemId = itemId ?? const Uuid().v4();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Create file message payload
      final fileMessagePayload = {
        'fileId': fileId,
        'fileName': fileName,
        'mimeType': mimeType,
        'fileSize': fileSize,
        'checksum': checksum,
        'chunkCount': chunkCount,
        'encryptedFileKey': encryptedFileKey,
        'uploaderId': _currentUserId,
        'timestamp': timestamp,
        if (message != null && message.isNotEmpty) 'message': message,
      };

      final payloadJson = jsonEncode(fileMessagePayload);

      // Send as GroupItem with type='file'
      await sendGroupItem(
        channelId: channelId,
        message: payloadJson, // sendGroupItem expects 'message' parameter
        type: 'file',
        itemId: messageItemId,
      );

      debugPrint(
        '[SIGNAL_SERVICE] Sent file group item $messageItemId ($fileName) to channel $channelId',
      );

      // Trigger callback to notify UI that file was sent
      if (_itemTypeCallbacks['fileSent'] != null) {
        for (final callback in _itemTypeCallbacks['fileSent']!) {
          callback({
            'channelId': channelId,
            'itemId': messageItemId,
            'fileName': fileName,
          });
        }
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending file group item: $e');
      rethrow;
    }
  }

  /// Send encrypted message to user (encrypts for all devices of recipient and sender)
  Future<void> sendItem({
    required String recipientUserId,
    required String type,
    required dynamic payload,
    String? itemId,
    Map<String, dynamic>? metadata,
    bool forcePreKeyMessage = false,
  }) async {
    // Delegate to MessageSender service
    return await messageSender.sendItem(
      recipientUserId: recipientUserId,
      type: type,
      payload: payload,
      itemId: itemId,
      metadata: metadata,
      forcePreKeyMessage: forcePreKeyMessage,
    );
  }

  Future<String> decryptItem({
    required SignalProtocolAddress senderAddress,
    required String payload,
    required int cipherType,
    String? itemId,
  }) async {
    // Delegate to MessageReceiver service
    return await messageReceiver.decryptItem(
      senderAddress: senderAddress,
      payload: payload,
      cipherType: cipherType,
      itemId: itemId,
    );
  }

  // ============================================================================
  // GROUP ENCRYPTION WITH SENDER KEYS
  // ============================================================================

  /// Create and distribute sender key for a group (broadcast returned message to all members)
  Future<Uint8List> createGroupSenderKey(
    String groupId, {
    bool broadcastDistribution = true,
  }) async {
    return await groupMessageSender.createGroupSenderKey(
      groupId,
      broadcastDistribution: broadcastDistribution,
    );
  }

  /// Process incoming sender key distribution message from another group member
  Future<void> processSenderKeyDistribution(
    String groupId,
    String senderId,
    int senderDeviceId,
    Uint8List distributionMessageBytes,
  ) async {
    return await groupMessageReceiver.processSenderKeyDistribution(
      groupId,
      senderId,
      senderDeviceId,
      distributionMessageBytes,
    );
  }

  /// Distribute meeting sender key to external guest
  ///
  /// Establishes Signal session with guest and sends encrypted sender key
  /// so they can decrypt group messages (receive-only, cannot create keys)
  Future<void> distributeKeyToExternalGuest({
    required String guestSessionId,
    required String meetingId,
  }) async {
    await guestSessionManager.distributeKeyToExternalGuest(
      guestSessionId: guestSessionId,
      meetingId: meetingId,
    );
  }

  /// Encrypt message for group using sender key
  Future<Map<String, dynamic>> encryptGroupMessage(
    String groupId,
    String message,
  ) async {
    return await groupMessageSender.encryptGroupMessage(groupId, message);
  }

  /// Decrypt group message using sender key
  /// [serverUrl] - Optional server URL for multi-server support
  Future<String> decryptGroupMessage(
    String groupId,
    String senderId,
    int senderDeviceId,
    String ciphertextBase64, {
    String? serverUrl,
  }) async {
    return await groupMessageReceiver.decryptGroupMessage(
      groupId,
      senderId,
      senderDeviceId,
      ciphertextBase64,
      serverUrl: serverUrl,
    );
  }

  /// Request sender key from a group member
  Future<void> requestSenderKey(
    String groupId,
    String userId,
    int deviceId,
  ) async {
    try {
      await ApiService.post(
        '/channels/$groupId/request-sender-key',
        data: {
          'requesterId': _currentUserId,
          'requesterDeviceId': _currentDeviceId,
          'targetUserId': userId,
          'targetDeviceId': deviceId,
        },
      );

      debugPrint(
        '[SIGNAL_SERVICE] Requested sender key from $userId:$deviceId for group $groupId',
      );
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error requesting sender key: $e');
      rethrow;
    }
  }

  /// Check if we have sender key for a specific sender in a group
  Future<bool> hasSenderKey(
    String groupId,
    String senderId,
    int senderDeviceId,
  ) async {
    return await groupMessageReceiver.hasSenderKey(
      groupId: groupId,
      userId: senderId,
      deviceId: senderDeviceId,
    );
  }

  /// Clear all sender keys for a group (e.g., when leaving)
  Future<void> clearGroupSenderKeys(String groupId) async {
    return await groupMessageReceiver.clearGroupSenderKeys(groupId);
  }

  // ===== NEW: GROUP ITEM API METHODS =====

  /// Send a group item (message, reaction, file, etc.) using new GroupItem architecture
  /// Send a file message to a group chat (LÖSUNG 17)
  ///
  /// Encrypts file metadata (fileId, fileName, encryptedFileKey) with SenderKey
  /// and sends as a GroupItem with type='file'.
  ///
  /// The file itself is transferred P2P via WebRTC DataChannels.
  /// This message only contains the metadata needed to initiate download.
  Future<void> sendFileMessage({
    required String channelId,
    required String fileId,
    required String fileName,
    required String mimeType,
    required int fileSize,
    required String checksum,
    required int chunkCount,
    required String encryptedFileKey,
    String? message,
  }) async {
    await fileMessageService.sendFileMessage(
      channelId: channelId,
      fileId: fileId,
      fileName: fileName,
      mimeType: mimeType,
      fileSize: fileSize,
      checksum: checksum,
      chunkCount: chunkCount,
      encryptedFileKey: encryptedFileKey,
      message: message,
    );
  }

  /// Send P2P file share update via Signal Protocol (uses Sender Key for groups, Session for direct)
  Future<void> sendFileShareUpdate({
    required String chatId,
    required String chatType, // 'group' | 'direct'
    required String fileId,
    required String action, // 'add' | 'revoke'
    required List<String> affectedUserIds,
    String? checksum, // ← NEW: Canonical checksum for verification
    String? encryptedFileKey, // Only for 'add' action
  }) async {
    await fileMessageService.sendFileShareUpdate(
      chatId: chatId,
      chatType: chatType,
      fileId: fileId,
      action: action,
      affectedUserIds: affectedUserIds,
      checksum: checksum,
      encryptedFileKey: encryptedFileKey,
    );
  }

  /// Send video E2EE key via Signal Protocol (Sender Key for groups, Session for direct)
  Future<void> sendVideoKey({
    required String channelId,
    required String chatType, // 'group' | 'direct'
    required List<int> encryptedKey, // AES-256 key (32 bytes)
    required List<String> recipientUserIds, // Users in the video call
  }) async {
    await fileMessageService.sendVideoKey(
      channelId: channelId,
      chatType: chatType,
      encryptedKey: encryptedKey,
      recipientUserIds: recipientUserIds,
    );
  }

  Future<void> sendGroupItem({
    required String channelId,
    required String message,
    required String itemId,
    String type = 'message',
    Map<String, dynamic>?
    metadata, // Optional metadata (for image/voice messages)
  }) async {
    return await groupMessageSender.sendGroupItem(
      channelId: channelId,
      message: message,
      itemId: itemId,
      type: type,
      metadata: metadata,
    );
  }

  /// Decrypt a received group item with automatic sender key reload on error
  /// [serverUrl] - Optional server URL for multi-server support (extracts from socket event)
  Future<String> decryptGroupItem({
    required String channelId,
    required String senderId,
    required int senderDeviceId,
    required String ciphertext,
    bool retryOnError = true,
    String? serverUrl,
  }) async {
    return await groupMessageReceiver.decryptGroupItem(
      channelId: channelId,
      senderId: senderId,
      senderDeviceId: senderDeviceId,
      ciphertext: ciphertext,
      retryOnError: retryOnError,
      serverUrl: serverUrl,
    );
  }

  /// Load sender key from server database
  Future<bool> loadSenderKeyFromServer({
    required String channelId,
    required String userId,
    required int deviceId,
    bool forceReload = false,
  }) async {
    return await groupMessageReceiver.loadSenderKeyFromServer(
      channelId: channelId,
      userId: userId,
      deviceId: deviceId,
      forceReload: forceReload,
    );
  }

  /// Load all sender keys for a channel (when joining)
  Future<Map<String, dynamic>> loadAllSenderKeysForChannel(
    String channelId,
  ) async {
    return await groupMessageReceiver.loadAllSenderKeysForChannel(channelId);
  }

  /// Upload our sender key to server
  Future<void> uploadSenderKeyToServer(String channelId) async {
    return await groupMessageSender.uploadSenderKeyToServer(channelId);
  }

  /// Mark a group item as read
  Future<void> markGroupItemAsRead(String itemId) async {
    try {
      if (_currentDeviceId == null) {
        debugPrint('[SIGNAL_SERVICE] Cannot mark as read: device ID not set');
        return;
      }

      SocketService().emit("markGroupItemRead", <String, dynamic>{
        'itemId': itemId,
      });

      debugPrint('[SIGNAL_SERVICE] Marked group item $itemId as read');
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error marking item as read: $e');
    }
  }

  /// Load sent group items for a channel
  Future<List<Map<String, dynamic>>> loadSentGroupItems(
    String channelId,
  ) async {
    return await sentGroupItemsStore.loadSentItems(channelId);
  }

  /// Load received/decrypted group items for a channel
  Future<List<Map<String, dynamic>>> loadReceivedGroupItems(
    String channelId,
  ) async {
    return await decryptedGroupItemsStore.getChannelItems(channelId);
  }

  // ===== EMOJI REACTIONS =====

  /// Handle incoming emote message (emoji reaction)
  /// Accepts either raw socket data (requires decryption) or already-decrypted item data
  Future<void> _handleEmoteMessage(
    Map<String, dynamic> rawData, {
    required bool isGroupChat,
  }) async {
    try {
      String decryptedJson;

      // Check if data is already decrypted (has 'message' field)
      if (rawData.containsKey('message') && rawData['message'] is String) {
        // Already decrypted (from receiveItem or local processing)
        decryptedJson = rawData['message'] as String;
      } else {
        // Raw encrypted data - needs decryption
        if (isGroupChat) {
          // Group chat: decrypt with sender key
          final channelId = rawData['channel'] as String?;
          final senderId = rawData['sender'] as String?;
          final senderDeviceId = rawData['senderDevice'] is int
              ? rawData['senderDevice'] as int
              : int.parse(rawData['senderDevice'].toString());
          final payload = rawData['payload'] as String?;

          if (channelId == null || senderId == null || payload == null) {
            debugPrint(
              '[SIGNAL SERVICE] ✗ Missing required fields for group emote message',
            );
            return;
          }

          decryptedJson = await decryptGroupItem(
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            ciphertext: payload,
          );
        } else {
          // DM: decrypt with session cipher
          final senderId = rawData['sender'] as String?;
          final senderDeviceId = rawData['senderDeviceId'] is int
              ? rawData['senderDeviceId'] as int
              : int.parse(rawData['senderDeviceId'].toString());
          final payload = rawData['payload'];
          final cipherType = rawData['cipherType'];

          if (senderId == null || payload == null) {
            debugPrint(
              '[SIGNAL SERVICE] ✗ Missing required fields for DM emote message',
            );
            return;
          }

          final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
          decryptedJson = await decryptItem(
            senderAddress: senderAddress,
            payload: payload,
            cipherType: cipherType,
            itemId: null, // Emotes don't have itemIds
          );
        }
      }

      // Parse the decrypted JSON
      final emoteData = jsonDecode(decryptedJson) as Map<String, dynamic>;
      final messageId = emoteData['messageId'] as String?;
      final emoji = emoteData['emoji'] as String?;
      final action = emoteData['action'] as String?;
      final sender = emoteData['sender'] as String?;

      if (messageId == null ||
          emoji == null ||
          action == null ||
          sender == null) {
        debugPrint(
          '[SIGNAL SERVICE] ✗ Invalid emote message data after decryption',
        );
        return;
      }

      debugPrint(
        '[SIGNAL SERVICE] Processing emote: $emoji $action by $sender on message $messageId',
      );

      // Check if this is our own reaction
      final isOwnReaction = sender == _currentUserId;

      // Get appropriate message store
      if (isGroupChat) {
        final groupMessageStore = await SqliteGroupMessageStore.getInstance();
        if (action == 'add') {
          await groupMessageStore.addReaction(messageId, emoji, sender);
        } else if (action == 'remove') {
          await groupMessageStore.removeReaction(messageId, emoji, sender);
        }
        final reactions = await groupMessageStore.getReactions(messageId);

        // Always emit reaction updated event for UI refresh (both own and others)
        // The UI needs to update immediately for all reactions
        EventBus.instance.emit(AppEvent.reactionUpdated, {
          'messageId': messageId,
          'reactions': reactions,
          'channelId': emoteData['channelId'] ?? rawData['channel'],
          'isOwnReaction': isOwnReaction,
        });
      } else {
        final dmMessageStore = await SqliteMessageStore.getInstance();
        if (action == 'add') {
          await dmMessageStore.addReaction(messageId, emoji, sender);
        } else if (action == 'remove') {
          await dmMessageStore.removeReaction(messageId, emoji, sender);
        }
        final reactions = await dmMessageStore.getReactions(messageId);

        // Always emit reaction updated event for UI refresh (both own and others)
        EventBus.instance.emit(AppEvent.reactionUpdated, {
          'messageId': messageId,
          'reactions': reactions,
          'sender': rawData['sender'],
          'isOwnReaction': isOwnReaction,
        });
      }

      debugPrint('[SIGNAL SERVICE] ✓ Updated reactions for message $messageId');
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ✗ Error handling emote message: $e');
    }
  }

  // ===== HELPER METHODS =====

  /// Find contiguous ranges in a list of IDs for batch generation optimization
  ///
  /// Asynchronously regenerate a single PreKey after consumption
  /// This runs in the background and doesn't block message processing
  Future<void> _regeneratePreKeyAsync(int preKeyId) async {
    try {
      debugPrint('[SIGNAL SERVICE] Async regenerating PreKey $preKeyId...');

      final preKeys = generatePreKeys(preKeyId, preKeyId);
      if (preKeys.isNotEmpty) {
        await preKeyStore.storePreKey(preKeyId, preKeys.first);
        debugPrint('[SIGNAL SERVICE] ✓ PreKey $preKeyId regenerated locally');

        // Upload regenerated PreKey to server (fire-and-forget)
        // Server-side checks and PreKey count monitoring (< 20) will handle any failures
        final preKeyPublic = base64Encode(
          preKeys.first.getKeyPair().publicKey.serialize(),
        );
        SocketService().emit("storePreKey", {
          'preKeyId': preKeyId,
          'preKeyPublic': preKeyPublic,
        });
        debugPrint('[SIGNAL SERVICE] ✓ PreKey $preKeyId upload initiated');
      }
    } catch (e) {
      debugPrint(
        '[SIGNAL SERVICE] ✗ Failed to regenerate PreKey $preKeyId: $e',
      );
      // Don't rethrow - this is background work
    }
  }

  // ===== IDENTITY KEY CHANGE HANDLING =====

  /// Track addresses currently being handled to prevent infinite loops
  final Set<String> _handlingIdentityFor = {};

  /// Handle UntrustedIdentityException: auto-trust new key, optional notification
  /// sendNotification: true in receive path, false in send path (prevents loop)
  Future<T> handleUntrustedIdentity<T>(
    UntrustedIdentityException exception,
    SignalProtocolAddress address,
    Future<T> Function() retryOperation, {
    bool sendNotification = false,
  }) async {
    final addressKey = '${address.getName()}:${address.getDeviceId()}';

    // Prevent infinite loop - if already handling this address, fail
    if (_handlingIdentityFor.contains(addressKey)) {
      debugPrint('[SIGNAL] ⚠️ LOOP DETECTED for $addressKey');
      debugPrint('[SIGNAL] This usually means the stored identity is corrupt');
      debugPrint('[SIGNAL] Please clear app data or re-register device');

      // Remove from tracking and fail
      _handlingIdentityFor.remove(addressKey);
      throw Exception(
        'Identity key loop detected for $addressKey. '
        'The stored identity for this user may be corrupt. '
        'Please clear app storage and re-register, or have them re-register their device.',
      );
    }

    try {
      _handlingIdentityFor.add(addressKey);

      debugPrint('[SIGNAL] ⚠️ Identity key changed for $addressKey');
      debugPrint('[SIGNAL] Fetching and trusting new identity key from server');

      // 1. Fetch fresh PreKeyBundle with current identity key from server
      final userId = address.getName();
      final deviceId = address.getDeviceId();
      final bundles = await fetchPreKeyBundleForUser(userId);
      final targetBundle = bundles.firstWhere(
        (b) => b['userId'] == userId && b['deviceId'] == deviceId,
        orElse: () => throw Exception('No bundle found for $addressKey'),
      );

      // 2. Extract and save the new identity key (this is the critical step!)
      final newIdentityKey = targetBundle['identityKey'] as IdentityKey;
      final savedSuccessfully = await identityStore.saveIdentity(
        address,
        newIdentityKey,
      );

      if (savedSuccessfully) {
        debugPrint(
          '[SIGNAL] ✓ Saved and trusted new identity key for $addressKey',
        );
      } else {
        debugPrint('[SIGNAL] ⚠️ Identity key unchanged (already trusted)');
      }

      // 3. Delete the old session so it rebuilds with new identity
      await sessionStore.deleteSession(address);
      debugPrint('[SIGNAL] ✓ Deleted old session for $addressKey');

      // 4. Retry the original operation
      // The retry will rebuild session with the now-trusted new identity
      debugPrint('[SIGNAL] Retrying original operation...');
      final result = await retryOperation();

      debugPrint(
        '[SIGNAL] ✓ Identity key issue resolved and operation completed',
      );

      // 5. Send notification AFTER successful resolution (if requested and safe)
      if (sendNotification && savedSuccessfully) {
        debugPrint(
          '[SIGNAL] Sending identity change notification to $userId...',
        );
        try {
          // Store new_identity system message for user visibility
          final messageStore = await SqliteMessageStore.getInstance();
          final messageTimestamp = DateTime.now().toIso8601String();
          final newIdentityItemId = '${Uuid().v4()}_new_identity';

          await messageStore.storeReceivedMessage(
            itemId: newIdentityItemId,
            sender: userId,
            senderDeviceId: deviceId,
            message:
                'Security update detected. This conversation is now secured again.',
            timestamp: messageTimestamp,
            type: 'system',
            status: 'new_identity',
          );
          debugPrint('[SIGNAL] ✓ Stored new_identity system message');

          // Create system message payload for legacy support
          final notificationPayload = jsonEncode({
            'type': 'identityKeyChanged',
            'changedUserId': userId,
            'changedDeviceId': deviceId,
            'detectedByUserId': _currentUserId,
            'detectedByDeviceId': _currentDeviceId,
            'timestamp': DateTime.now().toIso8601String(),
            'message':
                'Security code changed. This could mean that someone is trying to intercept your communication, or that $userId simply reinstalled the app.',
          });

          // Send system message to the user whose identity changed
          // This will be visible in the chat for both users
          await sendItem(
            recipientUserId: userId,
            type: 'system:identityKeyChanged',
            payload: notificationPayload,
          );

          debugPrint('[SIGNAL] ✓ Identity change notification sent to $userId');
        } catch (notificationError) {
          // Don't fail the operation if notification fails
          debugPrint(
            '[SIGNAL] ⚠️ Failed to send identity change notification: $notificationError',
          );
        }
      } else if (sendNotification && !savedSuccessfully) {
        debugPrint(
          '[SIGNAL] ⚠️ Skipping notification - identity key unchanged',
        );
      }

      return result;
    } catch (e) {
      debugPrint('[SIGNAL] ✗ Error handling untrusted identity: $e');
      rethrow;
    } finally {
      _handlingIdentityFor.remove(addressKey);
    }
  }

  // ===== GUEST E2EE SUPPORT =====

  /// Send encrypted item to guest participant via Socket.IO
  Future<void> sendItemToGuest({
    required String meetingId,
    required String guestSessionId,
    required String type,
    required dynamic payload,
  }) async {
    try {
      debugPrint(
        '[SIGNAL SERVICE] Sending Signal item to guest: $guestSessionId',
      );

      // Get or create Signal session with guest
      final session = await _getOrCreateGuestSession(
        meetingId: meetingId,
        guestSessionId: guestSessionId,
      );

      // Prepare payload for encryption
      String payloadString;
      if (payload is String) {
        payloadString = payload;
      } else {
        payloadString = jsonEncode(payload);
      }

      // Encrypt using Signal Protocol
      final ciphertext = await _encryptForGuest(
        session: session,
        plaintext: payloadString,
      );

      if (kDebugMode) {
        debugPrint(
          '[SIGNAL SERVICE] 🔒 Encrypted ${payloadString.length} bytes for guest',
        );
      }

      // Emit via Socket.IO to guest
      final messageData = {
        'guest_session_id': guestSessionId, // Server expects snake_case
        'meeting_id': meetingId, // Server expects snake_case
        'type': type,
        'ciphertext': ciphertext['ciphertext'],
        'messageType': ciphertext['type'], // 3 = PreKey, 1 = Signal
        'timestamp': DateTime.now().toIso8601String(),
      };

      SocketService().emit(
        'participant:meeting_e2ee_key_response',
        messageData,
      );
      debugPrint('[SIGNAL SERVICE] ✓ Sent encrypted item to guest via Signal');
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ✗ Error sending item to guest: $e');
      rethrow;
    }
  }

  /// Receive encrypted Signal item from authenticated participant (participant → guest)
  /// Decrypts using guest's sessionStorage-based Signal session
  /// Called from external_guest_socket_service.dart listener
  Future<Map<String, dynamic>> receiveItemFromParticipant({
    required String meetingId,
    required String participantUserId,
    required int participantDeviceId,
    required String ciphertextBase64,
    required int messageType,
    required String type,
  }) async {
    try {
      debugPrint(
        '[SIGNAL SERVICE] Receiving Signal item from participant: $participantUserId:$participantDeviceId',
      );

      // Get or create Signal session with participant
      final session = await _getOrCreateParticipantSession(
        meetingId: meetingId,
        participantUserId: participantUserId,
        participantDeviceId: participantDeviceId,
      );

      // Decrypt using Signal Protocol
      final plaintext = await _decryptFromParticipant(
        session: session,
        ciphertextBase64: ciphertextBase64,
        messageType: messageType,
      );

      if (kDebugMode) {
        debugPrint(
          '[SIGNAL SERVICE] 🔓 Decrypted ${plaintext.length} bytes from participant',
        );
      }

      // Parse and return decrypted data
      final decryptedData = jsonDecode(plaintext);
      return {
        'type': type,
        'payload': decryptedData,
        'sender': participantUserId,
        'senderDeviceId': participantDeviceId,
      };
    } catch (e) {
      debugPrint(
        '[SIGNAL SERVICE] ✗ Error receiving item from participant: $e',
      );
      rethrow;
    }
  }

  /// Get or create Signal session with guest (for participant → guest encryption)
  /// Fetches guest's keybundle from server and establishes session
  Future<SignalProtocolAddress> _getOrCreateGuestSession({
    required String meetingId,
    required String guestSessionId,
  }) async {
    return await guestSessionManager.getOrCreateGuestSession(
      meetingId: meetingId,
      guestSessionId: guestSessionId,
    );
  }

  /// Get or create Signal session with participant (for guest → participant encryption)
  /// Fetches participant's keybundle from server and establishes session
  Future<SignalProtocolAddress> _getOrCreateParticipantSession({
    required String meetingId,
    required String participantUserId,
    required int participantDeviceId,
  }) async {
    return await guestSessionManager.getOrCreateParticipantSession(
      meetingId: meetingId,
      participantUserId: participantUserId,
      participantDeviceId: participantDeviceId,
    );
  }

  /// Encrypt message for guest using Signal Protocol
  Future<Map<String, dynamic>> _encryptForGuest({
    required SignalProtocolAddress session,
    required String plaintext,
  }) async {
    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      session,
    );

    final ciphertext = await sessionCipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    return {
      'ciphertext': base64Encode(ciphertext.serialize()),
      'type': ciphertext
          .getType(), // 3 = PreKeySignalMessage, 1 = SignalMessage
    };
  }

  /// Decrypt message from participant using Signal Protocol
  Future<String> _decryptFromParticipant({
    required SignalProtocolAddress session,
    required String ciphertextBase64,
    required int messageType,
  }) async {
    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      session,
    );

    final ciphertextBytes = base64Decode(ciphertextBase64);
    Uint8List plaintext;

    if (messageType == 3) {
      // PreKeySignalMessage
      final preKeyMessage = PreKeySignalMessage(ciphertextBytes);
      plaintext = await sessionCipher.decrypt(preKeyMessage);
    } else {
      // SignalMessage
      final signalMessage = SignalMessage.fromSerialized(ciphertextBytes);
      plaintext = await sessionCipher.decryptFromSignal(signalMessage);
    }

    return utf8.decode(plaintext);
  }

  /// Clear guest Signal sessions when meeting ends (security cleanup)
  Future<void> clearGuestSessions(String meetingId) async {
    try {
      // Delete all sessions with addresses starting with "guest_"
      final allSessions = await sessionStore.getSubDeviceSessions('guest_');
      for (final deviceId in allSessions) {
        final address = SignalProtocolAddress('guest_', deviceId);
        await sessionStore.deleteSession(address);
      }
      debugPrint(
        '[SIGNAL SERVICE] ✓ Cleared all guest sessions for meeting: $meetingId',
      );
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ✗ Error clearing guest sessions: $e');
    }
  }
}
