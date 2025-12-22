import '../models/key_metrics_model.dart';

/// Data source for troubleshooting operations.
///
/// Abstracts Signal Protocol service interactions.
abstract class TroubleshootDataSource {
  Future<KeyMetricsModel> getKeyMetrics();
  Future<void> deleteIdentityKey();
  Future<void> deleteSignedPreKey();
  Future<void> deletePreKeys();
  Future<void> deleteGroupKey(String channelId);
  Future<void> deleteUserSession(String userId);
  Future<void> deleteDeviceSession(String userId, int deviceId);
  Future<void> forceSignedPreKeyRotation();
  Future<void> forcePreKeyRegeneration();
  Future<List<Map<String, String>>> getActiveChannels();
}
