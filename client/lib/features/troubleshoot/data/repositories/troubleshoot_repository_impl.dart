import '../../domain/entities/key_metrics.dart';
import '../../domain/repositories/troubleshoot_repository.dart';
import '../datasources/troubleshoot_datasource.dart';

/// Implementation of troubleshoot repository.
class TroubleshootRepositoryImpl implements TroubleshootRepository {
  final TroubleshootDataSource dataSource;

  const TroubleshootRepositoryImpl({required this.dataSource});

  @override
  Future<KeyMetrics> getKeyMetrics() {
    return dataSource.getKeyMetrics();
  }

  @override
  Future<void> deleteIdentityKey() {
    return dataSource.deleteIdentityKey();
  }

  @override
  Future<void> deleteSignedPreKey() {
    return dataSource.deleteSignedPreKey();
  }

  @override
  Future<void> deletePreKeys() {
    return dataSource.deletePreKeys();
  }

  @override
  Future<void> deleteGroupKey(String channelId) {
    return dataSource.deleteGroupKey(channelId);
  }

  @override
  Future<void> deleteUserSession(String userId) {
    return dataSource.deleteUserSession(userId);
  }

  @override
  Future<void> deleteDeviceSession(String userId, int deviceId) {
    return dataSource.deleteDeviceSession(userId, deviceId);
  }

  @override
  Future<void> forceSignedPreKeyRotation() {
    return dataSource.forceSignedPreKeyRotation();
  }

  @override
  Future<void> forcePreKeyRegeneration() {
    return dataSource.forcePreKeyRegeneration();
  }

  @override
  Future<List<Map<String, String>>> getActiveChannels() {
    return dataSource.getActiveChannels();
  }
}
