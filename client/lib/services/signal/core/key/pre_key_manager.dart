import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../../api_service.dart';
import '../../../socket_service.dart'
    if (dart.library.io) '../../../socket_service_native.dart';
import '../../../permanent_pre_key_store.dart';
import '../../../../core/metrics/key_management_metrics.dart';

/// Manages Signal Protocol PreKeys
///
/// Responsibilities:
/// - PreKey generation in batches
/// - PreKey fingerprint generation (for validation)
/// - PreKey upload to server
/// - PreKey synchronization with server
/// - PreKey count monitoring
class PreKeyManager {
  final PermanentPreKeyStore preKeyStore;

  PreKeyManager(this.preKeyStore);

  /// Generate and store PreKeys in a range
  /// Returns list of generated PreKey records
  Future<List<PreKeyRecord>> generatePreKeysInRange(int start, int end) async {
    debugPrint(
      '[PRE_KEY_MANAGER] Generating PreKeys from $start to $end (${end - start + 1} keys)',
    );

    final preKeys = generatePreKeys(start, end);

    for (final preKey in preKeys) {
      await preKeyStore.storePreKey(preKey.id, preKey);
    }

    debugPrint('[PRE_KEY_MANAGER] ✓ Generated ${preKeys.length} PreKeys');
    return preKeys;
  }

  /// Get local PreKey count
  Future<int> getLocalPreKeyCount() async {
    try {
      final ids = await preKeyStore.getAllPreKeyIds();
      return ids.length;
    } catch (e) {
      debugPrint('[PRE_KEY_MANAGER] Error getting local PreKey count: $e');
      return 0;
    }
  }

  /// Generate PreKey fingerprints (hashes) for validation
  /// Returns map of keyId -> hash for all keys
  Future<Map<String, String>> getPreKeyFingerprints() async {
    try {
      final keyIds = await preKeyStore.getAllPreKeyIds();
      final fingerprints = <String, String>{};

      for (final id in keyIds) {
        try {
          final preKey = await preKeyStore.loadPreKey(id);
          final publicKeyBytes = preKey.getKeyPair().publicKey.serialize();
          final hash = base64Encode(publicKeyBytes);
          fingerprints[id.toString()] = hash;
        } catch (e) {
          debugPrint(
            '[PRE_KEY_MANAGER] Failed to get fingerprint for PreKey $id: $e',
          );
        }
      }

      debugPrint(
        '[PRE_KEY_MANAGER] Generated ${fingerprints.length} PreKey fingerprints',
      );
      return fingerprints;
    } catch (e) {
      debugPrint('[PRE_KEY_MANAGER] Error generating PreKey fingerprints: $e');
      return {};
    }
  }

  /// Upload PreKeys to server in batch
  Future<void> uploadPreKeys(List<PreKeyRecord> preKeys) async {
    debugPrint(
      '[PRE_KEY_MANAGER] Uploading ${preKeys.length} PreKeys to server...',
    );

    final preKeysPayload = preKeys
        .map(
          (pk) => {
            'id': pk.id,
            'data': base64Encode(pk.getKeyPair().publicKey.serialize()),
          },
        )
        .toList();

    final response = await ApiService.post(
      '/signal/prekeys/batch',
      data: {'preKeys': preKeysPayload},
    );

    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception('Failed to upload PreKeys: ${response.statusCode}');
    }

