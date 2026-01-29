import 'package:flutter_test/flutter_test.dart';
import 'package:peerwave_client/services/device_identity_service.dart';
import 'package:peerwave_client/services/native_crypto_service.dart';

int _testCounter = 0;

/// Initialize DeviceIdentityService for integration testing
///
/// This allows DeviceScopedStorageService to work properly in tests
/// by satisfying the _waitForDeviceIdentity() check.
///
/// Also initializes encryption keys for secure storage.
/// Creates real storage that will be cleaned up after tests complete.
Future<void> initializeTestDeviceIdentity({
  String email = 'test@example.com',
  String credentialId = 'test-credential-12345678',
  String clientId = 'test-client-12345678',
}) async {
  // Generate unique ID per test to avoid data conflicts
  _testCounter++;
  final uniqueId = '${DateTime.now().millisecondsSinceEpoch}-$_testCounter';

  await DeviceIdentityService.instance.setDeviceIdentity(
    '$email-$uniqueId',
    '$credentialId-$uniqueId',
    '$clientId-$uniqueId',
  );

  // Verify initialization
  expect(DeviceIdentityService.instance.isInitialized, isTrue);
  expect(DeviceIdentityService.instance.deviceId, isNotNull);

  // Initialize encryption key for secure storage
  // This creates the key that EncryptedStorageWrapper needs
  final deviceId = DeviceIdentityService.instance.deviceId;
  await NativeCryptoService.instance.getOrCreateKey(deviceId);
}
