import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'api_service.dart';
import '../web_config.dart';
import 'socket_service.dart';
import 'package:uuid/uuid.dart';
import 'permanent_session_store.dart';
import 'permanent_pre_key_store.dart';
import 'permanent_signed_pre_key_store.dart';
import 'permanent_identity_key_store.dart';
import 'permanent_sent_messages_store.dart';
import 'permanent_decrypted_messages_store.dart';
import 'sender_key_store.dart';
import 'decrypted_group_items_store.dart';
import 'sent_group_items_store.dart';

/*class SocketPreKeyStore extends InMemoryPreKeyStore {

  Future<void> checkPreKeys() async {
    if(store.length < 20) {
      print("Not enough pre keys, generating more");
      var lastId = store.isNotEmpty ? store.keys.reduce((a, b) => a > b ? a : b) : 0;
      if(lastId == 9007199254740991) {
          lastId = 0;
      }
      var newPreKeys = generatePreKeys(lastId + 1, lastId + 110);
      for (var newPreKey in newPreKeys) {
        storePreKey(newPreKey.id, newPreKey);
      }
    }
  }

  Future<void> loadRemotePreKeys() async {
    SocketService().registerListener("getPreKeysResponse", (data) {
      print(data);
      for (var item in data) {
          if(item['prekey_id'] != null && item['prekey_data'] != null) {
           store[item['prekey_id']] = base64Decode(item['prekey_data']);
          }
      }
      if(data.isEmpty) {
        print("No pre keys found, generating more");
        var newPreKeys = generatePreKeys(0, 110);
        for (var newPreKey in newPreKeys) {
          storePreKey(newPreKey.id, newPreKey);
        }
      }
      if(data.length <= 20) {
        print("Not enough pre keys found, generating more");
        var lastId = data.isNotEmpty ? data.map((e) => e['prekey_id']).reduce((a, b) => a > b ? a : b) : 0;
        if(lastId == 9007199254740991) {
          lastId = 0;
        }
        var newPreKeys = generatePreKeys(lastId + 1, lastId + 110);
        for (var newPreKey in newPreKeys) {
          storePreKey(newPreKey.id, newPreKey);
        }
      }
    });
    SocketService().emit("getPreKeys", null);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    print("Storing pre key: $preKeyId");
    SocketService().emit("storePreKey", {
      'id': preKeyId,
      'data': base64Encode(record.serialize()),
    });
    store[preKeyId] = record.serialize();
  }
}*/

/*class SocketSignedPreKeyStore extends InMemorySignedPreKeyStore {

  final IdentityKeyPair identityKeyPair;

  SocketSignedPreKeyStore(this.identityKeyPair);

  Future<void> loadRemoteSignedPreKeys() async {
    SocketService().registerListener("getSignedPreKeysResponse", (data) {
      print(data);
      for (var item in data) {
        if(item['signed_prekey_id'] != null && item['signed_prekey_data'] != null && item['createdAt'] != null) {
           store[item['signed_prekey_id']] = base64Decode(item['signed_prekey_data']);
           if(DateTime.parse(item['createdAt']).millisecondsSinceEpoch < DateTime.now().millisecondsSinceEpoch - 1 * 24 * 60 * 60 * 1000) {
             // If preSignedKey is older than 1 day, create new one
             var newPreSignedKey = generateSignedPreKey(identityKeyPair, data.length);
             storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
             removeSignedPreKey(item['signed_prekey_id']);
           }
        }
      }
      if(data.isEmpty) {
        print("No signed pre keys found, creating new one");
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
    });
    SocketService().emit("getSignedPreKeys", null);
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    print("Removing signed pre key: $signedPreKeyId");
    SocketService().emit("removeSignedPreKey", {
      'id': signedPreKeyId,
    });
    store.remove(signedPreKeyId);
  }

  @override
  Future<void> storeSignedPreKey(
      int signedPreKeyId, SignedPreKeyRecord record) async {
    print("Storing signed pre key: $signedPreKeyId");
    SocketService().emit("storeSignedPreKey", {
      'id': signedPreKeyId,
      'data': base64Encode(record.serialize()),
    });
    store[signedPreKeyId] = record.serialize();
  }
}*/


class SignalService {
  static final SignalService instance = SignalService._internal();
  factory SignalService() => instance;
  SignalService._internal();

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  final Map<String, List<Function(dynamic)>> _itemTypeCallbacks = {};
  final Map<String, List<Function(String)>> _deliveryCallbacks = {};
  final Map<String, List<Function(Map<String, dynamic>)>> _readCallbacks = {};
  PermanentIdentityKeyStore identityStore = PermanentIdentityKeyStore();
  late PermanentSessionStore sessionStore;
  PermanentPreKeyStore preKeyStore = PermanentPreKeyStore();
  late PermanentSignedPreKeyStore signedPreKeyStore;
  late PermanentSentMessagesStore sentMessagesStore;
  late PermanentDecryptedMessagesStore decryptedMessagesStore;
  late PermanentSenderKeyStore senderKeyStore;
  late DecryptedGroupItemsStore decryptedGroupItemsStore;
  late SentGroupItemsStore sentGroupItemsStore;
  String? _currentUserId; // Store current user's UUID
  int? _currentDeviceId; // Store current device ID
  
  // Getters for current user and device info
  String? get currentUserId => _currentUserId;
  int? get currentDeviceId => _currentDeviceId;
  
  // Set current user and device info (call this after authentication)
  void setCurrentUserInfo(String userId, int deviceId) {
    _currentUserId = userId;
    _currentDeviceId = deviceId;
    print('[SIGNAL SERVICE] Current user set: userId=$userId, deviceId=$deviceId');
  }

