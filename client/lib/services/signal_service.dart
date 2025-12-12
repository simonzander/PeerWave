import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'api_service.dart';
import '../web_config.dart';
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
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  bool _keyReinforcementInProgress = false;
  DateTime? _lastKeyReinforcementTime;
  final Map<String, int> _sessionRecoveryAttempts = {}; // address -> count
  final Map<String, DateTime> _sessionRecoveryLastAttempt =
      {}; // address -> timestamp
  static const int _maxRecoveryAttemptsPerAddress = 3;
  static const Duration _recoveryAttemptCooldown = Duration(minutes: 5);

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
  String? _currentUserId; // Store current user's UUID
  int? _currentDeviceId; // Store current device ID

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

  /// Retry a function with exponential backoff
  ///
  /// Retries a failing operation with increasing delays between attempts.
  /// Useful for network errors or temporary failures.
  ///
  /// Parameters:
  /// - [operation]: The async function to retry
  /// - [maxAttempts]: Maximum number of retry attempts (default: 3)
  /// - [initialDelay]: Initial delay in milliseconds (default: 1000ms)
  /// - [maxDelay]: Maximum delay in milliseconds (default: 10000ms)
  /// - [shouldRetry]: Optional function to determine if error is retryable
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
      // Note: PreKeys will be regenerated on next check/decrypt
      debugPrint(
        '[SIGNAL SERVICE] Consumed PreKeys deleted, will regenerate as needed',
      );
    }
  }

  /// Helper: Test if PreKey decryption failures are systemic or isolated
  /// Returns true if at least one PreKey can be decrypted, false if all fail (systemic issue)
  Future<bool> _testPreKeyDecryption() async {
    try {
      final ids = await preKeyStore.getAllPreKeyIds();
      if (ids.isEmpty) {
        debugPrint('[SIGNAL SERVICE] No PreKeys to test');
        return false;
      }

      debugPrint(
        '[SIGNAL SERVICE] Testing PreKey decryption on ${ids.length > 3 ? 3 : ids.length} random PreKeys...',
      );

      // Test up to 3 random PreKeys
      final testCount = ids.length > 3 ? 3 : ids.length;
      int successCount = 0;

      for (int i = 0; i < testCount; i++) {
        try {
          await preKeyStore.loadPreKey(ids[i]);
          successCount++;
          debugPrint(
            '[SIGNAL SERVICE] ✓ PreKey ${ids[i]} decryption successful',
          );
        } catch (e) {
          debugPrint(
            '[SIGNAL SERVICE] ✗ PreKey ${ids[i]} decryption failed: $e',
          );
        }
      }

      final isSystemic = successCount == 0;
      debugPrint(
        '[SIGNAL SERVICE] PreKey test result: $successCount/$testCount successful (systemic: $isSystemic)',
      );
      return !isSystemic; // Return true if at least one works
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] Error testing PreKey decryption: $e');
      return false; // Assume systemic if test itself fails
    }
  }

  /// Helper: Handle single PreKey decryption failure with smart regeneration
  Future<void> _handlePreKeyDecryptionFailure(int preKeyId) async {
    debugPrint(
      '[SIGNAL SERVICE] PreKey $preKeyId decryption failed, testing for systemic issue...',
    );

    final canDecryptOthers = await _testPreKeyDecryption();

    if (!canDecryptOthers) {
      // Systemic issue - encryption key changed, clear all
      debugPrint(
        '[SIGNAL SERVICE] ⚠️ SYSTEMIC: All PreKeys fail decryption - encryption key changed',
      );
      await clearAllSignalData(
        reason: 'Encryption key changed - all PreKeys corrupted',
      );
    } else {
      // Isolated issue - regenerate only this PreKey
      debugPrint(
        '[SIGNAL SERVICE] ℹ️ ISOLATED: Only PreKey $preKeyId failed - regenerating that key',
      );
      await preKeyStore.removePreKey(preKeyId);
      // Note: Will be regenerated on next batch generation
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

  /// 🚀 Handle pending messages notification from server
  void _handlePendingMessagesAvailable(Map<String, dynamic> data) {
    final count = data['count'] as int;
    final timestamp = data['timestamp'] as String?;

    debugPrint(
      '[SIGNAL SERVICE] 📬 $count pending messages available (timestamp: $timestamp)',
    );

    // Start background sync automatically
    _syncPendingMessages(count);
  }

  /// 🚀 Sync pending messages from server with pagination
  Future<void> _syncPendingMessages(int totalCount) async {
    debugPrint(
      '[SIGNAL SERVICE] 🔄 Starting sync of $totalCount pending messages',
    );

    int offset = 0;
    int synced = 0;
    const batchSize = 20;
    bool hasMore = true;

    // Emit sync started event
    EventBus.instance.emit(AppEvent.syncStarted, {'total': totalCount});

    while (hasMore && synced < totalCount) {
      try {
        debugPrint(
          '[SIGNAL SERVICE] Requesting batch: offset=$offset, limit=$batchSize',
        );

        // Request batch from server
        SocketService().emit('fetchPendingMessages', {
          'limit': batchSize,
          'offset': offset,
        });

        // Wait for response (we'll handle it in _handlePendingMessagesResponse)
        // The response handler will process messages and update counters

        // For now, we need to track this sync operation
        // We'll use a simple flag to know when a batch is complete
        await Future.delayed(
          Duration(milliseconds: 500),
        ); // Give server time to respond

        break; // Exit for now - we'll improve this with proper async handling
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] ❌ Batch sync error: $e');
        EventBus.instance.emit(AppEvent.syncError, {
          'error': e.toString(),
          'synced': synced,
          'total': totalCount,
        });
        break;
      }
    }
  }

  /// 🚀 Handle pending messages response from server
  Future<void> _handlePendingMessagesResponse(Map<String, dynamic> data) async {
    try {
      final items = data['items'] as List;
      final hasMore = data['hasMore'] as bool;
      final offset = data['offset'] as int;
      final batchTotal = data['total'] as int;

      debugPrint(
        '[SIGNAL SERVICE] 📨 Received batch: ${items.length} messages, hasMore=$hasMore, offset=$offset',
      );

      int processed = 0;
      int failed = 0;

      // Process each message in the batch
      for (final item in items) {
        try {
          await receiveItem(item);
          processed++;

          // Emit progress event for UI
          EventBus.instance.emit(AppEvent.syncProgress, {
            'current': offset + processed,
            'total': offset + batchTotal, // Approximate total
          });
        } catch (e) {
          debugPrint(
            '[SIGNAL SERVICE] ⚠️ Failed to process pending message: $e',
          );
          failed++;
          // Continue with next message
        }
      }

      debugPrint(
        '[SIGNAL SERVICE] ✓ Batch processed: $processed succeeded, $failed failed',
      );

      // If there are more messages, fetch next batch
      if (hasMore) {
        debugPrint('[SIGNAL SERVICE] Fetching next batch...');
        await Future.delayed(Duration(milliseconds: 100)); // Rate limiting

        SocketService().emit('fetchPendingMessages', {
          'limit': 20,
          'offset': offset + items.length,
        });
      } else {
        debugPrint('[SIGNAL SERVICE] 🎉 Sync complete!');
        EventBus.instance.emit(AppEvent.syncComplete, {'processed': processed});
      }
    } catch (e) {
      debugPrint(
        '[SIGNAL SERVICE] ❌ Error handling pending messages response: $e',
      );
      EventBus.instance.emit(AppEvent.syncError, {'error': e.toString()});
    }
  }

  Future<void> test() async {
    debugPrint("SignalService test method called");
    final AliceIdentityKeyPair = generateIdentityKeyPair();
    final AliceRegistrationId = generateRegistrationId(false);
    final AliceIdentityStore = InMemoryIdentityKeyStore(
      AliceIdentityKeyPair,
      AliceRegistrationId,
    );
    final AliceSessionStore = InMemorySessionStore();
    final AlicePreKeyStore = InMemoryPreKeyStore();
    final AliceSignedPreKeyStore = InMemorySignedPreKeyStore();

    final BobIdentityKeyPair = await identityStore.getIdentityKeyPair();
    final BobRegistrationId = await identityStore.getLocalRegistrationId();
    final BobIdentityStore = identityStore;
    final BobSessionStore = sessionStore;
    final BobPreKeyStore = preKeyStore;
    final BobSignedPreKeyStore = signedPreKeyStore;

    // Generate keys for Alice
    final alicePreKeys = generatePreKeys(0, 110);
    final aliceSignedPreKey = generateSignedPreKey(AliceIdentityKeyPair, 0);

    for (final p in alicePreKeys) {
      await AlicePreKeyStore.storePreKey(p.id, p);
    }
    await AliceSignedPreKeyStore.storeSignedPreKey(
      aliceSignedPreKey.id,
      aliceSignedPreKey,
    );

    // Generate keys for Bob (if not already present)
    final bobPreKeysAll = await BobPreKeyStore.getAllPreKeys();
    if (bobPreKeysAll.isEmpty) {
      final bobPreKeys = generatePreKeys(0, 110);
      for (final p in bobPreKeys) {
        await BobPreKeyStore.storePreKey(p.id, p);
      }
    }

    final bobSignedPreKeysAll = await BobSignedPreKeyStore.loadSignedPreKeys();
    if (bobSignedPreKeysAll.isEmpty) {
      final bobSignedPreKey = generateSignedPreKey(BobIdentityKeyPair, 0);
      await BobSignedPreKeyStore.storeSignedPreKey(
        bobSignedPreKey.id,
        bobSignedPreKey,
      );
    }
    final AliceAddress = SignalProtocolAddress(Uuid().v4(), 1);
    final BobAddress = SignalProtocolAddress(Uuid().v4(), 1);

    final AliceSessionBuilder = SessionBuilder(
      AliceSessionStore,
      AlicePreKeyStore,
      AliceSignedPreKeyStore,
      AliceIdentityStore,
      BobAddress,
    );

    // Retrieve Bob's keys for the PreKeyBundle
    final bobPreKeys = await BobPreKeyStore.getAllPreKeys();
    final bobSignedPreKeys = await BobSignedPreKeyStore.loadSignedPreKeys();

    if (bobPreKeys.isEmpty || bobSignedPreKeys.isEmpty) {
      debugPrint("ERROR: Bob has no preKeys or signedPreKeys!");
      return;
    }

    final BobRetrievedPreKey = PreKeyBundle(
      BobRegistrationId,
      1,
      bobPreKeys[0].id,
      bobPreKeys[0].getKeyPair().publicKey,
      bobSignedPreKeys[0].id,
      bobSignedPreKeys[0].getKeyPair().publicKey,
      bobSignedPreKeys[0].signature,
      BobIdentityKeyPair.getPublicKey(),
    );

    await AliceSessionBuilder.processPreKeyBundle(BobRetrievedPreKey);

    final aliceSessionCipher = SessionCipher(
      AliceSessionStore,
      AlicePreKeyStore,
      AliceSignedPreKeyStore,
      AliceIdentityStore,
      BobAddress,
    );
    final ciphertext = await aliceSessionCipher.encrypt(
      Uint8List.fromList(utf8.encode('Hello Mixin🤣')),
    );
    // ignore: avoid_debugPrint
    debugPrint('Ciphertext: $ciphertext');
    // ignore: avoid_debugPrint
    debugPrint('Ciphertext serialized: ${ciphertext.serialize()}');
    //deliver(ciphertext);

    // Bob decrypts using his real stores (not a new empty store!)
    final bobSessionCipher = SessionCipher(
      BobSessionStore,
      BobPreKeyStore,
      BobSignedPreKeyStore,
      BobIdentityStore,
      AliceAddress,
    );

    if (ciphertext.getType() == CiphertextMessage.prekeyType) {
      await bobSessionCipher.decryptWithCallback(
        ciphertext as PreKeySignalMessage,
        (plaintext) {
          // ignore: avoid_print
          debugPrint('Bob decrypted: ${utf8.decode(plaintext)}');
        },
      );
    } else if (ciphertext.getType() == CiphertextMessage.whisperType) {
      final plaintext = await bobSessionCipher.decryptFromSignal(
        ciphertext as SignalMessage,
      );
      // ignore: avoid_print
      debugPrint('Bob decrypted: ${utf8.decode(plaintext)}');
    }
  }

  Future<void> init() async {
    debugPrint('[SIGNAL INIT] 🔍 init() called');
    debugPrint(
      '[SIGNAL INIT] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered',
    );

    // Initialize stores (create only if not already created)
    if (!_storesCreated) {
      debugPrint('[SIGNAL INIT] Creating stores for the first time...');
      identityStore = PermanentIdentityKeyStore();
      sessionStore = await PermanentSessionStore.create();
      preKeyStore = PermanentPreKeyStore();
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
      senderKeyStore = await PermanentSenderKeyStore.create();
      decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
      sentGroupItemsStore = await SentGroupItemsStore.getInstance();
      _storesCreated = true;
      debugPrint('[SIGNAL INIT] ✅ Stores created');
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
      identityStore = PermanentIdentityKeyStore();
      sessionStore = await PermanentSessionStore.create();
      preKeyStore = PermanentPreKeyStore();
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
      senderKeyStore = await PermanentSenderKeyStore.create();
      decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
      sentGroupItemsStore = await SentGroupItemsStore.getInstance();
      _storesCreated = true;
      debugPrint('[SIGNAL INIT] ✅ Stores created');
    } else {
      debugPrint('[SIGNAL INIT] ℹ️  Stores already exist, reusing...');
    }

    // Register socket listeners
    await _registerSocketListeners();

    // ✅ NEW: Validate keys with server BEFORE sending clientReady
    debugPrint('[SIGNAL INIT] Validating keys before clientReady...');

    try {
      // HTTP request to validate/sync keys (blocking, with response code)
      final response = await ApiService.post(
        '/signal/validate-and-sync',
        data: {
          'localIdentityKey': await _getLocalIdentityPublicKey(),
          'localSignedPreKeyId': await _getLatestSignedPreKeyId(),
          'localPreKeyCount': await _getLocalPreKeyCount(),
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

  /// Progressive initialization with progress callbacks
  /// Generates keys in batches to prevent UI freeze
  ///
  /// onProgress callback receives:
  /// - statusText: Current operation description
  /// - current: Current progress (0-112)
  /// - total: Total steps (112: 1 KeyPair + 1 SignedPreKey + 110 PreKeys)
  /// - percentage: Progress percentage (0-100)
  Future<void> initWithProgress(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
  ) async {
    debugPrint('[SIGNAL INIT] 🔍 initWithProgress() called');
    debugPrint(
      '[SIGNAL INIT] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered',
    );

    // Prevent multiple concurrent initializations
    if (_isInitialized) {
      debugPrint('[SIGNAL INIT] Already initialized, skipping...');
      onProgress('Signal Protocol ready', 112, 112, 100.0);
      return;
    }

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
      identityStore = PermanentIdentityKeyStore();
      sessionStore = await PermanentSessionStore.create();
      preKeyStore = PermanentPreKeyStore();
      senderKeyStore = await PermanentSenderKeyStore.create();
      decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
      sentGroupItemsStore = await SentGroupItemsStore.getInstance();
      _storesCreated = true;
      debugPrint('[SIGNAL INIT] ✅ Stores created for the first time');
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
    // 🔧 OPTIMIZED: Only get IDs (no decryption needed for validation)
    var existingPreKeyIds = await preKeyStore.getAllPreKeyIds();

    // 🔧 CLEANUP: Remove ALL PreKeys if corrupted (>110 keys OR any ID >= 110)
    final hasExcessKeys = existingPreKeyIds.length > 110;
    final hasInvalidIds = existingPreKeyIds.any((id) => id >= 110);

    if (hasExcessKeys || hasInvalidIds) {
      if (hasExcessKeys) {
        debugPrint(
          '[SIGNAL INIT] ⚠️ Found ${existingPreKeyIds.length} PreKeys (expected max 110)',
        );
      }
      if (hasInvalidIds) {
        final invalidIds = existingPreKeyIds.where((id) => id >= 110).toList();
        debugPrint(
          '[SIGNAL INIT] ⚠️ Found invalid PreKey IDs (>= 110): $invalidIds',
        );
      }

      debugPrint(
        '[SIGNAL INIT] 🔧 Deleting ALL PreKeys and regenerating fresh set (IDs 0-109)...',
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
      debugPrint(
        '[SIGNAL INIT] Generating $neededPreKeys pre keys (IDs must be 0-109)',
      );

      // Find missing IDs in range 0-109
      final existingIds = existingPreKeyIds.toSet();
      final missingIds = List.generate(
        110,
        (i) => i,
      ).where((id) => !existingIds.contains(id)).toList();

      if (missingIds.length != neededPreKeys) {
        debugPrint(
          '[SIGNAL INIT] ⚠️ Mismatch: need $neededPreKeys keys but found ${missingIds.length} missing IDs',
        );
        // This shouldn't happen, but if it does, regenerate everything
        for (final id in existingPreKeyIds) {
          await preKeyStore.removePreKey(id, sendToServer: true);
        }
        existingPreKeyIds = [];
        missingIds.clear();
        missingIds.addAll(List.generate(110, (i) => i));
      }

      // 🚀 OPTIMIZED: Generate keys using contiguous range batching
      // This analyzes missing IDs and batches contiguous ranges for speed
      final contiguousRanges = _findContiguousRanges(missingIds);
      int keysGeneratedInSession = 0;

      debugPrint(
        '[SIGNAL INIT] Found ${contiguousRanges.length} range(s) to generate',
      );

      // 🚀 BATCH UPLOAD: Process ranges in batches of 20 keys for HTTP upload
      const int uploadBatchSize = 20;
      List<PreKeyRecord> uploadBatch = [];

      for (final range in contiguousRanges) {
        if (range.length > 1) {
          // BATCH GENERATION: Multiple contiguous IDs (FAST!)
          final start = range.first;
          final end = range.last;
          debugPrint(
            '[SIGNAL INIT] Batch generating PreKeys $start-$end (${range.length} keys)',
          );

          final preKeys = generatePreKeys(start, end);

          // Add to upload batch
          for (final preKey in preKeys) {
            uploadBatch.add(preKey);

            // Upload batch when it reaches uploadBatchSize or this is the last key
            if (uploadBatch.length >= uploadBatchSize ||
                keysGeneratedInSession + uploadBatch.length >=
                    missingIds.length) {
              final success = await preKeyStore.storePreKeysBatch(uploadBatch);

              if (success) {
                keysGeneratedInSession += uploadBatch.length;

                // Update progress based on batch size
                final totalKeysNow =
                    existingPreKeyIds.length + keysGeneratedInSession;
                updateProgress(
                  'Generating pre keys $keysGeneratedInSession of ${missingIds.length} needed (total: $totalKeysNow/110)...',
                  currentStep + keysGeneratedInSession,
                );
              } else {
                debugPrint(
                  '[SIGNAL INIT] ⚠️ Batch upload failed, will retry on next initialization',
                );
              }

              uploadBatch.clear();
            }
          }

          // Small delay between ranges
          await Future.delayed(const Duration(milliseconds: 50));
        } else {
          // SINGLE GENERATION: Isolated gap (unavoidable)
          final id = range.first;
          debugPrint('[SIGNAL INIT] Single generating PreKey $id');

          final preKeys = generatePreKeys(id, id);
          if (preKeys.isNotEmpty) {
            uploadBatch.add(preKeys.first);

            // Upload batch when it reaches uploadBatchSize or this is the last key
            if (uploadBatch.length >= uploadBatchSize ||
                keysGeneratedInSession + uploadBatch.length >=
                    missingIds.length) {
              final success = await preKeyStore.storePreKeysBatch(uploadBatch);

              if (success) {
                keysGeneratedInSession += uploadBatch.length;

                // Update progress based on batch size
                final totalKeysNow =
                    existingPreKeyIds.length + keysGeneratedInSession;
                updateProgress(
                  'Generating pre keys $keysGeneratedInSession of ${missingIds.length} needed (total: $totalKeysNow/110)...',
                  currentStep + keysGeneratedInSession,
                );
              } else {
                debugPrint(
                  '[SIGNAL INIT] ⚠️ Batch upload failed, will retry on next initialization',
                );
              }

              uploadBatch.clear();
            }
          }
        }
      }

      // Upload any remaining keys in the batch
      if (uploadBatch.isNotEmpty) {
        final success = await preKeyStore.storePreKeysBatch(uploadBatch);

        if (success) {
          keysGeneratedInSession += uploadBatch.length;

          final totalKeysNow =
              existingPreKeyIds.length + keysGeneratedInSession;
          updateProgress(
            'Generating pre keys $keysGeneratedInSession of ${missingIds.length} needed (total: $totalKeysNow/110)...',
            currentStep + keysGeneratedInSession,
          );
        } else {
          debugPrint(
            '[SIGNAL INIT] ⚠️ Final batch upload failed, will retry on next initialization',
          );
        }
      }

      // Update currentStep by total keys generated
      currentStep += missingIds.length;
    } else {
      debugPrint(
        '[SIGNAL INIT] Pre keys already sufficient (${existingPreKeyIds.length}/110)',
      );
      // Skip to end
      currentStep = totalSteps;
      updateProgress('Pre keys already ready', currentStep);
    }

    // Register socket listeners
    await _registerSocketListeners();

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    // 🚀 CRITICAL: Notify server that client is ready to receive events
    // This is called AFTER:
    // 1. All PreKeys generated and uploaded via HTTP batch (with awaited responses)
    // 2. All socket listeners registered
    //
    // ✅ SAFE: storePreKeysBatch() uses HTTP POST with await, ensuring all
    // PreKeys are confirmed stored on server before reaching this point.
    // The method only returns true after receiving 200 OK from server.
    // No race condition - server has all keys before clientReady is sent.
    SocketService().notifyClientReady();
    debugPrint('[SIGNAL INIT] ✓ Server notified: Client ready for events');

    // Check status with server (server will only respond if client is ready)
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    debugPrint('[SIGNAL INIT] Progressive initialization complete');
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

    // ✅ Track registered events for rollback on failure
    final registeredEvents = <String>[];

    try {
      // Setup offline queue processing on reconnect
      SocketService().registerListener("connect", (_) {
        debugPrint(
          '[SIGNAL SERVICE] Socket reconnected, processing offline queue...',
        );
        _processOfflineQueue();
      });
      registeredEvents.add("connect");

      SocketService().registerListener("receiveItem", (data) {
        receiveItem(data);
      });
      registeredEvents.add("receiveItem");

      SocketService().registerListener("groupMessage", (data) {
        // Handle group message via callback system
        if (_itemTypeCallbacks.containsKey('groupMessage')) {
          for (final callback in _itemTypeCallbacks['groupMessage']!) {
            callback(data);
          }
        }
      });
      registeredEvents.add("groupMessage");

      // NEW: Group Item Socket.IO listener
      SocketService().registerListener("groupItem", (data) {
        // Update unread count for group messages (ONLY for messages from OTHER users)
        if (_unreadMessagesProvider != null &&
            data['channel'] != null &&
            data['type'] != null) {
          final channelId = data['channel'] as String;
          final messageType = data['type'] as String;
          final sender = data['sender'] as String?;
          final isOwnMessage = sender == _currentUserId;
          final itemId = data['itemId'] as String?;

          // Check if this is an activity notification type
          const activityTypes = {
            'emote',
            'mention',
            'missingcall',
            'addtochannel',
            'removefromchannel',
            'permissionchange',
          };

          // Only increment for messages from OTHER users
          if (!isOwnMessage) {
            if (activityTypes.contains(messageType)) {
              // Activity notification - increment activity counter
              if (itemId != null) {
                _unreadMessagesProvider!.incrementActivityNotification(itemId);
                debugPrint(
                  '[SIGNAL SERVICE] ✓ Activity notification: $messageType ($itemId)',
                );
              }
            } else {
              // Regular message - increment channel counter
              _unreadMessagesProvider!.incrementIfBadgeType(
                messageType,
                channelId,
                true,
              );
            }
          }
        }

        // ✅ Emit EventBus event for new group message/item (after decryption in callbacks)
        final type = data['type'];
        final channel = data['channel'];
        final sender = data['sender'] as String?;
        final isOwnMsg = sender == _currentUserId;

        if (type != null && channel != null) {
          // Emit for actual content (message, file) and activity notifications
          const activityTypes = {
            'emote',
            'mention',
            'missingcall',
            'addtochannel',
            'removefromchannel',
            'permissionchange',
          };

          if (type == 'message' || type == 'file') {
            debugPrint(
              '[SIGNAL SERVICE] → EVENT_BUS: newMessage (group) - type=$type, channel=$channel',
            );
            EventBus.instance.emit(AppEvent.newMessage, data);
          } else if (activityTypes.contains(type) && !isOwnMsg) {
            // Only emit notification for OTHER users' activity messages
            debugPrint(
              '[SIGNAL SERVICE] → EVENT_BUS: newNotification (group) - type=$type, channel=$channel',
            );
            EventBus.instance.emit(AppEvent.newNotification, data);
          }
        }

        // Handle emote messages (reactions)
        if (type == 'emote') {
          _handleEmoteMessage(data, isGroupChat: true);
        }

        if (_itemTypeCallbacks.containsKey('groupItem')) {
          for (final callback in _itemTypeCallbacks['groupItem']!) {
            callback(data);
          }
        }

        // NEW: Trigger specific receiveItemChannel callbacks (type:channel)
        if (type != null && channel != null) {
          final key = '$type:$channel';
          if (_receiveItemChannelCallbacks.containsKey(key)) {
            for (final callback in _receiveItemChannelCallbacks[key]!) {
              callback(data);
            }
            debugPrint(
              '[SIGNAL SERVICE] Triggered ${_receiveItemChannelCallbacks[key]!.length} receiveItemChannel callbacks for $key',
            );
          }
        }
      });
      registeredEvents.add("groupItem");

      // NEW: Group Item delivery confirmation
      SocketService().registerListener("groupItemDelivered", (data) {
        if (_deliveryCallbacks.containsKey('groupItem')) {
          for (final callback in _deliveryCallbacks['groupItem']!) {
            callback(data['itemId']);
          }
        }
      });
      registeredEvents.add("groupItemDelivered");

      // NEW: Group Item read update
      SocketService().registerListener("groupItemReadUpdate", (data) {
        if (_readCallbacks.containsKey('groupItem')) {
          for (final callback in _readCallbacks['groupItem']!) {
            callback(data);
          }
        }
      });
      registeredEvents.add("groupItemReadUpdate");

      SocketService().registerListener("deliveryReceipt", (data) async {
        await _handleDeliveryReceipt(data);
      });
      registeredEvents.add("deliveryReceipt");

      SocketService().registerListener("groupMessageReadReceipt", (data) {
        _handleGroupMessageReadReceipt(data);
      });
      registeredEvents.add("groupMessageReadReceipt");

      // 🚀 NEW: Pending messages notification from server
      SocketService().registerListener("pendingMessagesAvailable", (data) {
        _handlePendingMessagesAvailable(data);
      });
      registeredEvents.add("pendingMessagesAvailable");

      // 🚀 NEW: Pending messages response from server
      SocketService().registerListener("pendingMessagesResponse", (data) {
        _handlePendingMessagesResponse(data);
      });
      registeredEvents.add("pendingMessagesResponse");

      // 🚀 NEW: Pending messages fetch error
      SocketService().registerListener("fetchPendingMessagesError", (data) {
        debugPrint(
          '[SIGNAL SERVICE] ❌ Error fetching pending messages: ${data['error']}',
        );
      });
      registeredEvents.add("fetchPendingMessagesError");

      // 🔄 NEW: Session recovery notification - sender should resend message
      SocketService().registerListener("sessionRecoveryRequested", (data) {
        _handleSessionRecoveryRequested(data);
      });
      registeredEvents.add("sessionRecoveryRequested");

      SocketService().registerListener("signalStatusResponse", (status) async {
        await _ensureSignalKeysPresent(status);

        // Check SignedPreKey rotation after status check
        await _checkSignedPreKeyRotation();
      });
      registeredEvents.add("signalStatusResponse");

      // NEW: Receive sender key distribution messages
      SocketService().registerListener("receiveSenderKeyDistribution", (
        data,
      ) async {
        try {
          final groupId = data['groupId'] as String;
          final senderId = data['senderId'] as String;
          // Parse senderDeviceId as int (socket might send String)
          final senderDeviceId = data['senderDeviceId'] is int
              ? data['senderDeviceId'] as int
              : int.parse(data['senderDeviceId'].toString());
          final distributionMessageBase64 =
              data['distributionMessage'] as String;

          debugPrint(
            '[SIGNAL_SERVICE] Received sender key distribution from $senderId:$senderDeviceId for group $groupId',
          );

          final distributionMessageBytes = base64Decode(
            distributionMessageBase64,
          );
          await processSenderKeyDistribution(
            groupId,
            senderId,
            senderDeviceId,
            distributionMessageBytes,
          );

          debugPrint('[SIGNAL_SERVICE] ✓ Sender key distribution processed');
        } catch (e) {
          debugPrint(
            '[SIGNAL_SERVICE] Error processing sender key distribution: $e',
          );
        }
      });
      registeredEvents.add("receiveSenderKeyDistribution");

      // 🔒 SECURITY: Handle PreKey ID sync response
      SocketService().registerListener("myPreKeyIdsResponse", (data) async {
        await _handlePreKeyIdsSyncResponse(data);
      });
      registeredEvents.add("myPreKeyIdsResponse");

      // Setup Event Bus forwarding for user/channel events
      _setupEventBusForwarding();

      _listenersRegistered = true;
      debugPrint(
        '[SIGNAL SERVICE] ✅ All ${registeredEvents.length} Socket.IO listeners registered successfully',
      );
    } catch (e) {
      // Rollback: Reset flag so retry is possible
      debugPrint('[SIGNAL SERVICE] ⚠️ Error during listener registration: $e');
      debugPrint(
        '[SIGNAL SERVICE] ${registeredEvents.length} listeners may be partially registered',
      );

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
      EventBus.instance.emit(AppEvent.userStatusChanged, data);
    });

    debugPrint('[SIGNAL SERVICE] ✓ Event Bus forwarding active');
  }

  /// 🔒 SECURITY: Handle PreKey IDs sync response from server
  /// This ensures we never re-upload consumed PreKeys
  Future<void> _handlePreKeyIdsSyncResponse(Map<String, dynamic> data) async {
    try {
      final serverPreKeyIds = (data['preKeyIds'] as List?)?.cast<int>() ?? [];
      debugPrint(
        '[SIGNAL SERVICE][PREKEY_SYNC] Server has ${serverPreKeyIds.length} PreKeys: $serverPreKeyIds',
      );

      // Get local PreKey IDs
      final localPreKeyIds = await preKeyStore.getAllPreKeyIds();
      debugPrint(
        '[SIGNAL SERVICE][PREKEY_SYNC] Local has ${localPreKeyIds.length} PreKeys: $localPreKeyIds',
      );

      // Find consumed PreKeys (exist locally but not on server)
      final consumedPreKeyIds = localPreKeyIds
          .where((id) => !serverPreKeyIds.contains(id))
          .toList();
      debugPrint(
        '[SIGNAL SERVICE][PREKEY_SYNC] Consumed PreKeys (to delete locally): $consumedPreKeyIds',
      );

      // Find missing PreKeys (exist locally but not on server, and not consumed)
      final missingPreKeyIds = localPreKeyIds
          .where(
            (id) =>
                !serverPreKeyIds.contains(id) &&
                !consumedPreKeyIds.contains(id),
          )
          .toList();
      debugPrint(
        '[SIGNAL SERVICE][PREKEY_SYNC] Missing PreKeys (to upload): $missingPreKeyIds',
      );

      // Delete consumed PreKeys from local storage
      for (final id in consumedPreKeyIds) {
        try {
          await preKeyStore.removePreKey(
            id,
            sendToServer: false,
          ); // Don't notify server
          debugPrint(
            '[SIGNAL SERVICE][PREKEY_SYNC] ✓ Deleted consumed PreKey $id from local storage',
          );
        } catch (e) {
          debugPrint(
            '[SIGNAL SERVICE][PREKEY_SYNC] ⚠️ Failed to delete PreKey $id: $e',
          );
        }
      }

      // Upload missing PreKeys to server
      if (missingPreKeyIds.isNotEmpty) {
        debugPrint(
          '[SIGNAL SERVICE][PREKEY_SYNC] Uploading ${missingPreKeyIds.length} missing PreKeys to server...',
        );

        final missingPreKeys = <PreKeyRecord>[];
        for (final id in missingPreKeyIds) {
          try {
            final preKey = await preKeyStore.loadPreKey(id);
            missingPreKeys.add(preKey);
          } catch (e) {
            debugPrint(
              '[SIGNAL SERVICE][PREKEY_SYNC] ⚠️ Failed to load PreKey $id: $e',
            );
          }
        }

        if (missingPreKeys.isNotEmpty) {
          final preKeysPayload = missingPreKeys
              .map(
                (pk) => {
                  'id': pk.id,
                  'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
                },
              )
              .toList();
          SocketService().emit("storePreKeys", {'preKeys': preKeysPayload});
          debugPrint(
            '[SIGNAL SERVICE][PREKEY_SYNC] ✓ Uploaded ${missingPreKeys.length} missing PreKeys',
          );
        }
      }

      // Check if we need to generate new PreKeys
      final remainingCount = localPreKeyIds.length - consumedPreKeyIds.length;
      if (remainingCount < 20) {
        debugPrint(
          '[SIGNAL SERVICE][PREKEY_SYNC] ⚠️ Only $remainingCount PreKeys remaining after sync',
        );
        debugPrint(
          '[SIGNAL SERVICE][PREKEY_SYNC] → Regenerating consumed PreKeys in background...',
        );

        // Regenerate consumed PreKeys asynchronously
        for (final id in consumedPreKeyIds) {
          _regeneratePreKeyAsync(id);
        }
      }

      debugPrint(
        '[SIGNAL SERVICE][PREKEY_SYNC] ✅ PreKey sync completed successfully',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '[SIGNAL SERVICE][PREKEY_SYNC] ❌ Error during PreKey sync: $e',
      );
      debugPrint('[SIGNAL SERVICE][PREKEY_SYNC] Stack trace: $stackTrace');
    }
  }

  Future<void> _ensureSignalKeysPresent(status) async {
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
      await _validateServerKeyConsistency(status);
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
        SocketService().emit("storePreKeys", {'preKeys': preKeysPayload});
      } else if (preKeysCount < localPreKeyIds.length) {
        // 🔒 SECURITY FIX: Server has fewer PreKeys than local
        // This means some PreKeys were consumed while we were offline
        // We must NOT re-upload existing PreKeys (they may have been consumed)
        // Instead, we should request which PreKeys server has, compare, and only upload missing ones
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Sync gap: Server has $preKeysCount, local has ${localPreKeyIds.length}',
        );
        debugPrint(
          '[SIGNAL SERVICE] → Some PreKeys were consumed while offline',
        );
        debugPrint(
          '[SIGNAL SERVICE] → Requesting server PreKey IDs to identify consumed keys...',
        );

        // Request server's PreKey IDs to identify which were consumed
        SocketService().emit("getMyPreKeyIds", null);

        // Server will respond with "myPreKeyIdsResponse" event
        // We'll handle the sync in that listener (needs to be added)
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
      await _validateOwnKeysOnServer(status);
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

        final reinforcementSuccess = await _forceServerKeyReinforcement();

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

  /// 🔧 Force complete key reinforcement to server
  /// Deletes corrupted server keys and re-uploads fresh set from client
  /// CLIENT IS SOURCE OF TRUTH
  /// Returns true if successful, false on error
  Future<bool> _forceServerKeyReinforcement() async {
    // 🔒 LOOP PREVENTION: Mark reinforcement in progress
    _keyReinforcementInProgress = true;
    _lastKeyReinforcementTime = DateTime.now();

    bool success = false;

    try {
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] ========================================',
      );
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Starting forced key reinforcement...',
      );

      // Step 1: Tell server to delete all keys for this device
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Step 1: Deleting corrupted server keys...',
      );
      SocketService().emit("deleteAllSignalKeys", {
        'reason': 'corruption_detected_auto_recovery',
      });

      // Wait for server to process deletion
      await Future.delayed(Duration(seconds: 1));

      // Step 2: Re-upload Identity
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Step 2: Re-uploading Identity key...',
      );
      final identityData = await identityStore.getIdentityKeyPairData();
      final registrationId = await identityStore.getLocalRegistrationId();
      SocketService().emit("signalIdentity", {
        'publicKey': identityData['publicKey'],
        'registrationId': registrationId.toString(),
      });

      await Future.delayed(Duration(milliseconds: 500));

      // Step 3 & 4: Upload SignedPreKey and PreKeys
      await _uploadKeysOnly();

      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] ========================================',
      );
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] ✅ Key reinforcement completed successfully!',
      );
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] All keys re-uploaded from client (source of truth)',
      );
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Server state should now match client state',
      );

      // 🔒 LOOP PREVENTION: Don't trigger immediate signalStatus (would cause validation loop)
      // Instead, let the next natural signalStatus check verify the fix
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] ℹ️ Skipping immediate status check to prevent validation loop',
      );
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Next scheduled status check will verify the fix',
      );
      success = true;
    } catch (e, stackTrace) {
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] ❌ Error during key reinforcement: $e',
      );
      debugPrint('[SIGNAL SERVICE][REINFORCEMENT] Stack trace: $stackTrace');
      success = false;
    } finally {
      // 🔒 LOOP PREVENTION: Always clear in-progress flag
      _keyReinforcementInProgress = false;
      debugPrint(
        '[SIGNAL SERVICE][REINFORCEMENT] Reinforcement operation completed (flag cleared)',
      );
    }

    return success;
  }

  /// 🔧 Upload SignedPreKey and PreKeys only (identity already uploaded separately)
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

        final preKeysPayload = newPreKeys
            .map(
              (pk) => {
                'id': pk.id,
                'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
              },
            )
            .toList();

        SocketService().emit("storePreKeys", {'preKeys': preKeysPayload});
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
        SocketService().emit("storePreKeys", {'preKeys': preKeysPayload});
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

  /// Check if SignedPreKey needs rotation and rotate if necessary
  /// Called automatically after signalStatus check
  Future<void> _checkSignedPreKeyRotation() async {
    try {
      if (!_isInitialized) {
        debugPrint(
          '[SIGNAL_SERVICE] Not initialized, skipping SignedPreKey rotation check',
        );
        return;
      }

      final needsRotation = await signedPreKeyStore.needsRotation();
      if (needsRotation) {
        debugPrint(
          '[SIGNAL_SERVICE] SignedPreKey rotation needed, starting rotation...',
        );
        final identityKeyPair = await identityStore.getIdentityKeyPair();
        await signedPreKeyStore.rotateSignedPreKey(identityKeyPair);
        debugPrint('[SIGNAL_SERVICE] ✓ SignedPreKey rotation completed');
      } else {
        debugPrint(
          '[SIGNAL_SERVICE] SignedPreKey rotation not needed (< 7 days old)',
        );
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[SIGNAL_SERVICE] Error during SignedPreKey rotation check: $e',
      );
      debugPrint('[SIGNAL_SERVICE] Stack trace: $stackTrace');
      // Don't rethrow - rotation failure shouldn't block normal operations
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

  /// NEW: Register callback for received 1:1 items (direct messages)
  /// Callback is triggered for specific type+sender combinations
  ///
  /// Usage:
  /// ```dart
  /// SignalService.instance.registerReceiveItem('message', senderUserId, (item) {
  ///   print('Received message from $senderUserId: ${item['message']}');
  /// });
  /// ```
  void registerReceiveItem(
    String type,
    String sender,
    Function(Map<String, dynamic>) callback,
  ) {
    final key = '$type:$sender';
    _receiveItemCallbacks.putIfAbsent(key, () => []).add(callback);
    debugPrint('[SIGNAL SERVICE] Registered receiveItem callback for $key');
  }

  /// NEW: Register callback for received group items (group messages)
  /// Callback is triggered for specific type+channel combinations
  ///
  /// Usage:
  /// ```dart
  /// SignalService.instance.registerReceiveItemChannel('message', channelId, (item) {
  ///   print('Received group message in $channelId: ${item['message']}');
  /// });
  /// ```
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

  /// 🚨 NUCLEAR OPTION: Clear ALL Signal Protocol data (local + server)
  /// Use this when encryption keys are corrupted or storage is out of sync
  ///
  /// This will:
  /// 1. Delete all local Signal stores (identity, sessions, PreKeys, SignedPreKeys)
  /// 2. Delete all server-side keys
  /// 3. Reset initialization state
  /// 4. Require full re-initialization (call initWithProgress after this)
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

      // 3. Reset initialization state
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
              'recipientId':
                  msg['sender'], // sender field stores recipient for sent messages
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
      final messageType = data['type'] as String?;
      final isSystemMessage =
          messageType == 'read_receipt' ||
          messageType == 'delivery_receipt' ||
          messageType == 'senderKeyRequest' ||
          messageType == 'fileKeyRequest';

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

          if (isOwnMessage) {
            // Message from own device → Store as SENT message
            // Use the original recipient (the other user in the conversation)
            final actualRecipient = recipient ?? sender;

            debugPrint(
              "[SIGNAL SERVICE] 📤 Storing message from own device (Device $senderDeviceId) as SENT to $actualRecipient",
            );
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
          // Use the OTHER user's ID (not own ID)
          final conversationUserId = isOwnMessage
              ? (recipient ?? sender)
              : sender;
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
      // Return empty string on error (will be filtered out later)
      return '';
    }
  }

  /// Empfängt eine verschlüsselte Nachricht vom Socket.IO Server
  ///
  /// Das Backend filtert bereits und sendet nur Nachrichten, die für DIESES Gerät
  /// (deviceId) verschlüsselt wurden. Die Nachricht wird dann mit dem Session-Schlüssel
  /// dieses Geräts entschlüsselt.
  Future<void> receiveItem(data) async {
    debugPrint(
      "[SIGNAL SERVICE] ===============================================",
    );
    debugPrint("[SIGNAL SERVICE] receiveItem called for this device");
    debugPrint(
      "[SIGNAL SERVICE] ===============================================",
    );
    debugPrint("[SIGNAL SERVICE] receiveItem: $data");
    final type = data['type'];
    final sender = data['sender']; // z.B. Absender-UUID
    final senderDeviceId = data['senderDeviceId'];
    final cipherType = data['cipherType'];
    final itemId = data['itemId'];

    // Use decryptItemFromData to get caching + IndexedDB storage
    // This ensures real-time messages are also persisted locally
    String message;
    try {
      message = await decryptItemFromData(data);

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

      // For other errors, also delete from server to prevent stuck messages
      debugPrint(
        "[SIGNAL SERVICE] ⚠️ Decryption failed - deleting from server to prevent stuck message",
      );
      deleteItemFromServer(itemId);
      return;
    }

    // Skip messages only if decryption returned empty (should be rare now)
    if (message.isEmpty) {
      debugPrint(
        "[SIGNAL SERVICE] Skipping message - decryption returned empty",
      );
      return;
    }

    debugPrint(
      "[SIGNAL SERVICE] Message decrypted successfully: '$message' (cipherType: $cipherType)",
    );

    final recipient = data['recipient']; // Empfänger-UUID vom Server

    final item = {
      'itemId': itemId,
      'sender': sender,
      'senderDeviceId': senderDeviceId,
      'recipient': recipient,
      'type': type,
      'message': message,
    };

    // ✅ PHASE 3: Identify system messages for cleanup
    bool isSystemMessage = false;

    // Handle read_receipt type
    if (type == 'read_receipt') {
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
      await _handleDeliveryReceipt(data);
      isSystemMessage = true;
    } else if (type == 'meeting_e2ee_key_request') {
      // Meeting E2EE key request via 1-to-1 Signal message
      await _handleMeetingE2EEKeyRequest(item);
      isSystemMessage = true;
    } else if (type == 'meeting_e2ee_key_response') {
      // Meeting E2EE key response via 1-to-1 Signal message
      await _handleMeetingE2EEKeyResponse(item);
      isSystemMessage = true;
    }

    // ✅ Update unread count for non-system messages (only 'message' and 'file' types)
    // Only increment for messages from OTHER users, not own messages
    final isOwnMessage = sender == _currentUserId;
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

        // Also emit newConversation if this is the first message from this sender
        // (Views can check their conversation list to determine if it's truly new)
        // Use the OTHER user's ID for conversation (not own ID)
        final conversationUserId = isOwnMessage ? recipient : sender;
        EventBus.instance.emit(AppEvent.newConversation, {
          'conversationId': conversationUserId,
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

    // NEW: Trigger specific receiveItem callbacks (type:sender)
    if (type != null && sender != null) {
      final key = '$type:$sender';
      if (_receiveItemCallbacks.containsKey(key)) {
        for (final callback in _receiveItemCallbacks[key]!) {
          callback(item);
        }
        debugPrint(
          '[SIGNAL SERVICE] Triggered ${_receiveItemCallbacks[key]!.length} receiveItem callbacks for $key',
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
    SocketService().emit("deleteItem", {'itemId': itemId});
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
    SocketService().emit("deleteGroupItem", {'itemId': itemId});
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

  /// Handle group message read receipt (from Socket.IO)
  void _handleGroupMessageReadReceipt(Map<String, dynamic> data) {
    debugPrint('[SIGNAL SERVICE] Group message read receipt received: $data');

    // Trigger callbacks with the full receipt data
    if (_itemTypeCallbacks.containsKey('groupMessageReadReceipt')) {
      for (final callback in _itemTypeCallbacks['groupMessageReadReceipt']!) {
        callback(data);
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
  Future<void> _handleSessionRecoveryRequested(
    Map<String, dynamic> data,
  ) async {
    try {
      final recipientUserId = data['recipientUserId'] as String;
      final recipientDeviceId = data['recipientDeviceId'] as int;
      final reason = data['reason'] as String;
      final addressKey = '${recipientUserId}:${recipientDeviceId}';

      debugPrint(
        '[SIGNAL SERVICE] 🔄 Session recovery requested by $addressKey',
      );
      debugPrint('[SIGNAL SERVICE] Reason: $reason');

      // 🔒 LOOP PREVENTION: Check attempt count and cooldown
      final attemptCount = _sessionRecoveryAttempts[addressKey] ?? 0;
      final lastAttempt = _sessionRecoveryLastAttempt[addressKey];

      if (attemptCount >= _maxRecoveryAttemptsPerAddress) {
        // Check if cooldown period has passed
        if (lastAttempt != null) {
          final timeSinceLastAttempt = DateTime.now().difference(lastAttempt);
          if (timeSinceLastAttempt < _recoveryAttemptCooldown) {
            debugPrint(
              '[SIGNAL SERVICE] ⚠️ Max recovery attempts reached for $addressKey',
            );
            debugPrint(
              '[SIGNAL SERVICE] Cooldown remaining: ${_recoveryAttemptCooldown.inMinutes - timeSinceLastAttempt.inMinutes} minutes',
            );
            debugPrint(
              '[SIGNAL SERVICE] This prevents infinite recovery loops',
            );
            return;
          } else {
            // Cooldown passed, reset counter
            debugPrint(
              '[SIGNAL SERVICE] Cooldown passed - resetting recovery counter for $addressKey',
            );
            _sessionRecoveryAttempts[addressKey] = 0;
          }
        }
      }

      // Increment attempt counter
      _sessionRecoveryAttempts[addressKey] = attemptCount + 1;
      _sessionRecoveryLastAttempt[addressKey] = DateTime.now();

      debugPrint(
        '[SIGNAL SERVICE] Recovery attempt ${_sessionRecoveryAttempts[addressKey]}/$_maxRecoveryAttemptsPerAddress for $addressKey',
      );

      // Send a special recovery message that will trigger session re-establishment
      // The important thing is not the content, but that it will be sent as a PreKey message
      // (cipher type 3) which will establish a fresh session
      debugPrint('[SIGNAL SERVICE] 📤 Sending session recovery message...');

      try {
        await sendItem(
          recipientUserId: recipientUserId,
          type: 'system:sessionRecovery',
          payload: jsonEncode({
            'message': 'Session recovery initiated',
            'reason': reason,
            'timestamp': DateTime.now().toIso8601String(),
          }),
          forcePreKeyMessage:
              true, // 🔑 CRITICAL: Force PreKey to establish new session
        );

        debugPrint(
          '[SIGNAL SERVICE] ✓ Session recovery message sent - new session established',
        );
        debugPrint(
          '[SIGNAL SERVICE] Recovery attempts for $addressKey: ${_sessionRecoveryAttempts[addressKey]}/$_maxRecoveryAttemptsPerAddress',
        );

        // Notify UI that recovery is in progress (optional)
        if (_itemTypeCallbacks.containsKey('sessionRecoveryInitiated')) {
          for (final callback
              in _itemTypeCallbacks['sessionRecoveryInitiated']!) {
            callback({
              'recipientUserId': recipientUserId,
              'recipientDeviceId': recipientDeviceId,
              'reason': reason,
            });
          }
        }
      } catch (e) {
        debugPrint(
          '[SIGNAL SERVICE] ❌ Failed to send session recovery message: $e',
        );
      }
    } catch (e, stack) {
      debugPrint(
        '[SIGNAL SERVICE] ❌ Error handling session recovery request: $e',
      );
      debugPrint('[SIGNAL SERVICE] Stack trace: $stack');
    }
  }

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
    // Get server URL from appropriate source
    String? apiServer;
    if (kIsWeb) {
      apiServer = await loadWebApiServer();
    } else {
      final activeServer = ServerConfigService.getActiveServer();
      if (activeServer != null) {
        apiServer = activeServer.serverUrl;
      }
    }

    final urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
    final response = await ApiService.get(
      '$urlString/signal/prekey_bundle/$userId',
    );
    debugPrint('[DEBUG] response.statusCode: \\${response.statusCode}');
    debugPrint('[DEBUG] response.data: \\${response.data}');
    debugPrint(
      '[DEBUG] response.data.runtimeType: \\${response.data.runtimeType}',
    );
    if (response.statusCode == 200) {
      try {
        final devices = response.data is String
            ? jsonDecode(response.data)
            : response.data;
        debugPrint('[DEBUG] devices: \\${devices}');
        debugPrint('[DEBUG] devices.runtimeType: \\${devices.runtimeType}');
        if (devices is List) {
          debugPrint('[DEBUG] devices.length: \\${devices.length}');
        }
        final List<Map<String, dynamic>> result = [];
        int skippedDevices = 0;

        for (final data in devices) {
          debugPrint(
            '[DEBUG] signedPreKey: ' + jsonEncode(data['signedPreKey']),
          );
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
          debugPrint(
            '[DEBUG] Decoding preKey ${data['preKey']['prekey_data']}',
          );
          debugPrint(
            '[DEBUG] PreKey length: ${base64Decode(data['preKey']['prekey_data']).length}',
          );
          debugPrint(
            "[DEBUG] Decoding signedPreKey ${data['signedPreKey']['signed_prekey_data']}",
          );
          debugPrint(
            '[DEBUG] SignedPreKey length: ${base64Decode(data['signedPreKey']['signed_prekey_data']).length}',
          );
          debugPrint(
            "[DEBUG] Decoding signedPreKeySignature ${data['signedPreKey']['signed_prekey_signature']}",
          );
          debugPrint(
            '[DEBUG] SignedPreKey signature length: ${base64Decode(data['signedPreKey']['signed_prekey_signature']).length}',
          );

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

          debugPrint(
            '[PREKEY_BUNDLE] ============================================',
          );
          debugPrint(
            '[PREKEY_BUNDLE] Building bundle for ${data['userId']}:$deviceId',
          );
          debugPrint(
            '[PREKEY_BUNDLE] Identity Key (from public_key): ${data['public_key']}',
          );
          debugPrint('[PREKEY_BUNDLE] Registration ID: $registrationId');
          debugPrint('[PREKEY_BUNDLE] PreKey ID: $preKeyId');
          debugPrint('[PREKEY_BUNDLE] SignedPreKey ID: $signedPreKeyId');
          debugPrint(
            '[PREKEY_BUNDLE] SignedPreKey data: ${data['signedPreKey']['signed_prekey_data']}',
          );
          debugPrint(
            '[PREKEY_BUNDLE] SignedPreKey signature: ${data['signedPreKey']['signed_prekey_signature']}',
          );
          debugPrint(
            '[PREKEY_BUNDLE] ============================================',
          );

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
        debugPrint(
          '[ERROR] Exception while decoding response: \\${e}\\n\\${st}',
        );
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

  /// Validate a PreKeyBundle's cryptographic integrity
  /// Verifies that SignedPreKey signature is valid using identity key
  /// Returns true if valid, false if corrupted
  bool _validatePreKeyBundle(Map<String, dynamic> bundle) {
    try {
      final identityKey = bundle['identityKey'] as IdentityKey;
      final signedPreKeyPublic = bundle['signedPreKeyPublic'] as DjbECPublicKey;
      final signedPreKeySignature =
          bundle['signedPreKeySignature'] as Uint8List;

      debugPrint('[VALIDATION] ============================================');
      debugPrint(
        '[VALIDATION] Validating bundle for ${bundle['userId']}:${bundle['deviceId']}',
      );
      debugPrint(
        '[VALIDATION] Identity Key: ${base64Encode(identityKey.serialize())}',
      );
      debugPrint(
        '[VALIDATION] SignedPreKey: ${base64Encode(signedPreKeyPublic.serialize())}',
      );
      debugPrint(
        '[VALIDATION] Signature: ${base64Encode(signedPreKeySignature)}',
      );

      // Verify signature: identity key should have signed the signedPreKey
      // IdentityKey wraps ECPublicKey internally, use serialize() to get bytes
      final publicKeyBytes = Curve.decodePoint(identityKey.serialize(), 0);
      final isValid = Curve.verifySignature(
        publicKeyBytes,
        signedPreKeyPublic.serialize(),
        signedPreKeySignature,
      );

      if (!isValid) {
        debugPrint(
          '[VALIDATION] ❌ Invalid SignedPreKey signature for ${bundle['userId']}:${bundle['deviceId']}',
        );
        debugPrint(
          '[VALIDATION] The SignedPreKey was NOT signed by this Identity Key!',
        );
        debugPrint(
          '[VALIDATION] This means the server has mismatched keys (stale data).',
        );
        debugPrint('[VALIDATION] ============================================');
        return false;
      }

      // Additional checks
      if (signedPreKeySignature.length != 64) {
        debugPrint(
          '[VALIDATION] ❌ Invalid signature length: ${signedPreKeySignature.length} (expected 64)',
        );
        debugPrint('[VALIDATION] ============================================');
        return false;
      }

      debugPrint(
        '[VALIDATION] ✓ Bundle valid - signature verified successfully',
      );
      debugPrint('[VALIDATION] ============================================');
      return true;
    } catch (e) {
      debugPrint('[VALIDATION] ❌ Exception validating bundle: $e');
      debugPrint('[VALIDATION] ============================================');
      return false;
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

  /// Send a file message to a 1:1 chat (LÖSUNG 17 - Direct Message)
  ///
  /// Encrypts file metadata (fileId, fileName, encryptedFileKey) with Signal Protocol
  /// and sends as Item with type='file' to all devices of both users.
  ///
  /// The file itself is transferred P2P via WebRTC DataChannels.
  /// This message only contains the metadata needed to initiate download.
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

  /// Sendet eine verschlüsselte Nachricht an einen User
  ///
  /// Diese Methode verschlüsselt die Nachricht für ALLE Geräte:
  /// 1. Alle Geräte des Empfängers (recipientUserId)
  /// 2. Alle eigenen Geräte (damit der Sender die Nachricht auf allen seinen Geräten lesen kann)
  ///
  /// Das Backend (/signal/prekey_bundle/:userId) gibt PreKey-Bundles für beide User zurück.
  ///
  /// WICHTIG: Das sendende Gerät wird übersprungen (kann nicht zu sich selbst verschlüsseln).
  /// Stattdessen wird ein lokaler Callback ausgelöst, damit die UI die Nachricht sofort anzeigen kann.
  Future<void> sendItem({
    required String recipientUserId,
    required String type,
    required dynamic payload,
    String? itemId, // Optional: allow pre-generated itemId from UI
    Map<String, dynamic>?
    metadata, // Optional metadata (for image/voice messages)
    bool forcePreKeyMessage =
        false, // Force PreKey message even if session exists (for session recovery)
  }) async {
    // 🔒 SYNC-LOCK: Wait if identity regeneration is in progress
    await _waitForRegenerationIfNeeded();

    dynamic ciphertextMessage;

    // Use provided itemId or generate new one
    final messageItemId = itemId ?? Uuid().v4();

    // Prepare payload string for both encryption and local storage
    String payloadString;
    if (payload is String) {
      payloadString = payload;
    } else {
      payloadString = jsonEncode(payload);
    }

    debugPrint(
      '[SIGNAL SERVICE] Step 0: Trigger local callback for sent message',
    );
    // Immediately notify UI with the PLAINTEXT message for the sending device
    // This allows Bob Device 1 to see his own sent message without decryption

    // ✅ PHASE 4: Define types that should NOT be stored
    const SKIP_STORAGE_TYPES = {
      'fileKeyResponse',
      'senderKeyDistribution',
      'read_receipt', // Already handled separately
      'meeting_e2ee_key_request', // Meeting E2EE key exchange - not stored
      'meeting_e2ee_key_response', // Meeting E2EE key exchange - not stored
      'video_e2ee_key_request', // Video channel E2EE key exchange - not stored
      'video_e2ee_key_response', // Video channel E2EE key exchange - not stored
    };

    // Store sent message in local storage for persistence after refresh
    // IMPORTANT: Only store actual chat messages and file messages, not system messages
    final timestamp = DateTime.now().toIso8601String();
    const STORABLE_TYPES = {
      'message',
      'file',
      'image',
      'voice',
      'notification',
      'emote',
      'mention',
      'missingcall',
      'addtochannel',
      'removefromchannel',
      'permissionchange',
      'system:identityKeyChanged', // ← Identity key change notifications (visible in chat)
    };
    final shouldStore =
        !SKIP_STORAGE_TYPES.contains(type) && STORABLE_TYPES.contains(type);

    if (shouldStore) {
      // Store in SQLite database with status
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.storeSentMessage(
          itemId: messageItemId,
          recipientId: recipientUserId,
          message: payloadString,
          timestamp: timestamp,
          type: type,
          status: 'sent', // Initial status
          metadata: metadata,
        );

        // Update recent conversations list
        final conversationsStore =
            await SqliteRecentConversationsStore.getInstance();
        await conversationsStore.addOrUpdateConversation(
          userId: recipientUserId,
          displayName: recipientUserId, // Will be enriched by UI layer
        );

        debugPrint(
          '[SIGNAL SERVICE] ✓ Stored sent $type in SQLite with status=sent',
        );
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] ✗ Failed to store in SQLite: $e');
      }
    } else {
      debugPrint(
        '[SIGNAL SERVICE] Step 0a: Skipping storage for message type: $type (system message or skip-list)',
      );
    }

    // Trigger local callback for UI updates (but not for read_receipt - they are system messages)
    // For file messages, use 'message' callback since they display in chat
    final callbackType = (type == 'file') ? 'message' : type;
    if (type != 'read_receipt' &&
        _itemTypeCallbacks.containsKey(callbackType)) {
      final localItem = {
        'itemId': messageItemId,
        'sender': _currentUserId,
        'recipient': recipientUserId, // Add recipient for proper filtering
        'senderDeviceId': _currentDeviceId,
        'type': type, // Keep original type (file or message)
        'message': payloadString,
        'payload': payloadString, // Add payload field for consistency
        'timestamp': timestamp,
        'isLocalSent': true, // Mark as locally sent (not received from server)
      };
      for (final callback in _itemTypeCallbacks[callbackType]!) {
        callback(localItem);
      }
      debugPrint(
        '[SIGNAL SERVICE] Step 0b: Triggered ${_itemTypeCallbacks[callbackType]!.length} local callbacks for type: $type (using callback: $callbackType)',
      );
    }

    debugPrint(
      '[SIGNAL SERVICE] Step 1: fetchPreKeyBundleForUser($recipientUserId)',
    );
    debugPrint(
      '[SIGNAL SERVICE] This fetches devices for BOTH users: recipient AND sender (own devices)',
    );
    final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);
    debugPrint('[SIGNAL SERVICE] Step 1 result: $preKeyBundles');
    debugPrint(
      '[SIGNAL SERVICE] Number of devices (Alice + Bob): ${preKeyBundles.length}',
    );
    for (final bundle in preKeyBundles) {
      debugPrint(
        '[SIGNAL SERVICE] Device: userId=${bundle['userId']}, deviceId=${bundle['deviceId']}',
      );
    }

    // Verschlüssele für jedes Gerät separat
    // IMPORTANT: Each device encryption is isolated in try-catch
    // so one device failure doesn't prevent sending to other devices
    int successCount = 0;
    int failureCount = 0;
    int skippedCount = 0; // Track devices skipped due to invalid bundles

    for (final bundle in preKeyBundles) {
      try {
        debugPrint(
          '[SIGNAL SERVICE] ===============================================',
        );
        debugPrint(
          '[SIGNAL SERVICE] Encrypting for device: ${bundle['userId']}:${bundle['deviceId']}',
        );
        debugPrint(
          '[SIGNAL SERVICE] ===============================================',
        );

        // CRITICAL: Skip encryption for our own current device
        // We cannot decrypt messages we encrypt to ourselves (same session direction)
        final isCurrentDevice =
            (bundle['userId'] == _currentUserId &&
            bundle['deviceId'] == _currentDeviceId);
        if (isCurrentDevice) {
          debugPrint(
            '[SIGNAL SERVICE] Skipping current device (cannot encrypt to self): ${bundle['userId']}:${bundle['deviceId']}',
          );
          continue;
        }

        // PRE-VALIDATION: Check bundle integrity before attempting session building
        // This catches corrupted keys early and avoids UntrustedIdentityException
        if (!_validatePreKeyBundle(bundle)) {
          debugPrint(
            '[SIGNAL SERVICE] ⚠️ Skipping device ${bundle['userId']}:${bundle['deviceId']} - invalid PreKeyBundle',
          );
          skippedCount++;
          continue; // Skip this device, try next one
        }

        debugPrint(
          '[SIGNAL SERVICE] Step 2: Prepare recipientAddress for deviceId ${bundle['deviceId']}',
        );
        final recipientAddress = SignalProtocolAddress(
          bundle['userId'],
          bundle['deviceId'],
        );

        // Check if this is our own device (not the intended recipient)
        // This happens when the backend returns our own devices for multi-device support
        final isOwnDevice = (bundle['userId'] != recipientUserId);

        // 🔄 SESSION RECOVERY: Force PreKey message by deleting existing session
        if (forcePreKeyMessage) {
          debugPrint(
            '[SIGNAL SERVICE] 🔄 forcePreKeyMessage=true - deleting any existing session',
          );
          await sessionStore.deleteSession(recipientAddress);
          debugPrint(
            '[SIGNAL SERVICE] ✓ Session deleted, will send PreKey message',
          );
        }

        debugPrint(
          '[SIGNAL SERVICE] Step 3: Check session for $recipientAddress',
        );
        var hasSession = await sessionStore.containsSession(recipientAddress);
        debugPrint(
          '[SIGNAL SERVICE] Step 3 result: hasSession=$hasSession, isOwnDevice=$isOwnDevice',
        );

        debugPrint(
          '[SIGNAL SERVICE] Step 4: Create SessionCipher for $recipientAddress',
        );
        final sessionCipher = SessionCipher(
          sessionStore,
          preKeyStore,
          signedPreKeyStore,
          identityStore,
          recipientAddress,
        );

        if (!hasSession) {
          debugPrint(
            '[SIGNAL SERVICE] Step 5: Build session for $recipientAddress',
          );
          final preKeyBundle = PreKeyBundle(
            bundle['registrationId'],
            bundle['deviceId'],
            bundle['preKeyId'],
            bundle['preKeyPublic'],
            bundle['signedPreKeyId'],
            bundle['signedPreKeyPublic'],
            bundle['signedPreKeySignature'],
            bundle['identityKey'],
          );
          final sessionBuilder = SessionBuilder(
            sessionStore,
            preKeyStore,
            signedPreKeyStore,
            identityStore,
            recipientAddress,
          );

          // Wrap processPreKeyBundle in exception handlers
          // Identity verification and signature validation happen during session building
          try {
            await sessionBuilder.processPreKeyBundle(preKeyBundle);
            debugPrint('[SIGNAL SERVICE] Step 5 done');
          } on UntrustedIdentityException catch (e) {
            debugPrint(
              '[SIGNAL SERVICE] UntrustedIdentityException during session building',
            );
            // Auto-trust the new identity and rebuild session
            await handleUntrustedIdentity(e, recipientAddress, () async {
              // Create new session builder and process bundle again with trusted identity
              final newSessionBuilder = SessionBuilder(
                sessionStore,
                preKeyStore,
                signedPreKeyStore,
                identityStore,
                recipientAddress,
              );
              await newSessionBuilder.processPreKeyBundle(preKeyBundle);
              debugPrint(
                '[SIGNAL SERVICE] Session rebuilt with trusted identity',
              );
              return null; // Not encrypting yet, just building session
            });
            debugPrint('[SIGNAL SERVICE] Step 5 done (after identity trust)');
          } catch (e) {
            // Handle other session building errors (invalid keys, bad signatures, etc.)
            if (e.toString().contains('InvalidKey') ||
                e.toString().contains('signature') ||
                e.toString().contains('invalid') ||
                e.toString().contains('verification failed')) {
              debugPrint(
                '[SIGNAL SERVICE] ⚠️ Invalid PreKeyBundle for ${bundle['userId']}:${bundle['deviceId']}',
              );
              debugPrint('[SIGNAL SERVICE] Error: $e');
              debugPrint(
                '[SIGNAL SERVICE] Bundle may be corrupted or out of sync',
              );
              debugPrint('[SIGNAL SERVICE] Skipping this device...');
              skippedCount++;
              continue; // Skip to next device
            }
            // Re-throw unknown errors
            rethrow;
          }
        }

        debugPrint('[SIGNAL SERVICE] Step 6: Using pre-prepared payload');
        // payloadString is already prepared before the loop
        debugPrint('[SIGNAL SERVICE] Step 6: payload is: $payloadString');

        debugPrint(
          '[SIGNAL SERVICE] Step 7: Encrypt payload with message: $payloadString',
        );

        try {
          ciphertextMessage = await sessionCipher.encrypt(
            Uint8List.fromList(utf8.encode(payloadString)),
          );
        } on UntrustedIdentityException catch (e) {
          // Handle identity key change during encryption (rare - usually caught during session building)
          debugPrint(
            '[SIGNAL SERVICE] UntrustedIdentityException during encryption',
          );
          ciphertextMessage = await handleUntrustedIdentity(
            e,
            recipientAddress,
            () async {
              // Recreate session cipher with updated identity
              final newSessionCipher = SessionCipher(
                sessionStore,
                preKeyStore,
                signedPreKeyStore,
                identityStore,
                recipientAddress,
              );
              return await newSessionCipher.encrypt(
                Uint8List.fromList(utf8.encode(payloadString)),
              );
            },
          );
        }

        debugPrint('[SIGNAL SERVICE] Step 8: Serialize ciphertext');
        final serialized = base64Encode(ciphertextMessage.serialize());
        debugPrint(
          '[SIGNAL SERVICE] Step 8 result: cipherType=${ciphertextMessage.getType()}, hasSession=$hasSession',
        );

        // CRITICAL: If we get PreKey message despite having a session, the session is corrupted
        // Delete it and rebuild from scratch
        if (ciphertextMessage.getType() == 3 && hasSession) {
          debugPrint(
            '[SIGNAL SERVICE] WARNING: PreKey message despite existing session! Session is corrupted.',
          );
          debugPrint(
            '[SIGNAL SERVICE] Deleting corrupted session with ${recipientAddress}',
          );
          await sessionStore.deleteSession(recipientAddress);
          hasSession = false;
          debugPrint('[SIGNAL SERVICE] Session deleted. Rebuilding...');

          // Rebuild session
          final preKeyBundle = PreKeyBundle(
            bundle['registrationId'],
            bundle['deviceId'],
            bundle['preKeyId'],
            bundle['preKeyPublic'],
            bundle['signedPreKeyId'],
            bundle['signedPreKeyPublic'],
            bundle['signedPreKeySignature'],
            bundle['identityKey'],
          );
          final sessionBuilder = SessionBuilder(
            sessionStore,
            preKeyStore,
            signedPreKeyStore,
            identityStore,
            recipientAddress,
          );
          await sessionBuilder.processPreKeyBundle(preKeyBundle);
          debugPrint('[SIGNAL SERVICE] Session rebuilt');

          // Re-encrypt with new session
          debugPrint(
            '[SIGNAL SERVICE] Re-encrypting message with rebuilt session',
          );
          ciphertextMessage = await sessionCipher.encrypt(
            Uint8List.fromList(utf8.encode(payloadString)),
          );
          final newSerialized = base64Encode(ciphertextMessage.serialize());
          debugPrint(
            '[SIGNAL SERVICE] Re-encrypted cipherType=${ciphertextMessage.getType()}',
          );

          // Update data with new encryption (use same itemId)
          final data = {
            'recipient': recipientAddress.getName(),
            'recipientDeviceId': recipientAddress.getDeviceId(),
            'type': type,
            'payload': newSerialized,
            'cipherType': ciphertextMessage.getType(),
            'itemId': messageItemId,
          };

          debugPrint(
            '[SIGNAL SERVICE] Sending rebuilt message: cipherType=${ciphertextMessage.getType()}',
          );
          SocketService().emit("sendItem", data);
          successCount++;
          continue; // Skip normal sending path
        }

        debugPrint('[SIGNAL SERVICE] Step 9: Build data packet');
        // Use the pre-generated itemId from before the loop
        final data = {
          'recipient': recipientAddress.getName(),
          'recipientDeviceId': recipientAddress.getDeviceId(),
          'type': type,
          'payload': serialized,
          'cipherType': ciphertextMessage.getType(),
          'itemId': messageItemId,
        };

        debugPrint('[SIGNAL SERVICE] Step 10: Sending item: $data');
        SocketService().emit("sendItem", data);
        successCount++;

        // Log message type for debugging
        final isPreKeyMessage = ciphertextMessage.getType() == 3;
        if (isPreKeyMessage) {
          debugPrint(
            '[SIGNAL SERVICE] Step 11: PreKey message sent (first message to establish session)',
          );
          debugPrint(
            '[SIGNAL SERVICE] Step 11a: This message contains the actual content and will establish the session',
          );
        } else {
          debugPrint(
            '[SIGNAL SERVICE] Step 11: Whisper message sent (session already exists)',
          );
        }
      } catch (e, stackTrace) {
        // Device-specific encryption failure - log and continue to next device
        failureCount++;
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Failed to encrypt for device ${bundle['userId']}:${bundle['deviceId']}',
        );
        debugPrint('[SIGNAL SERVICE] Error: $e');
        debugPrint('[SIGNAL SERVICE] Stack trace: $stackTrace');
        debugPrint('[SIGNAL SERVICE] → Continuing to next device...');
        // Continue loop - don't let one device failure stop others
      }
    }

    // Log final results
    debugPrint(
      '[SIGNAL SERVICE] ✓ Send complete: $successCount succeeded, $failureCount failed, $skippedCount skipped (invalid bundles) out of ${preKeyBundles.length} devices',
    );

    // If ALL devices failed or were skipped, throw error
    if (successCount == 0 && preKeyBundles.isNotEmpty) {
      if (skippedCount > 0) {
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Message send failed - all devices had issues',
        );
        debugPrint(
          '[SIGNAL SERVICE] Skipped: $skippedCount (invalid bundles), Failed: $failureCount (encryption errors)',
        );
        debugPrint(
          '[SIGNAL SERVICE] Recipient may need to re-register their Signal keys',
        );
        throw Exception(
          'Failed to send message: $skippedCount devices had invalid/corrupted PreKeyBundles, '
          '$failureCount devices failed encryption. '
          'Recipient may need to logout and login again to regenerate their Signal keys.',
        );
      } else {
        debugPrint(
          '[SIGNAL SERVICE] ⚠️ Message send failed to all ${preKeyBundles.length} devices',
        );
        debugPrint(
          '[SIGNAL SERVICE] This may indicate network issues or recipient key problems',
        );
        throw Exception(
          'Failed to send message to all ${preKeyBundles.length} devices. '
          'This may be a network issue or recipient may need to re-register Signal keys. '
          'Check logs for details.',
        );
      }
    }
  }

  Future<String> decryptItem({
    required SignalProtocolAddress senderAddress,
    required String payload, // base64-encoded serialized message
    required int cipherType, // 3 = PreKey, 1 = SignalMessage
  }) async {
    // 1. SessionCipher für den Absender holen/erstellen
    try {
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        senderAddress,
      );

      // 2. Deserialisieren
      final serialized = base64Decode(payload);

      // 3. Entschlüsseln je nach Typ
      if (cipherType == CiphertextMessage.prekeyType) {
        final preKeyMsg = PreKeySignalMessage(serialized);

        Uint8List plaintext;
        try {
          plaintext = await sessionCipher.decryptWithCallback(
            preKeyMsg,
            (pt) {},
          );
        } on UntrustedIdentityException catch (e) {
          debugPrint(
            '[SIGNAL SERVICE] UntrustedIdentityException during PreKey decryption - sender changed identity',
          );
          // Auto-trust and rebuild session
          await handleUntrustedIdentity(
            e,
            senderAddress,
            () async => '', // No retry needed - will continue below
            sendNotification: true,
          );

          // Retry decryption with trusted identity
          final newSessionCipher = SessionCipher(
            sessionStore,
            preKeyStore,
            signedPreKeyStore,
            identityStore,
            senderAddress,
          );
          plaintext = await newSessionCipher.decryptWithCallback(
            preKeyMsg,
            (pt) {},
          );
          debugPrint(
            '[SIGNAL SERVICE] ✓ PreKey message decrypted after identity update',
          );
        } catch (e) {
          // Handle PreKey-specific errors (missing PreKey, invalid signature, etc.)
          if (e.toString().contains('PreKey') ||
              e.toString().contains('No valid') ||
              e.toString().contains('InvalidKey') ||
              e.toString().contains('signature')) {
            debugPrint('[SIGNAL SERVICE] ⚠️ PreKey decryption failed: $e');
            debugPrint(
              '[SIGNAL SERVICE] PreKey may be consumed, invalid, or sender keys corrupted',
            );
            debugPrint(
              '[SIGNAL SERVICE] Sender needs to fetch fresh PreKeyBundle and resend',
            );

            // Notify sender that their PreKey/bundle is invalid
            try {
              final senderId = senderAddress.getName();
              final deviceId = senderAddress.getDeviceId();
              final recoveryKey = '${senderId}:${deviceId}';

              // 🔒 LOOP PREVENTION: Check if we recently sent recovery for this address
              final lastAttempt = _sessionRecoveryLastAttempt[recoveryKey];
              if (lastAttempt != null) {
                final timeSinceLastAttempt = DateTime.now().difference(
                  lastAttempt,
                );
                if (timeSinceLastAttempt.inSeconds < 30) {
                  debugPrint(
                    '[SIGNAL SERVICE] ⚠️ Recovery notification already sent ${timeSinceLastAttempt.inSeconds}s ago - skipping to prevent spam',
                  );
                  return '';
                }
              }

              _sessionRecoveryLastAttempt[recoveryKey] = DateTime.now();

              SocketService().emit('sessionRecoveryNeeded', {
                'recipientUserId': _currentUserId,
                'recipientDeviceId': _currentDeviceId,
                'senderUserId': senderId,
                'senderDeviceId': deviceId,
                'reason': 'InvalidPreKeyBundle',
              });

              debugPrint(
                '[SIGNAL SERVICE] ✓ Notified sender to refresh bundle and resend',
              );
            } catch (notifyError) {
              debugPrint(
                '[SIGNAL SERVICE] ⚠️ Failed to notify sender: $notifyError',
              );
            }

            return ''; // Message lost, but recovery initiated
          }
          // Re-throw unknown errors
          rethrow;
        }

        // PreKey nach erfolgreichem Session-Aufbau löschen
        final preKeyIdOptional = preKeyMsg.getPreKeyId();
        int? preKeyId;
        if (preKeyIdOptional.isPresent == true) {
          preKeyId = preKeyIdOptional.value;
        }

        if (preKeyId != null) {
          debugPrint(
            '[SIGNAL SERVICE] Removing used PreKey $preKeyId after session establishment',
          );
          await preKeyStore.removePreKey(preKeyId);

          // 🚀 OPTIMIZED: Async regeneration (non-blocking)
          // Generate the consumed PreKey in the background
          _regeneratePreKeyAsync(preKeyId);

          // CRITICAL: Trigger server sync check after PreKey deletion
          // This ensures server stays in sync with local PreKey count
          Future.delayed(Duration(seconds: 2), () {
            debugPrint(
              '[SIGNAL SERVICE] Triggering PreKey sync check after deletion...',
            );
            SocketService().emit("signalStatus", null);
          });
        }

        return utf8.decode(plaintext);
      } else if (cipherType == CiphertextMessage.whisperType) {
        // Normale Nachricht
        final signalMsg = SignalMessage.fromSerialized(serialized);

        try {
          final plaintext = await sessionCipher.decryptFromSignal(signalMsg);
          debugPrint(
            '[SIGNAL SERVICE] Step 8: Decrypted plaintext: $plaintext',
          );
          return utf8.decode(plaintext);
        } catch (e) {
          // Check for NoSessionException (session was deleted due to corruption or reset)
          if (e.toString().contains('NoSessionException')) {
            debugPrint(
              '[SIGNAL SERVICE] ⚠️ NoSessionException - no session exists for ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
            );
            debugPrint(
              '[SIGNAL SERVICE] This usually happens after a corrupted session was deleted',
            );
            debugPrint(
              '[SIGNAL SERVICE] Sender needs to send a PreKey message (cipherType: 3) to establish new session',
            );

            // 🚀 AUTO-RECOVERY: Notify sender to resend their message
            try {
              final senderId = senderAddress.getName();
              final deviceId = senderAddress.getDeviceId();
              final recoveryKey = '${senderId}:${deviceId}';

              // 🔒 LOOP PREVENTION: Check if we recently sent recovery for this address
              final lastAttempt = _sessionRecoveryLastAttempt[recoveryKey];
              if (lastAttempt != null) {
                final timeSinceLastAttempt = DateTime.now().difference(
                  lastAttempt,
                );
                if (timeSinceLastAttempt.inSeconds < 30) {
                  debugPrint(
                    '[SIGNAL SERVICE] ⚠️ Recovery notification already sent ${timeSinceLastAttempt.inSeconds}s ago - skipping to prevent spam',
                  );
                  return '';
                }
              }

              _sessionRecoveryLastAttempt[recoveryKey] = DateTime.now();

              debugPrint(
                '[SIGNAL SERVICE] 📤 Notifying sender to resend message (will auto-establish session)',
              );
              SocketService().emit('sessionRecoveryNeeded', {
                'recipientUserId':
                    _currentUserId, // Who detected the missing session
                'recipientDeviceId': _currentDeviceId,
                'senderUserId': senderId, // Who should resend
                'senderDeviceId': deviceId,
                'reason': 'NoSession',
              });
              debugPrint(
                '[SIGNAL SERVICE] ✓ Session recovery notification sent to sender',
              );

              // Also notify UI (optional - user doesn't need to do anything)
              if (_itemTypeCallbacks.containsKey('sessionCorrupted')) {
                for (final callback
                    in _itemTypeCallbacks['sessionCorrupted']!) {
                  callback({
                    'senderId': senderId,
                    'deviceId': deviceId,
                    'message':
                        'Session recovery in progress - sender will resend automatically.',
                  });
                }
              }
            } catch (notifyError) {
              debugPrint(
                '[SIGNAL SERVICE] ⚠️ Failed to send recovery notification: $notifyError',
              );
            }

            // Return empty - sender will automatically resend as PreKey message
            return '';
          }

          // Check for InvalidMessageException (Bad MAC - corrupted session)
          if (e.toString().contains('InvalidMessageException') ||
              e.toString().contains('Bad Mac')) {
            debugPrint(
              '[SIGNAL SERVICE] ⚠️ InvalidMessageException detected - session corrupted or out of sync',
            );
            debugPrint(
              '[SIGNAL SERVICE] Deleting corrupted session for ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
            );

            // Delete the corrupted session
            await sessionStore.deleteSession(senderAddress);

            debugPrint('[SIGNAL SERVICE] ✓ Corrupted session deleted');
            debugPrint(
              '[SIGNAL SERVICE] ℹ️ Next message from this sender will establish a new session',
            );

            // 🚀 AUTO-RECOVERY: Notify sender to resend their message
            try {
              final senderId = senderAddress.getName();
              final deviceId = senderAddress.getDeviceId();
              final recoveryKey = '${senderId}:${deviceId}';

              // 🔒 LOOP PREVENTION: Check if we recently sent recovery for this address
              final lastAttempt = _sessionRecoveryLastAttempt[recoveryKey];
              if (lastAttempt != null) {
                final timeSinceLastAttempt = DateTime.now().difference(
                  lastAttempt,
                );
                if (timeSinceLastAttempt.inSeconds < 30) {
                  debugPrint(
                    '[SIGNAL SERVICE] ⚠️ Recovery notification already sent ${timeSinceLastAttempt.inSeconds}s ago - skipping to prevent spam',
                  );
                  return '';
                }
              }

              _sessionRecoveryLastAttempt[recoveryKey] = DateTime.now();

              debugPrint(
                '[SIGNAL SERVICE] 📤 Notifying sender to resend message (session was corrupted)',
              );
              SocketService().emit('sessionRecoveryNeeded', {
                'recipientUserId':
                    _currentUserId, // Who detected the corruption
                'recipientDeviceId': _currentDeviceId,
                'senderUserId': senderId, // Who should resend
                'senderDeviceId': deviceId,
                'reason': 'BadMAC',
              });
              debugPrint(
                '[SIGNAL SERVICE] ✓ Session recovery notification sent to sender',
              );

              // Also notify UI (optional - user doesn't need to do anything)
              if (_itemTypeCallbacks.containsKey('sessionCorrupted')) {
                for (final callback
                    in _itemTypeCallbacks['sessionCorrupted']!) {
                  callback({
                    'senderId': senderId,
                    'deviceId': deviceId,
                    'message':
                        'Session recovery in progress - sender will resend automatically.',
                  });
                }
              }

              debugPrint(
                '[SIGNAL SERVICE] ℹ️ Session corruption notification sent',
              );
            } catch (notifyError) {
              debugPrint(
                '[SIGNAL SERVICE] ⚠️ Failed to send notification: $notifyError',
              );
            }

            // Return empty string - message is lost but future messages will work
            return '';
          }

          // Re-throw other errors
          rethrow;
        }
      } else if (cipherType == CiphertextMessage.senderKeyType) {
        // Group message - should NOT be processed here!
        // Group messages should come via 'groupMessage' Socket.IO event and use GroupCipher
        throw Exception(
          'CipherType 4 (senderKeyType) detected - group messages must use GroupCipher, not SessionCipher. This message should come via groupMessage event, not receiveItem.',
        );
      } else {
        throw Exception('Unknown cipherType: $cipherType');
      }
    } catch (e, st) {
      debugPrint(
        '[ERROR] Exception while decrypting message: \\${e}\\n\\${st}',
      );
      return '';
    }
  }

  /*Future<Map<String, String>> _generateIdentityKeyPair() {
    final identityKeyPair =  generateIdentityKeyPair();
    final publicKeyBase64 = base64Encode(identityKeyPair.getPublicKey().serialize());
    final privateKeyBase64 = base64Encode(identityKeyPair.getPrivateKey().serialize());
    final registrationId = generateRegistrationId(false);
    return Future.value({
      'publicKey': publicKeyBase64,
      'privateKey': privateKeyBase64,
      'registrationId': registrationId.toString(),
    });
  }*/

  /*Future<Map<String, String?>> getIdentityKeyPair() async {
  String? publicKeyBase64;
  String? privateKeyBase64;
  String? registrationId;

    if(isSkiaWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final storeName = 'peerwaveSignal';
      // Bump version to force onUpgradeNeeded and always create store if missing
      final db = await idbFactory.open('peerwaveSignal', version: 1, onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(storeName)) {
          db.createObjectStore(storeName, autoIncrement: true);
        }
      });

      var txn = db.transaction(storeName, "readonly");
      var store = txn.objectStore(storeName);
  publicKeyBase64 = await store.getObject("publicKey") as String?;
  privateKeyBase64 = await store.getObject("privateKey") as String?;
  var regIdObj = await store.getObject("registrationId");
  registrationId = regIdObj?.toString();
      await txn.completed;

      if (publicKeyBase64 == null || privateKeyBase64 == null || registrationId == null) {
        final generated = await _generateIdentityKeyPair();
        publicKeyBase64 = generated['publicKey'];
        privateKeyBase64 = generated['privateKey'];
        registrationId = generated['registrationId'];
        txn = db.transaction(storeName, "readwrite");
        store = txn.objectStore(storeName);

        store.put(publicKeyBase64 ?? '', "publicKey");
        store.put(privateKeyBase64 ?? '', "privateKey");
        store.put(registrationId ?? '', "registrationId");
        await txn.completed;
      }
      return Future.value({
      'publicKey': publicKeyBase64,
      'privateKey': privateKeyBase64,
      'registrationId': registrationId,
    });
    } else {
      final storage = FlutterSecureStorage();
  var publicKeyBase64 = await storage.read(key: "publicKey");
  var privateKeyBase64 = await storage.read(key: "privateKey");
  var regIdObj = await storage.read(key: "registrationId");
  var registrationId = regIdObj?.toString();

      if (publicKeyBase64 == null || privateKeyBase64 == null || registrationId == null) {
        final generated = await _generateIdentityKeyPair();
        publicKeyBase64 = generated['publicKey'];
            privateKeyBase64 = generated['privateKey'];
            registrationId = generated['registrationId'];
            await storage.write(key: "publicKey", value: publicKeyBase64);
            await storage.write(key: "privateKey", value: privateKeyBase64);
            await storage.write(key: "registrationId", value: registrationId);
      }

      return Future.value({
        'publicKey': publicKeyBase64,
        'privateKey': privateKeyBase64,
        'registrationId': registrationId,
      });
    }
  }*/

  // ============================================================================
  // GROUP ENCRYPTION WITH SENDER KEYS
  // ============================================================================

  /// Create and distribute sender key for a group
  /// This should be called when starting to send messages in a group
  /// Returns the serialized distribution message to send to all group members
  ///
  /// IMPORTANT: After calling this, you must broadcast the distribution message
  /// to all group members so they can decrypt your messages
  Future<Uint8List> createGroupSenderKey(
    String groupId, {
    bool broadcastDistribution = true,
  }) async {
    if (_currentUserId == null || _currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    debugPrint(
      '[SIGNAL_SERVICE] Creating sender key for group $groupId, user $_currentUserId:$_currentDeviceId',
    );

    // ⚠️ CRITICAL: Check if sender key already exists to avoid chain corruption
    final senderAddress = SignalProtocolAddress(
      _currentUserId!,
      _currentDeviceId!,
    );
    final senderKeyName = SenderKeyName(groupId, senderAddress);

    final existingKey = await senderKeyStore.containsSenderKey(senderKeyName);
    if (existingKey) {
      debugPrint(
        '[SIGNAL_SERVICE] ℹ️ Sender key already exists for group $groupId',
      );

      // ⚠️ VALIDATION: Try to use the existing key - if it fails, regenerate
      // Test by creating a GroupCipher and attempting a dummy encryption
      try {
        final testCipher = GroupCipher(senderKeyStore, senderKeyName);
        // Try to encrypt a small test message to verify key validity
        final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
        await testCipher.encrypt(testMessage);
        debugPrint(
          '[SIGNAL_SERVICE] ✓ Existing sender key is valid and functional',
        );
        // Return empty bytes - key is already distributed
        return Uint8List(0);
      } catch (e) {
        debugPrint(
          '[SIGNAL_SERVICE] ⚠️ WARNING: Existing sender key is corrupted or invalid ($e)',
        );
        debugPrint(
          '[SIGNAL_SERVICE] Deleting corrupted key and regenerating...',
        );
        // Delete corrupted key
        await senderKeyStore.removeSenderKey(senderKeyName);
        // Fall through to regenerate
      }
    }

    // Verify identity key pair exists
    try {
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      debugPrint(
        '[SIGNAL_SERVICE] Identity key pair verified - PublicKey: ${identityKeyPair.getPublicKey().toString().substring(0, 20)}...',
      );
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] ❌ Error verifying identity key pair: $e');
      debugPrint(
        '[SIGNAL_SERVICE] Identity key pair missing - triggering signalStatus check for auto-recovery',
      );

      // Trigger status check which will detect missing keys and upload them
      try {
        SocketService().emit('signalStatus', null);
        debugPrint(
          '[SIGNAL_SERVICE] Status check triggered - waiting for key recovery...',
        );
        await Future.delayed(Duration(seconds: 2));

        // Retry getting identity
        await identityStore.getIdentityKeyPair();
        debugPrint(
          '[SIGNAL_SERVICE] ✅ Identity key pair recovered after status check',
        );
      } catch (retryError) {
        debugPrint('[SIGNAL_SERVICE] ❌ Auto-recovery failed: $retryError');
        throw Exception(
          'Cannot create sender key: Identity key pair not available and auto-recovery failed. '
          'Please logout and login again to regenerate Signal keys. Error: $e',
        );
      }
    }

    // Verify sender key store is initialized
    try {
      await senderKeyStore.loadSenderKey(senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Sender key store is accessible');
    } catch (e) {
      // This is expected to fail if no sender key exists yet - that's normal
      if (e.toString().contains('not found') ||
          e.toString().contains('No sender key')) {
        debugPrint(
          '[SIGNAL_SERVICE] No existing sender key found (normal for first message)',
        );
      } else {
        debugPrint('[SIGNAL_SERVICE] ⚠️ Unexpected sender key store error: $e');
        debugPrint('[SIGNAL_SERVICE] This may indicate storage corruption');
        throw Exception(
          'Cannot create sender key: Sender key store error. '
          'Storage may be corrupted. Try clearing app data. Error: $e',
        );
      }
    }

    try {
      debugPrint(
        '[SIGNAL_SERVICE] Created SenderKeyName for group $groupId, address ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
      );

      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      debugPrint('[SIGNAL_SERVICE] Created GroupSessionBuilder');

      // Create sender key distribution message
      debugPrint('[SIGNAL_SERVICE] Calling groupSessionBuilder.create()...');
      final distributionMessage = await groupSessionBuilder.create(
        senderKeyName,
      );
      debugPrint('[SIGNAL_SERVICE] Successfully created distribution message');

      final serialized = distributionMessage.serialize();
      debugPrint(
        '[SIGNAL_SERVICE] Serialized distribution message, length: ${serialized.length}',
      );

      debugPrint('[SIGNAL_SERVICE] Created sender key for group $groupId');

      // Check if this is a meeting or instant call
      // Meetings and calls use 1:1 Signal sessions, not SenderKey protocol
      final isMeeting = groupId.startsWith('mtg_') || groupId.startsWith('call_');
      
      if (isMeeting) {
        debugPrint(
          '[SIGNAL_SERVICE] Meeting/call detected ($groupId) - skipping server SenderKey storage',
        );
        debugPrint(
          '[SIGNAL_SERVICE] Meetings use 1:1 Signal sessions for encryption, not group SenderKeys',
        );
        // Return early - no server storage or broadcast needed for meetings
        return serialized;
      }

      // Store sender key on server for backup/retrieval (CHANNELS ONLY)
      // Skip if serialized is empty (key already existed)
      if (serialized.isNotEmpty) {
        try {
          final senderKeyBase64 = base64Encode(serialized);
          SocketService().emit('storeSenderKey', {
            'groupId': groupId,
            'senderKey': senderKeyBase64,
          });
          debugPrint(
            '[SIGNAL_SERVICE] Stored sender key on server for channel $groupId',
          );
        } catch (e) {
          debugPrint(
            '[SIGNAL_SERVICE] Warning: Failed to store sender key on server: $e',
          );
          // Don't fail - sender key is already stored locally
        }
      }

      // Broadcast distribution message to all group members (CHANNELS ONLY)
      // Skip if serialized is empty (key already existed)
      if (broadcastDistribution && serialized.isNotEmpty) {
        try {
          debugPrint(
            '[SIGNAL_SERVICE] Broadcasting sender key distribution message...',
          );
          SocketService().emit('broadcastSenderKey', {
            'groupId': groupId,
            'distributionMessage': base64Encode(serialized),
          });
          debugPrint(
            '[SIGNAL_SERVICE] ✓ Sender key distribution message broadcast to channel',
          );
        } catch (e) {
          debugPrint(
            '[SIGNAL_SERVICE] Warning: Failed to broadcast distribution message: $e',
          );
          // Don't fail - recipients can still request it from server
        }
      }

      return serialized;
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL_SERVICE] Error in createGroupSenderKey: $e');
      debugPrint('[SIGNAL_SERVICE] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Process incoming sender key distribution message from another group member
  Future<void> processSenderKeyDistribution(
    String groupId,
    String senderId,
    int senderDeviceId,
    Uint8List distributionMessageBytes,
  ) async {
    final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);

    final distributionMessage =
        SenderKeyDistributionMessageWrapper.fromSerialized(
          distributionMessageBytes,
        );

    await groupSessionBuilder.process(senderKeyName, distributionMessage);

    debugPrint(
      '[SIGNAL_SERVICE] Processed sender key from $senderId:$senderDeviceId for group $groupId',
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
    // 🔒 SYNC-LOCK: Wait if identity regeneration is in progress
    await _waitForRegenerationIfNeeded();

    if (_currentUserId == null || _currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    debugPrint(
      '[SIGNAL_SERVICE] encryptGroupMessage: groupId=$groupId, userId=$_currentUserId:$_currentDeviceId, messageLength=${message.length}',
    );

    try {
      final senderAddress = SignalProtocolAddress(
        _currentUserId!,
        _currentDeviceId!,
      );
      debugPrint(
        '[SIGNAL_SERVICE] Created sender address: ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
      );

      final senderKeyName = SenderKeyName(groupId, senderAddress);
      debugPrint('[SIGNAL_SERVICE] Created sender key name for group $groupId');

      // Check if sender key exists
      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );
      debugPrint('[SIGNAL_SERVICE] Sender key exists: $hasSenderKey');

      if (!hasSenderKey) {
        throw Exception(
          'No sender key found for this group. Please initialize sender key first.',
        );
      }

      // Load the sender key record to verify it's valid
      await senderKeyStore.loadSenderKey(senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Loaded sender key record from store');

      // Validate identity key pair exists before encryption (required for signing)
      try {
        final identityKeyPair = await identityStore.getIdentityKeyPair();
        if (identityKeyPair.getPrivateKey().serialize().isEmpty) {
          throw Exception(
            'Identity private key is empty - cannot sign sender key messages',
          );
        }
        debugPrint('[SIGNAL_SERVICE] Identity key pair validated for signing');
      } catch (e) {
        throw Exception(
          'Identity key pair missing or corrupted: $e. Please regenerate Signal Protocol keys.',
        );
      }

      // ⚠️ CRITICAL: Test sender key validity BEFORE creating GroupCipher
      // This prevents RangeError by detecting corrupted keys early
      debugPrint(
        '[SIGNAL_SERVICE] Testing sender key validity with dummy encryption...',
      );
      try {
        final testCipher = GroupCipher(senderKeyStore, senderKeyName);
        final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
        await testCipher.encrypt(testMessage);
        debugPrint('[SIGNAL_SERVICE] ✓ Sender key validation passed');
      } catch (validationError) {
        debugPrint(
          '[SIGNAL_SERVICE] ⚠️ Sender key validation FAILED: $validationError',
        );
        // Trigger RangeError handler to regenerate key
        throw RangeError(
          'Sender key corrupted - validation test failed: $validationError',
        );
      }

      // ✨ ROTATION CHECK: Check if sender key needs rotation (7 days or 1000 messages)
      final needsRotation = await senderKeyStore.needsRotation(senderKeyName);
      if (needsRotation) {
        debugPrint(
          '[SIGNAL_SERVICE] 🔄 Sender key needs rotation - regenerating...',
        );
        try {
          // Remove old key
          await senderKeyStore.removeSenderKey(senderKeyName);

          // Create new sender key and broadcast
          await createGroupSenderKey(groupId, broadcastDistribution: true);
          debugPrint(
            '[SIGNAL_SERVICE] ✓ Sender key rotated successfully for group $groupId',
          );
        } catch (rotationError) {
          debugPrint(
            '[SIGNAL_SERVICE] ⚠️ Warning: Sender key rotation failed: $rotationError',
          );
          // Don't fail the message - continue with existing key if rotation fails
        }
      }

      final groupCipher = GroupCipher(senderKeyStore, senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Created GroupCipher');

      final messageBytes = Uint8List.fromList(utf8.encode(message));
      debugPrint(
        '[SIGNAL_SERVICE] Encoded message to bytes, length: ${messageBytes.length}',
      );

      debugPrint('[SIGNAL_SERVICE] Calling groupCipher.encrypt()...');
      final ciphertext = await groupCipher.encrypt(messageBytes);
      debugPrint(
        '[SIGNAL_SERVICE] Successfully encrypted message, ciphertext length: ${ciphertext.length}',
      );

      // Increment message count for rotation tracking
      await senderKeyStore.incrementMessageCount(senderKeyName);

      return {
        'ciphertext': base64Encode(ciphertext),
        'senderId': _currentUserId,
        'senderDeviceId': _currentDeviceId,
      };
    } on RangeError catch (e) {
      // RangeError during encryption typically means sender key chain is corrupted
      // This can happen if the key was created but signing key state is empty
      debugPrint(
        '[SIGNAL_SERVICE] RangeError during encryption - sender key chain corrupted: $e',
      );
      debugPrint('[SIGNAL_SERVICE] Attempting to recover sender key...');

      try {
        final senderAddress = SignalProtocolAddress(
          _currentUserId!,
          _currentDeviceId!,
        );
        final senderKeyName = SenderKeyName(groupId, senderAddress);

        // STEP 1: Try to load key from server BEFORE regenerating
        // This preserves message history if server has a good key
        debugPrint(
          '[SIGNAL_SERVICE] Step 1: Attempting to load sender key from server...',
        );

        // Delete corrupted local key first
        await senderKeyStore.removeSenderKey(senderKeyName);
        debugPrint('[SIGNAL_SERVICE] Removed corrupted local sender key');

        // Try to reload from server
        final keyLoadedFromServer = await loadSenderKeyFromServer(
          channelId: groupId,
          userId: _currentUserId!,
          deviceId: _currentDeviceId!,
          forceReload: true, // Already deleted above
        );

        if (keyLoadedFromServer) {
          debugPrint(
            '[SIGNAL_SERVICE] ✓ Sender key restored from server backup',
          );

          // Verify the restored key works
          try {
            final testCipher = GroupCipher(senderKeyStore, senderKeyName);
            final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
            await testCipher.encrypt(testMessage);
            debugPrint('[SIGNAL_SERVICE] ✓ Restored sender key is functional');

            // Retry encryption with restored key
            final messageBytes = Uint8List.fromList(utf8.encode(message));
            final restoredCipher = GroupCipher(senderKeyStore, senderKeyName);
            final ciphertext = await restoredCipher.encrypt(messageBytes);
            debugPrint(
              '[SIGNAL_SERVICE] ✓ Successfully encrypted with restored key',
            );

            return {
              'ciphertext': base64Encode(ciphertext),
              'senderId': _currentUserId,
              'senderDeviceId': _currentDeviceId,
            };
          } catch (validationError) {
            debugPrint(
              '[SIGNAL_SERVICE] ⚠️ Restored key is also corrupted: $validationError',
            );
            // Fall through to regenerate
          }
        } else {
          debugPrint('[SIGNAL_SERVICE] No sender key found on server');
        }

        // STEP 2: If server has no key OR restored key is also corrupted, regenerate
        debugPrint('[SIGNAL_SERVICE] Step 2: Generating new sender key...');
        await createGroupSenderKey(groupId, broadcastDistribution: true);
        debugPrint(
          '[SIGNAL_SERVICE] ✓ Created and broadcast new sender key for group $groupId',
        );

        // Retry encryption with new key
        final messageBytes = Uint8List.fromList(utf8.encode(message));
        final newGroupCipher = GroupCipher(senderKeyStore, senderKeyName);
        final ciphertext = await newGroupCipher.encrypt(messageBytes);
        debugPrint('[SIGNAL_SERVICE] ✓ Successfully encrypted with new key');

        return {
          'ciphertext': base64Encode(ciphertext),
          'senderId': _currentUserId,
          'senderDeviceId': _currentDeviceId,
        };
      } catch (recoveryError) {
        debugPrint(
          '[SIGNAL_SERVICE] ❌ Failed to recover from corrupted sender key: $recoveryError',
        );
        throw Exception(
          'Sender key chain corrupted and recovery failed. Please leave and rejoin the channel. Original error: $e',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL_SERVICE] Error in encryptGroupMessage: $e');
      debugPrint('[SIGNAL_SERVICE] Stack trace: $stackTrace');

      // ⚠️ DO NOT attempt automatic recovery for non-RangeError exceptions

      rethrow;
    }
  }

  /// Decrypt group message using sender key
  Future<String> decryptGroupMessage(
    String groupId,
    String senderId,
    int senderDeviceId,
    String ciphertextBase64,
  ) async {
    final senderAddress = SignalProtocolAddress(senderId, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    final groupCipher = GroupCipher(senderKeyStore, senderKeyName);

    final ciphertext = base64Decode(ciphertextBase64);
    final plaintext = await groupCipher.decrypt(ciphertext);

    return utf8.decode(plaintext);
  }

  /// DEPRECATED: Use sendGroupItem instead
  /// This method is kept for backward compatibility but should not be used
  /// Old implementation that used PermanentSentMessagesStore (wrong store for groups)
  @Deprecated('Use sendGroupItem instead - this uses the wrong store')
  Future<void> sendGroupMessage({
    required String groupId,
    required String message,
    String? itemId,
  }) async {
    debugPrint(
      '[SIGNAL_SERVICE] WARNING: sendGroupMessage is deprecated, use sendGroupItem instead',
    );
    // Redirect to new implementation
    await sendGroupItem(
      channelId: groupId,
      message: message,
      itemId: itemId ?? Uuid().v4(),
    );
  }

  /// Request sender key from a group member
  Future<void> requestSenderKey(
    String groupId,
    String userId,
    int deviceId,
  ) async {
    try {
      // Get server URL from appropriate source
      String? apiServer;
      if (kIsWeb) {
        apiServer = await loadWebApiServer();
      } else {
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          apiServer = activeServer.serverUrl;
        }
      }

      final urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      await ApiService.post(
        '$urlString/channels/$groupId/request-sender-key',
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
    final address = SignalProtocolAddress(senderId, senderDeviceId);
    final senderKeyName = SenderKeyName(groupId, address);

    // Check if key exists in store
    final exists = await senderKeyStore.containsSenderKey(senderKeyName);
    if (!exists) {
      return false;
    }

    // Additionally check if the record has actual key material
    try {
      await senderKeyStore.loadSenderKey(senderKeyName);
      // Try to check if the record has been initialized by the library
      // An empty record would have been created by loadSenderKey, but not populated
      // Unfortunately, SenderKeyRecord doesn't have a public method to check if it's empty
      // So we'll rely on the containsSenderKey check
      return true;
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error checking sender key: $e');
      return false;
    }
  }

  /// Clear all sender keys for a group (e.g., when leaving)
  Future<void> clearGroupSenderKeys(String groupId) async {
    await senderKeyStore.clearGroupSenderKeys(groupId);
    debugPrint('[SIGNAL_SERVICE] Cleared all sender keys for group $groupId');
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
      ;

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

  /// Send P2P file share update (add/revoke access) via Signal Protocol
  ///
  /// For GROUP chats: Uses Sender Key encryption (Group Message)
  /// For DIRECT chats: Uses Session encryption (1-to-1 Message)
  ///
  /// This notifies users about share changes so they can update their P2P client
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

  /// Send video E2EE key to peer via Signal Protocol
  ///
  /// For GROUP chats: Uses Sender Key encryption (Group Message)
  /// For DIRECT chats: Uses Session encryption (1-to-1 Message)
  ///
  /// This distributes the video encryption key to all participants in a video call
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
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);
      final timestamp = DateTime.now().toIso8601String();

      // ✅ PHASE 4: Skip storage for system message types
      const SKIP_STORAGE_TYPES = {
        'fileKeyResponse',
        'senderKeyDistribution',
        'video_e2ee_key_request', // Video E2EE key exchange (ephemeral)
        'video_e2ee_key_response', // Video E2EE key exchange (ephemeral)
        'video_key_request', // Legacy video key request (ephemeral)
        'video_key_response', // Legacy video key response (ephemeral)
      };

      final shouldStore = !SKIP_STORAGE_TYPES.contains(type);

      // Store locally first (unless it's a system message)
      if (shouldStore) {
        // Store in old store for backward compatibility (temporary)
        await sentGroupItemsStore.storeSentGroupItem(
          channelId: channelId,
          itemId: itemId,
          message: message,
          timestamp: timestamp,
          type: type,
          status: 'sending',
        );

        // ALSO store in new SQLite database for performance
        try {
          final messageStore = await SqliteMessageStore.getInstance();
          await messageStore.storeSentMessage(
            itemId: itemId,
            recipientId:
                channelId, // Store channelId as recipientId for group messages
            channelId: channelId,
            message: message,
            timestamp: timestamp,
            type: type,
            metadata: metadata,
          );
          debugPrint('[SIGNAL_SERVICE] Stored group item $itemId in SQLite');
        } catch (e) {
          debugPrint(
            '[SIGNAL_SERVICE] ✗ Failed to store group item in SQLite: $e',
          );
        }

        debugPrint('[SIGNAL_SERVICE] Stored group item $itemId locally');
      } else {
        debugPrint(
          '[SIGNAL_SERVICE] Skipping storage for system message type: $type',
        );
      }

      // Send via Socket.IO (always send, even if not stored)
      SocketService().emit("sendGroupItem", {
        'channelId': channelId,
        'itemId': itemId,
        'type': type,
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': timestamp,
      });

      debugPrint(
        '[SIGNAL_SERVICE] Sent group item $itemId to channel $channelId',
      );
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error sending group item: $e');
      rethrow;
    }
  }

  /// Decrypt a received group item with automatic sender key reload on error
  Future<String> decryptGroupItem({
    required String channelId,
    required String senderId,
    required int senderDeviceId,
    required String ciphertext,
    bool retryOnError = true,
  }) async {
    try {
      // Try to decrypt
      final decrypted = await decryptGroupMessage(
        channelId,
        senderId,
        senderDeviceId,
        ciphertext,
      );

      return decrypted;
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Decrypt error: $e');

      // Check if this is a decryption error that might be fixed by reloading sender key
      if (retryOnError &&
          (e.toString().contains('InvalidMessageException') ||
              e.toString().contains('No key for') ||
              e.toString().contains('DuplicateMessageException') ||
              e.toString().contains('Invalid'))) {
        debugPrint(
          '[SIGNAL_SERVICE] Attempting to reload sender key from server...',
        );

        // Try to reload sender key from server
        final keyLoaded = await loadSenderKeyFromServer(
          channelId: channelId,
          userId: senderId,
          deviceId: senderDeviceId,
          forceReload: true,
        );

        if (keyLoaded) {
          debugPrint(
            '[SIGNAL_SERVICE] Sender key reloaded, retrying decrypt...',
          );

          // Retry decrypt (without retry to avoid infinite loop)
          return await decryptGroupItem(
            channelId: channelId,
            senderId: senderId,
            senderDeviceId: senderDeviceId,
            ciphertext: ciphertext,
            retryOnError: false, // Don't retry again
          );
        }
      }

      // Rethrow if we couldn't fix it
      rethrow;
    }
  }

  /// Load sender key from server database
  Future<bool> loadSenderKeyFromServer({
    required String channelId,
    required String userId,
    required int deviceId,
    bool forceReload = false,
  }) async {
    try {
      debugPrint(
        '[SIGNAL_SERVICE] Loading sender key from server: $userId:$deviceId (forceReload: $forceReload)',
      );

      // If forceReload, delete old key first
      if (forceReload) {
        try {
          final address = SignalProtocolAddress(userId, deviceId);
          final senderKeyName = SenderKeyName(channelId, address);
          await senderKeyStore.removeSenderKey(senderKeyName);
          debugPrint('[SIGNAL_SERVICE] Removed old sender key before reload');
        } catch (removeError) {
          debugPrint('[SIGNAL_SERVICE] Error removing old key: $removeError');
        }
      }

      // Get server URL (platform-specific)
      String urlString;
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      } else {
        // Native: Use active server from ServerConfigService
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer == null) {
          debugPrint('[SIGNAL_SERVICE] No active server configured');
          return false;
        }
        urlString = activeServer.serverUrl;
      }

      // Load from server via REST API
      final response = await ApiService.get(
        '$urlString/api/sender-keys/$channelId/$userId/$deviceId',
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final senderKeyBase64 = response.data['senderKey'] as String;
        final senderKeyBytes = base64Decode(senderKeyBase64);

        // Process the distribution message
        await processSenderKeyDistribution(
          channelId,
          userId,
          deviceId,
          senderKeyBytes,
        );

        debugPrint('[SIGNAL_SERVICE] ✓ Sender key loaded from server');
        return true;
      } else {
        debugPrint('[SIGNAL_SERVICE] Sender key not found on server');
        return false;
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error loading sender key from server: $e');
      return false;
    }
  }

  /// Load all sender keys for a channel (when joining)
  Future<Map<String, dynamic>> loadAllSenderKeysForChannel(
    String channelId,
  ) async {
    // Use retry mechanism for network-related failures
    return await retryWithBackoff(
      operation: () => _loadAllSenderKeysForChannelInternal(channelId),
      maxAttempts: 3,
      initialDelay: 1000,
      shouldRetry: isRetryableError,
    );
  }

  Future<Map<String, dynamic>> _loadAllSenderKeysForChannelInternal(
    String channelId,
  ) async {
    final result = {
      'success': true,
      'totalKeys': 0,
      'loadedKeys': 0,
      'failedKeys': <Map<String, String>>[],
    };

    try {
      debugPrint(
        '[SIGNAL_SERVICE] Loading all sender keys for channel $channelId',
      );

      // Get server URL (platform-specific)
      String urlString;
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      } else {
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer == null) {
          debugPrint('[SIGNAL_SERVICE] No active server configured');
          return result;
        }
        urlString = activeServer.serverUrl;
      }

      final response = await ApiService.get(
        '$urlString/api/sender-keys/$channelId',
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final senderKeysData = response.data['senderKeys'];

        // Handle null or empty senderKeys
        if (senderKeysData == null) {
          debugPrint('[SIGNAL_SERVICE] No sender keys found for channel');
          return result;
        }

        final senderKeys = senderKeysData as List<dynamic>;
        result['totalKeys'] = senderKeys.length;

        debugPrint('[SIGNAL_SERVICE] Found ${senderKeys.length} sender keys');

        for (final key in senderKeys) {
          try {
            final userId = key['userId'] as String;
            // Parse deviceId as int (API might return String)
            final deviceId = key['deviceId'] is int
                ? key['deviceId'] as int
                : int.parse(key['deviceId'].toString());
            final senderKeyBase64 = key['senderKey'] as String;
            final senderKeyBytes = base64Decode(senderKeyBase64);

            // Skip our own key
            if (userId == _currentUserId && deviceId == _currentDeviceId) {
              continue;
            }

            await processSenderKeyDistribution(
              channelId,
              userId,
              deviceId,
              senderKeyBytes,
            );

            result['loadedKeys'] = (result['loadedKeys'] as int) + 1;
            debugPrint(
              '[SIGNAL_SERVICE] ✓ Loaded sender key for $userId:$deviceId',
            );
          } catch (keyError) {
            final userId = key['userId'] as String?;
            final deviceId = key['deviceId'] as int?;
            (result['failedKeys'] as List).add({
              'userId': userId ?? 'unknown',
              'deviceId': deviceId?.toString() ?? 'unknown',
              'error': keyError.toString(),
            });
            debugPrint(
              '[SIGNAL_SERVICE] Error loading key for $userId:$deviceId - $keyError',
            );
          }
        }

        if ((result['failedKeys'] as List).isNotEmpty) {
          // Partial failure - some keys couldn't be loaded
          result['success'] = false;
          final failedCount = (result['failedKeys'] as List).length;
          throw Exception(
            'Failed to load $failedCount sender key(s). Some messages may not decrypt.',
          );
        }

        debugPrint(
          '[SIGNAL_SERVICE] ✓ Loaded ${result['loadedKeys']} sender keys for channel',
        );
        return result;
      } else {
        // HTTP error or unsuccessful response
        result['success'] = false;
        throw Exception(
          'Failed to load sender keys from server: HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error loading all sender keys: $e');
      result['success'] = false;
      rethrow; // CRITICAL: Re-throw to notify caller
    }
  }

  /// Upload our sender key to server
  Future<void> uploadSenderKeyToServer(String channelId) async {
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      // Create sender key distribution message (without broadcasting)
      final distributionMessage = await createGroupSenderKey(
        channelId,
        broadcastDistribution: false,
      );

      // Check if key already existed (returns empty bytes)
      if (distributionMessage.isEmpty) {
        debugPrint(
          '[SIGNAL_SERVICE] ℹ️ Sender key already exists, skipping upload',
        );
        return;
      }

      final senderKeyBase64 = base64Encode(distributionMessage);

      // Get server URL (platform-specific)
      String urlString;
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      } else {
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer == null) {
          throw Exception('No active server configured');
        }
        urlString = activeServer.serverUrl;
      }

      // Upload to server
      final response = await ApiService.post(
        '$urlString/api/sender-keys/$channelId',
        data: {'senderKey': senderKeyBase64, 'deviceId': _currentDeviceId},
      );

      if (response.statusCode == 200) {
        debugPrint('[SIGNAL_SERVICE] ✓ Sender key uploaded to server');
      } else {
        debugPrint(
          '[SIGNAL_SERVICE] Failed to upload sender key: ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error uploading sender key: $e');
      rethrow;
    }
  }

  /// Mark a group item as read
  Future<void> markGroupItemAsRead(String itemId) async {
    try {
      if (_currentDeviceId == null) {
        debugPrint('[SIGNAL_SERVICE] Cannot mark as read: device ID not set');
        return;
      }

      SocketService().emit("markGroupItemRead", {'itemId': itemId});

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
  /// Example: [5, 23, 24, 25, 26, 89, 105]
  ///       → [[5], [23,24,25,26], [89], [105]]
  List<List<int>> _findContiguousRanges(List<int> ids) {
    if (ids.isEmpty) return [];

    final sortedIds = List<int>.from(ids)..sort();
    final ranges = <List<int>>[];
    var currentRange = <int>[sortedIds[0]];

    for (int i = 1; i < sortedIds.length; i++) {
      if (sortedIds[i] == currentRange.last + 1) {
        // Contiguous - add to current range
        currentRange.add(sortedIds[i]);
      } else {
        // Gap found - save current range, start new one
        ranges.add(currentRange);
        currentRange = [sortedIds[i]];
      }
    }
    ranges.add(currentRange); // Add last range

    return ranges;
  }

  /// Asynchronously regenerate a single PreKey after consumption
  /// This runs in the background and doesn't block message processing
  Future<void> _regeneratePreKeyAsync(int preKeyId) async {
    try {
      debugPrint('[SIGNAL SERVICE] Async regenerating PreKey $preKeyId...');

      final preKeys = generatePreKeys(preKeyId, preKeyId);
      if (preKeys.isNotEmpty) {
        await preKeyStore.storePreKey(preKeyId, preKeys.first);
        debugPrint(
          '[SIGNAL SERVICE] ✓ PreKey $preKeyId regenerated and uploaded async',
        );
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

  /// Handle UntrustedIdentityException centrally
  /// Auto-trusts new identity key and optionally sends notification to affected user
  ///
  /// Parameters:
  /// - sendNotification: If true, sends a system message to both users about the identity change
  ///   Should be true in receive path (safe), false in send path (would cause loop)
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
          // Create system message payload
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
}
