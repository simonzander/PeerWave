@TestOn('vm')
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:mockito/mockito.dart';

import 'package:peerwave_client/services/api_service.dart';
import 'package:peerwave_client/services/signal/core/healing_service.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';

class MockSignalKeyManager extends Mock implements SignalKeyManager {
  ApiService? _apiServiceOverride;
  IdentityKeyPair? _identityKeyPairOverride;
  String? _publicKeyOverride;
  Map<String, String> _preKeyFingerprintsOverride = <String, String>{};
  int uploadAllKeysCallCount = 0;
  List<List<int>> syncedPreKeyIds = <List<int>>[];

  set apiServiceOverride(ApiService value) => _apiServiceOverride = value;

  set identityKeyPairOverride(IdentityKeyPair value) {
    _identityKeyPairOverride = value;
    _publicKeyOverride = base64Encode(value.getPublicKey().serialize());
  }

  set preKeyFingerprintsOverride(Map<String, String> value) {
    _preKeyFingerprintsOverride = value;
  }

  @override
  ApiService get apiService => _apiServiceOverride!;

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async =>
      _identityKeyPairOverride!;

  @override
  Future<String> getPublicKey() async => _publicKeyOverride!;

  @override
  Future<Map<String, String>> getPreKeyFingerprints() async =>
      _preKeyFingerprintsOverride;

  @override
  Future<void> syncPreKeyIds(List<int> serverKeyIds) async {
    syncedPreKeyIds.add(serverKeyIds);
  }

  @override
  Future<void> checkPreKeys() async {}

  @override
  Future<void> uploadAllKeysToServer() async {
    uploadAllKeysCallCount++;
  }
}

class MockSessionManager extends Mock implements SessionManager {}

class MockApiService extends Mock implements ApiService {
  Future<Response<dynamic>> Function(
    String url,
    Map<String, dynamic>? queryParameters,
    Options? options,
  )?
  onGet;

  Future<Response<dynamic>> Function(
    String url,
    dynamic data,
    Options? options,
  )?
  onDelete;

  @override
  Future<Response<dynamic>> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    final handler = onGet;
    if (handler == null) {
      throw StateError('MockApiService.onGet not set');
    }
    return handler(url, queryParameters, options);
  }

  @override
  Future<Response<dynamic>> delete(
    String url, {
    dynamic data,
    Options? options,
  }) {
    final handler = onDelete;
    if (handler == null) {
      throw StateError('MockApiService.onDelete not set');
    }
    return handler(url, data, options);
  }
}

void main() {
  const userId = 'user-1';
  const deviceId = 1;

  late MockSignalKeyManager keyManager;
  late MockSessionManager sessionManager;
  late MockApiService apiService;
  late SignalHealingService healingService;

  late IdentityKeyPair identityKeyPair;
  late String identityKeyBase64;
  late SignedPreKeyRecord signedPreKey;
  late String signedPreKeyBase64;
  late String signedPreKeySignatureBase64;

  Future<Response<dynamic>> _response(Map<String, dynamic> data) async {
    return Response<dynamic>(
      data: data,
      statusCode: 200,
      requestOptions: RequestOptions(path: '/signal/status/minimal'),
    );
  }

  setUp(() async {
    keyManager = MockSignalKeyManager();
    sessionManager = MockSessionManager();
    apiService = MockApiService();

    keyManager.apiServiceOverride = apiService;

    identityKeyPair = generateIdentityKeyPair();
    identityKeyBase64 = base64Encode(
      identityKeyPair.getPublicKey().serialize(),
    );
    signedPreKey = generateSignedPreKey(identityKeyPair, 1);
    signedPreKeyBase64 = base64Encode(
      signedPreKey.getKeyPair().publicKey.serialize(),
    );
    signedPreKeySignatureBase64 = base64Encode(signedPreKey.signature);

    keyManager.identityKeyPairOverride = identityKeyPair;
    keyManager.preKeyFingerprintsOverride = <String, String>{};
    apiService.onDelete = (url, data, options) async {
      return Response<dynamic>(
        statusCode: 200,
        requestOptions: RequestOptions(path: url),
      );
    };

    apiService.onGet = (url, queryParameters, options) async {
      return _response({
        'identityKey': identityKeyBase64,
        'signedPreKey': signedPreKeyBase64,
        'signedPreKeySignature': signedPreKeySignatureBase64,
        'preKeysCount': 100,
        'preKeyFingerprints': <String, dynamic>{},
      });
    };

    healingService = await SignalHealingService.create(
      keyManager: keyManager,
      sessionManager: sessionManager,
      getCurrentUserId: () => userId,
      getCurrentDeviceId: () => deviceId,
      runInitialVerification: false,
    );
  });

  test('reuploads identity when server has no identity', () async {
    apiService.onGet = (url, queryParameters, options) async {
      return _response({
        'signedPreKey': signedPreKeyBase64,
        'signedPreKeySignature': signedPreKeySignatureBase64,
        'preKeysCount': 100,
        'preKeyFingerprints': <String, dynamic>{},
      });
    };

    final result = await healingService.verifyOwnKeysOnServer(userId, deviceId);

    expect(result.isValid, isTrue);
    expect(result.needsHealing, isFalse);
    expect(result.reason, 'identity_reuploaded');
    expect(keyManager.uploadAllKeysCallCount, 1);
  });

  test('reuploads signed prekey when missing on server', () async {
    apiService.onGet = (url, queryParameters, options) async {
      return _response({
        'identityKey': identityKeyBase64,
        'preKeysCount': 100,
        'preKeyFingerprints': <String, dynamic>{},
      });
    };

    final result = await healingService.verifyOwnKeysOnServer(userId, deviceId);

    expect(result.isValid, isTrue);
    expect(result.needsHealing, isFalse);
    expect(result.reason, 'signed_prekey_reuploaded');
    expect(keyManager.uploadAllKeysCallCount, 1);
  });

  test('detects prekey hash mismatch as corruption', () async {
    keyManager.preKeyFingerprintsOverride = <String, String>{'1': 'local-hash'};
    apiService.onGet = (url, queryParameters, options) async {
      return _response({
        'identityKey': identityKeyBase64,
        'signedPreKey': signedPreKeyBase64,
        'signedPreKeySignature': signedPreKeySignatureBase64,
        'preKeysCount': 100,
        'preKeyFingerprints': <String, dynamic>{'1': 'server-hash'},
      });
    };

    final result = await healingService.verifyOwnKeysOnServer(userId, deviceId);

    expect(result.isValid, isFalse);
    expect(result.needsHealing, isTrue);
    expect(result.reason, 'prekey_hash_mismatch');
  });

  test('resyncs when prekey set diverges without corruption', () async {
    keyManager.preKeyFingerprintsOverride = <String, String>{
      '1': 'h1',
      '2': 'h2',
    };
    apiService.onGet = (url, queryParameters, options) async {
      return _response({
        'identityKey': identityKeyBase64,
        'signedPreKey': signedPreKeyBase64,
        'signedPreKeySignature': signedPreKeySignatureBase64,
        'preKeysCount': 100,
        'preKeyFingerprints': <String, dynamic>{'1': 'h1'},
      });
    };

    final result = await healingService.verifyOwnKeysOnServer(userId, deviceId);

    expect(result.isValid, isTrue);
    expect(result.needsHealing, isFalse);
    expect(result.reason, 'ok');
    expect(keyManager.syncedPreKeyIds, isNotEmpty);
    expect(keyManager.syncedPreKeyIds.first, [1]);
  });
}
