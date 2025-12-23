/// Signal Protocol key management metrics collector.
///
/// Tracks cryptographic operations for diagnostics and troubleshooting.
/// Used by SignalService to record key lifecycle events.
class KeyManagementMetrics {
  static int identityRegenerations = 0;
  static int signedPreKeyRotations = 0;
  static int preKeysRegenerated = 0;
  static int decryptionFailures = 0;
  static int serverKeyMismatches = 0;
  static int ownPreKeysConsumed = 0;
  static int remotePreKeysConsumed = 0;
  static int sessionsInvalidated = 0;

  /// Records identity key regeneration event.
  static void recordIdentityRegeneration({String? reason}) {
    identityRegenerations++;
  }

  /// Records SignedPreKey rotation event.
  static void recordSignedPreKeyRotation({bool isScheduled = true}) {
    signedPreKeyRotations++;
  }

  /// Records PreKey regeneration event.
  static void recordPreKeyRegeneration(int count, {String? reason}) {
    preKeysRegenerated += count;
  }

  /// Records decryption failure event.
  static void recordDecryptionFailure(String keyType, {String? reason}) {
    decryptionFailures++;
  }

  /// Records server key mismatch event.
  static void recordServerKeyMismatch(String keyType) {
    serverKeyMismatches++;
  }

  /// Records own PreKey consumption event (when others consume our PreKeys).
  static void recordOwnPreKeyConsumed(int count) {
    ownPreKeysConsumed += count;
  }

  /// Records remote PreKey consumption event (when we consume others' PreKeys).
  static void recordRemotePreKeyConsumed(int count) {
    remotePreKeysConsumed += count;
  }

  /// Records session invalidation event.
  static void recordSessionInvalidation(String address, {String? reason}) {
    sessionsInvalidated++;
  }

  /// Resets all metrics to zero.
  static void reset() {
    identityRegenerations = 0;
    signedPreKeyRotations = 0;
    preKeysRegenerated = 0;
    decryptionFailures = 0;
    serverKeyMismatches = 0;
    ownPreKeysConsumed = 0;
    remotePreKeysConsumed = 0;
    sessionsInvalidated = 0;
  }

  /// Returns current metrics as JSON.
  static Map<String, dynamic> toJson() {
    return {
      'identityRegenerations': identityRegenerations,
      'signedPreKeyRotations': signedPreKeyRotations,
      'preKeysRegenerated': preKeysRegenerated,
      'ownPreKeysConsumed': ownPreKeysConsumed,
      'remotePreKeysConsumed': remotePreKeysConsumed,
      'sessionsInvalidated': sessionsInvalidated,
      'decryptionFailures': decryptionFailures,
      'serverKeyMismatches': serverKeyMismatches,
    };
  }
}
