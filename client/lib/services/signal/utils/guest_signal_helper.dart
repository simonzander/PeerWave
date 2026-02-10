import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as signal;

import '../../../utils/html_stub.dart'
    if (dart.library.html) 'dart:html'
    as html;

class GuestSignalHelper {
  signal.InMemorySessionStore _sessionStore;
  signal.InMemoryPreKeyStore _preKeyStore;
  signal.InMemorySignedPreKeyStore _signedPreKeyStore;
  signal.InMemoryIdentityKeyStore _identityStore;

  GuestSignalHelper._(
    this._sessionStore,
    this._preKeyStore,
    this._signedPreKeyStore,
    this._identityStore,
  );

  static Future<GuestSignalHelper> createFromSessionStorage() async {
    if (!kIsWeb) {
      throw Exception('Session storage only available on web');
    }

    final storage = html.window.sessionStorage;

    final identityPublic = storage['external_identity_key_public'];
    final identityPrivate = storage['external_identity_key_private'];

    if (identityPublic == null || identityPrivate == null) {
      throw Exception('Guest identity keys not found in session storage');
    }

    final privateKeyBytes = Uint8List.fromList(base64Decode(identityPrivate));
    final publicKeyPoint = signal.Curve.decodePoint(
      Uint8List.fromList(base64Decode(identityPublic)),
      0,
    );
    final privateKeyPoint = signal.Curve.decodePrivatePoint(privateKeyBytes);

    final identityKeyPair = signal.IdentityKeyPair(
      signal.IdentityKey(publicKeyPoint),
      privateKeyPoint,
    );

    final sessionStore = signal.InMemorySessionStore();
    final preKeyStore = signal.InMemoryPreKeyStore();
    final signedPreKeyStore = signal.InMemorySignedPreKeyStore();
    final identityStore = signal.InMemoryIdentityKeyStore(identityKeyPair, 0);

    final signedPreKeyJson = storage['external_signed_pre_key'];
    if (signedPreKeyJson != null) {
      final signedPreKeyData = jsonDecode(signedPreKeyJson);
      final serializedBytes = base64Decode(signedPreKeyData['serialized']);
      final guestSignedPreKey = signal.SignedPreKeyRecord.fromSerialized(
        serializedBytes,
      );

      await signedPreKeyStore.storeSignedPreKey(
        signedPreKeyData['keyId'] as int,
        guestSignedPreKey,
      );
    }

    final preKeysJson = storage['external_pre_keys'];
    if (preKeysJson != null) {
      final preKeysData = jsonDecode(preKeysJson) as List;
      for (final preKeyData in preKeysData) {
        final serializedBytes = base64Decode(preKeyData['serialized']);
        final preKeyRecord = signal.PreKeyRecord.fromBuffer(serializedBytes);
        await preKeyStore.storePreKey(preKeyData['keyId'] as int, preKeyRecord);
      }
    }

    return GuestSignalHelper._(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
    );
  }

  Future<signal.SignalProtocolAddress> establishSessionWithParticipant({
    required String participantUserId,
    required int participantDeviceId,
    required Map<String, dynamic> keybundle,
  }) async {
    final identityKey = signal.IdentityKey(
      signal.Curve.decodePoint(
        Uint8List.fromList(base64Decode(keybundle['identity_key'])),
        0,
      ),
    );

    final signedPreKey = keybundle['signed_pre_key'];
    final oneTimePreKey = keybundle['one_time_pre_key'];

    final bundle = signal.PreKeyBundle(
      0,
      participantDeviceId,
      oneTimePreKey != null ? oneTimePreKey['keyId'] as int : null,
      oneTimePreKey != null
          ? signal.Curve.decodePoint(
              Uint8List.fromList(base64Decode(oneTimePreKey['publicKey'])),
              0,
            )
          : null,
      signedPreKey['keyId'] as int,
      signal.Curve.decodePoint(
        Uint8List.fromList(base64Decode(signedPreKey['publicKey'])),
        0,
      ),
      Uint8List.fromList(base64Decode(signedPreKey['signature'])),
      identityKey,
    );

    final address = signal.SignalProtocolAddress(
      participantUserId,
      participantDeviceId,
    );

    final sessionBuilder = signal.SessionBuilder(
      _sessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      address,
    );

    await sessionBuilder.processPreKeyBundle(bundle);

    return address;
  }

  Future<Map<String, dynamic>> encrypt(
    signal.SignalProtocolAddress address,
    String plaintext,
  ) async {
    final sessionCipher = signal.SessionCipher(
      _sessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      address,
    );

    final ciphertextMessage = await sessionCipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    return {
      'ciphertext': base64Encode(ciphertextMessage.serialize()),
      'messageType': ciphertextMessage.getType(),
    };
  }

  Future<String> decrypt(
    signal.SignalProtocolAddress address,
    String ciphertextBase64,
    int messageType,
  ) async {
    final sessionCipher = signal.SessionCipher(
      _sessionStore,
      _preKeyStore,
      _signedPreKeyStore,
      _identityStore,
      address,
    );

    final ciphertextBytes = base64Decode(ciphertextBase64);
    Uint8List plaintext;

    if (messageType == signal.CiphertextMessage.prekeyType) {
      final preKeyMsg = signal.PreKeySignalMessage(ciphertextBytes);
      plaintext = await sessionCipher.decryptWithCallback(preKeyMsg, (pt) {});
    } else if (messageType == signal.CiphertextMessage.whisperType) {
      final signalMsg = signal.SignalMessage.fromSerialized(ciphertextBytes);
      plaintext = await sessionCipher.decryptFromSignal(signalMsg);
    } else {
      throw Exception('Unknown message type: $messageType');
    }

    return utf8.decode(plaintext);
  }
}
