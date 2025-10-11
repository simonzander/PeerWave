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

  final Map<String, List<Function(dynamic)>> _itemTypeCallbacks = {};
  PermanentIdentityKeyStore identityStore = PermanentIdentityKeyStore();
  late PermanentSessionStore sessionStore;
  PermanentPreKeyStore preKeyStore = PermanentPreKeyStore();
  late PermanentSignedPreKeyStore signedPreKeyStore;

  Future<void> init() async {
  identityStore = PermanentIdentityKeyStore();
  sessionStore = await PermanentSessionStore.create();
  preKeyStore = PermanentPreKeyStore();
  final identityKeyPair = await identityStore.getIdentityKeyPair();
  signedPreKeyStore = PermanentSignedPreKeyStore(identityKeyPair);

    SocketService().registerListener("receiveItem", (data) {
      receiveItem(data);
    });

    SocketService().registerListener("signalStatusResponse", (status) async {
      await _ensureSignalKeysPresent(status);
    });

    // --- Signal status check and conditional upload ---
    SocketService().emit("signalStatus", null);
  }

  Future<void> _ensureSignalKeysPresent(status) async {
    // Use a socket callback to get status
    print('[SIGNAL SERVICE] signalStatus: $status');
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

  /// Unregister a callback for a specific item type
  void unregisterItemCallback(String type, Function(dynamic) callback) {
    _itemTypeCallbacks[type]?.remove(callback);
    if (_itemTypeCallbacks[type]?.isEmpty ?? false) {
      _itemTypeCallbacks.remove(type);
    }
  }

  void receiveItem(data) async {
  print("[SIGNAL SERVICE] receiveItem: $data");
  final type = data['type'];
  final sender = data['sender']; // z.B. Absender-UUID
  final senderDeviceId = data['senderDeviceId'];
  final payload = data['payload'];
  final cipherType = data['cipherType'];
  final itemId = data['itemId'];

  final senderAddress = SignalProtocolAddress(sender, senderDeviceId);

  final message = await decryptItem(
    senderAddress: senderAddress,
    payload: payload,
    cipherType: cipherType,
  );

  final item = {
    'itemId': itemId,
    'sender': sender,
    'senderDeviceId': senderDeviceId,
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
            'userId': userId,
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

  Future<void> sendItem({
    required String recipientUserId,
    required String type,
    required dynamic payload,
  }) async {
    final itemId = Uuid().v4();
    print('[SIGNAL SERVICE] Step 1: fetchPreKeyBundleForUser($recipientUserId)');
    final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);
    print('[SIGNAL SERVICE] Step 1 result: $preKeyBundles');

    for (final bundle in preKeyBundles) {
      print('[SIGNAL SERVICE] Step 2: Prepare recipientAddress for deviceId ${bundle['deviceId']}');
      final recipientAddress = SignalProtocolAddress(bundle['userId'], bundle['deviceId']);
      print('[SIGNAL SERVICE] Step 3: Check session for $recipientAddress');
      final hasSession = await sessionStore.containsSession(recipientAddress);
      print('[SIGNAL SERVICE] Step 3 result: hasSession=$hasSession');

      if (!hasSession) {
        print('[SIGNAL SERVICE] Step 4: Build session for $recipientAddress');
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
        print('[SIGNAL SERVICE] Step 4 done');
      }

      print('[SIGNAL SERVICE] Step 5: Create SessionCipher for $recipientAddress');
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        recipientAddress,
      );

      print('[SIGNAL SERVICE] Step 6: Prepare payload');
      String payloadString;
      if (payload is String) {
        payloadString = payload;
        print('[SIGNAL SERVICE] Step 6a: payload is String: $payloadString');
      } else {
        payloadString = jsonEncode(payload);
        print('[SIGNAL SERVICE] Step 6b: payload is encoded to JSON: $payloadString');
      }

      print('[SIGNAL SERVICE] Step 7: Encrypt payload');
      final ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(payloadString)));

      print('[SIGNAL SERVICE] Step 8: Serialize ciphertext');
      final serialized = base64Encode(ciphertextMessage.serialize());

      print('[SIGNAL SERVICE] Step 9: Build data packet');
      final data = {
        'recipient': recipientAddress.getName(),
        'recipientDeviceId': recipientAddress.getDeviceId(),
        'type': type,
        'payload': serialized,
        'cipherType': ciphertextMessage.getType(),
        'itemId': itemId,
      };

      print('[SIGNAL SERVICE] Step 10: Sending item: $data');
      SocketService().emit("sendItem", data);
    }
  }

Future<String> decryptItem({
  required SignalProtocolAddress senderAddress,
  required String payload, // base64-encoded serialized message
  required int cipherType, // 3 = PreKey, 1 = SignalMessage
}) async {
  // 1. SessionCipher für den Absender holen/erstellen
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
    return utf8.decode(plaintext);
  } else {
    throw Exception('Unknown cipherType: $cipherType');
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
}