    debugPrint('[PRE_KEY_MANAGER] ✓ ${preKeys.length} PreKeys uploaded');
  }

  /// Synchronize local PreKey IDs with server state
  ///
  /// The server sends us a list of PreKey IDs it has stored. We compare with
  /// our local store and upload any PreKeys that the server is missing.
  ///
  /// Called by: SessionListeners when 'preKeyIdsSyncResponse' socket event fires
  Future<void> syncPreKeyIds(List<int> serverKeyIds) async {
    try {
      debugPrint(
        '[PRE_KEY_MANAGER] Syncing PreKey IDs (server has ${serverKeyIds.length})',
      );

      // Get local PreKey IDs
      final localKeyIds = <int>[];
      for (int id = 1; id <= 110; id++) {
        try {
          await preKeyStore.loadPreKey(id);
          localKeyIds.add(id);
        } catch (e) {
          // Key doesn't exist locally
        }
      }

      debugPrint('[PRE_KEY_MANAGER] Local PreKeys: ${localKeyIds.length}');

      // Find PreKeys that exist locally but not on server
      final missingOnServer = localKeyIds
          .where((id) => !serverKeyIds.contains(id))
          .toList();

      if (missingOnServer.isEmpty) {
        debugPrint('[PRE_KEY_MANAGER] ✓ Server has all local PreKeys');
        return;
      }

      debugPrint(
        '[PRE_KEY_MANAGER] Server missing ${missingOnServer.length} PreKeys: $missingOnServer',
      );

      // Upload missing PreKeys
      final preKeysToUpload = <PreKeyRecord>[];
      for (final id in missingOnServer) {
        try {
          final preKey = await preKeyStore.loadPreKey(id);
          preKeysToUpload.add(preKey);
        } catch (e) {
          debugPrint('[PRE_KEY_MANAGER] Failed to load PreKey $id: $e');
        }
      }

      if (preKeysToUpload.isNotEmpty) {
        await uploadPreKeys(preKeysToUpload);
        debugPrint(
          '[PRE_KEY_MANAGER] ✓ Uploaded ${preKeysToUpload.length} missing PreKeys',
        );
      }
    } catch (e, stack) {
      debugPrint('[PRE_KEY_MANAGER] Error syncing PreKey IDs: $e');
      debugPrint('[PRE_KEY_MANAGER] Stack: $stack');
      // Don't rethrow - this is a sync operation
    }
  }

  /// Regenerate PreKeys when already initialized but PreKeys are missing
  Future<void> regeneratePreKeysWithProgress(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
    List<int> existingPreKeyIds,
  ) async {
    const int totalSteps = 110;
    int currentStep = existingPreKeyIds.length;

    void updateProgress(String status, int step) {
      final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
      onProgress(status, step, totalSteps, percentage);
    }

    debugPrint('[PRE_KEY_MANAGER] Starting PreKey regeneration...');
    debugPrint(
      '[PRE_KEY_MANAGER] Existing PreKeys: ${existingPreKeyIds.length}/110',
    );

    // Check for invalid IDs (>= 110)
    final hasInvalidIds = existingPreKeyIds.any((id) => id >= 110);
    if (hasInvalidIds) {
      final invalidIds = existingPreKeyIds.where((id) => id >= 110).toList();
      debugPrint(
        '[PRE_KEY_MANAGER] ⚠️ Found invalid PreKey IDs (>= 110): $invalidIds',
      );
      debugPrint(
        '[PRE_KEY_MANAGER] 🔧 Deleting ALL PreKeys and regenerating fresh set...',
      );

      for (final id in existingPreKeyIds) {
        await preKeyStore.removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = [];
      debugPrint(
        '[PRE_KEY_MANAGER] ✓ Cleanup complete, will generate fresh 110 PreKeys',
      );
    }

    final neededPreKeys = 110 - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[PRE_KEY_MANAGER] Need to generate $neededPreKeys pre keys');

      try {
        await preKeyStore.checkPreKeys();
        final updatedIds = await preKeyStore.getAllPreKeyIds();
        final keysGenerated = updatedIds.length - existingPreKeyIds.length;

        debugPrint('[PRE_KEY_MANAGER] ✓ Generated $keysGenerated PreKeys');
        updateProgress(
          'Pre keys ready (${updatedIds.length}/110)',
          currentStep + keysGenerated,
        );
      } catch (e) {
        debugPrint('[PRE_KEY_MANAGER] ⚠️ PreKey generation failed: $e');
      }
    }

    updateProgress('Signal Protocol ready', totalSteps);
    debugPrint('[PRE_KEY_MANAGER] ✓ PreKey regeneration successful');
  }

  /// Generate PreKeys for initialization with progress tracking
  Future<void> generatePreKeysForInit(
    Function(String statusText, int current, int total, double percentage)
    onProgress,
    int currentStep,
    List<int> existingPreKeyIds,
  ) async {
    const int totalSteps = 112; // 1 KeyPair + 1 SignedPreKey + 110 PreKeys
    const int targetPrekeys = 110;

    // Cleanup excess PreKeys if > 110
    if (existingPreKeyIds.length > targetPrekeys) {
      debugPrint(
        '[PRE_KEY_MANAGER] Found ${existingPreKeyIds.length} PreKeys (expected $targetPrekeys)',
      );
      debugPrint('[PRE_KEY_MANAGER] Deleting excess PreKeys...');

      final sortedIds = List<int>.from(existingPreKeyIds)..sort();
      final toDelete = sortedIds.skip(targetPrekeys).toList();
      for (final id in toDelete) {
        await preKeyStore.removePreKey(id, sendToServer: true);
      }

      existingPreKeyIds = sortedIds.take(targetPrekeys).toList();
      debugPrint(
        '[PRE_KEY_MANAGER] Cleanup complete, now have ${existingPreKeyIds.length} PreKeys',
      );
    }

    final neededPreKeys = targetPrekeys - existingPreKeyIds.length;

    if (neededPreKeys > 0) {
      debugPrint('[PRE_KEY_MANAGER] Need to generate $neededPreKeys pre keys');

      try {
        await preKeyStore.checkPreKeys();
        final updatedIds = await preKeyStore.getAllPreKeyIds();
        final keysGenerated = updatedIds.length - existingPreKeyIds.length;

        debugPrint('[PRE_KEY_MANAGER] ✓ Generated $keysGenerated PreKeys');

        void updateProgress(String status, int step) {
          final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
          onProgress(status, step, totalSteps, percentage);
        }

        updateProgress(
          'Pre keys ready (${updatedIds.length}/110)',
          currentStep + keysGenerated,
        );

        if (keysGenerated > 0) {
          KeyManagementMetrics.recordPreKeyRegeneration(
            keysGenerated,
            reason: 'Initialization',
          );
        }
      } catch (e) {
        debugPrint('[PRE_KEY_MANAGER] ⚠️ PreKey generation failed: $e');
      }
    } else {
      debugPrint(
        '[PRE_KEY_MANAGER] Pre keys already sufficient (${existingPreKeyIds.length}/$targetPrekeys)',
      );

      void updateProgress(String status, int step) {
        final percentage = (step / totalSteps * 100).clamp(0.0, 100.0);
        onProgress(status, step, totalSteps, percentage);
      }

      updateProgress('Pre keys already ready', totalSteps);
    }
  }
}
