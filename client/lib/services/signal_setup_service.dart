import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'signal_service.dart';
import 'user_profile_service.dart';
import '../providers/unread_messages_provider.dart';
import 'message_listener_service.dart';
import 'message_cleanup_service.dart';
import 'storage/database_helper.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';

/// Service to check if Signal Protocol keys are properly set up
/// and handle post-login initialization
class SignalSetupService {
  static final SignalSetupService instance = SignalSetupService._internal();
  factory SignalSetupService() => instance;
  SignalSetupService._internal();

  bool _postLoginInitComplete = false;
  Completer<void>? _initializationCompleter;

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
      debugPrint('[SIGNAL SETUP] Initialization in progress, waiting for completion...');
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
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing database...');
      try {
        await DatabaseHelper.database; // Ensures DB is initialized
        debugPrint('[SIGNAL SETUP] ✓ Database initialized');
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Database initialization error (may already be initialized): $e');
      }

      // Step 2: Initialize Message Cleanup Service (Auto-Delete)
      currentStep++;
      onProgress?.call('Initializing cleanup service...', currentStep, totalSteps);
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing Message Cleanup Service...');
      try {
        await MessageCleanupService.instance.init();
        debugPrint('[SIGNAL SETUP] ✓ Message Cleanup Service initialized');
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Failed to initialize Message Cleanup Service: $e');
      }

      // Step 3: Load user profiles (smart loading)
      currentStep++;
      onProgress?.call('Loading user profiles...', currentStep, totalSteps);
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Loading user profiles...');
      try {
        final profileService = UserProfileService.instance;
        if (!profileService.isLoaded) {
          await profileService.initProfiles();
          debugPrint('[SIGNAL SETUP] ✓ User profiles loaded: ${profileService.cacheSize} profiles');
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
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Loading unread message counts...');
      try {
        await unreadProvider.loadFromStorage();
        debugPrint('[SIGNAL SETUP] ✓ Loaded unread message counts from storage');
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error loading unread message counts: $e');
      }

      // Step 5: Connect UnreadMessagesProvider to SignalService
      currentStep++;
      onProgress?.call('Connecting services...', currentStep, totalSteps);
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Connecting UnreadMessagesProvider...');
      try {
        SignalService.instance.setUnreadMessagesProvider(unreadProvider);
        debugPrint('[SIGNAL SETUP] ✓ Connected UnreadMessagesProvider to SignalService');
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error connecting unread provider: $e');
      }

      // Step 5: Initialize SignalService stores and listeners
      currentStep++;
      onProgress?.call('Initializing Signal Protocol...', currentStep, totalSteps);
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing Signal stores and listeners...');
      try {
        if (!SignalService.instance.isInitialized) {
          await SignalService.instance.initStoresAndListeners();
          debugPrint('[SIGNAL SETUP] ✓ Signal stores and listeners initialized');
        } else {
          debugPrint('[SIGNAL SETUP] ✓ Signal already initialized');
        }
      } catch (e) {
        debugPrint('[SIGNAL SETUP] ⚠ Error initializing Signal stores: $e');
        // This is more critical, but still continue
      }

      // Step 6: Initialize global message listeners
      currentStep++;
      onProgress?.call('Setting up message listeners...', currentStep, totalSteps);
      debugPrint('[SIGNAL SETUP] [$currentStep/$totalSteps] Initializing message listeners...');
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
        debugPrint('[SIGNAL SETUP] Device identity not initialized - attempting restore...');
        if (!DeviceIdentityService.instance.tryRestoreFromSession()) {
          debugPrint('[SIGNAL SETUP] Cannot check keys without device identity');
          result['needsSetup'] = true;
          missingKeys['deviceIdentity'] = 'Device identity not initialized - login required';
          return result;
        }
      }

      // 🔑 Check if encryption key exists
      final deviceId = DeviceIdentityService.instance.deviceId;
      final encryptionKey = WebAuthnCryptoService.instance.getKeyFromSession(deviceId);
      if (encryptionKey == null) {
        debugPrint('[SIGNAL SETUP] Encryption key not found in session');
        result['needsSetup'] = true;
        missingKeys['encryptionKey'] = 'Encryption key not found - re-authentication required';
        return result;
      }

      // Check if SignalService is initialized (stores are ready)
      if (!SignalService.instance.isInitialized) {
        debugPrint('[SIGNAL SETUP] SignalService not initialized yet');
        result['needsSetup'] = true;
        missingKeys['signalService'] = 'Signal service not initialized';
        return result;
      }

      // Check Identity Key Pair
      try {
        await SignalService.instance.identityStore.getIdentityKeyPair();
        result['hasIdentity'] = true; // If no exception, key exists
      } catch (e) {
        debugPrint('[SIGNAL SETUP] No identity key pair found: $e');
        result['hasIdentity'] = false;
      }

      // Check Signed PreKey
      try {
        final signedPreKeys = await SignalService.instance.signedPreKeyStore.loadSignedPreKeys();
        result['hasSignedPreKey'] = signedPreKeys.isNotEmpty;
      } catch (e) {
        debugPrint('[SIGNAL SETUP] No signed pre keys found: $e');
        result['hasSignedPreKey'] = false;
      }

      // Check PreKeys count
      try {
        final preKeys = await SignalService.instance.preKeyStore.getAllPreKeys();
        result['preKeysCount'] = preKeys.length;
      } catch (e) {
        debugPrint('[SIGNAL SETUP] Error getting pre keys count: $e');
        result['preKeysCount'] = 0;
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
        missingKeys['preKeys'] = 'Insufficient pre keys: $preKeysCount/$minRequired';
      }

      debugPrint('[SIGNAL SETUP] Status check: needsSetup=${result['needsSetup']}, identity=$hasIdentity, signedPreKey=$hasSignedPreKey, preKeys=$preKeysCount');

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

  /// Cleanup on logout - reset initialization state
  void cleanupOnLogout() {
    // 🔒 GUARD: Only cleanup if we were actually initialized
    // Don't run cleanup on login page or when user was never logged in
    if (!_postLoginInitComplete && !SignalService.instance.isInitialized) {
      debugPrint('[SIGNAL SETUP] ℹ️  Skipping cleanup - services were never initialized');
      return;
    }
    
    debugPrint('[SIGNAL SETUP] Cleaning up on logout...');
    
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

