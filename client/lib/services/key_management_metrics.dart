import 'package:flutter/foundation.dart' show debugPrint;

/// Metrics tracking for Signal Protocol key management
/// Helps diagnose key regeneration patterns and decryption issues
class KeyManagementMetrics {
  // Static counters
  static int identityRegenerations = 0;
  static int signedPreKeyRotations = 0;
  static int preKeysRegenerated = 0;
  static int decryptionFailures = 0;
  static int serverKeyMismatches = 0;
  static int preKeysConsumed = 0;

  /// Record identity key regeneration
  static void recordIdentityRegeneration({String? reason}) {
    identityRegenerations++;
    debugPrint(
      '[KEY METRICS] Identity regeneration #$identityRegenerations${reason != null ? ' - $reason' : ''}',
    );
  }

  /// Record SignedPreKey rotation
  static void recordSignedPreKeyRotation({bool isScheduled = true}) {
    signedPreKeyRotations++;
    debugPrint(
      '[KEY METRICS] SignedPreKey rotation #$signedPreKeyRotations (scheduled: $isScheduled)',
    );
  }

  /// Record PreKey regeneration
  static void recordPreKeyRegeneration(int count, {String? reason}) {
    preKeysRegenerated += count;
    debugPrint(
      '[KEY METRICS] PreKey regeneration: +$count (total: $preKeysRegenerated)${reason != null ? ' - $reason' : ''}',
    );
  }

  /// Record decryption failure
  static void recordDecryptionFailure(String keyType, {String? reason}) {
    decryptionFailures++;
    debugPrint(
      '[KEY METRICS] Decryption failure #$decryptionFailures - $keyType${reason != null ? ' - $reason' : ''}',
    );
  }

  /// Record server key mismatch
  static void recordServerKeyMismatch(String keyType) {
    serverKeyMismatches++;
    debugPrint(
      '[KEY METRICS] Server key mismatch #$serverKeyMismatches - $keyType',
    );
  }

  /// Record PreKey consumption
  static void recordPreKeyConsumed(int count) {
    preKeysConsumed += count;
    debugPrint(
      '[KEY METRICS] PreKeys consumed: +$count (total: $preKeysConsumed)',
    );
  }

  /// Print full metrics report
  static void report() {
    debugPrint('');
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('📊 Key Management Metrics Report');
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('Identity regenerations:    $identityRegenerations');
    debugPrint('SignedPreKey rotations:    $signedPreKeyRotations');
    debugPrint('PreKeys regenerated:       $preKeysRegenerated');
    debugPrint('PreKeys consumed:          $preKeysConsumed');
    debugPrint('Decryption failures:       $decryptionFailures');
    debugPrint('Server key mismatches:     $serverKeyMismatches');
    debugPrint('═══════════════════════════════════════════════');
    debugPrint('');
  }

  /// Reset all metrics (for testing/debugging)
  static void reset() {
    identityRegenerations = 0;
    signedPreKeyRotations = 0;
    preKeysRegenerated = 0;
    decryptionFailures = 0;
    serverKeyMismatches = 0;
    preKeysConsumed = 0;
    debugPrint('[KEY METRICS] All metrics reset');
  }

  /// Get metrics as JSON
  static Map<String, dynamic> toJson() {
    return {
      'identityRegenerations': identityRegenerations,
      'signedPreKeyRotations': signedPreKeyRotations,
      'preKeysRegenerated': preKeysRegenerated,
      'preKeysConsumed': preKeysConsumed,
      'decryptionFailures': decryptionFailures,
      'serverKeyMismatches': serverKeyMismatches,
    };
  }
}
