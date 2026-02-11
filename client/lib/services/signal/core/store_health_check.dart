import 'package:flutter/foundation.dart';

import '../../device_scoped_storage_service.dart';
import '../stores/identity_key_store.dart';

class SignalStoreHealthCheck {
  static Future<void> run({
    required PermanentIdentityKeyStore identityStore,
  }) async {
    debugPrint('[SIGNAL_HEALTH] Starting store health check...');

    await _ensureIdentityKeyPair(identityStore);

    final storage = DeviceScopedStorageService.instance;

    final identityPurged = await _purgeStore(
      storage: storage,
      baseName: 'peerwaveSignalIdentityKeys',
      storeName: 'peerwaveSignalIdentityKeys',
      keyPrefix: 'identity_',
    );

    final preKeyPurged = await _purgeStore(
      storage: storage,
      baseName: 'peerwaveSignalPreKeys',
      storeName: 'peerwaveSignalPreKeys',
      keyPrefix: 'prekey_',
    );

    final signedPreKeyPurged = await _purgeStore(
      storage: storage,
      baseName: 'peerwaveSignalSignedPreKeys',
      storeName: 'peerwaveSignalSignedPreKeys',
      keyPrefix: 'signedprekey_',
      metaSuffix: '_meta',
    );

    final sessionPurged = await _purgeStore(
      storage: storage,
      baseName: 'peerwaveSignalSessions',
      storeName: 'peerwaveSignalSessions',
      keyPrefix: 'session_',
    );

    final sessionMetaPurged = await _purgeStore(
      storage: storage,
      baseName: 'peerwaveSignalSessionsMeta',
      storeName: 'peerwaveSignalSessionsMeta',
      keyPrefix: 'session_meta_',
    );

    final senderKeyPurged = await _purgeStore(
      storage: storage,
      baseName: 'peerwaveSenderKeys',
      storeName: 'peerwaveSenderKeys',
      keyPrefix: 'sender_key_',
      metaSuffix: '_metadata',
    );

    debugPrint(
      '[SIGNAL_HEALTH] Done. Purged: identity=$identityPurged, prekey=$preKeyPurged, signedPreKey=$signedPreKeyPurged, sessions=$sessionPurged, sessionMeta=$sessionMetaPurged, senderKey=$senderKeyPurged',
    );
  }

  static Future<void> _ensureIdentityKeyPair(
    PermanentIdentityKeyStore identityStore,
  ) async {
    try {
      await identityStore.getIdentityKeyPairData();
      debugPrint('[SIGNAL_HEALTH] Identity key pair OK');
    } catch (e) {
      debugPrint('[SIGNAL_HEALTH] Identity key pair check failed: $e');
    }
  }

  static Future<int> _purgeStore({
    required DeviceScopedStorageService storage,
    required String baseName,
    required String storeName,
    required String keyPrefix,
    String? metaSuffix,
  }) async {
    int purged = 0;

    final keys = await storage.getAllKeys(baseName, storeName);
    for (final key in keys) {
      if (!key.startsWith(keyPrefix)) {
        continue;
      }

      try {
        await storage.getDecrypted(baseName, storeName, key);
      } catch (e) {
        debugPrint('[SIGNAL_HEALTH] Purging corrupted entry $key: $e');
        try {
          await storage.deleteEncrypted(baseName, storeName, key);
          purged++;
        } catch (deleteError) {
          debugPrint(
            '[SIGNAL_HEALTH] Warning: Failed to delete corrupted entry $key: $deleteError',
          );
        }

        if (metaSuffix != null) {
          final metaKey = '$key$metaSuffix';
          try {
            await storage.deleteEncrypted(baseName, storeName, metaKey);
          } catch (deleteError) {
            debugPrint(
              '[SIGNAL_HEALTH] Warning: Failed to delete meta entry $metaKey: $deleteError',
            );
          }
        }
      }
    }

    return purged;
  }
}
