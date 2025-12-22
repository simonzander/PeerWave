import '../entities/key_metrics.dart';

/// Repository interface for troubleshooting operations.
///
/// Provides access to Signal Protocol diagnostics and maintenance operations.
abstract class TroubleshootRepository {
  /// Retrieves current key management metrics.
  Future<KeyMetrics> getKeyMetrics();

  /// Deletes identity key locally and regenerates.
  Future<void> deleteIdentityKey();

  /// Deletes signed pre-key locally and on server.
  Future<void> deleteSignedPreKey();

  /// Deletes all pre-keys locally and on server.
  Future<void> deletePreKeys();

  /// Deletes group encryption key for specified channel.
  Future<void> deleteGroupKey(String channelId);

  /// Deletes all sessions with specified user.
  Future<void> deleteUserSession(String userId);

  /// Deletes session with specific device.
  Future<void> deleteDeviceSession(String userId, int deviceId);

  /// Forces signed pre-key rotation.
  Future<void> forceSignedPreKeyRotation();

  /// Forces complete pre-key regeneration.
  Future<void> forcePreKeyRegeneration();

  /// Retrieves list of active group channels for key deletion.
  Future<List<Map<String, String>>> getActiveChannels();
}
