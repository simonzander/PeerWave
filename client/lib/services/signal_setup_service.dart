import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_service.dart';
import 'user_profile_service.dart';
import '../providers/unread_messages_provider.dart';
import 'message_listener_service.dart';
import 'message_cleanup_service.dart';
import 'storage/database_helper.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';
import 'native_crypto_service.dart';
import 'api_service.dart';
import 'key_management_metrics.dart';
import 'server_config_web.dart' if (dart.library.io) 'server_config_native.dart';

/// Service to check if Signal Protocol keys are properly set up
/// and handle post-login initialization
class SignalSetupService {
  static final SignalSetupService instance = SignalSetupService._internal();
  factory SignalSetupService() => instance;
  SignalSetupService._internal();

  bool _postLoginInitComplete = false;
  Completer<void>? _initializationCompleter;
  bool _setupJustCompleted =
      false; // Flag to prevent immediate re-check after setup

  /// Initialize all services after successful login
  /// This consolidates multiple async operations into one sequential flow
  /// to avoid race conditions and provide a single loading indicator
  ///
  /// Uses a Completer to ensure only one initialization runs at a time.
  /// Subsequent calls will wait for the first initialization to complete.
  Future<void> initializeAfterLogin({
    required UnreadMessagesProvider unreadProvider,
    Function(String step, int current, int total)? onProgress,
  }) async {
    // If already complete, do nothing
    if (_postLoginInitComplete) {
      debugPrint('[SIGNAL SETUP] Already initialized, skipping');
      return;
    }

    // If currently initializing, wait for it to complete
    if (_initializationCompleter != null) {
      debugPrint(
        '[SIGNAL SETUP] Initialization in progress, waiting for completion...',
      );
      await _initializationCompleter!.future;
      debugPrint('[SIGNAL SETUP] Initialization completed by another caller');
      return;
    }

    // Start new initialization
    _initializationCompleter = Completer<void>();
    debugPrint('[SIGNAL SETUP] Starting new initialization...');

    try {
      final totalSteps = 7; // Updated from 6 to 7
      var currentStep = 0;

      // Step 1: Initialize Database (if not already done)
      currentStep++;
      onProgress?.call('Initializing database...', currentStep, totalSteps);
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing database...',
      );
      try {
        await DatabaseHelper.database; // Ensures DB is initialized
        debugPrint('[SIGNAL SETUP] ✓ Database initialized');
      } catch (e) {
        debugPrint(
          '[SIGNAL SETUP] ⚠ Database initialization error (may already be initialized): $e',
        );
      }

      // Step 2: Initialize Message Cleanup Service (Auto-Delete)
      currentStep++;
      onProgress?.call(
        'Initializing cleanup service...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing Message Cleanup Service...',
      );
      try {
        await MessageCleanupService.instance.init();
        debugPrint('[SIGNAL SETUP] ✓ Message Cleanup Service initialized');
      } catch (e) {
        debugPrint(
          '[SIGNAL SETUP] ⚠ Failed to initialize Message Cleanup Service: $e',
        );
      }

      // Step 3: Load user profiles (smart loading)
      currentStep++;
      onProgress?.call('Loading user profiles...', currentStep, totalSteps);
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Loading user profiles...',
      );
      try {
        final profileService = UserProfileService.instance;
        if (!profileService.isLoaded) {
          await profileService.initProfiles();
          debugPrint(
            '[SIGNAL SETUP] ✓ User profiles loaded: ${profileService.cacheSize} profiles',
          );
        } else {
          debugPrint('[SIGNAL SETUP] ✓ User profiles already loaded');
        }
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error loading user profiles: $e');
        // Don't block initialization on profile loading failure
      }

