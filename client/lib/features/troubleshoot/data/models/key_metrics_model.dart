import '../../domain/entities/key_metrics.dart';
import '../../../../core/metrics/key_management_metrics.dart';

/// Data transfer object for key management metrics.
class KeyMetricsModel extends KeyMetrics {
  const KeyMetricsModel({
    required super.identityRegenerations,
    required super.signedPreKeyRotations,
    required super.preKeysRegenerated,
    required super.preKeysConsumed,
    required super.sessionsInvalidated,
    required super.decryptionFailures,
    required super.serverKeyMismatches,
  });

  factory KeyMetricsModel.fromService() {
    return KeyMetricsModel(
      identityRegenerations: KeyManagementMetrics.identityRegenerations,
      signedPreKeyRotations: KeyManagementMetrics.signedPreKeyRotations,
      preKeysRegenerated: KeyManagementMetrics.preKeysRegenerated,
      preKeysConsumed: KeyManagementMetrics.preKeysConsumed,
      sessionsInvalidated: KeyManagementMetrics.sessionsInvalidated,
      decryptionFailures: KeyManagementMetrics.decryptionFailures,
      serverKeyMismatches: KeyManagementMetrics.serverKeyMismatches,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'identityRegenerations': identityRegenerations,
      'signedPreKeyRotations': signedPreKeyRotations,
      'preKeysRegenerated': preKeysRegenerated,
      'preKeysConsumed': preKeysConsumed,
      'sessionsInvalidated': sessionsInvalidated,
      'decryptionFailures': decryptionFailures,
      'serverKeyMismatches': serverKeyMismatches,
    };
  }
}
