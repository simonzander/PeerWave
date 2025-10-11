import 'socket_service.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:collection/collection.dart';

/// A persistent identity key store for Signal identities.
/// Uses IndexedDB on web and FlutterSecureStorage on native.

class PermanentIdentityKeyStore extends IdentityKeyStore {
  final String _storeName = 'peerwaveSignalIdentityKeys';
  final String _keyPrefix = 'identity_';
  IdentityKeyPair? identityKeyPair;
  int? localRegistrationId;

  PermanentIdentityKeyStore();

  String _identityKey(SignalProtocolAddress address) =>
      '$_keyPrefix${address.getName()}_${address.getDeviceId()}';

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final db = await idbFactory.open(_storeName, version: 1,
          onUpgradeNeeded: (VersionChangeEvent event) {
        Database db = event.database;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName, autoIncrement: false);
        }
      });
      var txn = db.transaction(_storeName, 'readonly');
      var store = txn.objectStore(_storeName);
      var value = await store.getObject(_identityKey(address));
      await txn.completed;
      if (value is String) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      } else if (value is List<int>) {
        return IdentityKey.fromBytes(Uint8List.fromList(value), 0);
      } else {
        return null;
      }
    } else {
      final storage = FlutterSecureStorage();
      var value = await storage.read(key: _identityKey(address));
      if (value != null) {
        return IdentityKey.fromBytes(base64Decode(value), 0);
      } else {
        return null;
      }
    }
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    if (identityKeyPair == null) {
      final identityData = await getIdentityKeyPairData();
      final publicKeyBytes = base64Decode(identityData['publicKey']!);
      final publicKey = Curve.decodePoint(publicKeyBytes, 0);
      final publicIdentityKey = IdentityKey(publicKey);
      final privateKey = Curve.decodePrivatePoint(base64Decode(identityData['privateKey']!));
      identityKeyPair = IdentityKeyPair(publicIdentityKey, privateKey);
      localRegistrationId = int.parse(identityData['registrationId']!);
    }
    return identityKeyPair!;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    if (localRegistrationId == null) {
      final identityData = await getIdentityKeyPairData();
      localRegistrationId = int.parse(identityData['registrationId']!);
    }
    return localRegistrationId!;
  }

  /// Loads or creates the identity key pair and registrationId from persistent storage.
  Future<Map<String, String?>> getIdentityKeyPairData() async {
    String? publicKeyBase64;
    String? privateKeyBase64;
    String? registrationId;

  bool createdNew = false;
  if (kIsWeb) {
      final IdbFactory idbFactory = idbFactoryBrowser;
      final storeName = 'peerwaveSignal';
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
        createdNew = true;
      }
      if (createdNew) {
        SocketService().emit("signalIdentity", {
          'publicKey': publicKeyBase64,
          'registrationId': registrationId,
        });
      }
      return {
        'publicKey': publicKeyBase64,
        'privateKey': privateKeyBase64,
        'registrationId': registrationId,
      };
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
        createdNew = true;
      }
      if (createdNew) {
        SocketService().emit("signalIdentity", {
          'publicKey': publicKeyBase64,
          'registrationId': registrationId,
        });
      }
      return {
        'publicKey': publicKeyBase64,
        'privateKey': privateKeyBase64,
        'registrationId': registrationId,
      };
    }
  }

  Future<Map<String, String>> _generateIdentityKeyPair() async {
    final identityKeyPair = generateIdentityKeyPair();
    final publicKeyBase64 = base64Encode(identityKeyPair.getPublicKey().serialize());
    final privateKeyBase64 = base64Encode(identityKeyPair.getPrivateKey().serialize());
    final registrationId = generateRegistrationId(false);
    return {
      'publicKey': publicKeyBase64,
      'privateKey': privateKeyBase64,
      'registrationId': registrationId.toString(),
    };
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address,
      IdentityKey? identityKey, Direction? direction) async {
    final trusted = await getIdentity(address);
    if (identityKey == null) {
      return false;
    }
    return trusted == null ||
        const ListEquality().equals(trusted.serialize(), identityKey.serialize());
  }

  @override
  Future<bool> saveIdentity(
      SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) {
      return false;
    }
    final existing = await getIdentity(address);
    if (existing == null || !const ListEquality().equals(existing.serialize(), identityKey.serialize())) {
      final encoded = base64Encode(identityKey.serialize());
      if (kIsWeb) {
        final IdbFactory idbFactory = idbFactoryBrowser;
        final db = await idbFactory.open(_storeName, version: 1,
            onUpgradeNeeded: (VersionChangeEvent event) {
          Database db = event.database;
          if (!db.objectStoreNames.contains(_storeName)) {
            db.createObjectStore(_storeName, autoIncrement: false);
          }
        });
        var txn = db.transaction(_storeName, 'readwrite');
        var store = txn.objectStore(_storeName);
        await store.put(encoded, _identityKey(address));
        await txn.completed;
      } else {
        final storage = FlutterSecureStorage();
        await storage.write(key: _identityKey(address), value: encoded);
      }
      return true;
    } else {
      return false;
    }
  }
}
