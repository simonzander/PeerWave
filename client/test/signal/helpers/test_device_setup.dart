import 'package:flutter_test/flutter_test.dart';
import 'package:peerwave_client/services/device_identity_service.dart';

/// Initialize DeviceIdentityService for testing
///
/// This allows DeviceScopedStorageService to work properly in tests
/// by satisfying the _waitForDeviceIdentity() check.
Future<void> initializeTestDeviceIdentity({
  String email = 'test@example.com',
  String credentialId = 'test-credential-12345678',
  String clientId = 'test-client-12345678',
}) async {
  await DeviceIdentityService.instance.setDeviceIdentity(
    email,
    credentialId,
    clientId,
  );

  // Verify initialization
  expect(DeviceIdentityService.instance.isInitialized, isTrue);
  expect(DeviceIdentityService.instance.deviceId, isNotNull);
}
