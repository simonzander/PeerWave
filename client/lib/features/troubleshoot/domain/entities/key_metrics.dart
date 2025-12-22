/// Immutable entity representing Signal Protocol key management metrics.
class KeyMetrics {
  final int identityRegenerations;
  final int signedPreKeyRotations;
  final int preKeysRegenerated;
  final int preKeysConsumed;
  final int sessionsInvalidated;
  final int decryptionFailures;
  final int serverKeyMismatches;

  const KeyMetrics({
    required this.identityRegenerations,
    required this.signedPreKeyRotations,
    required this.preKeysRegenerated,
    required this.preKeysConsumed,
    required this.sessionsInvalidated,
    required this.decryptionFailures,
    required this.serverKeyMismatches,
  });

  bool get hasIssues =>
      decryptionFailures > 0 ||
      serverKeyMismatches > 0 ||
      identityRegenerations > 1;

  KeyMetrics copyWith({
    int? identityRegenerations,
    int? signedPreKeyRotations,
    int? preKeysRegenerated,
    int? preKeysConsumed,
    int? sessionsInvalidated,
    int? decryptionFailures,
    int? serverKeyMismatches,
  }) {
    return KeyMetrics(
      identityRegenerations:
          identityRegenerations ?? this.identityRegenerations,
      signedPreKeyRotations:
          signedPreKeyRotations ?? this.signedPreKeyRotations,
      preKeysRegenerated: preKeysRegenerated ?? this.preKeysRegenerated,
      preKeysConsumed: preKeysConsumed ?? this.preKeysConsumed,
      sessionsInvalidated: sessionsInvalidated ?? this.sessionsInvalidated,
      decryptionFailures: decryptionFailures ?? this.decryptionFailures,
      serverKeyMismatches: serverKeyMismatches ?? this.serverKeyMismatches,
    );
  }
}