      // Step 4: Load unread message counts
      currentStep++;
      onProgress?.call('Loading unread messages...', currentStep, totalSteps);
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Loading unread message counts...',
      );
      try {
        await unreadProvider.loadFromStorage();
        debugPrint(
          '[SIGNAL SETUP] ✓ Loaded unread message counts from storage',
        );
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error loading unread message counts: $e');
      }

      // Step 5: Connect UnreadMessagesProvider to SignalService
      currentStep++;
      onProgress?.call('Connecting services...', currentStep, totalSteps);
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Connecting UnreadMessagesProvider...',
      );
      try {
        SignalService.instance.setUnreadMessagesProvider(unreadProvider);
        debugPrint(
          '[SIGNAL SETUP] ✓ Connected UnreadMessagesProvider to SignalService',
        );
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error connecting unread provider: $e');
      }

      // Step 5: Initialize SignalService stores and listeners
      currentStep++;
      onProgress?.call(
        'Initializing Signal Protocol...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing Signal stores and listeners...',
      );
      try {
        if (!SignalService.instance.isInitialized) {
          await SignalService.instance.initStoresAndListeners();
          debugPrint(
            '[SIGNAL SETUP] ✓ Signal stores and listeners initialized',
          );
        } else {
          debugPrint('[SIGNAL SETUP] ✓ Signal already initialized');
        }
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error initializing Signal stores: $e');
        // This is more critical, but still continue
      }

      // Step 6: Initialize global message listeners
      currentStep++;
      onProgress?.call(
        'Setting up message listeners...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing message listeners...',
      );
      try {
        await MessageListenerService.instance.initialize();
        debugPrint('[SIGNAL SETUP] ✓ Message listeners initialized');
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error initializing message listeners: $e');
      }

      _postLoginInitComplete = true;
      debugPrint('[SIGNAL SETUP] ========================================');
      debugPrint('[SIGNAL SETUP] ✅ Post-login initialization complete');
      debugPrint('[SIGNAL SETUP] ========================================');

      // Complete the future successfully
      _initializationCompleter!.complete();
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL SETUP] ❌ Initialization failed: $e');
      debugPrint('[SIGNAL SETUP] Stack trace: $stackTrace');

      // Complete with error so waiting callers also get the error
      _initializationCompleter!.completeError(e, stackTrace);
      rethrow;
    } finally {
      // Clear the completer after a short delay to allow waiting callers to complete
      Future.delayed(Duration(milliseconds: 100), () {
        _initializationCompleter = null;
      });
    }
  }

  /// Check if post-login initialization is complete
  bool get isPostLoginInitComplete => _postLoginInitComplete;

  /// Check if currently initializing
  bool get isInitializing => _initializationCompleter != null;

  /// Check if Signal Protocol keys are properly set up
  /// Returns a map with setup status and missing keys information
  Future<Map<String, dynamic>> checkKeysStatus() async {
    // 🔒 GUARD: If setup just completed, give it a grace period before checking again
    // This prevents redirect loops when keys are still being written to database
    if (_setupJustCompleted) {
      debugPrint(
        '[SIGNAL SETUP] Setup just completed, skipping check (grace period)',
      );
      return {
        'needsSetup': false,
        'missingKeys': <String, dynamic>{},
        'hasIdentity': true,
        'hasSignedPreKey': true,
        'preKeysCount': 110, // Assume full set
        'minPreKeysRequired': 20,
        'maxPreKeys': 110,
      };
    }

    final missingKeys = <String, dynamic>{};
    final result = {
      'needsSetup': false,
      'missingKeys': missingKeys,
      'hasIdentity': false,
      'hasSignedPreKey': false,
      'preKeysCount': 0,
      'minPreKeysRequired': 20,
      'maxPreKeys': 110,
    };

    try {
      // 🔒 CRITICAL: Check if device identity is initialized first
      if (!DeviceIdentityService.instance.isInitialized) {
        debugPrint(
          '[SIGNAL SETUP] Device identity not initialized - attempting restore...',
        );
        
        // For native, get the active server URL
        String? serverUrl;
        if (!kIsWeb) {
          final activeServer = ServerConfigService.getActiveServer();
          serverUrl = activeServer?.serverUrl;
          if (serverUrl != null) {
            debugPrint('[SIGNAL SETUP] Active server: $serverUrl');
          }
        }
        
        if (!await DeviceIdentityService.instance.tryRestoreFromSession(serverUrl: serverUrl)) {
          debugPrint(
            '[SIGNAL SETUP] Cannot check keys without device identity',
          );
          result['needsSetup'] = true;
          missingKeys['deviceIdentity'] =
              'Device identity not initialized - login required';
          return result;
        }
      }

      // 🔑 Check if encryption key exists
      final deviceId = DeviceIdentityService.instance.deviceId;
      Uint8List? encryptionKey;

      if (kIsWeb) {
        // Web: Use WebAuthn encryption key from SessionStorage
        encryptionKey = WebAuthnCryptoService.instance.getKeyFromSession(
          deviceId,
        );
      } else {
        // Native: Use secure storage encryption key
        encryptionKey = await NativeCryptoService.instance.getKey(deviceId);
      }

      if (encryptionKey == null) {
        debugPrint(
          '[SIGNAL SETUP] Encryption key not found in ${kIsWeb ? 'session' : 'secure storage'}',
        );
        result['needsSetup'] = true;
        missingKeys['encryptionKey'] =
            'Encryption key not found - re-authentication required';
        return result;
      }

      // Check if SignalService is initialized (stores are ready)
      if (!SignalService.instance.isInitialized) {
        debugPrint('[SIGNAL SETUP] SignalService not initialized yet');
        result['needsSetup'] = true;
        missingKeys['signalService'] = 'Signal service not initialized';
        return result;
      }

      // Track if full reset is needed (single flag approach)
      bool needsFullReset = false;
      String resetReason = '';

      // Check Identity Key Pair
      try {
        await SignalService.instance.identityStore.getIdentityKeyPair();
        result['hasIdentity'] = true;
      } catch (e) {
        debugPrint(
          '[SIGNAL SETUP] No identity key pair found or decryption failed: $e',
        );

        if (e.toString().contains('InvalidCipherTextException') ||
            e.toString().contains('Decryption failed')) {
          needsFullReset = true;
          resetReason = 'Identity decryption failed - encryption key mismatch';
        }
        result['hasIdentity'] = false;
      }

      // Check Signed PreKey (only if no reset needed yet)
      if (!needsFullReset) {
        try {
          final signedPreKeys = await SignalService.instance.signedPreKeyStore
              .loadSignedPreKeys();
          result['hasSignedPreKey'] = signedPreKeys.isNotEmpty;

          if (signedPreKeys.isNotEmpty && result['hasIdentity'] == true) {
            // Validate that SignedPreKeys were signed by current Identity Key
            debugPrint('[SIGNAL SETUP] Validating SignedPreKey signatures...');

            try {
              final identityKeyPair = await SignalService.instance.identityStore
                  .getIdentityKeyPair();
              final identityPublicKey = identityKeyPair.getPublicKey();
              final localPublicKey = Curve.decodePoint(
                identityPublicKey.serialize(),
                0,
              );

              bool allValid = true;
              int invalidCount = 0;

              for (final signedPreKey in signedPreKeys) {
                try {
                  final signedPreKeyPublic = signedPreKey
                      .getKeyPair()
                      .publicKey;
                  final signedPreKeySignature = signedPreKey.signature;

                  final isValid = Curve.verifySignature(
                    localPublicKey,
                    signedPreKeyPublic.serialize(),
                    signedPreKeySignature,
                  );

                  if (!isValid) {
                    debugPrint(
                      '[SIGNAL SETUP] ⚠️ SignedPreKey ID ${signedPreKey.id} has INVALID signature!',
                    );
                    allValid = false;
                    invalidCount++;
                  }
                } catch (e) {
                  debugPrint(
                    '[SIGNAL SETUP] ⚠️ Failed to verify SignedPreKey ID ${signedPreKey.id}: $e',
                  );
                  allValid = false;
                  invalidCount++;
                }
              }

              if (!allValid) {
                debugPrint(
                  '[SIGNAL SETUP] ⚠️ CRITICAL: $invalidCount/${signedPreKeys.length} SignedPreKeys have invalid signatures!',
                );
                needsFullReset = true;
                resetReason =
                    'SignedPreKey signature mismatch - Identity Key changed';
                result['hasSignedPreKey'] = false;
              } else {
                debugPrint(
                  '[SIGNAL SETUP] ✓ All ${signedPreKeys.length} SignedPreKey signatures valid',
                );
              }
            } catch (e) {
              debugPrint(
                '[SIGNAL SETUP] ⚠️ Error validating SignedPreKey signatures: $e',
              );
            }
          }
        } catch (e) {
          debugPrint(
            '[SIGNAL SETUP] No signed pre keys found or decryption failed: $e',
          );

          if (e.toString().contains('InvalidCipherTextException') ||
              e.toString().contains('Decryption failed')) {
            needsFullReset = true;
            resetReason = 'SignedPreKey decryption failed';
          }
          result['hasSignedPreKey'] = false;
        }
      } else {
        result['hasSignedPreKey'] = false;
      }

      // Check PreKeys count (only if no reset needed yet)
      if (!needsFullReset) {
        try {
          final preKeyIds = await SignalService.instance.preKeyStore
              .getAllPreKeyIds();
          result['preKeysCount'] = preKeyIds.length;
        } catch (e) {
          debugPrint(
            '[SIGNAL SETUP] Error getting pre keys count or decryption failed: $e',
          );

          if (e.toString().contains('InvalidCipherTextException') ||
              e.toString().contains('Decryption failed')) {
            needsFullReset = true;
            resetReason = 'PreKey decryption failed';
          }
          result['preKeysCount'] = 0;
        }
      } else {
        result['preKeysCount'] = 0;
      }

      // Single cleanup call if any decryption failure detected
      if (needsFullReset) {
        debugPrint('[SIGNAL SETUP] ⚠️ CRITICAL: $resetReason');
        debugPrint('[SIGNAL SETUP] → Clearing all keys (single operation)...');

        // Record metrics
        KeyManagementMetrics.recordDecryptionFailure(
          'Multiple keys',
          reason: resetReason,
        );

        try {
          await SignalService.instance.clearAllSignalData(
            reason: '$resetReason - regenerating all keys',
          );
          debugPrint('[SIGNAL SETUP] ✓ All keys cleared (local + remote)');

          KeyManagementMetrics.recordIdentityRegeneration(reason: resetReason);

          result['needsSetup'] = true;
          missingKeys['all'] = resetReason;
          result['hasIdentity'] = false;
          result['hasSignedPreKey'] = false;
          result['preKeysCount'] = 0;
        } catch (cleanupError) {
          debugPrint(
            '[SIGNAL SETUP] ⚠️ Error during key cleanup: $cleanupError',
          );
          result['needsSetup'] = true;
        }
      }

      // Determine if setup is needed
      final hasIdentity = result['hasIdentity'] as bool;
      final hasSignedPreKey = result['hasSignedPreKey'] as bool;
      final preKeysCount = result['preKeysCount'] as int;
      final minRequired = result['minPreKeysRequired'] as int;

      if (!hasIdentity) {
        result['needsSetup'] = true;
        missingKeys['identity'] = 'Identity key pair missing';
      }

      if (!hasSignedPreKey) {
        result['needsSetup'] = true;
        missingKeys['signedPreKey'] = 'Signed pre key missing';
      }

      if (preKeysCount < minRequired) {
        result['needsSetup'] = true;
        missingKeys['preKeys'] =
            'Insufficient pre keys: $preKeysCount/$minRequired';
      }

      // NEW: Server validation (lightweight check)
      if (!needsFullReset && hasIdentity) {
        try {
          debugPrint('[SIGNAL SETUP] Validating keys against server...');
          final response = await ApiService.get('/signal/status/minimal');
          final serverStatus = response.data as Map<String, dynamic>;

          // Compare Identity public key
          if (serverStatus['identityKey'] != null) {
            final localIdentity = await SignalService.instance.identityStore
                .getIdentityKeyPairData();
            if (serverStatus['identityKey'] != localIdentity['publicKey']) {
              debugPrint(
                '[SIGNAL SETUP] ⚠️ Server identity mismatch detected!',
              );
              KeyManagementMetrics.recordServerKeyMismatch('Identity');
              result['needsSetup'] = true;
              missingKeys['identity'] = 'Server identity key mismatch';
            } else {
              debugPrint('[SIGNAL SETUP] ✓ Identity key matches server');
            }
          }

          // Compare SignedPreKey ID (check if server has latest)
          if (hasSignedPreKey && serverStatus['signedPreKeyId'] != null) {
            final localSignedKeys = await SignalService
                .instance
                .signedPreKeyStore
                .loadSignedPreKeys();
            if (localSignedKeys.isNotEmpty) {
              final newestLocal = localSignedKeys.last;
              if (serverStatus['signedPreKeyId'] != newestLocal.id) {
                debugPrint(
                  '[SIGNAL SETUP] ⚠️ Server has outdated SignedPreKey (server: ${serverStatus['signedPreKeyId']}, local: ${newestLocal.id})',
                );
                KeyManagementMetrics.recordServerKeyMismatch('SignedPreKey');
                result['needsSetup'] = true;
                missingKeys['signedPreKey'] =
                    'Server has outdated SignedPreKey';
              } else {
                debugPrint('[SIGNAL SETUP] ✓ SignedPreKey ID matches server');
              }
            }
          }
        } catch (e) {
          // Network error - propagate to existing server unreachable flow
          debugPrint('[SIGNAL SETUP] ⚠️ Could not verify server status: $e');
          rethrow; // Let existing error handling deal with server unreachability
        }
      }

      debugPrint(
        '[SIGNAL SETUP] Status check: needsSetup=${result['needsSetup']}, identity=$hasIdentity, signedPreKey=$hasSignedPreKey, preKeys=$preKeysCount',
      );

      return result;
    } catch (e) {
      debugPrint('[SIGNAL SETUP] Error checking keys status: $e');
      // If we can't check, assume setup is needed
      result['needsSetup'] = true;
      missingKeys['error'] = 'Unable to check keys: $e';
      return result;
    }
  }

  /// Quick check if setup is needed (simplified version)
  Future<bool> needsSetup() async {
    final status = await checkKeysStatus();
    return status['needsSetup'] as bool;
  }

  /// Mark that signal setup was just completed
  /// This provides a grace period to prevent redirect loops
  void markSetupCompleted() {
    debugPrint(
      '[SIGNAL SETUP] ✅ Marking setup as just completed (grace period active)',
    );
    _setupJustCompleted = true;

    // Clear flag after 3 seconds (keys should be written by then)
    Future.delayed(const Duration(seconds: 3), () {
      debugPrint('[SIGNAL SETUP] Grace period expired, normal checks resumed');
      _setupJustCompleted = false;
    });
  }

  /// Cleanup on logout - reset initialization state
  void cleanupOnLogout() {
    // 🔒 GUARD: Only cleanup if we were actually initialized
    // Don't run cleanup on login page or when user was never logged in
    if (!_postLoginInitComplete && !SignalService.instance.isInitialized) {
      debugPrint(
        '[SIGNAL SETUP] ℹ️  Skipping cleanup - services were never initialized',
      );
      return;
    }

    debugPrint('[SIGNAL SETUP] Cleaning up on logout...');
    _setupJustCompleted = false;

    // Dispose message listeners
    MessageListenerService.instance.dispose();

    // Reset SignalService state
    SignalService.instance.resetOnLogout();

    // Reset initialization flags
    _postLoginInitComplete = false;
    _initializationCompleter = null;

    debugPrint('[SIGNAL SETUP] ✓ Cleanup complete');
  }
}
