import 'package:flutter/foundation.dart';
import '../models/key_metrics_model.dart';
import 'troubleshoot_datasource.dart';
import '../../../../services/signal_service.dart';
import '../../../../services/storage/sqlite_group_message_store.dart';

/// Implementation of troubleshoot data source using Signal Protocol services.
class TroubleshootDataSourceImpl implements TroubleshootDataSource {
  final SignalService signalService;

  const TroubleshootDataSourceImpl({required this.signalService});

  @override
  Future<KeyMetricsModel> getKeyMetrics() async {
    return KeyMetricsModel.fromService();
  }

  @override
  Future<void> deleteIdentityKey() async {
    debugPrint('[Troubleshoot] Identity key deletion - to be implemented');
    throw UnimplementedError(
      'Identity key deletion requires SignalService extension',
    );
  }

  @override
  Future<void> deleteSignedPreKey() async {
    debugPrint('[Troubleshoot] Signed pre-key deletion - to be implemented');
    throw UnimplementedError(
      'Signed pre-key deletion requires SignalService extension',
    );
  }

  @override
  Future<void> deletePreKeys() async {
    debugPrint('[Troubleshoot] Pre-keys deletion - to be implemented');
    throw UnimplementedError(
      'Pre-keys deletion requires SignalService extension',
    );
  }

  @override
  Future<void> deleteGroupKey(String channelId) async {
    debugPrint(
      '[Troubleshoot] Group key deletion for $channelId - to be implemented',
    );
    throw UnimplementedError(
      'Group key deletion requires SignalService extension',
    );
  }

  @override
  Future<void> deleteUserSession(String userId) async {
    debugPrint(
      '[Troubleshoot] User session deletion for $userId - to be implemented',
    );
    throw UnimplementedError(
      'User session deletion requires SignalService extension',
    );
  }

  @override
  Future<void> deleteDeviceSession(String userId, int deviceId) async {
    debugPrint(
      '[Troubleshoot] Device session deletion for $userId:$deviceId - to be implemented',
    );
    throw UnimplementedError(
      'Device session deletion requires SignalService extension',
    );
  }

  @override
  Future<void> forceSignedPreKeyRotation() async {
    debugPrint('[Troubleshoot] Signed pre-key rotation - to be implemented');
    throw UnimplementedError(
      'Signed pre-key rotation requires SignalService extension',
    );
  }

  @override
  Future<void> forcePreKeyRegeneration() async {
    debugPrint('[Troubleshoot] Pre-key regeneration - to be implemented');
    throw UnimplementedError(
      'Pre-key regeneration requires SignalService extension',
    );
  }

  @override
  Future<List<Map<String, String>>> getActiveChannels() async {
    try {
      final groupMessageStore = await SqliteGroupMessageStore.getInstance();
      final channelIds = await groupMessageStore.getAllChannels();

      return channelIds.map((id) {
        return {
          'id': id,
          'name': id, // Use ID as name for now
        };
      }).toList();
    } catch (e) {
      debugPrint('[Troubleshoot] Error fetching channels: $e');
      return [];
    }
  }
}
