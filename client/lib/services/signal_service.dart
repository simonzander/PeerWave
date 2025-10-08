import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'api_service.dart';
import '../web_config.dart';
import 'socket_service.dart';
import 'package:uuid/uuid.dart';

class SocketPreKeyStore extends InMemoryPreKeyStore {

  Future<void> checkPreKeys() async {
    if(store.length < 20) {
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
      for (var item in data) {
           store[item.prekey_id] = item.prekey_data;
      }
      if(data.isEmpty) {
        var newPreKeys = generatePreKeys(0, 110);
        for (var newPreKey in newPreKeys) {
          storePreKey(newPreKey.id, newPreKey);
        }
      }
      if(data.length <= 20) {
        var lastId = data.isNotEmpty ? data.map((e) => e.prekey_id).reduce((a, b) => a > b ? a : b) : 0;
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
    SocketService().emit("storePreKey", {
      'id': preKeyId,
      'data': record.serialize(),
    });
    store[preKeyId] = record.serialize();
  }
}

class SocketSignedPreKeyStore extends InMemorySignedPreKeyStore {

  final IdentityKeyPair identityKeyPair;

  SocketSignedPreKeyStore(this.identityKeyPair);

  Future<void> loadRemoteSignedPreKeys() async {
    SocketService().registerListener("getSignedPreKeysResponse", (data) {
      for (var item in data) {
           store[item.signed_prekey_id] = item.signed_prekey_data;
           if(item.createdAt < DateTime.now().millisecondsSinceEpoch - 1 * 24 * 60 * 60 * 1000) {
             // If preSignedKey is older than 1 day, create new one
             var newPreSignedKey = generateSignedPreKey(identityKeyPair, data.length);
             storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
             removeSignedPreKey(item.id);
           }
      }
      if(data.isEmpty) {
        var newPreSignedKey = generateSignedPreKey(identityKeyPair, 0);
        storeSignedPreKey(newPreSignedKey.id, newPreSignedKey);
      }
    });
    SocketService().emit("getSignedPreKeys", null);
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    SocketService().emit("removeSignedPreKey", {
      'id': signedPreKeyId,
    });
    store.remove(signedPreKeyId);
  }

  @override
  Future<void> storeSignedPreKey(
      int signedPreKeyId, SignedPreKeyRecord record) async {
    SocketService().emit("storeSignedPreKey", {
      'id': signedPreKeyId,
      'data': record.serialize(),
    });
    store[signedPreKeyId] = record.serialize();
  }
}

class SignalService {

  final Map<String, List<Function(dynamic)>> _itemTypeCallbacks = {};
  late var identityStore;
  late var sessionStore;
  late var preKeyStore;
  late var signedPreKeyStore;

  Future<void> init() async {

    final identityData = await getIdentityKeyPair();
    identityStore = InMemoryIdentityKeyStore(identityData['identityKeyPair'], identityData['registrationId']);
    SocketService().emit("signalIdentity", {
      'publicKey': identityStore.getLocalIdentityKey()?.publicKey,
      'registrationId': identityStore.getLocalRegistrationId(),
    });

    sessionStore = InMemorySessionStore();
    preKeyStore = SocketPreKeyStore();
    preKeyStore.loadRemotePreKeys();
    signedPreKeyStore = SocketSignedPreKeyStore(identityStore.getIdentityKeyPair());
    signedPreKeyStore.loadRemoteSignedPreKeys();

    SocketService().registerListener("receiveItem", (data) {
      receiveItem(data);
    });
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
    if (response.statusCode == 200) {
      final List<dynamic> devices = jsonDecode(response.data);

      return devices.map<Map<String, dynamic>>((data) => {
        'clientid': data['clientid'],
        'userId': data['userId'],
        'deviceId': data['device_id'],
        'publicKey': data['public_key'],
        'registrationId': data['registration_id'],
        'preKeyId': data['preKey']?['prekey_id'],
        'preKeyPublic': data['preKey'] != null
            ? Curve.decodePoint(base64Decode(data['preKey']['prekey_data']), 0)
            : null,
        'signedPreKeyId': data['signedPreKey']?['signed_prekey_id'],
        'signedPreKeyPublic': data['signedPreKey'] != null
            ? Curve.decodePoint(base64Decode(data['signedPreKey']['signed_prekey_data']), 0)
            : null,
        'signedPreKeySignature': data['signedPreKey']?['signed_prekey_signature'] != null
            ? base64Decode(data['signedPreKey']['signed_prekey_signature'])
            : null,
        'identityKey': data['public_key'] != null
            ? IdentityKey.fromBytes(base64Decode(data['public_key']), 0)
            : null,
      }).toList();
    } else {
      throw Exception('Failed to load PreKeyBundle');
    }
  }

  Future<void> sendItem({
    required String recipientUserId,
    required String type,
    required String payload,
  }) async {
    final itemId = Uuid().v4();
    // 1. Lade alle PreKeyBundles für alle Devices des Empfängers
    final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);

    // 2. Für jedes Device:
    for (final bundle in preKeyBundles) {
      final recipientAddress = SignalProtocolAddress(bundle['userId'], bundle['deviceId']);

      // 3. Prüfen, ob eine Session existiert
      final hasSession = sessionStore.containsSession(recipientAddress);

      // 4. Falls keine Session existiert, Session aufbauen
      if (!hasSession) {
        final preKeyBundle = PreKeyBundle(
          bundle['registrationId'],
          bundle['deviceId'],
          bundle['preKeyId'],
          bundle['preKeyPublic'], // ECPublicKey
          bundle['signedPreKeyId'],
          bundle['signedPreKeyPublic'], // ECPublicKey
          bundle['signedPreKeySignature'], // Uint8List
          bundle['identityKey'], // IdentityKey
        );

        final sessionBuilder = SessionBuilder(
          sessionStore,
          preKeyStore,
          signedPreKeyStore,
          identityStore,
          recipientAddress,
        );
        await sessionBuilder.processPreKeyBundle(preKeyBundle);
      }

      // 5. SessionCipher für das Device holen/erstellen
      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        recipientAddress,
      );

      // 6. Nachricht verschlüsseln
      final ciphertextMessage = await sessionCipher.encrypt(Uint8List.fromList(utf8.encode(payload)));

      // 7. Serialisieren
      final serialized = base64Encode(ciphertextMessage.serialize());

      // 8. Datenpaket bauen
      final data = {
        'recipient': recipientAddress.getName(),
        'recipientDeviceId': recipientAddress.getDeviceId(),
        'type': type,
        'payload': serialized,
        'cipherType': ciphertextMessage.getType(),
        'itemId': itemId,
      };

      // 9. Senden
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
  final preKeyId = preKeyMsg.getPreKeyId();
  await preKeyStore.removePreKey(preKeyId);
  preKeyStore.checkPreKeys();
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

  Future<Map<String, dynamic>> _generateIdentityKeyPair() {
    final identityKeyPair =  generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    return Future.value({
      'identityKeyPair': identityKeyPair,
      'registrationId': registrationId,
    });
  }

  Future<Map<String, dynamic>> getIdentityKeyPair() async {
    if(isSkiaWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final storeName = 'peerwaveSignal';
      final db = await idbFactory.open('peerwave', version: 1, onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        // create the store
        db.createObjectStore(storeName, autoIncrement: true);
      });

      var txn = db.transaction(storeName, "readonly");
      var store = txn.objectStore(storeName);
      var identityKeyPair = await store.getObject("identityKeyPair");
      var registrationId = await store.getObject("registrationId");
      await txn.completed;

      if (identityKeyPair == null || registrationId == null) { 
        final generated = await _generateIdentityKeyPair();
        identityKeyPair = generated['identityKeyPair'];
        registrationId = generated['registrationId'];
        txn = db.transaction(storeName, "readwrite");
            store = txn.objectStore(storeName);
            store.put(identityKeyPair ?? '', "identityKeyPair");
            store.put(registrationId ?? '', "registrationId");
            await txn.completed;
      }
      return Future.value({
        'identityKeyPair': identityKeyPair,
        'registrationId': registrationId,
      });
    } else {
      final storage = FlutterSecureStorage();
      var identityKeyPair = await storage.read(key: "identityKeyPair");
      var registrationId = await storage.read(key: "registrationId");

      if (identityKeyPair == null || registrationId == null) { 
            final generated = await _generateIdentityKeyPair();
            identityKeyPair = generated['identityKeyPair'];
            registrationId = generated['registrationId'];
            await storage.write(key: "identityKeyPair", value: identityKeyPair ?? '');
            await storage.write(key: "registrationId", value: registrationId ?? '');
      }

      return Future.value({
        'identityKeyPair': identityKeyPair,
        'registrationId': registrationId,
      });
    }
  }
}