  Future<void> test() async {
    print("SignalService test method called");
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
      print("ERROR: Bob has no preKeys or signedPreKeys!");
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
    // ignore: avoid_print
    print(ciphertext);
    // ignore: avoid_print
    print(ciphertext.serialize());
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
        print('Bob decrypted: ${utf8.decode(plaintext)}');
      });
    } else if (ciphertext.getType() == CiphertextMessage.whisperType) {
      final plaintext = await bobSessionCipher.decryptFromSignal(ciphertext as SignalMessage);
      // ignore: avoid_print
      print('Bob decrypted: ${utf8.decode(plaintext)}');
    }

}


  Future<void> init() async {
  identityStore = PermanentIdentityKeyStore();
  sessionStore = await PermanentSessionStore.create();
  preKeyStore = PermanentPreKeyStore();
  final identityKeyPair = await identityStore.getIdentityKeyPair();
  signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
  sentMessagesStore = await PermanentSentMessagesStore.create();
  decryptedMessagesStore = await PermanentDecryptedMessagesStore.create();
  senderKeyStore = await PermanentSenderKeyStore.create();
    decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
    sentGroupItemsStore = await SentGroupItemsStore.getInstance();

    await _registerSocketListeners();

    // --- Signal status check and conditional upload ---
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    //await test();
  }

  /// Initialize stores and listeners without generating keys
  /// Used when keys already exist (after successful setup or on returning user)
  Future<void> initStoresAndListeners() async {
    print('[SIGNAL SERVICE] Initializing stores and listeners (keys already exist)...');
    
    // Initialize all stores
    identityStore = PermanentIdentityKeyStore();
    sessionStore = await PermanentSessionStore.create();
    preKeyStore = PermanentPreKeyStore();
    final identityKeyPair = await identityStore.getIdentityKeyPair();
    signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);
    sentMessagesStore = await PermanentSentMessagesStore.create();
    decryptedMessagesStore = await PermanentDecryptedMessagesStore.create();
    senderKeyStore = await PermanentSenderKeyStore.create();
    decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
    sentGroupItemsStore = await SentGroupItemsStore.getInstance();

    // Register socket listeners
    await _registerSocketListeners();

    // Check status with server (may trigger key uploads if server is missing keys)
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    print('[SIGNAL SERVICE] Stores and listeners initialized successfully');
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
    const int totalSteps = 112; // 1 KeyPair + 1 SignedPreKey + 110 PreKeys
    int currentStep = 0;

    // Helper to update progress
    void updateProgress(String status, int step) {
      final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
      onProgress(status, step, totalSteps, percentage);
    }

    // Initialize stores first
    identityStore = PermanentIdentityKeyStore();
    sessionStore = await PermanentSessionStore.create();
    preKeyStore = PermanentPreKeyStore();
    sentMessagesStore = await PermanentSentMessagesStore.create();
    decryptedMessagesStore = await PermanentDecryptedMessagesStore.create();
    senderKeyStore = await PermanentSenderKeyStore.create();
    decryptedGroupItemsStore = await DecryptedGroupItemsStore.getInstance();
    sentGroupItemsStore = await SentGroupItemsStore.getInstance();

    // Step 1: Generate Identity Key Pair (if needed)
    updateProgress('Generating identity key pair...', currentStep);
    try {
      await identityStore.getIdentityKeyPair();
      print('[SIGNAL INIT] Identity key pair exists');
    } catch (e) {
      print('[SIGNAL INIT] Identity key pair will be generated: $e');
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
      print('[SIGNAL INIT] Signed pre key generated');
    } else {
      print('[SIGNAL INIT] Signed pre key already exists');
    }
    currentStep++;
    updateProgress('Signed pre key ready', currentStep);
    await Future.delayed(const Duration(milliseconds: 50));

    // Step 3: Generate PreKeys in batches (110 keys, 10 per batch)
    final existingPreKeys = await preKeyStore.getAllPreKeys();
    final neededPreKeys = 110 - existingPreKeys.length;
    
    if (neededPreKeys > 0) {
      print('[SIGNAL INIT] Generating $neededPreKeys pre keys');
      final startId = existingPreKeys.isNotEmpty 
          ? existingPreKeys.map((k) => k.id).reduce((a, b) => a > b ? a : b) + 1 
          : 0;
      
      const int batchSize = 10;
      final int totalBatches = (neededPreKeys / batchSize).ceil();
      
      for (int batch = 0; batch < totalBatches; batch++) {
        final int batchStart = startId + (batch * batchSize);
        final int batchEnd = (batchStart + batchSize).clamp(0, startId + neededPreKeys);
        final int keysInBatch = batchEnd - batchStart;
        
        updateProgress('Generating pre keys ${existingPreKeys.length + (batch * batchSize) + 1}-${existingPreKeys.length + (batch * batchSize) + keysInBatch} of 110...', currentStep);
        
        final preKeys = generatePreKeys(batchStart, batchEnd - 1);
        for (final preKey in preKeys) {
          await preKeyStore.storePreKey(preKey.id, preKey);
          currentStep++;
          
          // Update progress every 5 keys or on last key
          if (currentStep % 5 == 0 || currentStep == totalSteps) {
            final keysGenerated = currentStep - 2; // Subtract KeyPair and SignedPreKey
            updateProgress('Generating pre keys $keysGenerated of 110...', currentStep);
          }
        }
        
        // Small delay between batches to prevent UI freeze
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } else {
      print('[SIGNAL INIT] Pre keys already sufficient (${existingPreKeys.length}/110)');
      // Skip to end
      currentStep = totalSteps;
      updateProgress('Pre keys already ready', currentStep);
    }

    // Register socket listeners
    await _registerSocketListeners();

    // Final progress update
    updateProgress('Signal Protocol ready', totalSteps);

    // Check status with server
    SocketService().emit("signalStatus", null);

    _isInitialized = true;
    print('[SIGNAL INIT] Progressive initialization complete');
  }

  /// Register all Socket.IO listeners (extracted for reuse)
  Future<void> _registerSocketListeners() async {
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
      if (_itemTypeCallbacks.containsKey('groupItem')) {
        for (final callback in _itemTypeCallbacks['groupItem']!) {
          callback(data);
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

    SocketService().registerListener("signalStatusResponse", (status) async {
      await _ensureSignalKeysPresent(status);
    });
  }

  Future<void> _ensureSignalKeysPresent(status) async {
    // Use a socket callback to get status
    print('[SIGNAL SERVICE] signalStatus: $status');
    
    // Check if user is authenticated
    if (status is Map && status['error'] != null) {
      print('[SIGNAL SERVICE] ERROR: ${status['error']} - Cannot upload Signal keys without authentication');
      return;
    }
    
    // 1. Identity
    if (status is Map && status['identity'] != true) {
      print('[SIGNAL SERVICE] Uploading missing identity');
    final identityData = await identityStore.getIdentityKeyPairData();
    final registrationId = await identityStore.getLocalRegistrationId();
      SocketService().emit("signalIdentity", {
        'publicKey': identityData['publicKey'],
        'registrationId': registrationId.toString(),
      });
    }
    // 2. PreKeys
    final int preKeysCount = (status is Map && status['preKeys'] is int) ? status['preKeys'] : 0;
    if (preKeysCount < 20) {
      print('[SIGNAL SERVICE] Not enough pre-keys on server, uploading more');
      final localPreKeys = await preKeyStore.getAllPreKeys();
      if (localPreKeys.isNotEmpty) {
        final preKeysPayload = localPreKeys.map((pk) => {
          'id': pk.id,
          'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
        }).toList();
        SocketService().emit("storePreKeys", { 'preKeys': preKeysPayload });
      }
    }
    // 3. SignedPreKey
    final signedPreKey = status is Map ? status['signedPreKey'] : null;
    if (signedPreKey == null) {
      print('[SIGNAL SERVICE] No signed pre-key on server, uploading');
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

  /// Unregister delivery receipt callbacks
  void clearDeliveryCallbacks() {
    _deliveryCallbacks.remove('default');
  }

  /// Unregister read receipt callbacks
  void clearReadCallbacks() {
    _readCallbacks.remove('default');
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
  Future<List<Map<String, dynamic>>> loadSentMessages(String recipientUserId) async {
    return await sentMessagesStore.loadSentMessages(recipientUserId);
  }
  
  /// Load all sent messages from local storage
  Future<List<Map<String, dynamic>>> loadAllSentMessages() async {
    return await sentMessagesStore.loadAllSentMessages();
  }

  /// Entschlüsselt ein Item-Objekt (wie receiveItem), gibt aber nur die entschlüsselte Nachricht zurück
  /// Prüft zuerst den lokalen Cache, um DuplicateMessageException zu vermeiden
  Future<String> decryptItemFromData(Map<String, dynamic> data) async {
    final sender = data['sender'];
    final senderDeviceId = data['senderDeviceId'];
    final payload = data['payload'];
    final cipherType = data['cipherType'];
    final itemId = data['itemId'];
    
    // Check if we already decrypted this message (prevents DuplicateMessageException)
    if (itemId != null) {
      final cached = await decryptedMessagesStore.getDecryptedMessage(itemId);
      if (cached != null) {
        print("[SIGNAL SERVICE] ✓ Using cached decrypted message for itemId: $itemId (message: ${cached.substring(0, cached.length > 50 ? 50 : cached.length)}...)");
        return cached;
      } else {
        print("[SIGNAL SERVICE] Cache miss for itemId: $itemId - will decrypt");
      }
    } else {
      print("[SIGNAL SERVICE] No itemId provided - cannot use cache");
    }
    
    print("[SIGNAL SERVICE] Decrypting new message: itemId=$itemId, sender=$sender, deviceId=$senderDeviceId");
    final senderAddress = SignalProtocolAddress(sender, senderDeviceId);
    
    try {
      final message = await decryptItem(
        senderAddress: senderAddress,
        payload: payload,
        cipherType: cipherType,
      );
      
      // Cache the decrypted message to prevent re-decryption
      // IMPORTANT: Only cache 1:1 messages (no channelId)
      // Group messages use DecryptedGroupItemsStore instead
      if (itemId != null && message.isNotEmpty && data['channel'] == null) {
        await decryptedMessagesStore.storeDecryptedMessage(
          itemId: itemId,
          message: message,
          sender: sender,
          senderDeviceId: senderDeviceId,
          timestamp: data['timestamp'] ?? data['createdAt'] ?? DateTime.now().toIso8601String(),
          type: data['type'],
        );
        print("[SIGNAL SERVICE] ✓ Cached decrypted 1:1 message for itemId: $itemId");
      } else if (data['channel'] != null) {
        print("[SIGNAL SERVICE] ⚠ Skipping cache for group message (use DecryptedGroupItemsStore)");
      }
      
      return message;
    } catch (e) {
      print('[SIGNAL SERVICE] ✗ Decryption failed for itemId: $itemId - $e');
      // Return empty string on error (will be filtered out later)
      return '';
    }
  }

  /// Empfängt eine verschlüsselte Nachricht vom Socket.IO Server
  /// 
  /// Das Backend filtert bereits und sendet nur Nachrichten, die für DIESES Gerät
  /// (deviceId) verschlüsselt wurden. Die Nachricht wird dann mit dem Session-Schlüssel
  /// dieses Geräts entschlüsselt.
  void receiveItem(data) async {
  print("[SIGNAL SERVICE] ===============================================");
  print("[SIGNAL SERVICE] receiveItem called for this device");
  print("[SIGNAL SERVICE] ===============================================");
  print("[SIGNAL SERVICE] receiveItem: $data");
  final type = data['type'];
  final sender = data['sender']; // z.B. Absender-UUID
  final senderDeviceId = data['senderDeviceId'];
  final cipherType = data['cipherType'];
  final itemId = data['itemId'];

  // Use decryptItemFromData to get caching + IndexedDB storage
  // This ensures real-time messages are also persisted locally
  final message = await decryptItemFromData(data);

  // Skip messages only if decryption failed (empty result from error handling)
  if (message.isEmpty) {
    print("[SIGNAL SERVICE] Skipping message - decryption failed or returned empty result");
    return;
  }

  print("[SIGNAL SERVICE] Message decrypted successfully: '$message' (cipherType: $cipherType)");

  final recipient = data['recipient']; // Empfänger-UUID vom Server

  final item = {
    'itemId': itemId,
    'sender': sender,
    'senderDeviceId': senderDeviceId,
    'recipient': recipient,
    'type': type,
    'message': message,
  };

  // Jetzt kannst du message weiterverarbeiten
  if (cipherType != CiphertextMessage.whisperType && _itemTypeCallbacks.containsKey(cipherType)) {
    for (final callback in _itemTypeCallbacks[cipherType]!) {
      callback(message);
    }
  }

  // Jetzt kannst du message weiterverarbeiten
  if (type != null && _itemTypeCallbacks.containsKey(type)) {
    for (final callback in _itemTypeCallbacks[type]!) {
      callback(item);
    }
  }
  
  // Handle read_receipt type
  if (type == 'read_receipt') {
    print('[SIGNAL_SERVICE] receiveItem detected read_receipt type, calling _handleReadReceipt');
    await _handleReadReceipt(item);
  } else {
    print('[SIGNAL_SERVICE] receiveItem type is: $type (not a read_receipt)');
  }
}

  /// Handle delivery receipt from server
  Future<void> _handleDeliveryReceipt(Map<String, dynamic> data) async {
    final itemId = data['itemId'];
    print('[SIGNAL SERVICE] Delivery receipt received for itemId: $itemId');
    
    // Update local store
    await sentMessagesStore.markAsDelivered(itemId);
    
    // Trigger callbacks
    if (_deliveryCallbacks.containsKey('default')) {
      for (final callback in _deliveryCallbacks['default']!) {
        callback(itemId);
      }
    }
  }

  /// Handle group message read receipt (from Socket.IO)
  void _handleGroupMessageReadReceipt(Map<String, dynamic> data) {
    print('[SIGNAL SERVICE] Group message read receipt received: $data');
    
    // Trigger callbacks with the full receipt data
    if (_itemTypeCallbacks.containsKey('groupMessageReadReceipt')) {
      for (final callback in _itemTypeCallbacks['groupMessageReadReceipt']!) {
        callback(data);
      }
    }
  }

  /// Handle read receipt (encrypted Signal message)
  Future<void> _handleReadReceipt(Map<String, dynamic> item) async {
    print('[SIGNAL_SERVICE] _handleReadReceipt called with item: $item');
    try {
      final receiptData = jsonDecode(item['message']);
      final itemId = receiptData['itemId'];
      final readByDeviceId = receiptData['readByDeviceId'] as int?;
      final readByUserId = item['sender']; // The user who sent the read receipt
      print('[SIGNAL_SERVICE] Processing read receipt for itemId: $itemId, readByDeviceId: $readByDeviceId, readByUserId: $readByUserId');
      
      // Update local store
      await sentMessagesStore.markAsRead(itemId);
      
      // Trigger callbacks with itemId, deviceId, and userId
      if (_readCallbacks.containsKey('default')) {
        print('[SIGNAL_SERVICE] Triggering ${_readCallbacks['default']!.length} read receipt callbacks');
        for (final callback in _readCallbacks['default']!) {
          // Pass all three parameters: itemId, readByDeviceId, readByUserId
          callback({'itemId': itemId, 'readByDeviceId': readByDeviceId, 'readByUserId': readByUserId});
        }
        print('[SIGNAL_SERVICE] ✓ All read receipt callbacks executed');
      } else {
        print('[SIGNAL_SERVICE] ⚠ No read receipt callbacks registered');
      }
    } catch (e, stack) {
      print('[SIGNAL_SERVICE] ❌ Error handling read receipt: $e');
      print('[SIGNAL_SERVICE] Stack trace: $stack');
    }
  }

  Future<List<Map<String, dynamic>>> fetchPreKeyBundleForUser(String userId) async {
    final apiServer = await loadWebApiServer();
    String urlString = apiServer ?? '';
    if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
      urlString = 'https://$urlString';
    }
    final response = await ApiService.get('$urlString/signal/prekey_bundle/$userId');
    print('[DEBUG] response.statusCode: \\${response.statusCode}');
    print('[DEBUG] response.data: \\${response.data}');
    print('[DEBUG] response.data.runtimeType: \\${response.data.runtimeType}');
    if (response.statusCode == 200) {
      try {
        final devices = response.data is String ? jsonDecode(response.data) : response.data;
        print('[DEBUG] devices: \\${devices}');
        print('[DEBUG] devices.runtimeType: \\${devices.runtimeType}');
        if (devices is List) {
          print('[DEBUG] devices.length: \\${devices.length}');
        }
        final List<Map<String, dynamic>> result = [];
        for (final data in devices) {
          print('[DEBUG] signedPreKey: ' + jsonEncode(data['signedPreKey']));
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
            print('[SIGNAL SERVICE][WARN] Device ${data['clientid']} skipped: missing required Signal fields.');
            continue;
          }
          print('[DEBUG] Decoding preKey ${data['preKey']['prekey_data']}');
          print(base64Decode(data['preKey']['prekey_data']).length);
          print("[DEBUG] Decoding signedPreKey ${data['signedPreKey']['signed_prekey_data']}");
          print(base64Decode(data['signedPreKey']['signed_prekey_data']).length);
          print("[DEBUG] Decoding signedPreKeySignature ${data['signedPreKey']['signed_prekey_signature']}");
          print(base64Decode(data['signedPreKey']['signed_prekey_signature']).length);
          result.add({
            'clientid': data['clientid'],
            'userId': data['userId'],
            'deviceId': data['device_id'],
            'publicKey': data['public_key'],
            'registrationId': data['registration_id'],
            'preKeyId': data['preKey']['prekey_id'],
            'preKeyPublic': Curve.decodePoint(base64Decode(data['preKey']['prekey_data']), 0),
            'signedPreKeyId': data['signedPreKey']['signed_prekey_id'],
            'signedPreKeyPublic': Curve.decodePoint(base64Decode(data['signedPreKey']['signed_prekey_data']), 0),
            'signedPreKeySignature': base64Decode(data['signedPreKey']['signed_prekey_signature']),
            'identityKey': IdentityKey.fromBytes(base64Decode(data['public_key']), 0),
          });
        }
        if (result.isEmpty) {
          print('[SIGNAL SERVICE][ERROR] No valid Signal devices found for user $userId.');
        }
        return result;
      } catch (e, st) {
        print('[ERROR] Exception while decoding response: \\${e}\\n\\${st}');
        rethrow;
      }
    } else {
      throw Exception('Failed to load PreKeyBundle');
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
  }) async {
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
    
    print('[SIGNAL SERVICE] Step 0: Trigger local callback for sent message');
    // Immediately notify UI with the PLAINTEXT message for the sending device
    // This allows Bob Device 1 to see his own sent message without decryption
    
    // Store sent message in local storage for persistence after refresh
    // IMPORTANT: Only store actual chat messages, not system messages
    final timestamp = DateTime.now().toIso8601String();
    if (type == 'message') {
      await sentMessagesStore.storeSentMessage(
        recipientUserId: recipientUserId,
        itemId: messageItemId,
        message: payloadString,
        timestamp: timestamp,
        type: type,  // Include message type
      );
      print('[SIGNAL SERVICE] Step 0a: Stored sent message in local storage');
    } else {
      print('[SIGNAL SERVICE] Step 0a: Skipping storage for system message type: $type');
    }
    
    // Trigger local callback for UI updates (but not for read_receipt - they are system messages)
    if (type != 'read_receipt' && _itemTypeCallbacks.containsKey(type)) {
      final localItem = {
        'itemId': messageItemId,
        'sender': _currentUserId,
        'recipient': recipientUserId, // Add recipient for proper filtering
        'senderDeviceId': _currentDeviceId,
        'type': type,
        'message': payloadString,
        'timestamp': timestamp,
        'isLocalSent': true, // Mark as locally sent (not received from server)
      };
      for (final callback in _itemTypeCallbacks[type]!) {
        callback(localItem);
      }
      print('[SIGNAL SERVICE] Step 0b: Triggered ${_itemTypeCallbacks[type]!.length} local callbacks for type: $type');
    }
    
    print('[SIGNAL SERVICE] Step 1: fetchPreKeyBundleForUser($recipientUserId)');
    print('[SIGNAL SERVICE] This fetches devices for BOTH users: recipient AND sender (own devices)');
    final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);
    print('[SIGNAL SERVICE] Step 1 result: $preKeyBundles');
    print('[SIGNAL SERVICE] Number of devices (Alice + Bob): ${preKeyBundles.length}');
    for (final bundle in preKeyBundles) {
      print('[SIGNAL SERVICE] Device: userId=${bundle['userId']}, deviceId=${bundle['deviceId']}');
    }

    // Verschlüssele für jedes Gerät separat
    for (final bundle in preKeyBundles) {
      print('[SIGNAL SERVICE] ===============================================');
      print('[SIGNAL SERVICE] Encrypting for device: ${bundle['userId']}:${bundle['deviceId']}');
      print('[SIGNAL SERVICE] ===============================================');
      
      // CRITICAL: Skip encryption for our own current device
      // We cannot decrypt messages we encrypt to ourselves (same session direction)
      final isCurrentDevice = (bundle['userId'] == _currentUserId && bundle['deviceId'] == _currentDeviceId);
      if (isCurrentDevice) {
        print('[SIGNAL SERVICE] Skipping current device (cannot encrypt to self): ${bundle['userId']}:${bundle['deviceId']}');
        continue;
      }
      
      print('[SIGNAL SERVICE] Step 2: Prepare recipientAddress for deviceId ${bundle['deviceId']}');
      final recipientAddress = SignalProtocolAddress(bundle['userId'], bundle['deviceId']);
      
      // Check if this is our own device (not the intended recipient)
      // This happens when the backend returns our own devices for multi-device support
      final isOwnDevice = (bundle['userId'] != recipientUserId);
      
      print('[SIGNAL SERVICE] Step 3: Check session for $recipientAddress');
      var hasSession = await sessionStore.containsSession(recipientAddress);
      print('[SIGNAL SERVICE] Step 3 result: hasSession=$hasSession, isOwnDevice=$isOwnDevice');

      print('[SIGNAL SERVICE] Step 4: Create SessionCipher for $recipientAddress');
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        recipientAddress,
      );

      if (!hasSession) {
        print('[SIGNAL SERVICE] Step 5: Build session for $recipientAddress');
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
        print('[SIGNAL SERVICE] Step 5 done');
      }

      

      print('[SIGNAL SERVICE] Step 6: Using pre-prepared payload');
      // payloadString is already prepared before the loop
      print('[SIGNAL SERVICE] Step 6: payload is: $payloadString');
      
      print('[SIGNAL SERVICE] Step 7: Encrypt payload with message: $payloadString');
      ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(payloadString)));

      

      print('[SIGNAL SERVICE] Step 8: Serialize ciphertext');
      final serialized = base64Encode(ciphertextMessage.serialize());
      print('[SIGNAL SERVICE] Step 8 result: cipherType=${ciphertextMessage.getType()}, hasSession=$hasSession');
      
      // CRITICAL: If we get PreKey message despite having a session, the session is corrupted
      // Delete it and rebuild from scratch
      if (ciphertextMessage.getType() == 3 && hasSession) {
        print('[SIGNAL SERVICE] WARNING: PreKey message despite existing session! Session is corrupted.');
        print('[SIGNAL SERVICE] Deleting corrupted session with ${recipientAddress}');
        await sessionStore.deleteSession(recipientAddress);
        hasSession = false;
        print('[SIGNAL SERVICE] Session deleted. Rebuilding...');
        
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
        print('[SIGNAL SERVICE] Session rebuilt');
        
        // Re-encrypt with new session
        print('[SIGNAL SERVICE] Re-encrypting message with rebuilt session');
        ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(payloadString)));
        final newSerialized = base64Encode(ciphertextMessage.serialize());
        print('[SIGNAL SERVICE] Re-encrypted cipherType=${ciphertextMessage.getType()}');
        
        // Update data with new encryption (use same itemId)
        final data = {
          'recipient': recipientAddress.getName(),
          'recipientDeviceId': recipientAddress.getDeviceId(),
          'type': type,
          'payload': newSerialized,
          'cipherType': ciphertextMessage.getType(),
          'itemId': messageItemId,
        };
        
        print('[SIGNAL SERVICE] Sending rebuilt message: cipherType=${ciphertextMessage.getType()}');
        SocketService().emit("sendItem", data);
        continue; // Skip normal sending path
      }

      print('[SIGNAL SERVICE] Step 9: Build data packet');
      // Use the pre-generated itemId from before the loop
      final data = {
        'recipient': recipientAddress.getName(),
        'recipientDeviceId': recipientAddress.getDeviceId(),
        'type': type,
        'payload': serialized,
        'cipherType': ciphertextMessage.getType(),
        'itemId': messageItemId,
      };

      print('[SIGNAL SERVICE] Step 10: Sending item: $data');
      SocketService().emit("sendItem", data);
      
      // Log message type for debugging
      final isPreKeyMessage = ciphertextMessage.getType() == 3;
      if(isPreKeyMessage) {
        print('[SIGNAL SERVICE] Step 11: PreKey message sent (first message to establish session)');
        print('[SIGNAL SERVICE] Step 11a: This message contains the actual content and will establish the session');
      } else {
        print('[SIGNAL SERVICE] Step 11: Whisper message sent (session already exists)');
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
      await preKeyStore.removePreKey(preKeyId);
      preKeyStore.checkPreKeys();
    }
    return utf8.decode(plaintext);
} else if (cipherType == CiphertextMessage.whisperType) {
    // Normale Nachricht
    final signalMsg = SignalMessage.fromSerialized(serialized);
    final plaintext = await sessionCipher.decryptFromSignal(signalMsg);
    print('[SIGNAL SERVICE] Step 8: Decrypted plaintext: $plaintext');
    return utf8.decode(plaintext);
  } else if (cipherType == CiphertextMessage.senderKeyType) {
    // Group message - should NOT be processed here!
    // Group messages should come via 'groupMessage' Socket.IO event and use GroupCipher
    throw Exception('CipherType 4 (senderKeyType) detected - group messages must use GroupCipher, not SessionCipher. This message should come via groupMessage event, not receiveItem.');
  } else {
    throw Exception('Unknown cipherType: $cipherType');
  }
  } catch (e, st) {
    print('[ERROR] Exception while decrypting message: \\${e}\\n\\${st}');
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
  Future<Uint8List> createGroupSenderKey(String groupId) async {
    if (_currentUserId == null || _currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    print('[SIGNAL_SERVICE] Creating sender key for group $groupId, user $_currentUserId:$_currentDeviceId');

    // Verify identity key pair exists
    try {
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      print('[SIGNAL_SERVICE] Identity key pair verified - PublicKey: ${identityKeyPair.getPublicKey().toString().substring(0, 20)}...');
    } catch (e) {
      print('[SIGNAL_SERVICE] Error verifying identity key pair: $e');
      throw Exception('Cannot create sender key: Identity key pair not available. Please register Signal keys first. Error: $e');
    }

    // Verify sender key store is initialized
    try {
      final testSenderKeyName = SenderKeyName(groupId, SignalProtocolAddress(_currentUserId!, _currentDeviceId!));
      await senderKeyStore.loadSenderKey(testSenderKeyName);
      print('[SIGNAL_SERVICE] Sender key store is accessible');
    } catch (e) {
      print('[SIGNAL_SERVICE] Error accessing sender key store: $e');
      throw Exception('Cannot create sender key: Sender key store error: $e');
    }

    try {
      final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      print('[SIGNAL_SERVICE] Created SenderKeyName for group $groupId, address ${senderAddress.getName()}:${senderAddress.getDeviceId()}');
      
      final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
      print('[SIGNAL_SERVICE] Created GroupSessionBuilder');
      
      // Create sender key distribution message
      print('[SIGNAL_SERVICE] Calling groupSessionBuilder.create()...');
      final distributionMessage = await groupSessionBuilder.create(senderKeyName);
      print('[SIGNAL_SERVICE] Successfully created distribution message');
      
      final serialized = distributionMessage.serialize();
      print('[SIGNAL_SERVICE] Serialized distribution message, length: ${serialized.length}');
      
      print('[SIGNAL_SERVICE] Created sender key for group $groupId');
      
      // Store sender key on server for backup/retrieval
      try {
        final senderKeyBase64 = base64Encode(serialized);
        SocketService().emit('storeSenderKey', {
          'groupId': groupId,
          'senderKey': senderKeyBase64,
        });
        print('[SIGNAL_SERVICE] Stored sender key on server for group $groupId');
      } catch (e) {
        print('[SIGNAL_SERVICE] Warning: Failed to store sender key on server: $e');
        // Don't fail - sender key is already stored locally
      }
      
      return serialized;
    } catch (e, stackTrace) {
      print('[SIGNAL_SERVICE] Error in createGroupSenderKey: $e');
      print('[SIGNAL_SERVICE] Stack trace: $stackTrace');
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
    
    print('[SIGNAL_SERVICE] Processed sender key from $senderId:$senderDeviceId for group $groupId');
  }

  /// Encrypt message for group using sender key
  Future<Map<String, dynamic>> encryptGroupMessage(
    String groupId,
    String message,
  ) async {
    if (_currentUserId == null || _currentDeviceId == null) {
      throw Exception('User info not set. Call setCurrentUserInfo first.');
    }

    print('[SIGNAL_SERVICE] encryptGroupMessage: groupId=$groupId, userId=$_currentUserId:$_currentDeviceId, messageLength=${message.length}');

    try {
      final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
      print('[SIGNAL_SERVICE] Created sender address: ${senderAddress.getName()}:${senderAddress.getDeviceId()}');
      
      final senderKeyName = SenderKeyName(groupId, senderAddress);
      print('[SIGNAL_SERVICE] Created sender key name for group $groupId');
      
      // Check if sender key exists
      final hasSenderKey = await senderKeyStore.containsSenderKey(senderKeyName);
      print('[SIGNAL_SERVICE] Sender key exists: $hasSenderKey');
      
      if (!hasSenderKey) {
        throw Exception('No sender key found for this group. Please initialize sender key first.');
      }
      
      // Load the sender key record to verify it's valid
      await senderKeyStore.loadSenderKey(senderKeyName);
      print('[SIGNAL_SERVICE] Loaded sender key record from store');
      
      final groupCipher = GroupCipher(senderKeyStore, senderKeyName);
      print('[SIGNAL_SERVICE] Created GroupCipher');
      
      final messageBytes = Uint8List.fromList(utf8.encode(message));
      print('[SIGNAL_SERVICE] Encoded message to bytes, length: ${messageBytes.length}');
      
      print('[SIGNAL_SERVICE] Calling groupCipher.encrypt()...');
      final ciphertext = await groupCipher.encrypt(messageBytes);
      print('[SIGNAL_SERVICE] Successfully encrypted message, ciphertext length: ${ciphertext.length}');
      
      return {
        'ciphertext': base64Encode(ciphertext),
        'senderId': _currentUserId,
        'senderDeviceId': _currentDeviceId,
      };
    } catch (e, stackTrace) {
      print('[SIGNAL_SERVICE] Error in encryptGroupMessage: $e');
      print('[SIGNAL_SERVICE] Stack trace: $stackTrace');
      
      // Check if this is a RangeError (corrupt/empty sender key)
      if (e.toString().contains('RangeError') || e.toString().contains('Invalid value')) {
        print('[SIGNAL_SERVICE] Detected RangeError - sender key is likely empty/corrupt');
        print('[SIGNAL_SERVICE] Attempting to recreate sender key...');
        
        // Delete the corrupt sender key
        try {
          final senderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
          final senderKeyName = SenderKeyName(groupId, senderAddress);
          await senderKeyStore.removeSenderKey(senderKeyName);
          print('[SIGNAL_SERVICE] Removed corrupt sender key');
        } catch (removeError) {
          print('[SIGNAL_SERVICE] Error removing corrupt key: $removeError');
        }
        
        // Recreate the sender key
        try {
          print('[SIGNAL_SERVICE] Creating new sender key...');
          final distributionMessage = await createGroupSenderKey(groupId);
          print('[SIGNAL_SERVICE] New sender key created');
          
          // Trigger callback to notify that sender key was recreated
          // This should trigger distribution to all group members
          if (_itemTypeCallbacks.containsKey('senderKeyRecreated')) {
            for (final callback in _itemTypeCallbacks['senderKeyRecreated']!) {
              callback({
                'groupId': groupId,
                'distributionMessage': distributionMessage,
              });
            }
          }
          
          print('[SIGNAL_SERVICE] Retrying encryption with new sender key...');
          
          // Retry encryption with new key
          final messageBytes = Uint8List.fromList(utf8.encode(message));
          final newSenderAddress = SignalProtocolAddress(_currentUserId!, _currentDeviceId!);
          final newSenderKeyName = SenderKeyName(groupId, newSenderAddress);
          final newGroupCipher = GroupCipher(senderKeyStore, newSenderKeyName);
          final newCiphertext = await newGroupCipher.encrypt(messageBytes);
          print('[SIGNAL_SERVICE] Successfully encrypted with new sender key');
          
          return {
            'ciphertext': base64Encode(newCiphertext),
            'senderId': _currentUserId,
            'senderDeviceId': _currentDeviceId,
          };
        } catch (retryError) {
          print('[SIGNAL_SERVICE] Failed to recreate and encrypt: $retryError');
          rethrow;
        }
      }
      
      // Not a RangeError, rethrow the original error
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
    print('[SIGNAL_SERVICE] WARNING: sendGroupMessage is deprecated, use sendGroupItem instead');
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
      await ApiService.post(
        '/channels/$groupId/request-sender-key',
        data: {
          'requesterId': _currentUserId,
          'requesterDeviceId': _currentDeviceId,
          'targetUserId': userId,
          'targetDeviceId': deviceId,
        },
      );
      
      print('[SIGNAL_SERVICE] Requested sender key from $userId:$deviceId for group $groupId');
    } catch (e) {
      print('[SIGNAL_SERVICE] Error requesting sender key: $e');
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
      print('[SIGNAL_SERVICE] Error checking sender key: $e');
      return false;
    }
  }

  /// Clear all sender keys for a group (e.g., when leaving)
  Future<void> clearGroupSenderKeys(String groupId) async {
    await senderKeyStore.clearGroupSenderKeys(groupId);
    print('[SIGNAL_SERVICE] Cleared all sender keys for group $groupId');
  }

  // ===== NEW: GROUP ITEM API METHODS =====

  /// Send a group item (message, reaction, file, etc.) using new GroupItem architecture
  Future<void> sendGroupItem({
    required String channelId,
    required String message,
    required String itemId,
    String type = 'message',
  }) async {
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }

      // Encrypt with sender key
      final encrypted = await encryptGroupMessage(channelId, message);
      final timestamp = DateTime.now().toIso8601String();

      // Store locally first
      await sentGroupItemsStore.storeSentGroupItem(
        channelId: channelId,
        itemId: itemId,
        message: message,
        timestamp: timestamp,
        type: type,
        status: 'sending',
      );

      // Send via Socket.IO
      SocketService().emit("sendGroupItem", {
        'channelId': channelId,
        'itemId': itemId,
        'type': type,
        'payload': encrypted['ciphertext'],
        'cipherType': 4, // Sender Key
        'timestamp': timestamp,
      });

      print('[SIGNAL_SERVICE] Sent group item $itemId to channel $channelId');
    } catch (e) {
      print('[SIGNAL_SERVICE] Error sending group item: $e');
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
      print('[SIGNAL_SERVICE] Decrypt error: $e');
      
      // Check if this is a decryption error that might be fixed by reloading sender key
      if (retryOnError && (
          e.toString().contains('InvalidMessageException') ||
          e.toString().contains('No key for') ||
          e.toString().contains('DuplicateMessageException') ||
          e.toString().contains('Invalid'))) {
        
        print('[SIGNAL_SERVICE] Attempting to reload sender key from server...');
        
        // Try to reload sender key from server
        final keyLoaded = await loadSenderKeyFromServer(
          channelId: channelId,
          userId: senderId,
          deviceId: senderDeviceId,
          forceReload: true,
        );
        
        if (keyLoaded) {
          print('[SIGNAL_SERVICE] Sender key reloaded, retrying decrypt...');
          
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
      print('[SIGNAL_SERVICE] Loading sender key from server: $userId:$deviceId (forceReload: $forceReload)');
      
      // If forceReload, delete old key first
      if (forceReload) {
        try {
          final address = SignalProtocolAddress(userId, deviceId);
          final senderKeyName = SenderKeyName(channelId, address);
          await senderKeyStore.removeSenderKey(senderKeyName);
          print('[SIGNAL_SERVICE] Removed old sender key before reload');
        } catch (removeError) {
          print('[SIGNAL_SERVICE] Error removing old key: $removeError');
        }
      }
      
      // Load from server via REST API
      final response = await ApiService.get(
        '/api/sender-keys/$channelId/$userId/$deviceId'
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
        
        print('[SIGNAL_SERVICE] ✓ Sender key loaded from server');
        return true;
      } else {
        print('[SIGNAL_SERVICE] Sender key not found on server');
        return false;
      }
    } catch (e) {
      print('[SIGNAL_SERVICE] Error loading sender key from server: $e');
      return false;
    }
  }

  /// Load all sender keys for a channel (when joining)
  Future<void> loadAllSenderKeysForChannel(String channelId) async {
    try {
      print('[SIGNAL_SERVICE] Loading all sender keys for channel $channelId');
      
      final response = await ApiService.get('/api/sender-keys/$channelId');
      
      if (response.statusCode == 200 && response.data['success'] == true) {
        final senderKeysData = response.data['senderKeys'];
        
        // Handle null or empty senderKeys
        if (senderKeysData == null) {
          print('[SIGNAL_SERVICE] No sender keys found for channel');
          return;
        }
        
        final senderKeys = senderKeysData as List<dynamic>;
        
        print('[SIGNAL_SERVICE] Found ${senderKeys.length} sender keys');
        
        for (final key in senderKeys) {
          try {
            final userId = key['userId'] as String;
            final deviceId = key['deviceId'] as int;
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
            
            print('[SIGNAL_SERVICE] ✓ Loaded sender key for $userId:$deviceId');
          } catch (keyError) {
            print('[SIGNAL_SERVICE] Error loading key: $keyError');
          }
        }
        
        print('[SIGNAL_SERVICE] ✓ Loaded ${senderKeys.length} sender keys for channel');
      }
    } catch (e) {
      print('[SIGNAL_SERVICE] Error loading all sender keys: $e');
    }
  }

  /// Upload our sender key to server
  Future<void> uploadSenderKeyToServer(String channelId) async {
    try {
      if (_currentUserId == null || _currentDeviceId == null) {
        throw Exception('User not authenticated');
      }
      
      // Create sender key distribution message
      final distributionMessage = await createGroupSenderKey(channelId);
      final senderKeyBase64 = base64Encode(distributionMessage);
      
      // Upload to server
      final response = await ApiService.post(
        '/api/sender-keys/$channelId',
        data: {
          'senderKey': senderKeyBase64,
          'deviceId': _currentDeviceId,
        },
      );
      
      if (response.statusCode == 200) {
        print('[SIGNAL_SERVICE] ✓ Sender key uploaded to server');
      } else {
        print('[SIGNAL_SERVICE] Failed to upload sender key: ${response.statusCode}');
      }
    } catch (e) {
      print('[SIGNAL_SERVICE] Error uploading sender key: $e');
      rethrow;
    }
  }

  /// Mark a group item as read
  Future<void> markGroupItemAsRead(String itemId) async {
    try {
      if (_currentDeviceId == null) {
        print('[SIGNAL_SERVICE] Cannot mark as read: device ID not set');
        return;
      }
      
      SocketService().emit("markGroupItemRead", {
        'itemId': itemId,
      });
      
      print('[SIGNAL_SERVICE] Marked group item $itemId as read');
    } catch (e) {
      print('[SIGNAL_SERVICE] Error marking item as read: $e');
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
}

