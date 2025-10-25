import 'signal_service.dart';

/// Service to check if Signal Protocol keys are properly set up
class SignalSetupService {
  static final SignalSetupService instance = SignalSetupService._internal();
  factory SignalSetupService() => instance;
  SignalSetupService._internal();

  /// Check if Signal keys need to be set up or regenerated
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
      // Check Identity Key Pair
      try {
        await SignalService.instance.identityStore.getIdentityKeyPair();
        result['hasIdentity'] = true; // If no exception, key exists
      } catch (e) {
        print('[SIGNAL SETUP] No identity key pair found: $e');
        result['hasIdentity'] = false;
      }

      // Check Signed PreKey
      try {
        final signedPreKeys = await SignalService.instance.signedPreKeyStore.loadSignedPreKeys();
        result['hasSignedPreKey'] = signedPreKeys.isNotEmpty;
      } catch (e) {
        print('[SIGNAL SETUP] No signed pre keys found: $e');
        result['hasSignedPreKey'] = false;
      }

      // Check PreKeys count
      try {
        final preKeys = await SignalService.instance.preKeyStore.getAllPreKeys();
        result['preKeysCount'] = preKeys.length;
      } catch (e) {
        print('[SIGNAL SETUP] Error getting pre keys count: $e');
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

      print('[SIGNAL SETUP] Status check: needsSetup=${result['needsSetup']}, identity=$hasIdentity, signedPreKey=$hasSignedPreKey, preKeys=$preKeysCount');

      return result;
    } catch (e) {
      print('[SIGNAL SETUP] Error checking keys status: $e');
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
}
