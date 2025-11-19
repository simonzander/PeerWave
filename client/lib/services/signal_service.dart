import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'api_service.dart';
import '../web_config.dart';
import 'socket_service.dart';
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
import 'storage/sqlite_recent_conversations_store.dart';
import 'storage/database_helper.dart';
import 'user_profile_service.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';
import 'event_bus.dart';

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
  final Map<String, List<Function(Map<String, dynamic>)>> _receiveItemCallbacks = {};
  
  // NEW: Callbacks for received group items (group messages)
  // Key format: "type:channel" (e.g., "message:channel-uuid-456")
  final Map<String, List<Function(Map<String, dynamic>)>> _receiveItemChannelCallbacks = {};
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
    debugPrint('[SIGNAL SERVICE] Current user set: userId=$userId, deviceId=$deviceId');
  }
  
  /// Set the UnreadMessagesProvider for badge updates
  void setUnreadMessagesProvider(UnreadMessagesProvider? provider) {
    _unreadMessagesProvider = provider;
    debugPrint('[SIGNAL SERVICE] UnreadMessagesProvider ${provider != null ? 'connected' : 'disconnected'}');
  }

  /// 🔒 SYNC-LOCK: Wait if identity key regeneration is in progress
  /// This prevents race conditions during key operations
  Future<void> _waitForRegenerationIfNeeded() async {
    if (identityStore.isRegenerating) {
      debugPrint('[SIGNAL SERVICE] 🔒 Identity regeneration in progress - waiting...');
      // The acquire lock will wait until regeneration completes
      await identityStore.acquireLock();
      identityStore.releaseLock();
      debugPrint('[SIGNAL SERVICE] ✓ Identity regeneration completed - proceeding');
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
          debugPrint('[SIGNAL SERVICE] Error is not retryable, throwing immediately');
          rethrow;
        }
        
        // Check if we've exhausted attempts
        if (attempt >= maxAttempts) {
          debugPrint('[SIGNAL SERVICE] Max attempts reached, giving up');
          rethrow;
        }
        
        // Calculate delay with exponential backoff
        final currentDelay = (delay * (1 << (attempt - 1))).clamp(initialDelay, maxDelay);
        debugPrint('[SIGNAL SERVICE] Waiting ${currentDelay}ms before retry...');
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

    debugPrint('[SIGNAL SERVICE] Processing ${queue.queueSize} queued messages...');

    await queue.processQueue(
      sendFunction: (queuedMessage) async {
        try {
          if (queuedMessage.type == 'group') {
            // Send group message
            final channelId = queuedMessage.metadata['channelId'] as String;
            debugPrint('[SIGNAL SERVICE] Sending queued group message to channel $channelId');
            
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
            debugPrint('[SIGNAL SERVICE] Sending queued direct message to $recipientId');
            
            await sendItem(
              recipientUserId: recipientId,
              type: 'message',
              payload: queuedMessage.text,
              itemId: queuedMessage.itemId,
            );
            return true;
          } else {
            debugPrint('[SIGNAL SERVICE] Unknown message type: ${queuedMessage.type}');
            return false;
          }
        } catch (e) {
          debugPrint('[SIGNAL SERVICE] Failed to send queued message ${queuedMessage.itemId}: $e');
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
    
    debugPrint('[SIGNAL SERVICE] 📬 $count pending messages available (timestamp: $timestamp)');
    
    // Start background sync automatically
    _syncPendingMessages(count);
  }

  /// 🚀 Sync pending messages from server with pagination
  Future<void> _syncPendingMessages(int totalCount) async {
    debugPrint('[SIGNAL SERVICE] 🔄 Starting sync of $totalCount pending messages');
    
    int offset = 0;
    int synced = 0;
    const batchSize = 20;
    bool hasMore = true;
    
    // Emit sync started event
    EventBus.instance.emit(AppEvent.syncStarted, {
      'total': totalCount,
    });
    
    while (hasMore && synced < totalCount) {
      try {
        debugPrint('[SIGNAL SERVICE] Requesting batch: offset=$offset, limit=$batchSize');
        
        // Request batch from server
        SocketService().emit('fetchPendingMessages', {
          'limit': batchSize,
          'offset': offset,
        });
        
        // Wait for response (we'll handle it in _handlePendingMessagesResponse)
        // The response handler will process messages and update counters
        
        // For now, we need to track this sync operation
        // We'll use a simple flag to know when a batch is complete
        await Future.delayed(Duration(milliseconds: 500)); // Give server time to respond
        
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
      
      debugPrint('[SIGNAL SERVICE] 📨 Received batch: ${items.length} messages, hasMore=$hasMore, offset=$offset');
      
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
          debugPrint('[SIGNAL SERVICE] ⚠️ Failed to process pending message: $e');
          failed++;
          // Continue with next message
        }
      }
      
      debugPrint('[SIGNAL SERVICE] ✓ Batch processed: $processed succeeded, $failed failed');
      
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
        EventBus.instance.emit(AppEvent.syncComplete, {
          'processed': processed,
        });
      }
      
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ❌ Error handling pending messages response: $e');
      EventBus.instance.emit(AppEvent.syncError, {
        'error': e.toString(),
      });
    }
  }

  Future<void> test() async {
    debugPrint("SignalService test method called");
    final AliceIdentityKeyPair = generateIdentityKeyPair();
    final AliceRegistrationId = generateRegistrationId(false);
    final AliceIdentityStore = InMemoryIdentityKeyStore(AliceIdentityKeyPair, AliceRegistrationId);
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
    await AliceSignedPreKeyStore.storeSignedPreKey(aliceSignedPreKey.id, aliceSignedPreKey);
    
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
      await BobSignedPreKeyStore.storeSignedPreKey(bobSignedPreKey.id, bobSignedPreKey);
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
      BobIdentityKeyPair.getPublicKey());

    await AliceSessionBuilder.processPreKeyBundle(BobRetrievedPreKey);

    final aliceSessionCipher = SessionCipher(
      AliceSessionStore, AlicePreKeyStore, AliceSignedPreKeyStore, AliceIdentityStore, BobAddress);
    final ciphertext = await aliceSessionCipher
        .encrypt(Uint8List.fromList(utf8.encode('Hello Mixin🤣')));
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
      await bobSessionCipher
          .decryptWithCallback(ciphertext as PreKeySignalMessage, (plaintext) {
        // ignore: avoid_print
        debugPrint('Bob decrypted: ${utf8.decode(plaintext)}');
      });
    } else if (ciphertext.getType() == CiphertextMessage.whisperType) {
      final plaintext = await bobSessionCipher.decryptFromSignal(ciphertext as SignalMessage);
      // ignore: avoid_print
      debugPrint('Bob decrypted: ${utf8.decode(plaintext)}');
    }

}


  Future<void> init() async {
    debugPrint('[SIGNAL INIT] 🔍 init() called');
    debugPrint('[SIGNAL INIT] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered');
    
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
    debugPrint('[SIGNAL SERVICE] Offline queue loaded: ${OfflineMessageQueue.instance.queueSize} messages');

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
    debugPrint('[SIGNAL SERVICE] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered');
    
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

    // 🚀 CRITICAL: Notify server that client is ready to receive events
    SocketService().notifyClientReady();
    debugPrint('[SIGNAL INIT] ✓ Server notified: Client ready for events');

    // Check status with server (server will only respond if client is ready)
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    debugPrint('[SIGNAL SERVICE] Stores and listeners initialized successfully');
  }

  /// Progressive initialization with progress callbacks
  /// Generates keys in batches to prevent UI freeze
  /// 
  /// onProgress callback receives:
  /// - statusText: Current operation description
  /// - current: Current progress (0-112)
  /// - total: Total steps (112: 1 KeyPair + 1 SignedPreKey + 110 PreKeys)
  /// - percentage: Progress percentage (0-100)
  Future<void> initWithProgress(Function(String statusText, int current, int total, double percentage) onProgress) async {
    debugPrint('[SIGNAL INIT] 🔍 initWithProgress() called');
    debugPrint('[SIGNAL INIT] Current state: _isInitialized=$_isInitialized, _storesCreated=$_storesCreated, _listenersRegistered=$_listenersRegistered');
    
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
      debugPrint('[SIGNAL INIT] Device identity not in memory, checking storage...');
      if (!await DeviceIdentityService.instance.tryRestoreFromSession()) {
        throw Exception('Device identity not initialized. Please log in first.');
      }
      debugPrint('[SIGNAL INIT] Device identity restored from storage');
    }

    // 🔑 CRITICAL: Check if encryption key exists in SessionStorage
    final deviceId = DeviceIdentityService.instance.deviceId;
    final encryptionKey = WebAuthnCryptoService.instance.getKeyFromSession(deviceId);
    if (encryptionKey == null) {
      throw Exception('Encryption key not found. Please log in again to re-authenticate with WebAuthn.');
    }
    debugPrint('[SIGNAL INIT] ✓ Encryption key verified');

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
        debugPrint('[SIGNAL INIT] ⚠️ Found ${existingPreKeyIds.length} PreKeys (expected max 110)');
      }
      if (hasInvalidIds) {
        final invalidIds = existingPreKeyIds.where((id) => id >= 110).toList();
        debugPrint('[SIGNAL INIT] ⚠️ Found invalid PreKey IDs (>= 110): $invalidIds');
      }
      
      debugPrint('[SIGNAL INIT] 🔧 Deleting ALL PreKeys and regenerating fresh set (IDs 0-109)...');
      
      // Delete ALL existing PreKeys
      for (final id in existingPreKeyIds) {
        await preKeyStore.removePreKey(id, sendToServer: true);
      }
      
      existingPreKeyIds = [];
      debugPrint('[SIGNAL INIT] ✓ Cleanup complete, will generate fresh 110 PreKeys');
    }
    
    final neededPreKeys = 110 - existingPreKeyIds.length;
    
    if (neededPreKeys > 0) {
      debugPrint('[SIGNAL INIT] Generating $neededPreKeys pre keys (IDs must be 0-109)');
      
      // Find missing IDs in range 0-109
      final existingIds = existingPreKeyIds.toSet();
      final missingIds = List.generate(110, (i) => i).where((id) => !existingIds.contains(id)).toList();
      
      if (missingIds.length != neededPreKeys) {
        debugPrint('[SIGNAL INIT] ⚠️ Mismatch: need $neededPreKeys keys but found ${missingIds.length} missing IDs');
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
      
      debugPrint('[SIGNAL INIT] Found ${contiguousRanges.length} range(s) to generate');
      
      // 🚀 BATCH UPLOAD: Process ranges in batches of 20 keys for HTTP upload
      const int uploadBatchSize = 20;
      List<PreKeyRecord> uploadBatch = [];
      
      for (final range in contiguousRanges) {
        if (range.length > 1) {
          // BATCH GENERATION: Multiple contiguous IDs (FAST!)
          final start = range.first;
          final end = range.last;
          debugPrint('[SIGNAL INIT] Batch generating PreKeys $start-$end (${range.length} keys)');
          
          final preKeys = generatePreKeys(start, end);
          
          // Add to upload batch
          for (final preKey in preKeys) {
            uploadBatch.add(preKey);
            
            // Upload batch when it reaches uploadBatchSize or this is the last key
            if (uploadBatch.length >= uploadBatchSize || 
                keysGeneratedInSession + uploadBatch.length >= missingIds.length) {
              
              final success = await preKeyStore.storePreKeysBatch(uploadBatch);
              
              if (success) {
                keysGeneratedInSession += uploadBatch.length;
                
                // Update progress based on batch size
                final totalKeysNow = existingPreKeyIds.length + keysGeneratedInSession;
                updateProgress(
                  'Generating pre keys $keysGeneratedInSession of ${missingIds.length} needed (total: $totalKeysNow/110)...',
                  currentStep + keysGeneratedInSession
                );
              } else {
                debugPrint('[SIGNAL INIT] ⚠️ Batch upload failed, will retry on next initialization');
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
                keysGeneratedInSession + uploadBatch.length >= missingIds.length) {
              
              final success = await preKeyStore.storePreKeysBatch(uploadBatch);
              
              if (success) {
                keysGeneratedInSession += uploadBatch.length;
                
                // Update progress based on batch size
                final totalKeysNow = existingPreKeyIds.length + keysGeneratedInSession;
                updateProgress(
                  'Generating pre keys $keysGeneratedInSession of ${missingIds.length} needed (total: $totalKeysNow/110)...',
                  currentStep + keysGeneratedInSession
                );
              } else {
                debugPrint('[SIGNAL INIT] ⚠️ Batch upload failed, will retry on next initialization');
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
          
          final totalKeysNow = existingPreKeyIds.length + keysGeneratedInSession;
          updateProgress(
            'Generating pre keys $keysGeneratedInSession of ${missingIds.length} needed (total: $totalKeysNow/110)...',
            currentStep + keysGeneratedInSession
          );
        } else {
          debugPrint('[SIGNAL INIT] ⚠️ Final batch upload failed, will retry on next initialization');
        }
      }
      
      // Update currentStep by total keys generated
      currentStep += missingIds.length;
    } else {
      debugPrint('[SIGNAL INIT] Pre keys already sufficient (${existingPreKeyIds.length}/110)');
      // Skip to end
      currentStep = totalSteps;
      updateProgress('Pre keys already ready', currentStep);
    }

    // Register socket listeners
    await _registerSocketListeners();

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    // 🚀 CRITICAL: Notify server that client is ready to receive events
    // This must be called AFTER:
    // 1. All PreKeys generated and uploaded
    // 2. All socket listeners registered
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
      debugPrint('[SIGNAL SERVICE] Socket listeners already registered, skipping...');
      return;
    }
    
    debugPrint('[SIGNAL SERVICE] Registering Socket.IO listeners...');
    
    // Setup offline queue processing on reconnect
    SocketService().registerListener("connect", (_) {
      debugPrint('[SIGNAL SERVICE] Socket reconnected, processing offline queue...');
      _processOfflineQueue();
    });
    
    SocketService().registerListener("receiveItem", (data) {
      receiveItem(data);
    });

    SocketService().registerListener("groupMessage", (data) {
      // Handle group message via callback system
      if (_itemTypeCallbacks.containsKey('groupMessage')) {
        for (final callback in _itemTypeCallbacks['groupMessage']!) {
          callback(data);
        }
      }
    });

    // NEW: Group Item Socket.IO listener
    SocketService().registerListener("groupItem", (data) {
      // Update unread count for group messages
      if (_unreadMessagesProvider != null && data['channel'] != null && data['type'] != null) {
        final channelId = data['channel'] as String;
        final messageType = data['type'] as String;
        // Only increment for 'message' and 'file' types
        _unreadMessagesProvider!.incrementIfBadgeType(messageType, channelId, true);
      }
      
      // ✅ Emit EventBus event for new group message/item (after decryption in callbacks)
      final type = data['type'];
      final channel = data['channel'];
      if (type != null && channel != null) {
        // Only emit for actual content (message, file), not system messages
        if (type == 'message' || type == 'file') {
          debugPrint('[SIGNAL SERVICE] → EVENT_BUS: newMessage (group) - type=$type, channel=$channel');
          EventBus.instance.emit(AppEvent.newMessage, data);
        }
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
          debugPrint('[SIGNAL SERVICE] Triggered ${_receiveItemChannelCallbacks[key]!.length} receiveItemChannel callbacks for $key');
        }
      }
    });

    // NEW: Group Item delivery confirmation
    SocketService().registerListener("groupItemDelivered", (data) {
      if (_deliveryCallbacks.containsKey('groupItem')) {
        for (final callback in _deliveryCallbacks['groupItem']!) {
          callback(data['itemId']);
        }
      }
    });

    // NEW: Group Item read update
    SocketService().registerListener("groupItemReadUpdate", (data) {
      if (_readCallbacks.containsKey('groupItem')) {
        for (final callback in _readCallbacks['groupItem']!) {
          callback(data);
        }
      }
    });

    SocketService().registerListener("deliveryReceipt", (data) async {
      await _handleDeliveryReceipt(data);
    });

    SocketService().registerListener("groupMessageReadReceipt", (data) {
      _handleGroupMessageReadReceipt(data);
    });

    // 🚀 NEW: Pending messages notification from server
    SocketService().registerListener("pendingMessagesAvailable", (data) {
      _handlePendingMessagesAvailable(data);
    });

    // 🚀 NEW: Pending messages response from server
    SocketService().registerListener("pendingMessagesResponse", (data) {
      _handlePendingMessagesResponse(data);
    });

    // 🚀 NEW: Pending messages fetch error
    SocketService().registerListener("fetchPendingMessagesError", (data) {
      debugPrint('[SIGNAL SERVICE] ❌ Error fetching pending messages: ${data['error']}');
    });

    SocketService().registerListener("signalStatusResponse", (status) async {
      await _ensureSignalKeysPresent(status);
      
      // Check SignedPreKey rotation after status check
      await _checkSignedPreKeyRotation();
    });

    // NEW: Receive sender key distribution messages
    SocketService().registerListener("receiveSenderKeyDistribution", (data) async {
      try {
        final groupId = data['groupId'] as String;
        final senderId = data['senderId'] as String;
        // Parse senderDeviceId as int (socket might send String)
        final senderDeviceId = data['senderDeviceId'] is int
            ? data['senderDeviceId'] as int
            : int.parse(data['senderDeviceId'].toString());
        final distributionMessageBase64 = data['distributionMessage'] as String;
        
        debugPrint('[SIGNAL_SERVICE] Received sender key distribution from $senderId:$senderDeviceId for group $groupId');
        
        final distributionMessageBytes = base64Decode(distributionMessageBase64);
        await processSenderKeyDistribution(
          groupId,
          senderId,
          senderDeviceId,
          distributionMessageBytes,
        );
        
        debugPrint('[SIGNAL_SERVICE] ✓ Sender key distribution processed');
      } catch (e) {
        debugPrint('[SIGNAL_SERVICE] Error processing sender key distribution: $e');
      }
    });
    
    // Setup Event Bus forwarding for user/channel events
    _setupEventBusForwarding();
    
    _listenersRegistered = true;
    debugPrint('[SIGNAL SERVICE] ✅ Socket.IO listeners registered');
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

  Future<void> _ensureSignalKeysPresent(status) async {
    // Use a socket callback to get status
    debugPrint('[SIGNAL SERVICE] signalStatus: $status');
    
    // Check if user is authenticated
    if (status is Map && status['error'] != null) {
      debugPrint('[SIGNAL SERVICE] ERROR: ${status['error']} - Cannot upload Signal keys without authentication');
      return;
    }
    
    // Guard: Only run after initialization is complete
    if (!_isInitialized) {
      debugPrint('[SIGNAL SERVICE] ⚠️ Not initialized yet, skipping key sync check');
      return;
    }
    
    // 1. Identity
    if (status is Map && status['identity'] != true) {
      debugPrint('[SIGNAL SERVICE] Uploading missing identity');
    final identityData = await identityStore.getIdentityKeyPairData();
    final registrationId = await identityStore.getLocalRegistrationId();
      SocketService().emit("signalIdentity", {
        'publicKey': identityData['publicKey'],
        'registrationId': registrationId.toString(),
      });
    }
    // 2. PreKeys - Sync check ONLY (no generation - that's done in initWithProgress)
    final int preKeysCount = (status is Map && status['preKeys'] is int) ? status['preKeys'] : 0;
    debugPrint('[SIGNAL SERVICE] ========================================');
    debugPrint('[SIGNAL SERVICE] PreKey Sync Check:');
    debugPrint('[SIGNAL SERVICE]   Server count: $preKeysCount');
    
    // 🔧 OPTIMIZED: Only get IDs first (no decryption for count check)
    final localPreKeyIds = await preKeyStore.getAllPreKeyIds();
    debugPrint('[SIGNAL SERVICE]   Local count:  ${localPreKeyIds.length}');
    debugPrint('[SIGNAL SERVICE]   Difference:   ${localPreKeyIds.length - preKeysCount}');
    debugPrint('[SIGNAL SERVICE] ========================================');
    
    if (preKeysCount < 20) {
      // Server critically low
      if (localPreKeyIds.isEmpty) {
        // No local PreKeys AND server has none → This shouldn't happen after initWithProgress()
        debugPrint('[SIGNAL SERVICE] ⚠️ CRITICAL: No local PreKeys found! Keys should have been generated during initialization.');
        debugPrint('[SIGNAL SERVICE] This indicates initWithProgress() was skipped or failed.');
        // Don't generate here - initialization should handle this
        return;
      } else if (preKeysCount == 0) {
        // Server has 0 but we have local → CRITICAL sync issue!
        debugPrint('[SIGNAL SERVICE] ⚠️ CRITICAL: Server has 0 PreKeys but local has ${localPreKeyIds.length}!');
        debugPrint('[SIGNAL SERVICE] Re-uploading ALL local PreKeys to server...');
        // NOW load full PreKeys (with decryption) only when needed for upload
        final localPreKeys = await preKeyStore.getAllPreKeys();
        final preKeysPayload = localPreKeys.map((pk) => {
          'id': pk.id,
          'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
        }).toList();
        SocketService().emit("storePreKeys", { 'preKeys': preKeysPayload });
      } else if (localPreKeyIds.length > preKeysCount + 10) {
        // Server significantly behind local (>10 difference) → Re-sync
        debugPrint('[SIGNAL SERVICE] ⚠️ Sync gap detected: Server has $preKeysCount, local has ${localPreKeyIds.length}');
        debugPrint('[SIGNAL SERVICE] Uploading ${localPreKeyIds.length} local PreKeys to server...');
        // NOW load full PreKeys (with decryption) only when needed for upload
        final localPreKeys = await preKeyStore.getAllPreKeys();
        final preKeysPayload = localPreKeys.map((pk) => {
          'id': pk.id,
          'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
        }).toList();
        SocketService().emit("storePreKeys", { 'preKeys': preKeysPayload });
      } else {
        // Server has some but < 20 → Upload what we have
        debugPrint('[SIGNAL SERVICE] Server needs more PreKeys, uploading ${localPreKeyIds.length} local keys');
        // NOW load full PreKeys (with decryption) only when needed for upload
        final localPreKeys = await preKeyStore.getAllPreKeys();
        final preKeysPayload = localPreKeys.map((pk) => {
          'id': pk.id,
          'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
        }).toList();
        SocketService().emit("storePreKeys", { 'preKeys': preKeysPayload });
      }
    } else if (localPreKeyIds.length > preKeysCount) {
      // NEW: Server has enough (>= 20), but local has MORE
      // Only re-upload if difference is significant (>5 keys) to avoid unnecessary work
      final difference = localPreKeyIds.length - preKeysCount;
      
      if (difference > 5) {
        // Significant difference - upload all keys
        debugPrint('[SIGNAL SERVICE] 🔄 Local has $difference more PreKeys than server (significant)');
        debugPrint('[SIGNAL SERVICE] Uploading ALL local PreKeys to ensure server sync...');
        // NOW load full PreKeys (with decryption) only when needed for upload
        final localPreKeys = await preKeyStore.getAllPreKeys();
        final preKeysPayload = localPreKeys.map((pk) => {
          'id': pk.id,
          'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
        }).toList();
        SocketService().emit("storePreKeys", { 'preKeys': preKeysPayload });
      } else {
        // Small difference - server will request missing keys when needed
        debugPrint('[SIGNAL SERVICE] ℹ️ Local has $difference more PreKeys than server (minor difference, will sync on demand)');
      }
    } else {
      debugPrint('[SIGNAL SERVICE] ✅ Server has sufficient PreKeys ($preKeysCount >= 20) and is in sync');
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
    }
  }

  /// Check if SignedPreKey needs rotation and rotate if necessary
  /// Called automatically after signalStatus check
  Future<void> _checkSignedPreKeyRotation() async {
    try {
      if (!_isInitialized) {
        debugPrint('[SIGNAL_SERVICE] Not initialized, skipping SignedPreKey rotation check');
        return;
      }

      final needsRotation = await signedPreKeyStore.needsRotation();
      if (needsRotation) {
        debugPrint('[SIGNAL_SERVICE] SignedPreKey rotation needed, starting rotation...');
        final identityKeyPair = await identityStore.getIdentityKeyPair();
        await signedPreKeyStore.rotateSignedPreKey(identityKeyPair);
        debugPrint('[SIGNAL_SERVICE] ✓ SignedPreKey rotation completed');
      } else {
        debugPrint('[SIGNAL_SERVICE] SignedPreKey rotation not needed (< 7 days old)');
      }
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL_SERVICE] Error during SignedPreKey rotation check: $e');
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
  void registerReceiveItem(String type, String sender, Function(Map<String, dynamic>) callback) {
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
  void registerReceiveItemChannel(String type, String channel, Function(Map<String, dynamic>) callback) {
    final key = '$type:$channel';
    _receiveItemChannelCallbacks.putIfAbsent(key, () => []).add(callback);
    debugPrint('[SIGNAL SERVICE] Registered receiveItemChannel callback for $key');
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
  void unregisterReceiveItem(String type, String sender, Function(Map<String, dynamic>) callback) {
    final key = '$type:$sender';
    _receiveItemCallbacks[key]?.remove(callback);
    if (_receiveItemCallbacks[key]?.isEmpty ?? false) {
      _receiveItemCallbacks.remove(key);
      debugPrint('[SIGNAL SERVICE] Removed all receiveItem callbacks for $key');
    }
  }

  /// NEW: Unregister callback for received group items
  void unregisterReceiveItemChannel(String type, String channel, Function(Map<String, dynamic>) callback) {
    final key = '$type:$channel';
    _receiveItemChannelCallbacks[key]?.remove(callback);
    if (_receiveItemChannelCallbacks[key]?.isEmpty ?? false) {
      _receiveItemChannelCallbacks.remove(key);
      debugPrint('[SIGNAL SERVICE] Removed all receiveItemChannel callbacks for $key');
    }
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
  Future<List<Map<String, dynamic>>> loadSentMessages(String recipientUserId) async {
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      final messages = await messageStore.getMessagesFromConversation(
        recipientUserId,
        types: ['message', 'file'],
      );
      
      // Filter only sent messages and convert to expected format
      return messages
          .where((msg) => msg['direction'] == 'sent')
          .map((msg) => {
            'itemId': msg['item_id'],
            'message': msg['message'],
            'timestamp': msg['timestamp'],
            'recipientId': recipientUserId,
            'type': msg['type'],
            'status': msg['status'], // Include status
          })
          .toList();
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] ✗ Error loading sent messages from SQLite: $e');
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
      
      return result.map((msg) => {
        'itemId': msg['item_id'],
        'message': msg['message'],
        'timestamp': msg['timestamp'],
        'recipientId': msg['sender'], // sender field stores recipient for sent messages
        'type': msg['type'],
        'status': msg['status'], // Include status
      }).toList();
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] ✗ Error loading all sent messages from SQLite: $e');
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
          debugPrint("[SIGNAL SERVICE] ✓ Using cached decrypted message from SQLite for itemId: $itemId");
          return cached['message'] as String;
        } else {
          debugPrint("[SIGNAL SERVICE] Cache miss for itemId: $itemId - will decrypt");
        }
      } catch (e) {
        debugPrint("[SIGNAL SERVICE] ⚠️ Error checking cache: $e");
      }
    } else {
      debugPrint("[SIGNAL SERVICE] No itemId provided - cannot use cache");
    }
    
    debugPrint("[SIGNAL SERVICE] Decrypting new message: itemId=$itemId, sender=$sender, deviceId=$senderDeviceId");
    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);
    
    try {
      final message = await decryptItem(
        senderAddress: senderAddress,
        payload: payload,
        cipherType: cipherType,
      );
      
      // Cache the decrypted message to prevent re-decryption in SQLite
      // IMPORTANT: Only cache 1:1 messages (no channelId)
      // ❌ SYSTEM MESSAGES: Don't cache read_receipt, delivery_receipt, or other system messages
      final messageType = data['type'] as String?;
      final isSystemMessage = messageType == 'read_receipt' || 
                              messageType == 'delivery_receipt' ||
                              messageType == 'senderKeyRequest' ||
                              messageType == 'fileKeyRequest';
      
      if (itemId != null && message.isNotEmpty && data['channel'] == null && !isSystemMessage) {
        // Store in SQLite database
        try {
          final messageStore = await SqliteMessageStore.getInstance();
          final messageTimestamp = data['timestamp'] ?? data['createdAt'] ?? DateTime.now().toIso8601String();
          
          await messageStore.storeReceivedMessage(
            itemId: itemId,
            sender: sender,
            senderDeviceId: senderDeviceId,
            message: message,
            timestamp: messageTimestamp,
            type: data['type'] ?? 'message',
          );
          
          // Update recent conversations list
          final conversationsStore = await SqliteRecentConversationsStore.getInstance();
          await conversationsStore.addOrUpdateConversation(
            userId: sender,
            displayName: sender, // Will be enriched by UI layer
          );
          
          // Increment unread count for this conversation
          await conversationsStore.incrementUnreadCount(sender);
          
          debugPrint("[SIGNAL SERVICE] ✓ Cached decrypted 1:1 message in SQLite for itemId: $itemId");
          
          // Load sender's profile if not already cached
          try {
            final profileService = UserProfileService.instance;
            if (!profileService.isProfileCached(sender)) {
              debugPrint("[SIGNAL SERVICE] Loading profile for sender: $sender");
              await profileService.loadProfiles([sender]);
              debugPrint("[SIGNAL SERVICE] ✓ Sender profile loaded");
            }
          } catch (e) {
            debugPrint("[SIGNAL SERVICE] ⚠ Failed to load sender profile (server may be unavailable): $e");
            // Don't block message processing if profile loading fails
          }
        } catch (e) {
          debugPrint("[SIGNAL SERVICE] ✗ Failed to cache in SQLite: $e");
        }
      } else if (isSystemMessage) {
        debugPrint("[SIGNAL SERVICE] ⚠ Skipping cache for system message type: $messageType");
      } else if (data['channel'] != null) {
        debugPrint("[SIGNAL SERVICE] ⚠ Skipping cache for group message (use DecryptedGroupItemsStore)");
      }
      
      return message;
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ✗ Decryption failed for itemId: $itemId - $e');
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
  debugPrint("[SIGNAL SERVICE] ===============================================");
  debugPrint("[SIGNAL SERVICE] receiveItem called for this device");
  debugPrint("[SIGNAL SERVICE] ===============================================");
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
    debugPrint("[SIGNAL SERVICE] ✓ Message decrypted and deleted from server: $itemId");
    
  } catch (e) {
    debugPrint("[SIGNAL SERVICE] ✗ Decryption error: $e");
    
    // If it's a DuplicateMessageException, the message was already processed
    if (e.toString().contains('DuplicateMessageException')) {
      debugPrint("[SIGNAL SERVICE] ⚠️ Duplicate message detected (already processed)");
      // Still delete from server to clean up
      deleteItemFromServer(itemId);
      return;
    }
    
    // For other errors, also delete from server to prevent stuck messages
    debugPrint("[SIGNAL SERVICE] ⚠️ Decryption failed - deleting from server to prevent stuck message");
    deleteItemFromServer(itemId);
    return;
  }

  // Skip messages only if decryption returned empty (should be rare now)
  if (message.isEmpty) {
    debugPrint("[SIGNAL SERVICE] Skipping message - decryption returned empty");
    return;
  }

  debugPrint("[SIGNAL SERVICE] Message decrypted successfully: '$message' (cipherType: $cipherType)");

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
    debugPrint('[SIGNAL_SERVICE] receiveItem detected read_receipt type, calling _handleReadReceipt');
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
  }
  
  // ✅ Update unread count for non-system messages (only 'message' and 'file' types)
  if (!isSystemMessage && _unreadMessagesProvider != null) {
    // This is a 1:1 direct message (no channel)
    _unreadMessagesProvider!.incrementIfBadgeType(type, sender, false);
  }
  
  // ✅ Emit EventBus event for new 1:1 message/item (after decryption)
  if (!isSystemMessage) {
    debugPrint('[SIGNAL SERVICE] → EVENT_BUS: newMessage (1:1) - type=$type, sender=$sender');
    EventBus.instance.emit(AppEvent.newMessage, item);
    
    // Also emit newConversation if this is the first message from this sender
    // (Views can check their conversation list to determine if it's truly new)
    EventBus.instance.emit(AppEvent.newConversation, {
      'conversationId': sender,
      'isChannel': false,
    });
  }
  
  // ✅ PHASE 3: System messages already deleted from server above
  if (isSystemMessage) {
    // System messages should never be in SQLite (filtered by storage layer)
    debugPrint("[SIGNAL SERVICE] ✓ System message processed: type=$type, itemId=$itemId");
    
    // Don't trigger regular callbacks for system messages
    return;
  }

  // Regular messages: Trigger callbacks
  if (cipherType != CiphertextMessage.whisperType && _itemTypeCallbacks.containsKey(cipherType)) {
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
      debugPrint('[SIGNAL SERVICE] Triggered ${_receiveItemCallbacks[key]!.length} receiveItem callbacks for $key');
    }
  }
  
  // Note: Message already deleted from server at the start of this function
  debugPrint("[SIGNAL SERVICE] ✓ Message processing complete for itemId: $itemId");
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
  debugPrint("[SIGNAL SERVICE] Deleting group item locally with itemId: $itemId");
  await decryptedGroupItemsStore.clearItem(itemId, channelId);
  await sentGroupItemsStore.clearChannelItem(itemId, channelId);
}
  /// Handle delivery receipt from server
  Future<void> _handleDeliveryReceipt(Map<String, dynamic> data) async {
    final itemId = data['itemId'];
    debugPrint('[SIGNAL SERVICE] Delivery receipt received for itemId: $itemId');
    
    // Update SQLite store
    try {
      final messageStore = await SqliteMessageStore.getInstance();
      await messageStore.markAsDelivered(itemId);
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ⚠️ Failed to update delivery status in SQLite: $e');
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
      debugPrint('[SIGNAL_SERVICE] Processing read receipt for itemId: $itemId, readByDeviceId: $readByDeviceId, readByUserId: $readByUserId');
      
      // Update SQLite store
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.markAsRead(itemId);
      } catch (e) {
        debugPrint('[SIGNAL_SERVICE] ⚠️ Failed to update read status in SQLite: $e');
      }
      
      // Trigger callbacks with itemId, deviceId, and userId
      if (_readCallbacks.containsKey('default')) {
        debugPrint('[SIGNAL_SERVICE] Triggering ${_readCallbacks['default']!.length} read receipt callbacks');
        for (final callback in _readCallbacks['default']!) {
          // Pass all three parameters: itemId, readByDeviceId, readByUserId
          callback({'itemId': itemId, 'readByDeviceId': readByDeviceId, 'readByUserId': readByUserId});
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

  Future<List<Map<String, dynamic>>> fetchPreKeyBundleForUser(String userId) async {
    // Use retry mechanism for network-related failures
    return await retryWithBackoff(
      operation: () => _fetchPreKeyBundleForUserInternal(userId),
      maxAttempts: 3,
      initialDelay: 1000,
      shouldRetry: isRetryableError,
    );
  }

  Future<List<Map<String, dynamic>>> _fetchPreKeyBundleForUserInternal(String userId) async {
    final apiServer = await loadWebApiServer();
    final urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
    final response = await ApiService.get('$urlString/signal/prekey_bundle/$userId');
    debugPrint('[DEBUG] response.statusCode: \\${response.statusCode}');
    debugPrint('[DEBUG] response.data: \\${response.data}');
    debugPrint('[DEBUG] response.data.runtimeType: \\${response.data.runtimeType}');
    if (response.statusCode == 200) {
      try {
        final devices = response.data is String ? jsonDecode(response.data) : response.data;
        debugPrint('[DEBUG] devices: \\${devices}');
        debugPrint('[DEBUG] devices.runtimeType: \\${devices.runtimeType}');
        if (devices is List) {
          debugPrint('[DEBUG] devices.length: \\${devices.length}');
        }
        final List<Map<String, dynamic>> result = [];
        int skippedDevices = 0;
        
        for (final data in devices) {
          debugPrint('[DEBUG] signedPreKey: ' + jsonEncode(data['signedPreKey']));
          final hasAllFields =
            data['public_key'] != null &&
            data['registration_id'] != null &&
            data['preKey'] != null &&
            data['signedPreKey'] != null &&
            data['preKey']['prekey_data'] != null &&
            data['signedPreKey']['signed_prekey_data'] != null &&
            data['signedPreKey']['signed_prekey_signature'] != null &&
            data['signedPreKey']['signed_prekey_signature'].toString().isNotEmpty;
          if (!hasAllFields) {
            debugPrint('[SIGNAL SERVICE][MULTI-DEVICE] Device ${data['clientid']} skipped: missing Signal keys (this is OK - will try other devices)');
            skippedDevices++;
            continue;
          }
          debugPrint('[DEBUG] Decoding preKey ${data['preKey']['prekey_data']}');
          debugPrint('[DEBUG] PreKey length: ${base64Decode(data['preKey']['prekey_data']).length}');
          debugPrint("[DEBUG] Decoding signedPreKey ${data['signedPreKey']['signed_prekey_data']}");
          debugPrint('[DEBUG] SignedPreKey length: ${base64Decode(data['signedPreKey']['signed_prekey_data']).length}');
          debugPrint("[DEBUG] Decoding signedPreKeySignature ${data['signedPreKey']['signed_prekey_signature']}");
          debugPrint('[DEBUG] SignedPreKey signature length: ${base64Decode(data['signedPreKey']['signed_prekey_signature']).length}');
          
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
          
          result.add({
            'clientid': data['clientid'],
            'userId': data['userId'],
            'deviceId': deviceId,
            'publicKey': data['public_key'],
            'registrationId': registrationId,
            'preKeyId': preKeyId,
            'preKeyPublic': Curve.decodePoint(base64Decode(data['preKey']['prekey_data']), 0),
            'signedPreKeyId': signedPreKeyId,
            'signedPreKeyPublic': Curve.decodePoint(base64Decode(data['signedPreKey']['signed_prekey_data']), 0),
            'signedPreKeySignature': base64Decode(data['signedPreKey']['signed_prekey_signature']),
            'identityKey': IdentityKey.fromBytes(base64Decode(data['public_key']), 0),
          });
        }
        
        // Multi-Device Logic:
        // - If NO devices have keys → Show error
        // - If SOME devices have keys → Success (skip devices without keys)
        // - Skipped devices will not receive messages, but that's expected behavior
        if (result.isEmpty) {
          if (skippedDevices > 0) {
            debugPrint('[SIGNAL SERVICE][ERROR] ❌ User $userId has $skippedDevices devices but NONE have valid Signal keys!');
            debugPrint('[SIGNAL SERVICE][ERROR] User needs to register Signal keys on at least one device.');
          } else {
            debugPrint('[SIGNAL SERVICE][ERROR] ❌ User $userId has no devices at all.');
          }
        } else {
          if (skippedDevices > 0) {
            debugPrint('[SIGNAL SERVICE][MULTI-DEVICE] ✓ Found ${result.length} devices with keys, $skippedDevices devices without keys');
            debugPrint('[SIGNAL SERVICE][MULTI-DEVICE] Messages will be sent to devices with keys only.');
          } else {
            debugPrint('[SIGNAL SERVICE][MULTI-DEVICE] ✓ All ${result.length} devices have valid keys');
          }
        }
        
        return result;
      } catch (e, st) {
        debugPrint('[ERROR] Exception while decoding response: \\${e}\\n\\${st}');
        rethrow;
      }
    } else {
      throw Exception('Failed to load PreKeyBundle');
    }
  }

  /// Check if recipient has available PreKeys
  /// Returns true if at least one valid device with PreKeys exists
  /// On API error: returns null to allow caller to decide (don't assume success)
  Future<bool?> hasPreKeysForRecipient(String recipientUserId) async {
    try {
      final bundles = await fetchPreKeyBundleForUser(recipientUserId);
      // Filter for recipient's devices only (not our own devices)
      final recipientDevices = bundles.where((bundle) => 
        bundle['userId'] == recipientUserId
      ).toList();
      return recipientDevices.isNotEmpty;
    } catch (e) {
      debugPrint('[SIGNAL SERVICE][ERROR] Failed to check PreKeys for $recipientUserId: $e');
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

      debugPrint('[SIGNAL_SERVICE] Sent file item $messageItemId ($fileName) to $recipientUserId');
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
        message: payloadJson,  // sendGroupItem expects 'message' parameter
        type: 'file',
        itemId: messageItemId,
      );

      debugPrint('[SIGNAL_SERVICE] Sent file group item $messageItemId ($fileName) to channel $channelId');
      
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
    Map<String, dynamic>? metadata, // Optional metadata (for image/voice messages)
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
    
    debugPrint('[SIGNAL SERVICE] Step 0: Trigger local callback for sent message');
    // Immediately notify UI with the PLAINTEXT message for the sending device
    // This allows Bob Device 1 to see his own sent message without decryption
    
    // ✅ PHASE 4: Define types that should NOT be stored
    const SKIP_STORAGE_TYPES = {
      'fileKeyResponse',
      'senderKeyDistribution',
      'read_receipt',  // Already handled separately
    };
    
    // Store sent message in local storage for persistence after refresh
    // IMPORTANT: Only store actual chat messages and file messages, not system messages
    final timestamp = DateTime.now().toIso8601String();
    const STORABLE_TYPES = {'message', 'file', 'image', 'voice', 'notification'};
    final shouldStore = !SKIP_STORAGE_TYPES.contains(type) && STORABLE_TYPES.contains(type);
    
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
        final conversationsStore = await SqliteRecentConversationsStore.getInstance();
        await conversationsStore.addOrUpdateConversation(
          userId: recipientUserId,
          displayName: recipientUserId, // Will be enriched by UI layer
        );
        
        debugPrint('[SIGNAL SERVICE] ✓ Stored sent $type in SQLite with status=sent');
      } catch (e) {
        debugPrint('[SIGNAL SERVICE] ✗ Failed to store in SQLite: $e');
      }
    } else {
      debugPrint('[SIGNAL SERVICE] Step 0a: Skipping storage for message type: $type (system message or skip-list)');
    }
    
    // Trigger local callback for UI updates (but not for read_receipt - they are system messages)
    // For file messages, use 'message' callback since they display in chat
    final callbackType = (type == 'file') ? 'message' : type;
    if (type != 'read_receipt' && _itemTypeCallbacks.containsKey(callbackType)) {
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
      debugPrint('[SIGNAL SERVICE] Step 0b: Triggered ${_itemTypeCallbacks[callbackType]!.length} local callbacks for type: $type (using callback: $callbackType)');
    }
    
    debugPrint('[SIGNAL SERVICE] Step 1: fetchPreKeyBundleForUser($recipientUserId)');
    debugPrint('[SIGNAL SERVICE] This fetches devices for BOTH users: recipient AND sender (own devices)');
    final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);
    debugPrint('[SIGNAL SERVICE] Step 1 result: $preKeyBundles');
    debugPrint('[SIGNAL SERVICE] Number of devices (Alice + Bob): ${preKeyBundles.length}');
    for (final bundle in preKeyBundles) {
      debugPrint('[SIGNAL SERVICE] Device: userId=${bundle['userId']}, deviceId=${bundle['deviceId']}');
    }

    // Verschlüssele für jedes Gerät separat
    for (final bundle in preKeyBundles) {
      debugPrint('[SIGNAL SERVICE] ===============================================');
      debugPrint('[SIGNAL SERVICE] Encrypting for device: ${bundle['userId']}:${bundle['deviceId']}');
      debugPrint('[SIGNAL SERVICE] ===============================================');
      
      // CRITICAL: Skip encryption for our own current device
      // We cannot decrypt messages we encrypt to ourselves (same session direction)
      final isCurrentDevice = (bundle['userId'] == _currentUserId && bundle['deviceId'] == _currentDeviceId);
      if (isCurrentDevice) {
        debugPrint('[SIGNAL SERVICE] Skipping current device (cannot encrypt to self): ${bundle['userId']}:${bundle['deviceId']}');
        continue;
      }
      
      debugPrint('[SIGNAL SERVICE] Step 2: Prepare recipientAddress for deviceId ${bundle['deviceId']}');
      final recipientAddress = SignalProtocolAddress(bundle['userId'], bundle['deviceId']);
      
      // Check if this is our own device (not the intended recipient)
      // This happens when the backend returns our own devices for multi-device support
      final isOwnDevice = (bundle['userId'] != recipientUserId);
      
      debugPrint('[SIGNAL SERVICE] Step 3: Check session for $recipientAddress');
      var hasSession = await sessionStore.containsSession(recipientAddress);
      debugPrint('[SIGNAL SERVICE] Step 3 result: hasSession=$hasSession, isOwnDevice=$isOwnDevice');

      debugPrint('[SIGNAL SERVICE] Step 4: Create SessionCipher for $recipientAddress');
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        recipientAddress,
      );

      if (!hasSession) {
        debugPrint('[SIGNAL SERVICE] Step 5: Build session for $recipientAddress');
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
        debugPrint('[SIGNAL SERVICE] Step 5 done');
      }

      

      debugPrint('[SIGNAL SERVICE] Step 6: Using pre-prepared payload');
      // payloadString is already prepared before the loop
      debugPrint('[SIGNAL SERVICE] Step 6: payload is: $payloadString');
      
      debugPrint('[SIGNAL SERVICE] Step 7: Encrypt payload with message: $payloadString');
      ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(payloadString)));

      

      debugPrint('[SIGNAL SERVICE] Step 8: Serialize ciphertext');
      final serialized = base64Encode(ciphertextMessage.serialize());
      debugPrint('[SIGNAL SERVICE] Step 8 result: cipherType=${ciphertextMessage.getType()}, hasSession=$hasSession');
      
      // CRITICAL: If we get PreKey message despite having a session, the session is corrupted
      // Delete it and rebuild from scratch
      if (ciphertextMessage.getType() == 3 && hasSession) {
        debugPrint('[SIGNAL SERVICE] WARNING: PreKey message despite existing session! Session is corrupted.');
        debugPrint('[SIGNAL SERVICE] Deleting corrupted session with ${recipientAddress}');
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
        debugPrint('[SIGNAL SERVICE] Re-encrypting message with rebuilt session');
        ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(payloadString)));
        final newSerialized = base64Encode(ciphertextMessage.serialize());
        debugPrint('[SIGNAL SERVICE] Re-encrypted cipherType=${ciphertextMessage.getType()}');
        
        // Update data with new encryption (use same itemId)
        final data = {
          'recipient': recipientAddress.getName(),
          'recipientDeviceId': recipientAddress.getDeviceId(),
          'type': type,
          'payload': newSerialized,
          'cipherType': ciphertextMessage.getType(),
          'itemId': messageItemId,
        };
        
        debugPrint('[SIGNAL SERVICE] Sending rebuilt message: cipherType=${ciphertextMessage.getType()}');
        SocketService().emit("sendItem", data);
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
      
      // Log message type for debugging
      final isPreKeyMessage = ciphertextMessage.getType() == 3;
      if(isPreKeyMessage) {
        debugPrint('[SIGNAL SERVICE] Step 11: PreKey message sent (first message to establish session)');
        debugPrint('[SIGNAL SERVICE] Step 11a: This message contains the actual content and will establish the session');
      } else {
        debugPrint('[SIGNAL SERVICE] Step 11: Whisper message sent (session already exists)');
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
    final plaintext = await sessionCipher.decryptWithCallback(preKeyMsg, (pt) {});
    
    // PreKey nach erfolgreichem Session-Aufbau löschen
    final preKeyIdOptional = preKeyMsg.getPreKeyId();
    int? preKeyId;
    if (preKeyIdOptional.isPresent == true) {
      preKeyId = preKeyIdOptional.value;
    }
    
    if (preKeyId != null) {
      debugPrint('[SIGNAL SERVICE] Removing used PreKey $preKeyId after session establishment');
      await preKeyStore.removePreKey(preKeyId);
      
      // 🚀 OPTIMIZED: Async regeneration (non-blocking)
      // Generate the consumed PreKey in the background
      _regeneratePreKeyAsync(preKeyId);
      
      // CRITICAL: Trigger server sync check after PreKey deletion
      // This ensures server stays in sync with local PreKey count
      Future.delayed(Duration(seconds: 2), () {
        debugPrint('[SIGNAL SERVICE] Triggering PreKey sync check after deletion...');
        SocketService().emit("signalStatus", null);
      });
    }
    
    return utf8.decode(plaintext);
} else if (cipherType == CiphertextMessage.whisperType) {
    // Normale Nachricht
    final signalMsg = SignalMessage.fromSerialized(serialized);
    final plaintext = await sessionCipher.decryptFromSignal(signalMsg);
    debugPrint('[SIGNAL SERVICE] Step 8: Decrypted plaintext: $plaintext');
    return utf8.decode(plaintext);
  } else if (cipherType == CiphertextMessage.senderKeyType) {
    // Group message - should NOT be processed here!
    // Group messages should come via 'groupMessage' Socket.IO event and use GroupCipher
    throw Exception('CipherType 4 (senderKeyType) detected - group messages must use GroupCipher, not SessionCipher. This message should come via groupMessage event, not receiveItem.');
  } else {
    throw Exception('Unknown cipherType: $cipherType');
  }
  } catch (e, st) {
    debugPrint('[ERROR] Exception while decrypting message: \\${e}\\n\\${st}');
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
  Future<Uint8List> createGroupSenderKey(String groupId, {bool broadcastDistribution = true}) async {
    if (_currentUserId == null || _currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    debugPrint('[SIGNAL_SERVICE] Creating sender key for group $groupId, user $_currentUserId:$_currentDeviceId');

    // ⚠️ CRITICAL: Check if sender key already exists to avoid chain corruption
    final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    
    final existingKey = await senderKeyStore.containsSenderKey(senderKeyName);
    if (existingKey) {
      debugPrint('[SIGNAL_SERVICE] ℹ️ Sender key already exists for group $groupId');
      
      // ⚠️ VALIDATION: Try to use the existing key - if it fails, regenerate
      // Test by creating a GroupCipher and attempting a dummy encryption
      try {
        final testCipher = GroupCipher(senderKeyStore, senderKeyName);
        // Try to encrypt a small test message to verify key validity
        final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
        await testCipher.encrypt(testMessage);
        debugPrint('[SIGNAL_SERVICE] ✓ Existing sender key is valid and functional');
        // Return empty bytes - key is already distributed
        return Uint8List(0);
      } catch (e) {
        debugPrint('[SIGNAL_SERVICE] ⚠️ WARNING: Existing sender key is corrupted or invalid ($e)');
        debugPrint('[SIGNAL_SERVICE] Deleting corrupted key and regenerating...');
        // Delete corrupted key
        await senderKeyStore.removeSenderKey(senderKeyName);
        // Fall through to regenerate
      }
    }

    // Verify identity key pair exists
    try {
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      debugPrint('[SIGNAL_SERVICE] Identity key pair verified - PublicKey: ${identityKeyPair.getPublicKey().toString().substring(0, 20)}...');
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error verifying identity key pair: $e');
      throw Exception('Cannot create sender key: Identity key pair not available. Please register Signal keys first. Error: $e');
    }

    // Verify sender key store is initialized
    try {
      await senderKeyStore.loadSenderKey(senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Sender key store is accessible');
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error accessing sender key store: $e');
      throw Exception('Cannot create sender key: Sender key store error: $e');
    }

    try {
      debugPrint('[SIGNAL_SERVICE] Created SenderKeyName for group $groupId, address ${senderAddress.getName()}:${senderAddress.getDeviceId()}');
      
      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      debugPrint('[SIGNAL_SERVICE] Created GroupSessionBuilder');
      
      // Create sender key distribution message
      debugPrint('[SIGNAL_SERVICE] Calling groupSessionBuilder.create()...');
      final distributionMessage = await groupSessionBuilder.create(senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Successfully created distribution message');
      
      final serialized = distributionMessage.serialize();
      debugPrint('[SIGNAL_SERVICE] Serialized distribution message, length: ${serialized.length}');
      
      debugPrint('[SIGNAL_SERVICE] Created sender key for group $groupId');
      
      // Store sender key on server for backup/retrieval
      // Skip if serialized is empty (key already existed)
      if (serialized.isNotEmpty) {
        try {
          final senderKeyBase64 = base64Encode(serialized);
          SocketService().emit('storeSenderKey', {
            'groupId': groupId,
            'senderKey': senderKeyBase64,
          });
          debugPrint('[SIGNAL_SERVICE] Stored sender key on server for group $groupId');
        } catch (e) {
          debugPrint('[SIGNAL_SERVICE] Warning: Failed to store sender key on server: $e');
          // Don't fail - sender key is already stored locally
        }
      }
      
      // Broadcast distribution message to all group members
      // Skip if serialized is empty (key already existed)
      if (broadcastDistribution && serialized.isNotEmpty) {
        try {
          debugPrint('[SIGNAL_SERVICE] Broadcasting sender key distribution message...');
          SocketService().emit('broadcastSenderKey', {
            'groupId': groupId,
            'distributionMessage': base64Encode(serialized),
          });
          debugPrint('[SIGNAL_SERVICE] ✓ Sender key distribution message broadcast to group');
        } catch (e) {
          debugPrint('[SIGNAL_SERVICE] Warning: Failed to broadcast distribution message: $e');
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
    
    final distributionMessage = SenderKeyDistributionMessageWrapper.fromSerialized(distributionMessageBytes);
    
    await groupSessionBuilder.process(senderKeyName, distributionMessage);
    
    debugPrint('[SIGNAL_SERVICE] Processed sender key from $senderId:$senderDeviceId for group $groupId');
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

    debugPrint('[SIGNAL_SERVICE] encryptGroupMessage: groupId=$groupId, userId=$_currentUserId:$_currentDeviceId, messageLength=${message.length}');

    try {
      final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
      debugPrint('[SIGNAL_SERVICE] Created sender address: ${senderAddress.getName()}:${senderAddress.getDeviceId()}');
      
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      debugPrint('[SIGNAL_SERVICE] Created sender key name for group $groupId');
      
      // Check if sender key exists
      final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Sender key exists: $hasSenderKey');
      
      if (!hasSenderKey) {
        throw Exception('No sender key found for this group. Please initialize sender key first.');
      }
      
      // Load the sender key record to verify it's valid
      await senderKeyStore.loadSenderKey(senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Loaded sender key record from store');
      
      // Validate identity key pair exists before encryption (required for signing)
      try {
        final identityKeyPair = await identityStore.getIdentityKeyPair();
        if (identityKeyPair.getPrivateKey().serialize().isEmpty) {
          throw Exception('Identity private key is empty - cannot sign sender key messages');
        }
        debugPrint('[SIGNAL_SERVICE] Identity key pair validated for signing');
      } catch (e) {
        throw Exception('Identity key pair missing or corrupted: $e. Please regenerate Signal Protocol keys.');
      }
      
      // ⚠️ CRITICAL: Test sender key validity BEFORE creating GroupCipher
      // This prevents RangeError by detecting corrupted keys early
      debugPrint('[SIGNAL_SERVICE] Testing sender key validity with dummy encryption...');
      try {
        final testCipher = GroupCipher(senderKeyStore, senderKeyName);
        final testMessage = Uint8List.fromList([0x01, 0x02, 0x03]);
        await testCipher.encrypt(testMessage);
        debugPrint('[SIGNAL_SERVICE] ✓ Sender key validation passed');
      } catch (validationError) {
        debugPrint('[SIGNAL_SERVICE] ⚠️ Sender key validation FAILED: $validationError');
        // Trigger RangeError handler to regenerate key
        throw RangeError('Sender key corrupted - validation test failed: $validationError');
      }
      
      // ✨ ROTATION CHECK: Check if sender key needs rotation (7 days or 1000 messages)
      final needsRotation = await senderKeyStore.needsRotation(senderKeyName);
      if (needsRotation) {
        debugPrint('[SIGNAL_SERVICE] 🔄 Sender key needs rotation - regenerating...');
        try {
          // Remove old key
          await senderKeyStore.removeSenderKey(senderKeyName);
          
          // Create new sender key and broadcast
          await createGroupSenderKey(groupId, broadcastDistribution: true);
          debugPrint('[SIGNAL_SERVICE] ✓ Sender key rotated successfully for group $groupId');
        } catch (rotationError) {
          debugPrint('[SIGNAL_SERVICE] ⚠️ Warning: Sender key rotation failed: $rotationError');
          // Don't fail the message - continue with existing key if rotation fails
        }
      }
      
      final groupCipher = GroupCipher(senderKeyStore, senderKeyName);
      debugPrint('[SIGNAL_SERVICE] Created GroupCipher');
      
      final messageBytes = Uint8List.fromList(utf8.encode(message));
      debugPrint('[SIGNAL_SERVICE] Encoded message to bytes, length: ${messageBytes.length}');
      
      debugPrint('[SIGNAL_SERVICE] Calling groupCipher.encrypt()...');
      final ciphertext = await groupCipher.encrypt(messageBytes);
      debugPrint('[SIGNAL_SERVICE] Successfully encrypted message, ciphertext length: ${ciphertext.length}');
      
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
      debugPrint('[SIGNAL_SERVICE] RangeError during encryption - sender key chain corrupted: $e');
      debugPrint('[SIGNAL_SERVICE] Attempting to recover sender key...');
      
      try {
        final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
        final senderKeyName = SenderKeyName(groupId, senderAddress);
        
        // STEP 1: Try to load key from server BEFORE regenerating
        // This preserves message history if server has a good key
        debugPrint('[SIGNAL_SERVICE] Step 1: Attempting to load sender key from server...');
        
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
          debugPrint('[SIGNAL_SERVICE] ✓ Sender key restored from server backup');
          
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
            debugPrint('[SIGNAL_SERVICE] ✓ Successfully encrypted with restored key');
            
            return {
              'ciphertext': base64Encode(ciphertext),
              'senderId': _currentUserId,
              'senderDeviceId': _currentDeviceId,
            };
          } catch (validationError) {
            debugPrint('[SIGNAL_SERVICE] ⚠️ Restored key is also corrupted: $validationError');
            // Fall through to regenerate
          }
        } else {
          debugPrint('[SIGNAL_SERVICE] No sender key found on server');
        }
        
        // STEP 2: If server has no key OR restored key is also corrupted, regenerate
        debugPrint('[SIGNAL_SERVICE] Step 2: Generating new sender key...');
        await createGroupSenderKey(groupId, broadcastDistribution: true);
        debugPrint('[SIGNAL_SERVICE] ✓ Created and broadcast new sender key for group $groupId');
        
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
        debugPrint('[SIGNAL_SERVICE] ❌ Failed to recover from corrupted sender key: $recoveryError');
        throw Exception('Sender key chain corrupted and recovery failed. Please leave and rejoin the channel. Original error: $e');
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
    debugPrint('[SIGNAL_SERVICE] WARNING: sendGroupMessage is deprecated, use sendGroupItem instead');
    // Redirect to new implementation
    await sendGroupItem(
      channelId: groupId,
      message: message,
      itemId: itemId ?? Uuid().v4(),
    );
  }

  /// Request sender key from a group member
  Future<void> requestSenderKey(String groupId, String userId, int deviceId) async {
    try {
      final apiServer = await loadWebApiServer();
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
      
      debugPrint('[SIGNAL_SERVICE] Requested sender key from $userId:$deviceId for group $groupId');
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error requesting sender key: $e');
      rethrow;
    }
  }

  /// Check if we have sender key for a specific sender in a group
  Future<bool> hasSenderKey(String groupId, String senderId, int senderDeviceId) async {
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
      final timestampIso = DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String();

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
        debugPrint('[SIGNAL_SERVICE] ✗ Failed to store file message in SQLite: $e');
      };

      // Send via Socket.IO
      SocketService().emit("sendGroupItem", {
        'channelId': channelId,
        'itemId': itemId,
        'type': 'file',
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': timestampIso,
      });

      debugPrint('[SIGNAL_SERVICE] Sent file message $itemId ($fileName) to channel $channelId');
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
        final timestampIso = DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String();

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

        debugPrint('[SIGNAL_SERVICE] Sent file share update ($action) to group $chatId');
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

          debugPrint('[SIGNAL_SERVICE] Sent file share update ($action) to user $userId');
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
        final timestampIso = DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String();

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
    Map<String, dynamic>? metadata, // Optional metadata (for image/voice messages)
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
            recipientId: channelId, // Store channelId as recipientId for group messages
            channelId: channelId,
            message: message,
            timestamp: timestamp,
            type: type,
            metadata: metadata,
          );
          debugPrint('[SIGNAL_SERVICE] Stored group item $itemId in SQLite');
        } catch (e) {
          debugPrint('[SIGNAL_SERVICE] ✗ Failed to store group item in SQLite: $e');
        }
        
        debugPrint('[SIGNAL_SERVICE] Stored group item $itemId locally');
      } else {
        debugPrint('[SIGNAL_SERVICE] Skipping storage for system message type: $type');
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

      debugPrint('[SIGNAL_SERVICE] Sent group item $itemId to channel $channelId');
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
      if (retryOnError && (
          e.toString().contains('InvalidMessageException') ||
          e.toString().contains('No key for') ||
          e.toString().contains('DuplicateMessageException') ||
          e.toString().contains('Invalid'))) {
        
        debugPrint('[SIGNAL_SERVICE] Attempting to reload sender key from server...');
        
        // Try to reload sender key from server
        final keyLoaded = await loadSenderKeyFromServer(
          channelId: channelId,
          userId: senderId,
          deviceId: senderDeviceId,
          forceReload: true,
        );
        
        if (keyLoaded) {
          debugPrint('[SIGNAL_SERVICE] Sender key reloaded, retrying decrypt...');
          
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
      debugPrint('[SIGNAL_SERVICE] Loading sender key from server: $userId:$deviceId (forceReload: $forceReload)');
      
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
      
      // Load from server via REST API
      final apiServer = await loadWebApiServer();
      final urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      final response = await ApiService.get(
        '$urlString/api/sender-keys/$channelId/$userId/$deviceId'
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
  Future<Map<String, dynamic>> loadAllSenderKeysForChannel(String channelId) async {
    // Use retry mechanism for network-related failures
    return await retryWithBackoff(
      operation: () => _loadAllSenderKeysForChannelInternal(channelId),
      maxAttempts: 3,
      initialDelay: 1000,
      shouldRetry: isRetryableError,
    );
  }

  Future<Map<String, dynamic>> _loadAllSenderKeysForChannelInternal(String channelId) async {
    final result = {
      'success': true,
      'totalKeys': 0,
      'loadedKeys': 0,
      'failedKeys': <Map<String, String>>[],
    };
    
    try {
      debugPrint('[SIGNAL_SERVICE] Loading all sender keys for channel $channelId');
      
      final apiServer = await loadWebApiServer();
      final urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      final response = await ApiService.get('$urlString/api/sender-keys/$channelId');
      
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
            debugPrint('[SIGNAL_SERVICE] ✓ Loaded sender key for $userId:$deviceId');
          } catch (keyError) {
            final userId = key['userId'] as String?;
            final deviceId = key['deviceId'] as int?;
            (result['failedKeys'] as List).add({
              'userId': userId ?? 'unknown',
              'deviceId': deviceId?.toString() ?? 'unknown',
              'error': keyError.toString(),
            });
            debugPrint('[SIGNAL_SERVICE] Error loading key for $userId:$deviceId - $keyError');
          }
        }
        
        if ((result['failedKeys'] as List).isNotEmpty) {
          // Partial failure - some keys couldn't be loaded
          result['success'] = false;
          final failedCount = (result['failedKeys'] as List).length;
          throw Exception('Failed to load $failedCount sender key(s). Some messages may not decrypt.');
        }
        
        debugPrint('[SIGNAL_SERVICE] ✓ Loaded ${result['loadedKeys']} sender keys for channel');
        return result;
      } else {
        // HTTP error or unsuccessful response
        result['success'] = false;
        throw Exception('Failed to load sender keys from server: HTTP ${response.statusCode}');
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
      final distributionMessage = await createGroupSenderKey(channelId, broadcastDistribution: false);
      
      // Check if key already existed (returns empty bytes)
      if (distributionMessage.isEmpty) {
        debugPrint('[SIGNAL_SERVICE] ℹ️ Sender key already exists, skipping upload');
        return;
      }
      
      final senderKeyBase64 = base64Encode(distributionMessage);
      
      // Upload to server
      final apiServer = await loadWebApiServer();
      final urlString = ApiService.ensureHttpPrefix(apiServer ?? '');
      final response = await ApiService.post(
        '$urlString/api/sender-keys/$channelId',
        data: {
          'senderKey': senderKeyBase64,
          'deviceId': _currentDeviceId,
        },
      );
      
      if (response.statusCode == 200) {
        debugPrint('[SIGNAL_SERVICE] ✓ Sender key uploaded to server');
      } else {
        debugPrint('[SIGNAL_SERVICE] Failed to upload sender key: ${response.statusCode}');
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
      
      SocketService().emit("markGroupItemRead", {
        'itemId': itemId,
      });
      
      debugPrint('[SIGNAL_SERVICE] Marked group item $itemId as read');
    } catch (e) {
      debugPrint('[SIGNAL_SERVICE] Error marking item as read: $e');
    }
  }

  /// Load sent group items for a channel
  Future<List<Map<String, dynamic>>> loadSentGroupItems(String channelId) async {
    return await sentGroupItemsStore.loadSentItems(channelId);
  }

  /// Load received/decrypted group items for a channel
  Future<List<Map<String, dynamic>>> loadReceivedGroupItems(String channelId) async {
    return await decryptedGroupItemsStore.getChannelItems(channelId);
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
        debugPrint('[SIGNAL SERVICE] ✓ PreKey $preKeyId regenerated and uploaded async');
      }
    } catch (e) {
      debugPrint('[SIGNAL SERVICE] ✗ Failed to regenerate PreKey $preKeyId: $e');
      // Don't rethrow - this is background work
    }
  }
}


