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
import 'storage/sqlite_recent_conversations_store.dart';
import 'storage/database_helper.dart';
import 'user_profile_service.dart';
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

  /// 🔒 Loop prevention: Track ongoing healing operations
  final bool _keyReinforcementInProgress = false;
  DateTime? _lastKeyReinforcementTime;

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

  // Meeting E2EE key exchange callbacks (via 1-to-1 Signal messages)
  // Keyed by meeting ID to allow multiple meetings
  final Map<String, Function(Map<String, dynamic>)>
  _meetingE2EEKeyRequestCallbacks = {};
  final Map<String, Function(Map<String, dynamic>)>
  _meetingE2EEKeyResponseCallbacks = {};

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

  /// Helper: Get local identity public key for validation
  Future<String?> _getLocalIdentityPublicKey() async {
    try {
      final identity = await identityStore.getIdentityKeyPairData();
      return identity['publicKey'];
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] Failed to get local identity key: $e');
      return null;
    }
  }

  /// Helper: Get latest SignedPreKey ID for validation
  Future<int?> _getLatestSignedPreKeyId() async {
    try {
      final keys = await signedPreKeyStore.loadSignedPreKeys();
      return keys.isNotEmpty ? keys.last.id : null;
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] Failed to get latest SignedPreKey ID: $e');
      return null;
    }
  }

  /// Helper: Get local PreKey count for validation
  Future<int> _getLocalPreKeyCount() async {
    try {
      final ids = await preKeyStore.getAllPreKeyIds();
      return ids.length;
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] Failed to get PreKey count: $e');
      return 0;
    }
  }

  /// Get prekey fingerprints (SHA256 hash of public key) for validation
  /// Returns map of keyId -> hash for all 110 keys (complete validation)
  /// Returns Map<String, String> for JSON encoding compatibility on web
  Future<Map<String, String>> _getPreKeyFingerprints() async {
    try {
      final keyIds = await preKeyStore.getAllPreKeyIds();
      final fingerprints = <String, String>{};

      // Send all 110 keys for validation (complete verification)
      for (final id in keyIds) {
        try {
          final preKey = await preKeyStore.loadPreKey(id);
          final publicKeyBytes = preKey.getKeyPair().publicKey.serialize();
          final hash = base64Encode(
            publicKeyBytes,
          ); // Use public key itself as fingerprint
          fingerprints[id.toString()] =
              hash; // Convert int key to string for JSON
        } catch (e) {
          debugPrint(
            '[SIGNAL SERVICE] Failed to get fingerprint for prekey $id: $e',
          );
        }
      }

      debugPrint(
        '[SIGNAL SERVICE] Generated ${fingerprints.length} prekey fingerprints for validation',
      );
      return fingerprints;
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] Error generating prekey fingerprints: $e');
      return {};
    }
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
  /// This method processes ALL queued messages globally, not per-screen.
  /// It sends messages to their respective channels/recipients.
  Future<void> _processOfflineQueue() async {
    final queue = OfflineMessageQueue.instance;

    if (!queue.hasMessages) {
      debugPrint('[SIGNAL SERVICE] No messages in offline queue');
      return;
    }

    debugPrint(
      '[SIGNAL SERVICE] Processing ${queue.queueSize} queued messages...',
    );

    await queue.processQueue(
      sendFunction: (queuedMessage) async {
        try {
          if (queuedMessage.type == 'group') {
            // Send group message
            final channelId = queuedMessage.metadata['channelId'] as String;
            debugPrint(
              '[SIGNAL SERVICE] Sending queued group message to channel $channelId',
            );

            await sendGroupItem(
              channelId: channelId,
              message: queuedMessage.text,
              itemId: queuedMessage.itemId,
              type: 'message',
            );
            return true;
          } else if (queuedMessage.type == 'direct') {
            // Send direct message
            final recipientId = queuedMessage.metadata['recipientId'] as String;
            debugPrint(
              '[SIGNAL SERVICE] Sending queued direct message to $recipientId',
            );

            await sendItem(
              recipientUserId: recipientId,
              type: 'message',
              payload: queuedMessage.text,
              itemId: queuedMessage.itemId,
            );
            return true;
          } else {
            debugPrint(
              '[SIGNAL SERVICE] Unknown message type: ${queuedMessage.type}',
            );
            return false;
          }
        } catch (e) {
          debugPrint(
            '[SIGNAL SERVICE] Failed to send queued message ${queuedMessage.itemId}: $e',
          );
          return false;
        }
      },
      onProgress: (processed, total) {
        debugPrint('[SIGNAL SERVICE] Queue progress: $processed/$total');
      },
    );

    debugPrint('[SIGNAL SERVICE] Offline queue processing complete');
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

    // 7. GroupMessageSender depends on EncryptionService
    groupMessageSender = await GroupMessageSender.create(
      encryptionService: encryptionService,
      getCurrentUserId: () => _currentUserId,
      getCurrentDeviceId: () => _currentDeviceId,
      waitForRegenerationIfNeeded: _waitForRegenerationIfNeeded,
    );

    // 8. GroupMessageReceiver depends on EncryptionService
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
      final preKeyFingerprints = await _getPreKeyFingerprints();

      // HTTP request to validate/sync keys (blocking, with response code)
      final response = await ApiService.post(
        '/signal/validate-and-sync',
        data: {
          'localIdentityKey': await _getLocalIdentityPublicKey(),
          'localSignedPreKeyId': await _getLatestSignedPreKeyId(),
          'localPreKeyCount': await _getLocalPreKeyCount(),
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

    final keysValid = await verifyOwnKeysOnServer();
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
          await _uploadKeysOnly();
          await Future.delayed(Duration(milliseconds: 1000));

          // Verify again
          final retryValid = await verifyOwnKeysOnServer();
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

  Future<void> _ensureSignalKeysPresent(dynamic status) async {
    // Use a socket callback to get status
    debugPrint('[SIGNAL SERVICE] signalStatus: $status');

    // Check if user is authenticated
    if (status is Map && status['error'] != null) {
      debugPrint(
        '[SIGNAL SERVICE] ERROR: ${status['error']} - Cannot upload Signal keys without authentication',
      );
      return;
    }

    // Guard: Only run after initialization is complete
    if (!_isInitialized) {
      debugPrint(
        '[SIGNAL SERVICE] ⚠️ Not initialized yet, skipping key sync check',
      );
      return;
    }

    // 1. Identity - Validate that server's public key matches local identity
    final identityData = await identityStore.getIdentityKeyPairData();
    final localPublicKey = identityData['publicKey'] as String;
    final serverPublicKey = (status is Map)
        ? status['identityPublicKey'] as String?
        : null;

    debugPrint('[SIGNAL SERVICE] Local public key: $localPublicKey');
    debugPrint('[SIGNAL SERVICE] Server public key: $serverPublicKey');
    debugPrint(
      '[SIGNAL SERVICE] Server identity present: ${status is Map ? status['identity'] : null}',
    );

    if (serverPublicKey != null && serverPublicKey != localPublicKey) {
      // CRITICAL: Server has different public key than local!
      // This can happen if device was deleted and recreated with same deviceId
      debugPrint(
        '[SIGNAL SERVICE] ⚠️ CRITICAL: Identity key mismatch detected!',
      );
      debugPrint(
        '[SIGNAL SERVICE]   Local public key length:  ${localPublicKey.length}',
      );
      debugPrint(
        '[SIGNAL SERVICE]   Server public key length: ${serverPublicKey.length}',
      );
      debugPrint('[SIGNAL SERVICE]   Local public key:  $localPublicKey');
      debugPrint('[SIGNAL SERVICE]   Server public key: $serverPublicKey');
      debugPrint(
        '[SIGNAL SERVICE]   Keys match: ${localPublicKey == serverPublicKey}',
      );
      debugPrint('[SIGNAL SERVICE] → Server has outdated/wrong identity!');
      debugPrint(
        '[SIGNAL SERVICE] → AUTO-RECOVERY: Re-uploading correct identity from client',
      );

      // 🔧 AUTO-FIX: Client is source of truth - re-upload correct identity
      try {
        debugPrint('[SIGNAL SERVICE] Deleting incorrect server identity...');
        SocketService().emit("deleteAllSignalKeys", {
          'reason':
              'Identity key mismatch - server has wrong key, re-uploading from client',
          'timestamp': DateTime.now().toIso8601String(),
        });

        await Future.delayed(Duration(milliseconds: 500));

        debugPrint(
          '[SIGNAL SERVICE] Uploading correct identity from local storage...',
        );
        final registrationId = await identityStore.getLocalRegistrationId();
        SocketService().emit("signalIdentity", {
          'publicKey': localPublicKey,
          'registrationId': registrationId.toString(),
        });

        await Future.delayed(Duration(milliseconds: 500));

        debugPrint('[SIGNAL SERVICE] Uploading SignedPreKey and PreKeys...');
        // Only upload SignedPreKey and PreKeys (identity already uploaded above)
        await _uploadKeysOnly();

        debugPrint(
          '[SIGNAL SERVICE] ✅ Identity mismatch resolved - server now has correct keys',
        );
        return; // Skip rest of validation - keys are fresh
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] ❌ Auto-recovery failed: $e');
        debugPrint(
          '[SIGNAL SERVICE] Manual intervention required: logout and login again',
        );

        // Reset initialization state so user can retry
        _isInitialized = false;
        _storesCreated = false;

        throw Exception(
          'Identity key mismatch detected and auto-recovery failed. '
          'Server has different public key than local storage. '
          'Please logout and login again to fix this issue.',
        );
      }
    }

    if (status is Map && status['identity'] != true) {
      debugPrint('[SIGNAL SERVICE] Uploading missing identity');
      final registrationId = await identityStore.getLocalRegistrationId();
      SocketService().emit("signalIdentity", {
        'publicKey': localPublicKey,
        'registrationId': registrationId.toString(),
      });
    } else if (serverPublicKey != null) {
      debugPrint(
        '[SIGNAL SERVICE] ✓ Identity key validated - local matches server',
      );

      // 🔍 DEEP VALIDATION: Check if server state is internally consistent
      await _validateServerKeyConsistency(
        Map<String, dynamic>.from(status as Map),
      );
    }
    // 2. PreKeys - Sync check ONLY (no generation - that's done in initWithProgress)
    final int preKeysCount = (status is Map && status['preKeys'] is int)
        ? status['preKeys']
        : 0;
    debugPrint('[SIGNAL SERVICE] ========================================');
    debugPrint('[SIGNAL SERVICE] PreKey Sync Check:');
    debugPrint('[SIGNAL SERVICE]   Server count: $preKeysCount');

    // 🔧 OPTIMIZED: Only get IDs first (no decryption for count check)
    final localPreKeyIds = await preKeyStore.getAllPreKeyIds();
    debugPrint('[SIGNAL SERVICE]   Local count:  ${localPreKeyIds.length}');
    debugPrint(
      '[SIGNAL SERVICE]   Difference:   ${localPreKeyIds.length - preKeysCount}',
    );
    debugPrint('[SIGNAL SERVICE] ========================================');

    if (preKeysCount < 20) {
      // Server critically low
      if (localPreKeyIds.isEmpty) {
        // No local PreKeys AND server has none → This shouldn't happen after initWithProgress()
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ CRITICAL: No local PreKeys found! Keys should have been generated during initialization.',
        );
        debugPrint(
          '[SIGNAL SERVICE] This indicates initWithProgress() was skipped or failed.',
        );
        // Don't generate here - initialization should handle this
        return;
      } else if (preKeysCount == 0) {
        // Server has 0 but we have local → This can happen on first sync or after server data loss
        // Upload existing local PreKeys (this is safe for first-time upload)
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Server has 0 PreKeys but local has ${localPreKeyIds.length}',
        );
        debugPrint(
          '[SIGNAL SERVICE] Uploading local PreKeys to server (first-time sync)...',
        );
        // NOW load full PreKeys (with decryption) only when needed for upload
        final localPreKeys = await preKeyStore.getAllPreKeys();
        final preKeysPayload = localPreKeys
            .map(
              (pk) => {
                'id': pk.id,
                'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
              },
            )
            .toList();
        SocketService().emit("storePreKeys", <String, dynamic>{
          'preKeys': preKeysPayload,
        });
      } else if (preKeysCount < localPreKeyIds.length) {
        // 🔒 SECURITY FIX: Server has fewer PreKeys than local
        // This means some PreKeys were consumed while we were offline
        // We must NOT re-upload existing PreKeys (they may have been consumed)
        // Instead, we should request which PreKeys server has, compare, and only upload missing ones
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Sync gap: Server has $preKeysCount, local has ${localPreKeyIds.length}',
        );
        debugPrint(
          '[SIGNAL SERVICE] → Server likely has different PreKeys, will upload missing ones',
        );

        // Upload all our PreKeys - server will accept only non-duplicates
        final preKeysToUpload = [];
        for (final keyId in localPreKeyIds) {
          final keyRecord = await preKeyStore.loadPreKey(keyId);
          final keyPair = keyRecord.getKeyPair();
          preKeysToUpload.add({
            'id': keyId,
            'key': base64Encode(keyPair.publicKey.serialize()),
          });
        }

        if (preKeysToUpload.isNotEmpty) {
          debugPrint(
            '[SIGNAL SERVICE] 📤 Uploading ${preKeysToUpload.length} PreKeys to close sync gap',
          );
          SocketService().emit("storePreKeys", <String, dynamic>{
            'preKeys': preKeysToUpload,
          });
        }
      } else {
        // Server has enough PreKeys (>= 20) or same count as local
        debugPrint(
          '[SIGNAL SERVICE] ✅ PreKey count OK: Server=$preKeysCount, Local=${localPreKeyIds.length}',
        );
      }
    } else if (localPreKeyIds.length > preKeysCount) {
      // NEW: Server has enough (>= 20), but local has MORE
      // 🔒 SECURITY: Do NOT blindly re-upload all keys!
      // Some may have been consumed. Only upload truly missing keys.
      final difference = localPreKeyIds.length - preKeysCount;

      if (difference > 5) {
        // Significant difference - check which keys are actually missing
        debugPrint(
          '[SIGNAL SERVICE] 🔄 Local has $difference more PreKeys than server',
        );
        debugPrint(
          '[SIGNAL SERVICE] → Requesting server PreKey IDs to identify missing keys...',
        );

        // Request server's PreKey IDs to safely sync
        SocketService().emit("getMyPreKeyIds", null);
      } else {
        // Small difference - server will request missing keys when needed
        debugPrint(
          '[SIGNAL SERVICE] ℹ️ Local has $difference more PreKeys than server (minor difference, will sync on demand)',
        );
      }
    } else {
      debugPrint(
        '[SIGNAL SERVICE] ✅ Server has sufficient PreKeys ($preKeysCount >= 20) and is in sync',
      );
    }
    // 3. SignedPreKey
    final signedPreKey = status is Map ? status['signedPreKey'] : null;
    if (signedPreKey == null) {
      debugPrint('[SIGNAL SERVICE] No signed pre-key on server, uploading');
      final allSigned = await signedPreKeyStore.loadSignedPreKeys();
      if (allSigned.isNotEmpty) {
        final latest = allSigned.last;
        SocketService().emit("storeSignedPreKey", {
          'id': latest.id,
          'data': base64Encode(latest.getKeyPair().publicKey.serialize()),
          'signature': base64Encode(latest.signature),
        });
      }
    } else {
      // SELF-VALIDATION: Verify our own SignedPreKey on server
      await _validateOwnKeysOnServer(Map<String, dynamic>.from(status as Map));
    }
  }

  /// Validate owner's own keys on the server
  /// This ensures the device owner knows if their keys are corrupted
  /// Called during signalStatus check after keys are confirmed present
  Future<void> _validateOwnKeysOnServer(Map<String, dynamic> status) async {
    try {
      debugPrint(
        '[SIGNAL SERVICE][SELF-VALIDATION] Validating own keys on server...',
      );

      // Get local identity key pair
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      final localIdentityKey = identityKeyPair
          .getPublicKey(); // Returns IdentityKey
      // Extract ECPublicKey from IdentityKey for signature verification
      final localPublicKey = Curve.decodePoint(localIdentityKey.serialize(), 0);

      // Get server's SignedPreKey data
      final signedPreKeyData = status['signedPreKey'];
      if (signedPreKeyData == null) {
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ⚠️ No SignedPreKey on server to validate',
        );
        return;
      }

      // Parse server data
      final signedPreKeyPublicBase64 =
          signedPreKeyData['signed_prekey_data'] as String?;
      final signedPreKeySignatureBase64 =
          signedPreKeyData['signed_prekey_signature'] as String?;

      if (signedPreKeyPublicBase64 == null ||
          signedPreKeySignatureBase64 == null) {
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ⚠️ Incomplete SignedPreKey data on server',
        );
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] → Regenerating and uploading new SignedPreKey...',
        );

        // Regenerate SignedPreKey
        final newSignedPreKey = generateSignedPreKey(identityKeyPair, 0);
        await signedPreKeyStore.storeSignedPreKey(
          newSignedPreKey.id,
          newSignedPreKey,
        );

        // Upload to server
        SocketService().emit("storeSignedPreKey", {
          'id': newSignedPreKey.id,
          'data': base64Encode(
            newSignedPreKey.getKeyPair().publicKey.serialize(),
          ),
          'signature': base64Encode(newSignedPreKey.signature),
        });

        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ✓ New SignedPreKey uploaded to server',
        );
        return;
      }

      // Decode server keys
      final signedPreKeyPublicBytes = base64Decode(signedPreKeyPublicBase64);
      final signedPreKeySignatureBytes = base64Decode(
        signedPreKeySignatureBase64,
      );
      final signedPreKeyPublic = Curve.decodePoint(signedPreKeyPublicBytes, 0);

      // VALIDATE: Verify that our identity key signed this SignedPreKey
      final isValid = Curve.verifySignature(
        localPublicKey,
        signedPreKeyPublic.serialize(),
        signedPreKeySignatureBytes,
      );

      if (!isValid) {
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ❌ CRITICAL: SignedPreKey signature INVALID!',
        );
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] Server has corrupted SignedPreKey for this device',
        );
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] → Re-generating and uploading new SignedPreKey...',
        );

        // Regenerate SignedPreKey
        final newSignedPreKey = generateSignedPreKey(identityKeyPair, 0);
        await signedPreKeyStore.storeSignedPreKey(
          newSignedPreKey.id,
          newSignedPreKey,
        );

        // Upload to server
        SocketService().emit("storeSignedPreKey", {
          'id': newSignedPreKey.id,
          'data': base64Encode(
            newSignedPreKey.getKeyPair().publicKey.serialize(),
          ),
          'signature': base64Encode(newSignedPreKey.signature),
        });

        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ✓ New SignedPreKey uploaded to server',
        );
      } else {
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ✓ SignedPreKey signature valid',
        );
      }

      // Additional check: Signature length
      if (signedPreKeySignatureBytes.length != 64) {
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] ⚠️ SignedPreKey signature has invalid length: ${signedPreKeySignatureBytes.length} (expected 64)',
        );
        debugPrint(
          '[SIGNAL SERVICE][SELF-VALIDATION] → Signature is malformed, re-uploading...',
        );

        // Regenerate and upload
        final newSignedPreKey = generateSignedPreKey(identityKeyPair, 0);
        await signedPreKeyStore.storeSignedPreKey(
          newSignedPreKey.id,
          newSignedPreKey,
        );
        SocketService().emit("storeSignedPreKey", {
          'id': newSignedPreKey.id,
          'data': base64Encode(
            newSignedPreKey.getKeyPair().publicKey.serialize(),
          ),
          'signature': base64Encode(newSignedPreKey.signature),
        });
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[SIGNAL SERVICE][SELF-VALIDATION] ⚠️ Error validating own keys: $e',
      );
      debugPrint('[SIGNAL SERVICE][SELF-VALIDATION] Stack trace: $stackTrace');
      // Don't throw - validation failure shouldn't block operations
    }
  }

  /// 🔍 Deep validation of server key consistency
  /// Detects if server has corrupted or inconsistent keys
  /// CLIENT IS SOURCE OF TRUTH - if corruption detected, re-upload all keys
  Future<void> _validateServerKeyConsistency(
    Map<String, dynamic> status,
  ) async {
    try {
      debugPrint(
        '[SIGNAL SERVICE][DEEP-VALIDATION] ========================================',
      );
      debugPrint(
        '[SIGNAL SERVICE][DEEP-VALIDATION] Checking server key consistency...',
      );

      bool corruptionDetected = false;
      final List<String> corruptionReasons = [];

      // 1. Get local identity key (source of truth)
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      final localIdentityKey = identityKeyPair.getPublicKey();
      final localPublicKey = Curve.decodePoint(localIdentityKey.serialize(), 0);

      // 2. Validate SignedPreKey consistency with Identity
      final signedPreKeyData = status['signedPreKey'];
      if (signedPreKeyData != null) {
        final signedPreKeyPublicBase64 =
            signedPreKeyData['signed_prekey_data'] as String?;
        final signedPreKeySignatureBase64 =
            signedPreKeyData['signed_prekey_signature'] as String?;

        if (signedPreKeyPublicBase64 != null &&
            signedPreKeySignatureBase64 != null) {
          try {
            final signedPreKeyPublicBytes = base64Decode(
              signedPreKeyPublicBase64,
            );
            final signedPreKeySignatureBytes = base64Decode(
              signedPreKeySignatureBase64,
            );
            final signedPreKeyPublic = Curve.decodePoint(
              signedPreKeyPublicBytes,
              0,
            );

            // Verify signature matches identity
            final isValid = Curve.verifySignature(
              localPublicKey,
              signedPreKeyPublic.serialize(),
              signedPreKeySignatureBytes,
            );

            if (!isValid) {
              corruptionDetected = true;
              corruptionReasons.add(
                'SignedPreKey signature does NOT match local Identity key',
              );
              debugPrint(
                '[SIGNAL SERVICE][DEEP-VALIDATION] ❌ SignedPreKey signature invalid!',
              );
            } else {
              debugPrint(
                '[SIGNAL SERVICE][DEEP-VALIDATION] ✓ SignedPreKey signature valid',
              );
            }
          } catch (e) {
            corruptionDetected = true;
            corruptionReasons.add('SignedPreKey data is malformed: $e');
            debugPrint(
              '[SIGNAL SERVICE][DEEP-VALIDATION] ❌ SignedPreKey malformed: $e',
            );
          }
        } else {
          corruptionDetected = true;
          corruptionReasons.add('SignedPreKey missing required fields');
          debugPrint(
            '[SIGNAL SERVICE][DEEP-VALIDATION] ❌ SignedPreKey incomplete',
          );
        }
      } else {
        corruptionDetected = true;
        corruptionReasons.add('No SignedPreKey on server');
        debugPrint(
          '[SIGNAL SERVICE][DEEP-VALIDATION] ❌ No SignedPreKey on server',
        );
      }

      // 3. Check PreKey count consistency
      final preKeysCount = (status['preKeys'] is int) ? status['preKeys'] : 0;
      if (preKeysCount == 0) {
        final localPreKeyIds = await preKeyStore.getAllPreKeyIds();
        if (localPreKeyIds.isNotEmpty) {
          // Client has PreKeys but server has none = corruption
          corruptionDetected = true;
          corruptionReasons.add(
            'Client has ${localPreKeyIds.length} PreKeys but server has 0',
          );
          debugPrint(
            '[SIGNAL SERVICE][DEEP-VALIDATION] ❌ PreKeys missing from server',
          );
        }
      }

      debugPrint(
        '[SIGNAL SERVICE][DEEP-VALIDATION] ========================================',
      );

      // 4. If corruption detected, FORCE FULL KEY RE-UPLOAD
      if (corruptionDetected) {
        debugPrint(
          '[SIGNAL SERVICE][DEEP-VALIDATION] ⚠️⚠️⚠️  CORRUPTION DETECTED  ⚠️⚠️⚠️',
        );
        debugPrint('[SIGNAL SERVICE][DEEP-VALIDATION] Reasons:');
        for (final reason in corruptionReasons) {
          debugPrint('[SIGNAL SERVICE][DEEP-VALIDATION]   - $reason');
        }

        // 🔒 LOOP PREVENTION: Check if reinforcement already in progress
        if (_keyReinforcementInProgress) {
          debugPrint(
            '[SIGNAL SERVICE][DEEP-VALIDATION] ⚠️ Key reinforcement already in progress - skipping',
          );
          return;
        }

        // 🔒 LOOP PREVENTION: Check cooldown (don't reinforce more than once per minute)
        if (_lastKeyReinforcementTime != null) {
          final timeSinceLastReinforcement = DateTime.now().difference(
            _lastKeyReinforcementTime!,
          );
          if (timeSinceLastReinforcement.inSeconds < 60) {
            debugPrint(
              '[SIGNAL SERVICE][DEEP-VALIDATION] ⚠️ Key reinforcement on cooldown (${60 - timeSinceLastReinforcement.inSeconds}s remaining)',
            );
            return;
          }
        }

        debugPrint('[SIGNAL SERVICE][DEEP-VALIDATION] ');
        debugPrint(
          '[SIGNAL SERVICE][DEEP-VALIDATION] 🔧 INITIATING AUTO-RECOVERY...',
        );
        debugPrint(
          '[SIGNAL SERVICE][DEEP-VALIDATION] Client is source of truth - re-uploading ALL keys',
        );

        final reinforcementSuccess = await healingService
            .forceServerKeyReinforcement(
              userId: _currentUserId!,
              deviceId: _currentDeviceId!,
            );

        if (reinforcementSuccess) {
          debugPrint(
            '[SIGNAL SERVICE][DEEP-VALIDATION] ✅ Auto-recovery completed - keys uploaded',
          );
          debugPrint(
            '[SIGNAL SERVICE][DEEP-VALIDATION] → Exiting validation to prevent duplicate uploads',
          );
          return; // Exit early - keys are fresh, no need to check stale status
        } else {
          debugPrint(
            '[SIGNAL SERVICE][DEEP-VALIDATION] ❌ Auto-recovery failed - continuing with normal validation',
          );
          // Fall through to normal validation
        }
      } else {
        debugPrint(
          '[SIGNAL SERVICE][DEEP-VALIDATION] ✅ Server keys are consistent and valid',
        );
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[SIGNAL SERVICE][DEEP-VALIDATION] ⚠️ Error during validation: $e',
      );
      debugPrint('[SIGNAL SERVICE][DEEP-VALIDATION] Stack trace: $stackTrace');
      // Don't throw - validation failure shouldn't block operations
    }
  }

  /// �🔧 Upload SignedPreKey and PreKeys only (identity already uploaded separately)
  /// Used when identity was already uploaded and we just need to upload the other keys
  Future<void> _uploadKeysOnly() async {
    try {
      // Step 3: Re-upload SignedPreKey
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Step 3: Re-uploading SignedPreKey...',
      );
      final identityKeyPair = await identityStore.getIdentityKeyPair();

      // Check if we have a valid SignedPreKey, if not regenerate
      final allSignedPreKeys = await signedPreKeyStore.loadSignedPreKeys();
      SignedPreKeyRecord signedPreKey;

      if (allSignedPreKeys.isEmpty) {
        debugPrint(
          '[SIGNAL SERVICE][REINFORCEMENT] No local SignedPreKey found - generating new one',
        );
        signedPreKey = generateSignedPreKey(identityKeyPair, 0);
        await signedPreKeyStore.storeSignedPreKey(
          signedPreKey.id,
          signedPreKey,
        );
      } else {
        signedPreKey = allSignedPreKeys.last;

        // Validate signature before uploading
        final localPublicKey = Curve.decodePoint(
          identityKeyPair.getPublicKey().serialize(),
          0,
        );
        final isValid = Curve.verifySignature(
          localPublicKey,
          signedPreKey.getKeyPair().publicKey.serialize(),
          signedPreKey.signature,
        );

        if (!isValid) {
          debugPrint(
            '[SIGNAL SERVICE][REINFORCEMENT] Local SignedPreKey signature invalid - regenerating',
          );
          signedPreKey = generateSignedPreKey(identityKeyPair, 0);
          await signedPreKeyStore.storeSignedPreKey(
            signedPreKey.id,
            signedPreKey,
          );
        }
      }

      SocketService().emit("storeSignedPreKey", {
        'id': signedPreKey.id,
        'data': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signedPreKey.signature),
      });

      await Future.delayed(Duration(milliseconds: 500));

      // Apply cleanup strategy after upload: remove old keys from server
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Applying SignedPreKey cleanup strategy...',
      );
      final allStoredKeys = await signedPreKeyStore
          .loadAllStoredSignedPreKeys();
      if (allStoredKeys.length > 1) {
        // Sort to find newest
        allStoredKeys.sort((a, b) {
          if (a.createdAt == null) return 1;
          if (b.createdAt == null) return -1;
          return b.createdAt!.compareTo(a.createdAt!);
        });

        // Remove ALL old keys from server immediately
        for (final key in allStoredKeys) {
          // Skip newest
          if (key.record.id == allStoredKeys.first.record.id) continue;

          debugPrint(
            '[SIGNAL SERVICE][REINFORCEMENT] Removing old server key: ${key.record.id}',
          );
          SocketService().emit("removeSignedPreKey", <String, dynamic>{
            'id': key.record.id,
          });
        }
      }

      // Step 4: Re-upload all PreKeys (optimized - check IDs first)
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Step 4: Re-uploading PreKeys...',
      );
      final localPreKeyIds = await preKeyStore.getAllPreKeyIds();

      if (localPreKeyIds.isEmpty) {
        debugPrint(
          '[SIGNAL SERVICE][REINFORCEMENT] No local PreKeys found - generating 110 new ones',
        );
        final newPreKeys = generatePreKeys(0, 109);
        for (final preKey in newPreKeys) {
          await preKeyStore.storePreKey(preKey.id, preKey);
        }

        // Track metrics for diagnostics
        KeyManagementMetrics.recordPreKeyRegeneration(
          newPreKeys.length,
          reason: 'Reinforcement recovery',
        );

        final preKeysPayload = newPreKeys
            .map(
              (pk) => {
                'id': pk.id,
                'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
              },
            )
            .toList();

        SocketService().emit("storePreKeys", <String, dynamic>{
          'preKeys': preKeysPayload,
        });
      } else {
        debugPrint(
          '[SIGNAL SERVICE][REINFORCEMENT] Found ${localPreKeyIds.length} local PreKey IDs - loading for upload...',
        );

        // Load PreKeys in batch (unavoidable - need to extract public keys)
        final preKeysPayload = <Map<String, dynamic>>[];
        for (final id in localPreKeyIds) {
          try {
            final preKey = await preKeyStore.loadPreKey(id);
            preKeysPayload.add({
              'id': preKey.id,
              'data': base64Encode(preKey.getKeyPair().publicKey.serialize()),
            });
          } catch (e) {
            debugPrint(
              '[SIGNAL SERVICE][REINFORCEMENT] ⚠️ Failed to load PreKey $id: $e',
            );
          }
        }

        debugPrint(
          '[SIGNAL SERVICE][REINFORCEMENT] Uploading ${preKeysPayload.length} PreKeys to server',
        );
        SocketService().emit("storePreKeys", <String, dynamic>{
          'preKeys': preKeysPayload,
        });
      }

      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] ✅ Keys uploaded successfully',
      );
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL SERVICE][REINFORCEMENT] ❌ Error uploading keys: $e');
      debugPrint('[SIGNAL SERVICE][REINFORCEMENT] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// 🔍 SELF-VERIFICATION: Verify our own keys are valid on the server
  /// This should be called after initialization and before sending messages
  ///
  /// Also called AUTOMATICALLY (async, non-blocking) when:
  /// - We encounter invalid PreKeyBundles from other users
  /// - Session building fails due to signature errors
  /// - Any key validation error suggests mutual corruption
  ///
  /// Rate-limited to once every 5 minutes to prevent excessive server load
  ///
  /// Returns true if keys are valid, false if issues detected
  Future<bool> verifyOwnKeysOnServer() async {
    try {
      debugPrint(
        '[SIGNAL_SELF_VERIFY] ========================================',
      );
      debugPrint(
        '[SIGNAL_SELF_VERIFY] Starting self-verification of keys on server...',
      );

      if (!_isInitialized) {
        debugPrint('[SIGNAL_SELF_VERIFY] ❌ Not initialized, cannot verify');
        return false;
      }

      // 1. Get our own device info
      final userId = _currentUserId;
      final deviceNumber = _currentDeviceId;

      if (userId == null || userId.isEmpty || deviceNumber == null) {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ❌ No user/device ID available yet (socket may not be connected)',
        );
        debugPrint(
          '[SIGNAL_SELF_VERIFY]    This is normal during app restart before socket authentication',
        );
        debugPrint('[SIGNAL_SELF_VERIFY]    Will retry after socket connects');
        return false;
      }

      debugPrint(
        '[SIGNAL_SELF_VERIFY] Checking keys for: $userId (device $deviceNumber)',
      );

      // 2. Fetch our own bundle from server
      final response = await ApiService.get(
        '/signal/status/minimal',
        queryParameters: {
          'userId': userId,
          'deviceId': deviceNumber.toString(),
        },
      );

      final serverData = response.data as Map<String, dynamic>;

      // 3. Verify identity key exists and matches
      final serverIdentityKey = serverData['identityKey'] as String?;
      if (serverIdentityKey == null) {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ❌ Server has NO identity key for our device!',
        );
        debugPrint(
          '[SIGNAL_SELF_VERIFY] → Keys were not uploaded or were deleted',
        );
        return false;
      }

      final identityKeyPair = await identityStore.getIdentityKeyPair();
      final localIdentityKey = base64Encode(
        identityKeyPair.getPublicKey().serialize(),
      );

      if (serverIdentityKey != localIdentityKey) {
        debugPrint('[SIGNAL_SELF_VERIFY] ❌ Identity key MISMATCH!');
        debugPrint('[SIGNAL_SELF_VERIFY]   Local:  $localIdentityKey');
        debugPrint('[SIGNAL_SELF_VERIFY]   Server: $serverIdentityKey');
        return false;
      }
      debugPrint('[SIGNAL_SELF_VERIFY] ✓ Identity key matches');

      // 4. Verify SignedPreKey exists and is valid
      final serverSignedPreKey = serverData['signedPreKey'] as String?;
      final serverSignedPreKeySignature =
          serverData['signedPreKeySignature'] as String?;

      if (serverSignedPreKey == null || serverSignedPreKeySignature == null) {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ❌ Server has NO SignedPreKey for our device!',
        );
        return false;
      }

      // Verify signature
      try {
        final localPublicKey = Curve.decodePoint(
          identityKeyPair.getPublicKey().serialize(),
          0,
        );
        final signedPreKeyBytes = base64Decode(serverSignedPreKey);
        final signatureBytes = base64Decode(serverSignedPreKeySignature);

        final isValid = Curve.verifySignature(
          localPublicKey,
          signedPreKeyBytes,
          signatureBytes,
        );

        if (!isValid) {
          debugPrint('[SIGNAL_SELF_VERIFY] ❌ SignedPreKey signature INVALID!');
          return false;
        }
        debugPrint('[SIGNAL_SELF_VERIFY] ✓ SignedPreKey valid');
      } catch (e) {
        debugPrint('[SIGNAL_SELF_VERIFY] ❌ SignedPreKey validation error: $e');
        return false;
      }

      // 5. Verify PreKeys count
      final preKeysCount = serverData['preKeysCount'] as int? ?? 0;
      if (preKeysCount == 0) {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ❌ Server has ZERO PreKeys for our device!',
        );
        return false;
      }

      if (preKeysCount < 10) {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ⚠️ Low PreKey count on server: $preKeysCount',
        );
        debugPrint('[SIGNAL_SELF_VERIFY] → Should regenerate PreKeys soon');
      } else {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ✓ PreKeys count adequate: $preKeysCount',
        );
      }

      // 6. Verify PreKey fingerprints (hashes) to detect corruption
      final serverFingerprints =
          serverData['preKeyFingerprints'] as Map<String, dynamic>?;
      if (serverFingerprints != null && serverFingerprints.isNotEmpty) {
        debugPrint('[SIGNAL_SELF_VERIFY] Validating PreKey fingerprints...');

        // Get local PreKey fingerprints
        final localFingerprints = await _getPreKeyFingerprints();

        // Compare fingerprints
        int matchCount = 0;
        int mismatchCount = 0;
        final mismatches = <String>[];

        for (final entry in serverFingerprints.entries) {
          final keyId = entry.key;
          final serverHash = entry.value as String?;
          final localHash = localFingerprints[keyId];

          if (localHash == null) {
            debugPrint(
              '[SIGNAL_SELF_VERIFY] ⚠️ PreKey $keyId on server but not in local store',
            );
            mismatchCount++;
            mismatches.add(keyId);
          } else if (serverHash != localHash) {
            debugPrint('[SIGNAL_SELF_VERIFY] ❌ PreKey $keyId HASH MISMATCH!');
            debugPrint(
              '[SIGNAL_SELF_VERIFY]   Local:  ${localHash.substring(0, 20)}...',
            );
            debugPrint(
              '[SIGNAL_SELF_VERIFY]   Server: ${serverHash?.substring(0, 20)}...',
            );
            mismatchCount++;
            mismatches.add(keyId);
          } else {
            matchCount++;
          }
        }

        // Check for local keys not on server
        for (final keyId in localFingerprints.keys) {
          if (!serverFingerprints.containsKey(keyId)) {
            debugPrint(
              '[SIGNAL_SELF_VERIFY] ⚠️ PreKey $keyId in local store but not on server',
            );
            mismatchCount++;
            mismatches.add(keyId);
          }
        }

        debugPrint(
          '[SIGNAL_SELF_VERIFY] PreKey validation: $matchCount matched, $mismatchCount mismatched',
        );

        if (mismatchCount > 0) {
          debugPrint(
            '[SIGNAL_SELF_VERIFY] ❌ PreKey corruption detected! Mismatched keys: ${mismatches.take(5).join(", ")}${mismatches.length > 5 ? "..." : ""}',
          );
          return false;
        }

        debugPrint('[SIGNAL_SELF_VERIFY] ✓ All PreKey hashes valid');
      } else {
        debugPrint(
          '[SIGNAL_SELF_VERIFY] ⚠️ No PreKey fingerprints from server (old endpoint version)',
        );
      }

      debugPrint(
        '[SIGNAL_SELF_VERIFY] ========================================',
      );
      debugPrint('[SIGNAL_SELF_VERIFY] ✅ All keys verified successfully');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL_SELF_VERIFY] ❌ Verification failed with error: $e');
      debugPrint('[SIGNAL_SELF_VERIFY] Stack trace: $stackTrace');
      return false;
    }
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
    _meetingE2EEKeyRequestCallbacks[meetingId] = callback;
    debugPrint(
      '[SIGNAL SERVICE] Registered meeting E2EE key request callback for $meetingId',
    );
  }

  /// Register callback for meeting E2EE key responses (via 1-to-1 Signal messages)
  /// Called when someone sends us the E2EE key
  void registerMeetingE2EEKeyResponseCallback(
    String meetingId,
    Function(Map<String, dynamic>) callback,
  ) {
    _meetingE2EEKeyResponseCallbacks[meetingId] = callback;
    debugPrint(
      '[SIGNAL SERVICE] Registered meeting E2EE key response callback for $meetingId',
    );
  }

  /// Unregister meeting E2EE callbacks (call when leaving meeting)
  void unregisterMeetingE2EECallbacks(String meetingId) {
    _meetingE2EEKeyRequestCallbacks.remove(meetingId);
    _meetingE2EEKeyResponseCallbacks.remove(meetingId);
    debugPrint(
      '[SIGNAL SERVICE] Unregistered meeting E2EE callbacks for $meetingId',
    );
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
    // Parse senderDeviceId as int (server/storage might return String)
    final senderDeviceId = data['senderDeviceId'] is int
        ? data['senderDeviceId'] as int
        : int.parse(data['senderDeviceId'].toString());
    final payload = data['payload'];
    final cipherType = data['cipherType'];
    final itemId = data['itemId'];

    // Check if we already decrypted this message (prevents DuplicateMessageException)
    if (itemId != null) {
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        final cached = await messageStore.getMessage(itemId);
        if (cached != null) {
          debugPrint(
            "[SIGNAL SERVICE] ✓ Using cached decrypted message from SQLite for itemId: $itemId",
          );
          return cached['message'] as String;
        } else {
          debugPrint(
            "[SIGNAL SERVICE] Cache miss for itemId: $itemId - will decrypt",
          );
        }
      } catch (e) {
        debugPrint("[SIGNAL SERVICE] ⚠️ Error checking cache: $e");
      }
    } else {
      debugPrint("[SIGNAL SERVICE] No itemId provided - cannot use cache");
    }

    debugPrint(
      "[SIGNAL SERVICE] Decrypting new message: itemId=$itemId, sender=$sender, deviceId=$senderDeviceId",
    );
    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);

    String message;
    try {
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
      // sendNotification: true is SAFE here (receive path, after successful resolution)
      message = await handleUntrustedIdentity(
        e,
        senderAddress,
        () async {
          // Retry decryption with now-trusted identity
          return await decryptItem(
            senderAddress: senderAddress,
            payload: payload,
            cipherType: cipherType,
            itemId: itemId,
          );
        },
        sendNotification: true, // ✅ Send system message to both users
      );
      debugPrint('[SIGNAL SERVICE] ✓ Message decrypted after identity update');
    }

    try {
      // Cache the decrypted message to prevent re-decryption in SQLite
      // IMPORTANT: Only cache 1:1 messages (no channelId)
      // ❌ SYSTEM MESSAGES: Don't cache read_receipt, delivery_receipt, or other system messages
      // ✅ EXCEPTION: system:session_reset with recovery reasons SHOULD be stored
      final messageType = data['type'] as String?;

      // Check if this is a session_reset with recovery reason (should be stored)
      bool isRecoverySessionReset = false;
      if (messageType == 'system:session_reset') {
        try {
          final payloadData = jsonDecode(message) as Map<String, dynamic>;
          final reason = payloadData['reason'] as String?;
          isRecoverySessionReset =
              (reason == 'bad_mac_recovery' || reason == 'no_session_recovery');
        } catch (e) {
          // If can't parse, treat as normal system message
        }
      }

      final isSystemMessage =
          messageType == 'read_receipt' ||
          messageType == 'delivery_receipt' ||
          messageType == 'senderKeyRequest' ||
          messageType == 'fileKeyRequest' ||
          (messageType == 'system:session_reset' && !isRecoverySessionReset);

      if (itemId != null &&
          message.isNotEmpty &&
          data['channel'] == null &&
          !isSystemMessage) {
        // Store in SQLite database
        try {
          final messageStore = await SqliteMessageStore.getInstance();
          final messageTimestamp =
              data['timestamp'] ??
              data['createdAt'] ??
              DateTime.now().toIso8601String();

          // 🔑 MULTI-DEVICE FIX: Check if message is from own user (different device)
          final isOwnMessage = sender == _currentUserId;
          final recipient = data['recipient'] as String?;
          final originalRecipient = data['originalRecipient'] as String?;

          // Declare actualRecipient outside blocks so it can be reused later
          late final String actualRecipient;

          if (isOwnMessage) {
            // Message from own device → Store as SENT message
            // BREAKING CHANGE: Multi-device sync MUST include originalRecipient
            // When Bob Device 1 sends to Alice, Bob Device 2 receives it with:
            // - sender=Bob, recipient=Bob, originalRecipient=Alice
            // We must store it as "Bob → Alice", not "Bob → Bob"
            final isMultiDeviceSync = (recipient == _currentUserId);

            if (isMultiDeviceSync && originalRecipient == null) {
              debugPrint(
                '[SIGNAL SERVICE] ❌ Multi-device sync message missing originalRecipient during storage',
              );
              throw Exception(
                'Cannot store sync message: originalRecipient required but missing',
              );
            }

            actualRecipient = isMultiDeviceSync
                ? originalRecipient!
                : (recipient ?? _currentUserId ?? 'UNKNOWN');

            // Final validation: actualRecipient must not be self or unknown
            if (actualRecipient == _currentUserId ||
                actualRecipient == 'UNKNOWN') {
              debugPrint(
                '[SIGNAL SERVICE] ⚠️ Warning: Attempting to store message to self (recipient=$actualRecipient)',
              );
            }

            debugPrint(
              "[SIGNAL SERVICE] 📤 Storing message from own device (Device $senderDeviceId) as SENT to $actualRecipient",
            );
            if (originalRecipient != null) {
              debugPrint(
                "[SIGNAL SERVICE] 🔄 Multi-device sync: originalRecipient=$originalRecipient used instead of recipient=$recipient",
              );
            }
            await messageStore.storeSentMessage(
              itemId: itemId,
              recipientId: actualRecipient,
              message: message,
              timestamp: messageTimestamp,
              type: data['type'] ?? 'message',
              status: 'delivered', // Already delivered (we received it!)
            );
          } else {
            // Message from another user → Store as RECEIVED message
            // For received messages, recipient field from server indicates who received it (us)
            // Validate recipient field exists for non-sync messages
            if (recipient == null) {
              debugPrint(
                '[SIGNAL SERVICE] ❌ Received message missing recipient field',
              );
              throw Exception(
                'Cannot store received message: recipient field missing',
              );
            }
            actualRecipient =
                recipient; // For received messages, use server's recipient field

            debugPrint(
              "[SIGNAL SERVICE] 📥 Storing message from other user ($sender) as RECEIVED",
            );
            await messageStore.storeReceivedMessage(
              itemId: itemId,
              sender: sender,
              senderDeviceId: senderDeviceId,
              message: message,
              timestamp: messageTimestamp,
              type: data['type'] ?? 'message',
            );
          }

          // Update recent conversations list
          final conversationsStore =
              await SqliteRecentConversationsStore.getInstance();
          // ✅ Reuse actualRecipient calculated above (no recalculation, no fallbacks)
          // For own messages: conversation is with actualRecipient
          // For received messages: conversation is with sender
          final conversationUserId = isOwnMessage ? actualRecipient : sender;
          await conversationsStore.addOrUpdateConversation(
            userId: conversationUserId,
            displayName: conversationUserId, // Will be enriched by UI layer
          );

          // Only increment unread count for messages from OTHER users
          if (!isOwnMessage) {
            await conversationsStore.incrementUnreadCount(sender);
          }

          debugPrint(
            "[SIGNAL SERVICE] ✓ Cached decrypted 1:1 message in SQLite for itemId: $itemId (direction: ${isOwnMessage ? 'sent' : 'received'})",
          );

          // Load sender's profile if not already cached
          try {
            final profileService = UserProfileService.instance;
            if (!profileService.isProfileCached(sender)) {
              debugPrint(
                "[SIGNAL SERVICE] Loading profile for sender: $sender",
              );
              await profileService.loadProfiles([sender]);
              debugPrint("[SIGNAL SERVICE] ✓ Sender profile loaded");
            }
          } catch (e) {
            debugPrint(
              "[SIGNAL SERVICE] ⚠ Failed to load sender profile (server may be unavailable): $e",
            );
            // Don't block message processing if profile loading fails
          }
        } catch (e) {
          debugPrint("[SIGNAL SERVICE] ✗ Failed to cache in SQLite: $e");
        }
      } else if (isSystemMessage) {
        debugPrint(
          "[SIGNAL SERVICE] ⚠ Skipping cache for system message type: $messageType",
        );
      } else if (data['channel'] != null) {
        debugPrint(
          "[SIGNAL SERVICE] ⚠ Skipping cache for group message (use DecryptedGroupItemsStore)",
        );
      }

      return message;
    } catch (e) {
      debugPrint(
        '[SIGNAL SERVICE] ✗ Decryption failed for itemId: $itemId - $e',
      );

      // Store failed decryption with status='decrypt_failed' so user sees there was an issue
      if (itemId != null && data['channel'] == null) {
        try {
          final messageStore = await SqliteMessageStore.getInstance();
          final messageTimestamp =
              data['timestamp'] ??
              data['createdAt'] ??
              DateTime.now().toIso8601String();
          final messageType = data['type'] as String?;

          // Check if this is from own device (multi-device sync)
          final isOwnMessage = sender == _currentUserId;
          final recipient = data['recipient'] as String?;
          final originalRecipient = data['originalRecipient'] as String?;

          if (isOwnMessage) {
            // Failed to decrypt message from own device
            final isMultiDeviceSync = (recipient == _currentUserId);
            final actualRecipient = isMultiDeviceSync
                ? (originalRecipient ?? recipient ?? 'UNKNOWN')
                : (recipient ?? 'UNKNOWN');

            await messageStore.storeSentMessage(
              itemId: itemId,
              recipientId: actualRecipient,
              message: 'Decryption failed',
              timestamp: messageTimestamp,
              type: messageType ?? 'message',
              status: 'decrypt_failed',
            );
            debugPrint(
              "[SIGNAL SERVICE] ✓ Stored failed decryption as SENT with decrypt_failed status",
            );
          } else {
            // Failed to decrypt message from another user
            await messageStore.storeReceivedMessage(
              itemId: itemId,
              sender: sender,
              senderDeviceId: senderDeviceId,
              message: 'Decryption failed',
              timestamp: messageTimestamp,
              type: messageType ?? 'message',
              status: 'decrypt_failed',
            );
            debugPrint(
              "[SIGNAL SERVICE] ✓ Stored failed decryption as RECEIVED with decrypt_failed status",
            );
          }

          // 🔄 Emit EventBus event so UI refreshes to show the decrypt_failed message
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

          // Also emit newConversation so conversation list updates
          EventBus.instance.emit(AppEvent.newConversation, {
            'conversationId': conversationWith,
            'isChannel': false,
            'isOwnMessage': isOwnMessage,
          });

          // 🔔 Trigger receiveItem callbacks so UI screens receive the failed message
          final callbackType = messageType ?? 'message';
          if (conversationWith != null) {
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
        } catch (storageError) {
          debugPrint(
            "[SIGNAL SERVICE] ✗ Failed to store decrypt_failed message: $storageError",
          );
        }
      }

      // Return special marker for decrypt failure
      return 'Decryption failed';
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
    // Use decryptItemFromData to get caching + IndexedDB storage
    // This ensures real-time messages are also persisted locally
    String message;
    try {
      message = await decryptItemFromData(dataMap);

      // ✅ Delete from server AFTER successful decryption
      deleteItemFromServer(itemId);
      debugPrint(
        "[SIGNAL SERVICE] ✓ Message decrypted and deleted from server: $itemId",
      );
    } catch (e) {
      debugPrint("[SIGNAL SERVICE] ✗ Decryption error: $e");

      // If it's a DuplicateMessageException, the message was already processed
      if (e.toString().contains('DuplicateMessageException')) {
        debugPrint(
          "[SIGNAL SERVICE] ⚠️ Duplicate message detected (already processed)",
        );
        // Still delete from server to clean up
        deleteItemFromServer(itemId);
        return;
      }

      // For other errors, notify UI and attempt recovery
      _notifyDecryptionFailure(
        SignalProtocolAddress(sender, senderDeviceId),
        reason: e.toString(),
        itemId: itemId,
      );

      debugPrint(
        "[SIGNAL SERVICE] ⚠️ Decryption failed - deleting from server to prevent stuck message",
      );
      deleteItemFromServer(itemId);

      // Set message to 'Decryption failed' to continue processing and show user
      message = 'Decryption failed';
    }

    // Check if decryption failed (message will be 'Decryption failed')
    // Don't skip - we want to show the decrypt_failed status to user
    if (message.isEmpty) {
      debugPrint(
        "[SIGNAL SERVICE] Skipping message - decryption returned empty",
      );
      return;
    }

    debugPrint(
      "[SIGNAL SERVICE] Message decrypted successfully: '$message' (cipherType: $cipherType)",
    );

    final recipient = dataMap['recipient']; // Empfänger-UUID vom Server
    final originalRecipient =
        dataMap['originalRecipient']; // Original recipient for multi-device sync

    // 🔒 BREAKING CHANGE: Multi-device sync messages MUST include originalRecipient
    // For multi-device sync: sender == currentUserId AND recipient == currentUserId
    final isMultiDeviceSync =
        (sender == _currentUserId && recipient == _currentUserId);

    if (isMultiDeviceSync && originalRecipient == null) {
      debugPrint(
        '[SIGNAL SERVICE] ❌ CRITICAL: Multi-device sync message missing originalRecipient!',
      );
      debugPrint('[SIGNAL SERVICE] sender=$sender, recipient=$recipient');
      debugPrint(
        '[SIGNAL SERVICE] Server must send originalRecipient for sync messages',
      );
      throw Exception(
        'Protocol violation: Multi-device sync message missing originalRecipient field',
      );
    }

    // Determine actual recipient (conversation context)
    final actualRecipient = isMultiDeviceSync ? originalRecipient! : recipient;

    // Validate that recipient exists
    if (actualRecipient == null) {
      debugPrint('[SIGNAL SERVICE] ❌ CRITICAL: Message has no recipient!');
      debugPrint(
        '[SIGNAL SERVICE] sender=$sender, recipient=$recipient, originalRecipient=$originalRecipient',
      );
      throw Exception('Protocol violation: Message missing recipient field');
    }

    // 🔑 Calculate message direction and conversation context BEFORE creating item
    final isOwnMessage = sender == _currentUserId;

    // 🔑 Calculate conversation context (who this message is with)
    // For own messages: conversation is with the recipient
    // For received messages: conversation is with the sender
    final conversationWith = isOwnMessage ? actualRecipient : sender;

    final item = {
      'itemId': itemId,
      'sender': sender,
      'senderDeviceId': senderDeviceId,
      'recipient': actualRecipient, // The actual conversation recipient
      'conversationWith':
          conversationWith, // ✨ NEW: Explicit conversation context
      'type': type,
      'message': message,
      'isOwnMessage': isOwnMessage, // ✨ NEW: Clear direction indicator
      // Keep originalRecipient for backward compatibility with read receipts
      if (originalRecipient != null) 'originalRecipient': originalRecipient,
    };

    if (originalRecipient != null) {
      debugPrint(
        "[SIGNAL SERVICE] Multi-device sync message - original recipient: $originalRecipient",
      );
    }

    // ✅ PHASE 3: Identify system messages for cleanup
    bool isSystemMessage = false;

    // Handle call notification type (cipherType 0 - unencrypted)
    if (type == 'call_notification') {
      debugPrint(
        '[SIGNAL SERVICE] Received call_notification - triggering callbacks',
      );

      // Trigger all registered callbacks for this type
      if (_itemTypeCallbacks.containsKey(type)) {
        final callbackItem = {
          'type': type,
          'payload': message, // Already decrypted (or plain for cipherType 0)
          'sender': sender,
          'itemId': itemId,
        };

        for (final callback in _itemTypeCallbacks[type]!) {
          try {
            debugPrint(
              '[SIGNAL SERVICE] Calling callback for call_notification',
            );
            callback(callbackItem);
          } catch (e) {
            debugPrint(
              '[SIGNAL SERVICE] Error in call_notification callback: $e',
            );
          }
        }
      } else {
        debugPrint(
          '[SIGNAL SERVICE] No callbacks registered for call_notification',
        );
      }

      isSystemMessage = true;
    }
    // Handle read_receipt type
    else if (type == 'read_receipt') {
      debugPrint(
        '[SIGNAL_SERVICE] receiveItem detected read_receipt type, calling _handleReadReceipt',
      );
      await _handleReadReceipt(item);
      isSystemMessage = true;
    } else if (type == 'senderKeyRequest') {
      // System message - will be handled by callbacks
      isSystemMessage = true;
    } else if (type == 'fileKeyRequest') {
      // System message - will be handled by callbacks
      isSystemMessage = true;
    } else if (type == 'delivery_receipt') {
      await _handleDeliveryReceipt(dataMap);
      isSystemMessage = true;
    } else if (type == 'meeting_e2ee_key_request') {
      // Meeting E2EE key request via 1-to-1 Signal message
      await _handleMeetingE2EEKeyRequest(item);
      isSystemMessage = true;
    } else if (type == 'meeting_e2ee_key_response') {
      // Meeting E2EE key response via 1-to-1 Signal message
      await _handleMeetingE2EEKeyResponse(item);
      isSystemMessage = true;
    } else if (type == 'system:session_reset') {
      // Session reset notification - save if it's due to recovery from errors
      // Parse the payload to check the reason
      try {
        final payloadData = jsonDecode(message) as Map<String, dynamic>;
        final reason = payloadData['reason'] as String?;

        if (reason == 'bad_mac_recovery' || reason == 'no_session_recovery') {
          // Session was recovered from an error - save it for user visibility
          // so both parties know the session was reset
          debugPrint(
            '[SIGNAL SERVICE] Session reset due to recovery ($reason) - will be saved for user visibility',
          );
          isSystemMessage = false; // Save and show to user
        } else {
          // Normal rotation or other reasons - don't show to user
          debugPrint(
            '[SIGNAL SERVICE] Session reset for routine maintenance - not showing to user',
          );
          isSystemMessage = true; // Don't save, just process
        }
      } catch (e) {
        // If we can't parse, treat as system message (don't show)
        debugPrint('[SIGNAL SERVICE] Could not parse session reset reason: $e');
        isSystemMessage = true;
      }
    }

    // ✅ Update unread count for non-system messages (only 'message' and 'file' types)
    // Only increment for messages from OTHER users, not own messages
    // (isOwnMessage already calculated above)
    if (!isSystemMessage && !isOwnMessage && _unreadMessagesProvider != null) {
      // Check if this is an activity notification type
      const activityTypes = {
        'emote',
        'mention',
        'missingcall',
        'addtochannel',
        'removefromchannel',
        'permissionchange',
      };

      if (activityTypes.contains(type)) {
        // Activity notification - increment activity counter
        _unreadMessagesProvider!.incrementActivityNotification(itemId);
        debugPrint(
          '[SIGNAL SERVICE] ✓ Activity notification (1:1): $type ($itemId)',
        );
      } else {
        // Regular 1:1 direct message from another user
        _unreadMessagesProvider!.incrementIfBadgeType(type, sender, false);
      }
    }

    // ✅ Emit EventBus event for new 1:1 message/item (after decryption)
    if (!isSystemMessage) {
      // Check if activity notification type
      const activityTypes = {
        'emote',
        'mention',
        'missingcall',
        'addtochannel',
        'removefromchannel',
        'permissionchange',
      };

      if (activityTypes.contains(type) && !isOwnMessage) {
        // Only emit notification for OTHER users' activity messages
        debugPrint(
          '[SIGNAL SERVICE] → EVENT_BUS: newNotification (1:1) - type=$type, sender=$sender',
        );

        // Add isOwnMessage flag
        final enrichedItem = {...item, 'isOwnMessage': isOwnMessage};

        EventBus.instance.emit(AppEvent.newNotification, enrichedItem);

        // IMPORTANT: Also handle emote messages to update reactions in the chat
        if (type == 'emote') {
          debugPrint('[SIGNAL SERVICE] Processing emote reaction for DM...');
          await _handleEmoteMessage(item, isGroupChat: false);
        }
      } else if (!activityTypes.contains(type)) {
        debugPrint(
          '[SIGNAL SERVICE] → EVENT_BUS: newMessage (1:1) - type=$type, sender=$sender, isOwnMessage=$isOwnMessage',
        );

        // Add isOwnMessage flag to item for UI to distinguish
        final enrichedItem = {...item, 'isOwnMessage': isOwnMessage};

        EventBus.instance.emit(AppEvent.newMessage, enrichedItem);

        // Handle emote messages (reactions) for DMs
        if (type == 'emote') {
          _handleEmoteMessage(item, isGroupChat: false);
        }

        // Emit newConversation event (views check if it's truly new)
        // ✅ Reuse conversationWith from item (already calculated above)
        EventBus.instance.emit(AppEvent.newConversation, {
          'conversationId': conversationWith,
          'isChannel': false,
          'isOwnMessage': isOwnMessage,
        });
      }
    }

    // ✅ PHASE 3: System messages already deleted from server above
    if (isSystemMessage) {
      // System messages should never be in SQLite (filtered by storage layer)
      debugPrint(
        "[SIGNAL SERVICE] ✓ System message processed: type=$type, itemId=$itemId",
      );

      // Don't trigger regular callbacks for system messages
      return;
    }

    // ✅ For session_reset recovery messages, trigger EventBus and callbacks
    // These are marked as non-system messages (isSystemMessage = false) when reason is recovery
    if (type == 'system:session_reset') {
      debugPrint(
        '[SIGNAL SERVICE] → EVENT_BUS: newMessage (session_reset) - sender=$sender',
      );

      // Emit newMessage event so UI shows the session reset notification
      EventBus.instance.emit(AppEvent.newMessage, {
        ...item,
        'isOwnMessage': isOwnMessage,
      });

      // Emit newConversation to update conversation list
      EventBus.instance.emit(AppEvent.newConversation, {
        'conversationId': conversationWith,
        'isChannel': false,
        'isOwnMessage': isOwnMessage,
      });
    }

    // Regular messages: Trigger callbacks
    if (cipherType != CiphertextMessage.whisperType &&
        _itemTypeCallbacks.containsKey(cipherType)) {
      for (final callback in _itemTypeCallbacks[cipherType]!) {
        callback(message);
      }
    }

    if (type != null && _itemTypeCallbacks.containsKey(type)) {
      for (final callback in _itemTypeCallbacks[type]!) {
        callback(item);
      }
    }

    // NEW: Trigger specific receiveItem callbacks (type:conversationWith)
    // ✅ Reuse conversationWith from item (already calculated above)
    if (type != null && conversationWith != null) {
      final key = '$type:$conversationWith';
      if (_receiveItemCallbacks.containsKey(key)) {
        for (final callback in _receiveItemCallbacks[key]!) {
          callback(item);
        }
        debugPrint(
          '[SIGNAL SERVICE] Triggered ${_receiveItemCallbacks[key]!.length} receiveItem callbacks for $key (conversationWith=$conversationWith, isOwnMessage=$isOwnMessage)',
        );
      }
    }

    // Note: Message already deleted from server at the start of this function
    debugPrint(
      "[SIGNAL SERVICE] ✓ Message processing complete for itemId: $itemId",
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

  /// Handle meeting E2EE key request (via 1-to-1 Signal message)
  /// Called when someone in the meeting requests the E2EE key from us
  Future<void> _handleMeetingE2EEKeyRequest(Map<String, dynamic> item) async {
    try {
      debugPrint('[SIGNAL SERVICE] 📨 Meeting E2EE key REQUEST received');
      debugPrint('[SIGNAL SERVICE] Item: $item');

      // Parse the decrypted message content
      final messageJson = jsonDecode(item['message'] as String);
      final meetingId = messageJson['meetingId'] as String?;
      final requesterId = messageJson['requesterId'] as String?;
      final timestamp = messageJson['timestamp'] as int?;

      debugPrint('[SIGNAL SERVICE] Meeting ID: $meetingId');
      debugPrint('[SIGNAL SERVICE] Requester: $requesterId');
      debugPrint('[SIGNAL SERVICE] Timestamp: $timestamp');

      if (meetingId == null || requesterId == null) {
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Missing meetingId or requesterId in key request',
        );
        return;
      }

      // Trigger registered callback for this meeting
      final callback = _meetingE2EEKeyRequestCallbacks[meetingId];
      if (callback != null) {
        callback({
          'meetingId': meetingId,
          'requesterId': requesterId,
          'senderId': item['sender'],
          'senderDeviceId': item['senderDeviceId'],
          'timestamp': timestamp,
        });
        debugPrint(
          '[SIGNAL SERVICE] ✓ Meeting E2EE key request callback triggered',
        );
      } else {
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ No callback registered for meeting: $meetingId',
        );
      }
    } catch (e, stack) {
      debugPrint(
        '[SIGNAL SERVICE] ❌ Error handling meeting E2EE key request: $e',
      );
      debugPrint('[SIGNAL SERVICE] Stack trace: $stack');
    }
  }

  /// Handle meeting E2EE key response (via 1-to-1 Signal message)
  /// Called when someone sends us the E2EE key for a meeting
  Future<void> _handleMeetingE2EEKeyResponse(Map<String, dynamic> item) async {
    try {
      debugPrint('[SIGNAL SERVICE] 🔑 Meeting E2EE key RESPONSE received');
      debugPrint('[SIGNAL SERVICE] Item: $item');

      // Parse the decrypted message content
      final messageJson = jsonDecode(item['message'] as String);
      final meetingId = messageJson['meetingId'] as String?;
      final encryptedKey = messageJson['encryptedKey'] as String?;
      final timestamp = messageJson['timestamp'] as int?;
      final targetUserId = messageJson['targetUserId'] as String?;

      debugPrint('[SIGNAL SERVICE] Meeting ID: $meetingId');
      debugPrint('[SIGNAL SERVICE] Target User: $targetUserId');
      debugPrint('[SIGNAL SERVICE] Timestamp: $timestamp');
      debugPrint(
        '[SIGNAL SERVICE] Key Length: ${encryptedKey?.length ?? 0} chars (base64)',
      );

      if (meetingId == null || encryptedKey == null || timestamp == null) {
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Missing required fields in key response',
        );
        return;
      }

      // Trigger registered callback for this meeting
      final callback = _meetingE2EEKeyResponseCallbacks[meetingId];
      if (callback != null) {
        callback({
          'meetingId': meetingId,
          'encryptedKey': encryptedKey,
          'timestamp': timestamp,
          'targetUserId': targetUserId,
          'senderId': item['sender'],
          'senderDeviceId': item['senderDeviceId'],
        });
        debugPrint(
          '[SIGNAL SERVICE] ✓ Meeting E2EE key response callback triggered',
        );
      } else {
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ No callback registered for meeting: $meetingId',
        );
      }
    } catch (e, stack) {
      debugPrint(
        '[SIGNAL SERVICE] ❌ Error handling meeting E2EE key response: $e',
      );
      debugPrint('[SIGNAL SERVICE] Stack trace: $stack');
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
    try {
      debugPrint(
        '[SIGNAL] Distributing sender key to guest $guestSessionId for meeting $meetingId',
      );

      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User info not set. Call setCurrentUserInfo first.');
      }

      // 1. Fetch guest's Signal keys
      final response = await ApiService.get(
        '/api/meetings/external/keys/$guestSessionId',
      );
      final keys = response.data as Map<String, dynamic>;

      final identityKeyPublic = keys['identityKeyPublic'] as String?;
      final signedPreKeyData = keys['signedPreKey'];
      final preKeyData = keys['preKey'];

      if (identityKeyPublic == null ||
          signedPreKeyData == null ||
          preKeyData == null) {
        throw Exception('Incomplete keys for guest $guestSessionId');
      }

      // Parse signed pre-key
      final signedPreKey = signedPreKeyData is String
          ? jsonDecode(signedPreKeyData)
          : signedPreKeyData as Map<String, dynamic>;

      final preKey = preKeyData is String
          ? jsonDecode(preKeyData)
          : preKeyData as Map<String, dynamic>;

      debugPrint('[SIGNAL] Fetched guest keys - preKeyId: ${preKey['id']}');

      // 2. Build PreKeyBundle
      final guestAddress = SignalProtocolAddress(
        guestSessionId,
        1,
      ); // Device 1 for guests

      final preKeyBytes = base64Decode(preKey['publicKey'] as String);
      final signedPreKeyBytes = base64Decode(
        signedPreKey['publicKey'] as String,
      );
      final identityKeyBytes = base64Decode(identityKeyPublic);

      final preKeyBundle = PreKeyBundle(
        0, // registrationId not used for external guests
        1, // deviceId
        preKey['id'] as int,
        Curve.decodePoint(preKeyBytes, 0),
        signedPreKey['id'] as int,
        Curve.decodePoint(signedPreKeyBytes, 0),
        base64Decode(signedPreKey['signature'] as String? ?? ''),
        IdentityKey(Curve.decodePoint(identityKeyBytes, 0)),
      );

      debugPrint('[SIGNAL] Built PreKeyBundle for guest');

      // 3. Establish session
      final sessionBuilder = SessionBuilder(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      await sessionBuilder.processPreKeyBundle(preKeyBundle);
      debugPrint('[SIGNAL] Session established with guest');

      // 4. Consume the pre-key on server
      try {
        await ApiService.post(
          '/api/meetings/external/session/$guestSessionId/consume-prekey',
          data: {'pre_key_id': preKey['id']},
        );
        debugPrint('[SIGNAL] Consumed pre-key ${preKey['id']}');
      } catch (e) {
        debugPrint('[SIGNAL] Warning: Failed to consume pre-key: $e');
        // Continue - session is established locally
      }

      // 5. Get meeting sender key
      final senderAddress = SignalProtocolAddress(
        _currentUserId!,
        _currentDeviceId!,
      );
      final senderKeyName = SenderKeyName(meetingId, senderAddress);

      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );
      if (!hasSenderKey) {
        throw Exception(
          'No sender key found for meeting $meetingId. Create sender key first.',
        );
      }

      final senderKeyRecord = await senderKeyStore.loadSenderKey(senderKeyName);
      final senderKeyBytes = senderKeyRecord.serialize();
      debugPrint(
        '[SIGNAL] Loaded sender key, size: ${senderKeyBytes.length} bytes',
      );

      // 6. Encrypt sender key for guest
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        guestAddress,
      );

      final encryptedSenderKey = await sessionCipher.encrypt(senderKeyBytes);
      final encryptedBase64 = base64Encode(encryptedSenderKey.serialize());

      debugPrint(
        '[SIGNAL] Encrypted sender key, type: ${encryptedSenderKey.getType()}',
      );

      // 7. Send via Socket.IO
      SocketService().emit('meeting:distributeSenderKeyToGuest', {
        'meetingId': meetingId,
        'guestSessionId': guestSessionId,
        'senderDeviceId': _currentDeviceId,
        'encryptedSenderKey': encryptedBase64,
        'messageType': encryptedSenderKey
            .getType(), // PreKey or Whisper message
      });

      debugPrint('[SIGNAL] Encrypted sender key sent to guest via Socket.IO');
    } catch (e, stack) {
      debugPrint('[SIGNAL] Error distributing key to guest: $e');
      debugPrint('[SIGNAL] Stack trace: $stack');
      rethrow;
    }
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
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final itemId = const Uuid().v4();
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

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, payloadJson);
      final timestampIso = DateTime.fromMillisecondsSinceEpoch(
        timestamp,
      ).toIso8601String();

      // Store locally first
      await sentGroupItemsStore.storeSentGroupItem(
        channelId: channelId,
        itemId: itemId,
        message: payloadJson,
        timestamp: timestampIso,
        type: 'file',
        status: 'sending',
      );

      // ALSO store in new SQLite database for performance
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.storeSentMessage(
          itemId: itemId,
          recipientId: channelId,
          channelId: channelId,
          message: payloadJson,
          timestamp: timestampIso,
          type: 'file',
        );
        debugPrint('[SIGNAL_SERVICE] Stored file message in SQLite');
      } catch (e) {
        debugPrint(
          '[SIGNAL_SERVICE] ✗ Failed to store file message in SQLite: $e',
        );
      }

      // Send via Socket.IO
      SocketService().emit("sendGroupItem", {
        'channelId': channelId,
        'itemId': itemId,
        'type': 'file',
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': timestampIso,
      });

      debugPrint(
        '[SIGNAL_SERVICE] Sent file message $itemId ($fileName) to channel $channelId',
      );
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending file message: $e');
      rethrow;
    }
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
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Create share update payload
      final shareUpdatePayload = {
        'fileId': fileId,
        'action': action,
        'affectedUserIds': affectedUserIds,
        'senderId': _currentUserId,
        'timestamp': timestamp,
        if (checksum != null) 'checksum': checksum, // ← NEW: Include checksum
        if (encryptedFileKey != null) 'encryptedFileKey': encryptedFileKey,
      };

      final payloadJson = jsonEncode(shareUpdatePayload);

      if (chatType == 'group') {
        // GROUP: Send via Sender Key
        final itemId = const Uuid().v4();
        final encrypted = await encryptGroupMessage(chatId, payloadJson);
        final timestampIso = DateTime.fromMillisecondsSinceEpoch(
          timestamp,
        ).toIso8601String();

        // Store locally
        await sentGroupItemsStore.storeSentGroupItem(
          channelId: chatId,
          itemId: itemId,
          message: payloadJson,
          timestamp: timestampIso,
          type: 'file_share_update',
          status: 'sending',
        );

        // Send via Socket.IO
        SocketService().emit("sendGroupItem", {
          'channelId': chatId,
          'itemId': itemId,
          'type': 'file_share_update',
          'payload': encrypted['ciphertext'],
          'cipherType': 4, // Sender Key
          'timestamp': timestampIso,
        });

        debugPrint(
          '[SIGNAL_SERVICE] Sent file share update ($action) to group $chatId',
        );
      } else if (chatType == 'direct') {
        // DIRECT: Send via Session encryption to each affected user
        for (final userId in affectedUserIds) {
          if (userId == _currentUserId) continue; // Skip self

          // Use sendItem to encrypt for all devices
          await sendItem(
            recipientUserId: userId,
            type: 'file_share_update',
            payload: payloadJson,
          );

          debugPrint(
            '[SIGNAL_SERVICE] Sent file share update ($action) to user $userId',
          );
        }
      } else {
        throw Exception('Invalid chatType: $chatType');
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending file share update: $e');
      rethrow;
    }
  }

  /// Send video E2EE key via Signal Protocol (Sender Key for groups, Session for direct)
  Future<void> sendVideoKey({
    required String channelId,
    required String chatType, // 'group' | 'direct'
    required List<int> encryptedKey, // AES-256 key (32 bytes)
    required List<String> recipientUserIds, // Users in the video call
  }) async {
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Convert key to base64 for JSON transport
      final keyBase64 = base64Encode(encryptedKey);

      // Create video key payload
      final videoKeyPayload = {
        'channelId': channelId,
        'key': keyBase64,
        'senderId': _currentUserId,
        'timestamp': timestamp,
        'type': 'video_e2ee_key',
      };

      final payloadJson = jsonEncode(videoKeyPayload);

      if (chatType == 'group') {
        // GROUP: Send via Sender Key
        final itemId = const Uuid().v4();
        final encrypted = await encryptGroupMessage(channelId, payloadJson);
        final timestampIso = DateTime.fromMillisecondsSinceEpoch(
          timestamp,
        ).toIso8601String();

        // Store locally
        await sentGroupItemsStore.storeSentGroupItem(
          channelId: channelId,
          itemId: itemId,
          message: payloadJson,
          timestamp: timestampIso,
          type: 'video_e2ee_key',
          status: 'sending',
        );

        // Send via Socket.IO
        SocketService().emit("sendGroupItem", {
          'channelId': channelId,
          'itemId': itemId,
          'type': 'video_e2ee_key',
          'payload': encrypted['ciphertext'],
          'cipherType': 4, // Sender Key
          'timestamp': timestampIso,
        });

        debugPrint('[SIGNAL_SERVICE] Sent video E2EE key to group $channelId');
      } else if (chatType == 'direct') {
        // DIRECT: Send via Session encryption to each recipient
        for (final userId in recipientUserIds) {
          if (userId == _currentUserId) continue; // Skip self

          // Use sendItem to encrypt for all devices
          await sendItem(
            recipientUserId: userId,
            type: 'video_e2ee_key',
            payload: payloadJson,
          );

          debugPrint('[SIGNAL_SERVICE] Sent video E2EE key to user $userId');
        }
      } else {
        throw Exception('Invalid chatType: $chatType');
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending video E2EE key: $e');
      rethrow;
    }
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
    // Create address for guest (using session ID as "user ID")
    final address = SignalProtocolAddress('guest_$guestSessionId', 0);

    // Check if session already exists
    if (await sessionStore.containsSession(address)) {
      debugPrint(
        '[SIGNAL SERVICE] ✓ Using existing guest session: $guestSessionId',
      );
      return address;
    }

    debugPrint(
      '[SIGNAL SERVICE] Creating new guest session, fetching keybundle...',
    );

    // Fetch guest's Signal keybundle from server
    final response = await ApiService.get(
      '/api/meetings/$meetingId/external/$guestSessionId/keys',
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch guest keybundle: ${response.statusCode}',
      );
    }

    final keybundle = response.data is String
        ? jsonDecode(response.data)
        : response.data;

    // Build PreKeyBundle
    final identityKey = IdentityKey(
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(keybundle['identity_key'])),
        0,
      ),
    );

    final signedPreKey = keybundle['signed_pre_key'];
    final oneTimePreKey = keybundle['one_time_pre_key'];

    final bundle = PreKeyBundle(
      0, // Registration ID (not used for guests)
      0, // Device ID
      oneTimePreKey != null ? oneTimePreKey['keyId'] : null,
      oneTimePreKey != null
          ? Curve.decodePoint(
              Uint8List.fromList(base64Decode(oneTimePreKey['publicKey'])),
              0,
            )
          : null,
      signedPreKey['keyId'],
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(signedPreKey['publicKey'])),
        0,
      ),
      Uint8List.fromList(base64Decode(signedPreKey['signature'])),
      identityKey,
    );

    // Process bundle to create session
    final sessionBuilder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      address,
    );

    await sessionBuilder.processPreKeyBundle(bundle);
    debugPrint('[SIGNAL SERVICE] ✓ Created new guest session: $guestSessionId');

    return address;
  }

  /// Get or create Signal session with participant (for guest → participant encryption)
  /// Fetches participant's keybundle from server and establishes session
  Future<SignalProtocolAddress> _getOrCreateParticipantSession({
    required String meetingId,
    required String participantUserId,
    required int participantDeviceId,
  }) async {
    // Create address for participant
    final address = SignalProtocolAddress(
      participantUserId,
      participantDeviceId,
    );

    // Check if session already exists
    if (await sessionStore.containsSession(address)) {
      debugPrint(
        '[SIGNAL SERVICE] ✓ Using existing participant session: $participantUserId:$participantDeviceId',
      );
      return address;
    }

    debugPrint(
      '[SIGNAL SERVICE] Creating new participant session, fetching keybundle...',
    );

    // For guests: we need sessionStorage-based fetch since we don't have authentication
    // The external_guest_socket_service.dart will need to inject sessionId/token
    final sessionId =
        ''; // TODO: Get from sessionStorage or ExternalParticipantService
    final response = await ApiService.get(
      '/api/meetings/external/$sessionId/participant/$participantUserId/$participantDeviceId/keys',
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch participant keybundle: ${response.statusCode}',
      );
    }

    final keybundle = response.data is String
        ? jsonDecode(response.data)
        : response.data;

    // Build PreKeyBundle
    final identityKey = IdentityKey(
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(keybundle['identity_key'])),
        0,
      ),
    );

    final signedPreKey = keybundle['signed_pre_key'];
    final oneTimePreKey = keybundle['one_time_pre_key'];

    final bundle = PreKeyBundle(
      0, // Registration ID
      participantDeviceId,
      oneTimePreKey != null ? oneTimePreKey['keyId'] : null,
      oneTimePreKey != null
          ? Curve.decodePoint(
              Uint8List.fromList(base64Decode(oneTimePreKey['publicKey'])),
              0,
            )
          : null,
      signedPreKey['keyId'],
      Curve.decodePoint(
        Uint8List.fromList(base64Decode(signedPreKey['publicKey'])),
        0,
      ),
      Uint8List.fromList(base64Decode(signedPreKey['signature'])),
      identityKey,
    );

    // Process bundle to create session
    final sessionBuilder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      address,
    );

    await sessionBuilder.processPreKeyBundle(bundle);
    debugPrint(
      '[SIGNAL SERVICE] ✓ Created new participant session: $participantUserId:$participantDeviceId',
    );

    return address;
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
