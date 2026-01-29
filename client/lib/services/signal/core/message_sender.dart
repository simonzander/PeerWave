import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../api_service.dart';
import '../../socket_service.dart';
import '../../device_identity_service.dart';
import '../../storage/database_helper.dart';
import '../../storage/sqlite_message_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_session_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../permanent_identity_key_store.dart';
import '../../../core/metrics/key_management_metrics.dart';
import 'healing_service.dart';
import 'encryption_service.dart';

/// MessageSender Service
///
/// Handles all outbound message operations including:
/// - Message encryption and sending to multiple devices
/// - PreKeyBundle fetching and validation
/// - Session establishment and validation
/// - Multi-device message distribution
/// - Local message storage and callbacks
///
/// Dependencies:
/// - EncryptionService: For encryption operations and store access
/// - HealingService: For automatic error recovery
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final messageSender = await MessageSender.create(
///   encryptionService: encryptionService,
///   healingService: healingService,
///   currentUserId: userId,
///   currentDeviceId: deviceId,
///   waitForRegeneration: () async {},
///   itemTypeCallbacks: {},
///   receiveItemCallbacks: {},
/// );
/// ```
class MessageSender {
  final EncryptionService encryptionService;
  final SignalHealingService healingService;
  final String currentUserId;
  final int currentDeviceId;
  final Function() waitForRegeneration;
  final Map<String, List<Function(Map<String, dynamic>)>> itemTypeCallbacks;
  final Map<String, List<Function(Map<String, dynamic>)>> receiveItemCallbacks;

  bool _initialized = false;

  // Delegate to EncryptionService for stores
  PermanentSessionStore get sessionStore => encryptionService.sessionStore;
  PermanentPreKeyStore get preKeyStore => encryptionService.preKeyStore;
  PermanentSignedPreKeyStore get signedPreKeyStore =>
      encryptionService.signedPreKeyStore;
  PermanentIdentityKeyStore get identityStore =>
      encryptionService.identityStore;

  bool get isInitialized => _initialized;

  // Private constructor
  MessageSender._({
    required this.encryptionService,
    required this.healingService,
    required this.currentUserId,
    required this.currentDeviceId,
    required this.waitForRegeneration,
    required this.itemTypeCallbacks,
    required this.receiveItemCallbacks,
  });

  /// Self-initializing factory
  static Future<MessageSender> create({
    required EncryptionService encryptionService,
    required SignalHealingService healingService,
    required String currentUserId,
    required int currentDeviceId,
    required Function() waitForRegeneration,
    required Map<String, List<Function(Map<String, dynamic>)>>
    itemTypeCallbacks,
    required Map<String, List<Function(Map<String, dynamic>)>>
    receiveItemCallbacks,
  }) async {
    final sender = MessageSender._(
      encryptionService: encryptionService,
      healingService: healingService,
      currentUserId: currentUserId,
      currentDeviceId: currentDeviceId,
      waitForRegeneration: waitForRegeneration,
      itemTypeCallbacks: itemTypeCallbacks,
      receiveItemCallbacks: receiveItemCallbacks,
    );
    await sender.init();
    return sender;
  }

  /// Initialize (no stores to create - all from EncryptionService)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[MESSAGE_SENDER] Already initialized');
      return;
    }

    debugPrint('[MESSAGE_SENDER] Initialized (using EncryptionService stores)');
    _initialized = true;
  }

  // ============================================================================
  // MESSAGE SENDING
  // ============================================================================

  /// Send an encrypted message to a recipient
  ///
  /// Encrypts and sends a message to all devices of the recipient user.
  /// Handles multi-device scenarios, session establishment, and error recovery.
  ///
  /// Parameters:
  /// - [recipientUserId]: Target user ID
  /// - [type]: Message type (message, file, image, etc.)
  /// - [payload]: Message content (String or JSON-serializable object)
  /// - [itemId]: Optional pre-generated message ID
  /// - [metadata]: Optional metadata for file messages
  /// - [forcePreKeyMessage]: Force PreKey message for session recovery
  Future<void> sendItem({
    required String recipientUserId,
    required String type,
    required dynamic payload,
    String? itemId,
    Map<String, dynamic>? metadata,
    bool forcePreKeyMessage = false,
  }) async {
    // Get current deviceId and database info
    final currentDeviceId = DeviceIdentityService.instance.deviceId;
    final dbName = DatabaseHelper.getDatabaseName();

    debugPrint('[SIGNAL SERVICE] ═══════════════════════════════════════════');
    debugPrint('[SIGNAL SERVICE] 📤 SENDING MESSAGE');
    debugPrint('[SIGNAL SERVICE] 🔑 Current DeviceId: $currentDeviceId');
    debugPrint('[SIGNAL SERVICE] 💾 Database: $dbName');
    debugPrint('[SIGNAL SERVICE] 👤 Recipient: $recipientUserId');
    debugPrint('[SIGNAL SERVICE] 📝 Type: $type');
    debugPrint('[SIGNAL SERVICE] ═══════════════════════════════════════════');

    // 🔒 SYNC-LOCK: Wait if identity regeneration is in progress
    await waitForRegeneration();

    dynamic ciphertextMessage;

    // Use provided itemId or generate new one
    final messageItemId = itemId ?? Uuid().v4();

    // Prepare payload string for both encryption and local storage
    String payloadString;
    if (payload is String) {
      payloadString = payload;
    } else {
      payloadString = jsonEncode(payload);
    }

    debugPrint(
      '[MESSAGE_SENDER] Step 0: Trigger local callback for sent message',
    );

    // ✅ Define types that should NOT be stored
    const skipStorageTypes = {
      'fileKeyResponse',
      'senderKeyDistribution',
      'read_receipt',
      'meeting_e2ee_key_request',
      'meeting_e2ee_key_response',
      'video_e2ee_key_request',
      'video_e2ee_key_response',
    };

    // Store sent message in local storage for persistence after refresh
    final timestamp = DateTime.now().toIso8601String();
    const storableTypes = {
      'message',
      'file',
      'image',
      'voice',
      'notification',
      'emote',
      'mention',
      'missingcall',
      'addtochannel',
      'removefromchannel',
      'permissionchange',
      'system:identityKeyChanged',
    };
    final shouldStore =
        !skipStorageTypes.contains(type) && storableTypes.contains(type);

    if (shouldStore) {
      try {
        final messageStore = await SqliteMessageStore.getInstance();
        await messageStore.storeSentMessage(
          itemId: messageItemId,
          recipientId: recipientUserId,
          message: payloadString,
          timestamp: timestamp,
          type: type,
          status: 'sent',
          metadata: metadata,
        );

        debugPrint(
          '[MESSAGE_SENDER] ✓ Stored sent $type in SQLite with status=sent',
        );
      } catch (e) {
        debugPrint('[MESSAGE_SENDER] ✗ Failed to store in SQLite: $e');
      }
    } else {
      debugPrint(
        '[MESSAGE_SENDER] Step 0a: Skipping storage for message type: $type',
      );
    }

    // Trigger local callback for UI updates
    final callbackType = (type == 'file') ? 'message' : type;
    if (type != 'read_receipt' && itemTypeCallbacks.containsKey(callbackType)) {
      final localItem = {
        'itemId': messageItemId,
        'sender': currentUserId,
        'recipient': recipientUserId,
        'senderDeviceId': this.currentDeviceId,
        'type': type,
        'message': payloadString,
        'payload': payloadString,
        'timestamp': timestamp,
        'isLocalSent': true,
      };
      for (final callback in itemTypeCallbacks[callbackType]!) {
        callback(localItem);
      }
      debugPrint(
        '[MESSAGE_SENDER] Step 0b: Triggered ${itemTypeCallbacks[callbackType]!.length} local callbacks',
      );
    }

    // ✅ Check our own prekey count before sending
    final ourPreKeyCount = (await preKeyStore.getAllPreKeyIds()).length;
    if (ourPreKeyCount < 10) {
      debugPrint(
        '[MESSAGE_SENDER] ⚠️ WARNING: Only $ourPreKeyCount prekeys available!',
      );
      preKeyStore.checkPreKeys().catchError((e) {
        debugPrint(
          '[MESSAGE_SENDER] Background prekey regeneration failed: $e',
        );
      });
    }

    debugPrint(
      '[MESSAGE_SENDER] Step 0c: Pre-flight check - does recipient have keys?',
    );
    final recipientHasKeys = await _recipientHasKeys(recipientUserId);
    if (!recipientHasKeys) {
      debugPrint(
        '[MESSAGE_SENDER] ❌ Recipient $recipientUserId has no keys on server',
      );
      throw Exception(
        'Recipient has not set up encryption keys. '
        'They need to log out and back in to generate Signal keys.',
      );
    }
    debugPrint(
      '[MESSAGE_SENDER] ✓ Recipient has keys, proceeding with encryption',
    );

    debugPrint(
      '[MESSAGE_SENDER] Step 1: fetchPreKeyBundleForUser($recipientUserId)',
    );
    final preKeyBundles = await fetchPreKeyBundleForUser(recipientUserId);

    if (preKeyBundles.isEmpty) {
      debugPrint(
        '[MESSAGE_SENDER] ❌ No PreKey bundles available for $recipientUserId',
      );
      throw Exception(
        'Cannot send message: recipient has no devices with encryption keys',
      );
    }

    debugPrint(
      '[MESSAGE_SENDER] Step 1 result: ${preKeyBundles.length} devices found',
    );

    if (preKeyBundles.length > 20) {
      debugPrint(
        '[MESSAGE_SENDER] ⚠️ WARNING: ${preKeyBundles.length} devices detected!',
      );
      debugPrint('[MESSAGE_SENDER] Consider cleaning up old/stale devices.');
    }

    for (final bundle in preKeyBundles) {
      debugPrint(
        '[MESSAGE_SENDER] Device: userId=${bundle['userId']}, deviceId=${bundle['deviceId']}',
      );
    }

    // 🔒 CRITICAL: Capture original recipient BEFORE loop
    final originalRecipientUserId = recipientUserId;

    int successCount = 0;
    int failureCount = 0;
    int skippedCount = 0;

    for (final bundle in preKeyBundles) {
      try {
        debugPrint(
          '[MESSAGE_SENDER] ===============================================',
        );
        debugPrint(
          '[MESSAGE_SENDER] Encrypting for device: ${bundle['userId']}:${bundle['deviceId']}',
        );
        debugPrint(
          '[MESSAGE_SENDER] ===============================================',
        );

        // Skip encryption for our own current device
        final isCurrentDevice =
            (bundle['userId'] == currentUserId &&
            bundle['deviceId'] == this.currentDeviceId);
        if (isCurrentDevice) {
          debugPrint(
            '[MESSAGE_SENDER] Skipping current device (cannot encrypt to self)',
          );
          continue;
        }

        // PRE-VALIDATION: Check bundle integrity
        if (!_validatePreKeyBundle(bundle)) {
          debugPrint(
            '[MESSAGE_SENDER] ⚠️ Skipping device ${bundle['userId']}:${bundle['deviceId']} - invalid PreKeyBundle',
          );
          skippedCount++;

          healingService.triggerAsyncSelfVerification(
            reason: 'Invalid bundle detected from recipient',
            userId: currentUserId,
            deviceId: this.currentDeviceId,
          );

          continue;
        }

        debugPrint('[MESSAGE_SENDER] Step 2: Prepare recipientAddress');
        final recipientAddress = SignalProtocolAddress(
          bundle['userId'],
          bundle['deviceId'],
        );

        // SESSION VALIDATION
        debugPrint('[MESSAGE_SENDER] Step 2a: Validate session');
        final isSessionValid = await _validateSessionWithBundle(
          recipientAddress,
          bundle,
        );

        if (!isSessionValid) {
          debugPrint('[MESSAGE_SENDER] Session invalid - keys changed');

          if (await sessionStore.containsSession(recipientAddress)) {
            await sessionStore.deleteSession(recipientAddress);
            debugPrint('[MESSAGE_SENDER] ✓ Stale session deleted');

            KeyManagementMetrics.recordSessionInvalidation(
              recipientAddress.getName(),
              reason: 'Keys changed (detected before send)',
            );
          } else {
            debugPrint(
              '[MESSAGE_SENDER] No session exists - will create new session',
            );
          }
        }

        // 🔄 SESSION RECOVERY: Force PreKey message
        if (forcePreKeyMessage) {
          debugPrint(
            '[MESSAGE_SENDER] 🔄 forcePreKeyMessage=true - deleting session',
          );
          await sessionStore.deleteSession(recipientAddress);
          debugPrint(
            '[MESSAGE_SENDER] ✓ Session deleted, will send PreKey message',
          );
        }

        debugPrint('[MESSAGE_SENDER] Step 3: Check session');
        var hasSession = await sessionStore.containsSession(recipientAddress);
        debugPrint('[MESSAGE_SENDER] Step 3 result: hasSession=$hasSession');

        debugPrint('[MESSAGE_SENDER] Step 4: Create SessionCipher');
        final sessionCipher = SessionCipher(
          sessionStore,
          preKeyStore,
          signedPreKeyStore,
          identityStore,
          recipientAddress,
        );

        if (!hasSession) {
          debugPrint('[MESSAGE_SENDER] Step 5: Build session');
          final preKeyBundle = PreKeyBundle(
            bundle['registrationId'],
            bundle['deviceId'],
            bundle['preKeyId'],
            bundle['preKeyPublic'],
            bundle['signedPreKeyId'],
            bundle['signedPreKeyPublic'],
            bundle['signedPreKeySignature'],
            bundle['identityKey'],
          );
          final sessionBuilder = SessionBuilder(
            sessionStore,
            preKeyStore,
            signedPreKeyStore,
            identityStore,
            recipientAddress,
          );

          try {
            await sessionBuilder.processPreKeyBundle(preKeyBundle);
            debugPrint('[MESSAGE_SENDER] Step 5 done');
          } on UntrustedIdentityException catch (e) {
            debugPrint(
              '[MESSAGE_SENDER] UntrustedIdentityException during session building',
            );
            // Auto-trust the new identity
            await _handleUntrustedIdentity(e, recipientAddress);

            final newSessionBuilder = SessionBuilder(
              sessionStore,
              preKeyStore,
              signedPreKeyStore,
              identityStore,
              recipientAddress,
            );
            await newSessionBuilder.processPreKeyBundle(preKeyBundle);
            debugPrint(
              '[MESSAGE_SENDER] Session rebuilt with trusted identity',
            );
          } catch (e) {
            if (e.toString().contains('InvalidKey') ||
                e.toString().contains('signature') ||
                e.toString().contains('invalid') ||
                e.toString().contains('verification failed')) {
              debugPrint('[MESSAGE_SENDER] ⚠️ Invalid PreKeyBundle: $e');
              debugPrint(
                '[MESSAGE_SENDER] Bundle may be corrupted or out of sync',
              );

              healingService.triggerAsyncSelfVerification(
                reason: 'Bundle processing error: $e',
                userId: currentUserId,
                deviceId: this.currentDeviceId,
              );

              skippedCount++;
              continue;
            }
            rethrow;
          }
        }

        debugPrint('[MESSAGE_SENDER] Step 6: Using pre-prepared payload');
        debugPrint('[MESSAGE_SENDER] Step 7: Encrypt payload');

        try {
          ciphertextMessage = await sessionCipher.encrypt(
            Uint8List.fromList(utf8.encode(payloadString)),
          );
        } on UntrustedIdentityException catch (e) {
          debugPrint(
            '[MESSAGE_SENDER] UntrustedIdentityException during encryption',
          );
          await _handleUntrustedIdentity(e, recipientAddress);

          final newSessionCipher = SessionCipher(
            sessionStore,
            preKeyStore,
            signedPreKeyStore,
            identityStore,
            recipientAddress,
          );
          ciphertextMessage = await newSessionCipher.encrypt(
            Uint8List.fromList(utf8.encode(payloadString)),
          );
        }

        debugPrint('[MESSAGE_SENDER] Step 8: Serialize ciphertext');
        final serialized = base64Encode(ciphertextMessage.serialize());
        debugPrint(
          '[MESSAGE_SENDER] Step 8 result: cipherType=${ciphertextMessage.getType()}',
        );

        debugPrint('[MESSAGE_SENDER] Step 9: Build data packet');
        final data = {
          'recipient': originalRecipientUserId,
          'recipientDeviceId': recipientAddress.getDeviceId(),
          'type': type,
          'payload': serialized,
          'cipherType': ciphertextMessage.getType(),
          'itemId': messageItemId,
        };

        final isSenderDevice = (recipientAddress.getName() == currentUserId);
        if (isSenderDevice) {
          debugPrint(
            '[MESSAGE_SENDER] Multi-device sync - sending to own device ${recipientAddress.getDeviceId()}',
          );
        }

        debugPrint('[MESSAGE_SENDER] Step 10: Sending item via socket');
        SocketService().emit("sendItem", data);
        successCount++;

        final isPreKeyMessage = ciphertextMessage.getType() == 3;
        if (isPreKeyMessage) {
          debugPrint(
            '[MESSAGE_SENDER] Step 11: PreKey message sent (establishing session)',
          );
          KeyManagementMetrics.recordRemotePreKeyConsumed(1);
        } else {
          debugPrint(
            '[MESSAGE_SENDER] Step 11: Whisper message sent (session exists)',
          );
        }
      } catch (e, stackTrace) {
        failureCount++;
        debugPrint(
          '[MESSAGE_SENDER] ⚠️ Failed to encrypt for device ${bundle['userId']}:${bundle['deviceId']}',
        );
        debugPrint('[MESSAGE_SENDER] Error: $e');
        debugPrint('[MESSAGE_SENDER] Stack trace: $stackTrace');
        debugPrint('[MESSAGE_SENDER] → Continuing to next device...');
      }
    }

    debugPrint(
      '[MESSAGE_SENDER] ✓ Send complete: $successCount succeeded, $failureCount failed, $skippedCount skipped',
    );

    if (successCount == 0 && preKeyBundles.isNotEmpty) {
      if (skippedCount > 0) {
        throw Exception(
          'Failed to send message: $skippedCount devices had invalid/corrupted PreKeyBundles, '
          '$failureCount devices failed encryption. '
          'Recipient may need to logout and login again to regenerate their Signal keys.',
        );
      } else {
        throw Exception(
          'Failed to send message to all ${preKeyBundles.length} devices. '
          'This may be a network issue or recipient may need to re-register Signal keys.',
        );
      }
    }
  }

  /// Fetch PreKeyBundle for a user
  ///
  /// Retrieves encryption keys for all devices of the target user.
  /// Returns list of bundles with device info and cryptographic keys.
  Future<List<Map<String, dynamic>>> fetchPreKeyBundleForUser(
    String userId,
  ) async {
    final response = await ApiService.get('/signal/prekey_bundle/$userId');

    if (response.statusCode == 200) {
      try {
        final devices = response.data is String
            ? jsonDecode(response.data)
            : response.data;

        final List<Map<String, dynamic>> result = [];
        int skippedDevices = 0;

        for (final data in devices) {
          final hasAllFields =
              data['public_key'] != null &&
              data['registration_id'] != null &&
              data['preKey'] != null &&
              data['signedPreKey'] != null &&
              data['preKey']['prekey_data'] != null &&
              data['signedPreKey']['signed_prekey_data'] != null &&
              data['signedPreKey']['signed_prekey_signature'] != null &&
              data['signedPreKey']['signed_prekey_signature']
                  .toString()
                  .isNotEmpty;

          if (!hasAllFields) {
            debugPrint(
              '[MESSAGE_SENDER] Device ${data['clientid']} skipped: missing Signal keys',
            );
            skippedDevices++;
            continue;
          }

          // Parse ALL numeric IDs as int
          final deviceId = data['device_id'] is int
              ? data['device_id'] as int
              : int.parse(data['device_id'].toString());

          final registrationId = data['registration_id'] is int
              ? data['registration_id'] as int
              : int.parse(data['registration_id'].toString());

          final preKeyId = data['preKey']['prekey_id'] is int
              ? data['preKey']['prekey_id'] as int
              : int.parse(data['preKey']['prekey_id'].toString());

          final signedPreKeyId = data['signedPreKey']['signed_prekey_id'] is int
              ? data['signedPreKey']['signed_prekey_id'] as int
              : int.parse(data['signedPreKey']['signed_prekey_id'].toString());

          final identityKeyBytes = base64Decode(data['public_key']);
          final identityKey = IdentityKey.fromBytes(identityKeyBytes, 0);

          result.add({
            'clientid': data['clientid'],
            'userId': data['userId'],
            'deviceId': deviceId,
            'publicKey': data['public_key'],
            'registrationId': registrationId,
            'preKeyId': preKeyId,
            'preKeyPublic': Curve.decodePoint(
              base64Decode(data['preKey']['prekey_data']),
              0,
            ),
            'signedPreKeyId': signedPreKeyId,
            'signedPreKeyPublic': Curve.decodePoint(
              base64Decode(data['signedPreKey']['signed_prekey_data']),
              0,
            ),
            'signedPreKeySignature': base64Decode(
              data['signedPreKey']['signed_prekey_signature'],
            ),
            'identityKey': identityKey,
          });
        }

        if (result.isEmpty) {
          if (skippedDevices > 0) {
            debugPrint(
              '[MESSAGE_SENDER] ❌ User $userId has $skippedDevices devices but NONE have valid Signal keys!',
            );
          } else {
            debugPrint(
              '[MESSAGE_SENDER] ❌ User $userId has no devices at all.',
            );
          }
        } else {
          if (skippedDevices > 0) {
            debugPrint(
              '[MESSAGE_SENDER] ✓ Found ${result.length} devices with keys, $skippedDevices without keys',
            );
          } else {
            debugPrint(
              '[MESSAGE_SENDER] ✓ All ${result.length} devices have valid keys',
            );
          }
        }

        return result;
      } catch (e, st) {
        debugPrint(
          '[MESSAGE_SENDER] Exception while decoding response: $e\n$st',
        );
        rethrow;
      }
    } else {
      debugPrint(
        '[MESSAGE_SENDER] ❌ Failed to load PreKeyBundle - HTTP ${response.statusCode}',
      );
      throw Exception(
        'Failed to load PreKeyBundle for user (HTTP ${response.statusCode}).',
      );
    }
  }

  /// Check if recipient has registered encryption keys
  Future<bool> _recipientHasKeys(String userId) async {
    try {
      debugPrint('[MESSAGE_SENDER] Checking if $userId has any keys...');

      final response = await ApiService.get('/signal/prekey_bundle/$userId');
      final devices = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      if (devices is! List || devices.isEmpty) {
        debugPrint(
          '[MESSAGE_SENDER] ❌ Recipient $userId has no registered devices',
        );
        return false;
      }

      debugPrint(
        '[MESSAGE_SENDER] Found ${devices.length} devices for $userId',
      );

      int devicesWithKeys = 0;
      for (final device in devices) {
        final hasAllFields =
            device['public_key'] != null &&
            device['registration_id'] != null &&
            device['preKey'] != null &&
            device['signedPreKey'] != null &&
            device['preKey']['prekey_data'] != null &&
            device['signedPreKey']['signed_prekey_data'] != null &&
            device['signedPreKey']['signed_prekey_signature'] != null;

        if (hasAllFields) {
          devicesWithKeys++;
        }
      }

      if (devicesWithKeys == 0) {
        debugPrint('[MESSAGE_SENDER] ❌ No devices have complete key bundles');
        return false;
      }

      debugPrint('[MESSAGE_SENDER] ✓ Found $devicesWithKeys devices with keys');
      return true;
    } catch (e) {
      debugPrint('[MESSAGE_SENDER] Error checking recipient keys: $e');
      return false;
    }
  }

  /// Validate PreKeyBundle's cryptographic integrity
  bool _validatePreKeyBundle(Map<String, dynamic> bundle) {
    try {
      final identityKey = bundle['identityKey'] as IdentityKey;
      final signedPreKeyPublic = bundle['signedPreKeyPublic'] as DjbECPublicKey;
      final signedPreKeySignature =
          bundle['signedPreKeySignature'] as Uint8List;

      debugPrint(
        '[MESSAGE_SENDER] Validating bundle for ${bundle['userId']}:${bundle['deviceId']}',
      );

      final publicKeyBytes = Curve.decodePoint(identityKey.serialize(), 0);
      final isValid = Curve.verifySignature(
        publicKeyBytes,
        signedPreKeyPublic.serialize(),
        signedPreKeySignature,
      );

      if (!isValid) {
        debugPrint('[MESSAGE_SENDER] ❌ Invalid SignedPreKey signature');
        return false;
      }

      if (signedPreKeySignature.length != 64) {
        debugPrint(
          '[MESSAGE_SENDER] ❌ Invalid signature length: ${signedPreKeySignature.length}',
        );
        return false;
      }

      debugPrint('[MESSAGE_SENDER] ✓ Bundle valid - signature verified');
      return true;
    } catch (e) {
      debugPrint('[MESSAGE_SENDER] ❌ Exception validating bundle: $e');
      return false;
    }
  }

  /// Validate session using PreKey bundle data
  Future<bool> _validateSessionWithBundle(
    SignalProtocolAddress remoteAddress,
    Map<String, dynamic> bundle,
  ) async {
    try {
      if (!await sessionStore.containsSession(remoteAddress)) {
        debugPrint(
          '[MESSAGE_SENDER] No session exists for ${remoteAddress.getName()}',
        );
        return false;
      }

      final storedIdentity = await identityStore.getIdentity(remoteAddress);
      if (storedIdentity == null) {
        debugPrint(
          '[MESSAGE_SENDER] No stored identity for ${remoteAddress.getName()}',
        );
        return false;
      }

      final bundleIdentityKey = bundle['identityKey'] as IdentityKey;
      final storedIdentityBytes = storedIdentity.serialize();
      final bundleIdentityBytes = bundleIdentityKey.serialize();

      final identityKeysMatch = const ListEquality().equals(
        storedIdentityBytes,
        bundleIdentityBytes,
      );

      if (!identityKeysMatch) {
        debugPrint(
          '[MESSAGE_SENDER] ⚠️ Recipient identity key changed for ${remoteAddress.getName()}!',
        );
        return false;
      }

      debugPrint(
        '[MESSAGE_SENDER] ✓ Session valid for ${remoteAddress.getName()}',
      );
      return true;
    } catch (e) {
      debugPrint('[MESSAGE_SENDER] Session validation error: $e');
      return false;
    }
  }

  /// Handle untrusted identity exception
  Future<void> _handleUntrustedIdentity(
    UntrustedIdentityException e,
    SignalProtocolAddress address,
  ) async {
    debugPrint(
      '[MESSAGE_SENDER] Auto-trusting new identity for ${address.getName()}',
    );

    // Fetch fresh PreKeyBundle with current identity key from server
    final userId = address.getName();
    final deviceId = address.getDeviceId();
    final bundles = await fetchPreKeyBundleForUser(userId);
    final targetBundle = bundles.firstWhere(
      (b) => b['userId'] == userId && b['deviceId'] == deviceId,
      orElse: () => throw Exception('No bundle found for $userId:$deviceId'),
    );

    // Extract and save the new identity key
    final newIdentityKey = targetBundle['identityKey'] as IdentityKey;
    await identityStore.saveIdentity(address, newIdentityKey);

    // Delete old session to force rebuild
    if (await sessionStore.containsSession(address)) {
      await sessionStore.deleteSession(address);
    }

    debugPrint('[MESSAGE_SENDER] ✓ Identity trusted and session reset');
  }
}
