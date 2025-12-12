import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:convert';
import '../utils/html_stub.dart'
    if (dart.library.html) 'dart:html' as html;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as signal;
import '../services/external_participant_service.dart';

/// External participant E2EE key setup view
/// 
/// Generates Signal Protocol keys for guest users before joining meeting:
/// - Identity key pair (reusable across meetings)
/// - Signed pre-key (7 day validity)
/// - 30 one-time pre-keys
/// 
/// Keys stored in sessionStorage for reuse within browser tab.
/// Progress shown with step-by-step indicators.
class ExternalKeySetupView extends StatefulWidget {
  final String invitationToken;
  final VoidCallback onComplete;
  final Function(String)? onError;

  const ExternalKeySetupView({
    super.key,
    required this.invitationToken,
    required this.onComplete,
    this.onError,
  });

  @override
  State<ExternalKeySetupView> createState() => _ExternalKeySetupViewState();
}

class _ExternalKeySetupViewState extends State<ExternalKeySetupView> {
  String _currentStep = 'Initializing...';
  double _progress = 0.0;
  bool _hasError = false;
  String _errorMessage = '';
  int _retryCount = 0;
  static const int MAX_RETRIES = 3;

  @override
  void initState() {
    super.initState();
    _initializeKeys();
  }

  Future<void> _initializeKeys() async {
    try {
      setState(() {
        _hasError = false;
        _errorMessage = '';
        _currentStep = 'Checking existing keys...';
        _progress = 0.1;
      });

      await Future.delayed(const Duration(milliseconds: 300));

      // Check if crypto API is available
      if (!_isCryptoApiAvailable()) {
        throw Exception('browser_not_supported');
      }

      // Step 1: Check existing keys in sessionStorage
      final storage = html.window.sessionStorage;
      final storedIdentity = storage['external_identity_key_public'];
      final storedSignedPre = storage['external_signed_pre_key'];
      final storedPreKeys = storage['external_pre_keys'];

      bool needNewIdentity = storedIdentity == null;
      bool needNewSignedPre = false;
      bool needNewPreKeys = false;

      // Check signed pre-key age (7 days max)
      if (storedSignedPre != null) {
        try {
          final signedPreJson = jsonDecode(storedSignedPre);
          final timestamp = signedPreJson['timestamp'] as int;
          final age = DateTime.now().millisecondsSinceEpoch - timestamp;
          final daysSinceCreation = age / (1000 * 60 * 60 * 24);

          if (daysSinceCreation > 7) {
            debugPrint('[KeySetup] Signed pre-key expired (${daysSinceCreation.toStringAsFixed(1)} days old)');
            needNewSignedPre = true;
          } else {
            debugPrint('[KeySetup] Reusing signed pre-key (${daysSinceCreation.toStringAsFixed(1)} days old)');
          }
        } catch (e) {
          debugPrint('[KeySetup] Invalid signed pre-key format: $e');
          needNewSignedPre = true;
        }
      } else {
        needNewSignedPre = true;
      }

      // Check pre-keys count
      if (storedPreKeys != null) {
        try {
          final preKeysJson = jsonDecode(storedPreKeys) as List;
          if (preKeysJson.length < 30) {
            debugPrint('[KeySetup] Pre-keys low (${preKeysJson.length}), generating new batch');
            needNewPreKeys = true;
          } else {
            debugPrint('[KeySetup] Reusing ${preKeysJson.length} pre-keys');
          }
        } catch (e) {
          debugPrint('[KeySetup] Invalid pre-keys format: $e');
          needNewPreKeys = true;
        }
      } else {
        needNewPreKeys = true;
      }

      // Step 2: Generate identity key if needed
      if (needNewIdentity) {
        setState(() {
          _currentStep = 'Generating identity keys...';
          _progress = 0.3;
        });
        await Future.delayed(const Duration(milliseconds: 200));
        await _generateIdentityKey(storage);
      } else {
        setState(() {
          _currentStep = 'Identity keys found, reusing...';
          _progress = 0.3;
        });
        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Step 3: Generate signed pre-key if needed
      if (needNewSignedPre) {
        setState(() {
          _currentStep = 'Generating signed pre-key...';
          _progress = 0.5;
        });
        await Future.delayed(const Duration(milliseconds: 200));
        await _generateSignedPreKey(storage);
      } else {
        setState(() {
          _currentStep = 'Signed pre-key valid, reusing...';
          _progress = 0.5;
        });
        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Step 4: Generate pre-keys if needed
      if (needNewPreKeys) {
        setState(() {
          _currentStep = 'Generating pre-keys (0/30)...';
          _progress = 0.7;
        });
        await Future.delayed(const Duration(milliseconds: 200));
        await _generatePreKeys(storage);
      } else {
        setState(() {
          _currentStep = 'Pre-keys valid, reusing...';
          _progress = 0.7;
        });
        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Step 5: Validate all keys
      setState(() {
        _currentStep = 'Validating keys...';
        _progress = 0.85;
      });
      await Future.delayed(const Duration(milliseconds: 300));

      // Step 6: Upload keys to server (register session)
      setState(() {
        _currentStep = 'Registering with server...';
        _progress = 0.95;
      });
      await _uploadKeysToServer(storage);

      // Step 7: Complete
      setState(() {
        _currentStep = 'Setup complete!';
        _progress = 1.0;
      });
      await Future.delayed(const Duration(milliseconds: 500));

      // Navigate to prejoin
      widget.onComplete();
    } catch (e) {
      debugPrint('[KeySetup] Error: $e');

      if (e.toString().contains('browser_not_supported')) {
        setState(() {
          _hasError = true;
          _errorMessage =
              'Your browser doesn\'t support encryption.\n\nPlease use a modern browser:\n• Chrome\n• Firefox\n• Edge\n• Safari';
        });
        return;
      }

      // Retry logic
      if (_retryCount < MAX_RETRIES) {
        _retryCount++;
        debugPrint('[KeySetup] Retry attempt $_retryCount/$MAX_RETRIES');
        setState(() {
          _currentStep = 'Retrying... (Attempt $_retryCount/$MAX_RETRIES)';
          _progress = 0.0;
        });
        await Future.delayed(const Duration(seconds: 1));
        _initializeKeys();
      } else {
        setState(() {
          _hasError = true;
          _errorMessage =
              'Your browser doesn\'t support encryption.\n\nPlease use a modern browser:\n• Chrome\n• Firefox\n• Edge\n• Safari';
        });
      }
    }
  }

  bool _isCryptoApiAvailable() {
    try {
      // Check if Web Crypto API is available
      return html.window.crypto != null;
    } catch (e) {
      return false;
    }
  }

  Future<void> _generateIdentityKey(dynamic storage) async {
    // Generate identity key pair using Signal Protocol
    final identityKeyPair = signal.generateIdentityKeyPair();

    // Convert to base64 for storage
    final publicKey = base64Encode(identityKeyPair.getPublicKey().serialize());
    final privateKey =
        base64Encode(identityKeyPair.getPrivateKey().serialize());

    // Store in sessionStorage
    storage['external_identity_key_public'] = publicKey;
    storage['external_identity_key_private'] = privateKey;

    debugPrint('[KeySetup] Generated new identity key');
  }

  Future<void> _generateSignedPreKey(dynamic storage) async {
    // Get identity key from storage
    final identityPublic = storage['external_identity_key_public']!;
    final identityPrivate = storage['external_identity_key_private']!;

    // Reconstruct identity key pair
    final publicKeyBytes = base64Decode(identityPublic);
    final privateKeyBytes = base64Decode(identityPrivate);
    
    final publicKey = signal.Curve.decodePoint(publicKeyBytes, 0);
    final privateKey = signal.Curve.decodePrivatePoint(privateKeyBytes);
    final identityKeyPair = signal.IdentityKeyPair(signal.IdentityKey(publicKey), privateKey);

    // Generate signed pre-key
    final signedPreKey = signal.generateSignedPreKey(identityKeyPair, 1);

    // Convert to JSON with timestamp
    final signedPreKeyData = {
      'id': 1,
      'publicKey': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
      'privateKey': base64Encode(signedPreKey.getKeyPair().privateKey.serialize()),
      'signature': base64Encode(signedPreKey.signature),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // Store in sessionStorage
    storage['external_signed_pre_key'] = jsonEncode(signedPreKeyData);

    debugPrint('[KeySetup] Generated new signed pre-key');
  }

  Future<void> _generatePreKeys(dynamic storage) async {
    // Get next pre-key ID from storage (or start at 0)
    final nextIdStr = storage['external_next_pre_key_id'] ?? '0';
    final startId = int.parse(nextIdStr);

    // Generate 30 pre-keys (libsignal generatePreKeys is INCLUSIVE)
    final preKeys = signal.generatePreKeys(startId, startId + 29);

    // Convert to JSON array
    final preKeysJson = preKeys.map((pk) {
      return {
        'id': pk.id,
        'publicKey': base64Encode(pk.getKeyPair().publicKey.serialize()),
        'privateKey': base64Encode(pk.getKeyPair().privateKey.serialize()),
      };
    }).toList();

    // Update progress
    for (int i = 0; i < preKeysJson.length; i++) {
      if (mounted) {
        setState(() {
          _currentStep = 'Generating pre-keys (${i + 1}/30)...';
          _progress = 0.7 + ((i + 1) / 30) * 0.15;
        });
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    // Store in sessionStorage
    storage['external_pre_keys'] = jsonEncode(preKeysJson);
    storage['external_next_pre_key_id'] = (startId + 30).toString();

    debugPrint('[KeySetup] Generated 30 pre-keys (IDs: $startId-${startId + 29})');
  }

  /// Upload keys to server and register the external participant session
  Future<void> _uploadKeysToServer(dynamic storage) async {
    debugPrint('[KeySetup] Uploading keys to server...');

    // Read keys from sessionStorage
    final identityPublic = storage['external_identity_key_public'];
    final signedPreKeyStr = storage['external_signed_pre_key'];
    final preKeysStr = storage['external_pre_keys'];

    if (identityPublic == null || signedPreKeyStr == null || preKeysStr == null) {
      throw Exception('E2EE keys not found in sessionStorage');
    }

    final signedPreKey = jsonDecode(signedPreKeyStr);
    final preKeys = jsonDecode(preKeysStr) as List;

    // Use a temporary display name for now - user can update it in pre-join
    const tempDisplayName = 'Guest';

    // Register session with keys
    final externalService = ExternalParticipantService();
    final session = await externalService.joinMeeting(
      invitationToken: widget.invitationToken,
      displayName: tempDisplayName,
      identityKeyPublic: identityPublic,
      signedPreKey: signedPreKey,
      preKeys: preKeys,
    );

    // Save session info to sessionStorage for pre-join view to use
    storage['external_session_id'] = session.sessionId;
    storage['external_meeting_id'] = session.meetingId;
    storage['external_display_name'] = session.displayName;

    debugPrint('[KeySetup] Session registered: ${session.sessionId}');
  }

  @override
  Widget build(BuildContext context) {
    // This view is web-only
    if (!kIsWeb) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text('This feature is only available on web'),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.secondary,
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 500),
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _hasError ? Icons.error_outline : Icons.shield,
                      size: 60,
                      color: _hasError
                          ? Colors.red
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Title
                  Text(
                    _hasError ? 'Setup Failed' : 'Securing Connection',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),

                  // Subtitle
                  Text(
                    _hasError
                        ? 'Encryption setup failed'
                        : 'Setting up end-to-end encryption...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),

                  if (_hasError) ...[
                    // Error message
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.error_outline,
                              color: Colors.red, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            _errorMessage,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 14,
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Progress bar
                    LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.grey[200],
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
                      ),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 16),

                    // Current step text
                    Text(
                      _currentStep,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),

                    // Progress percentage
                    Text(
                      '${(_progress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
