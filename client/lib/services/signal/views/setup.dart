import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../signal.dart';
import '../state/identity_key_state.dart';
import '../state/signed_pre_key_state.dart';
import '../state/pre_key_state.dart';

/// Clean setup view that watches Signal Protocol key states
///
/// No manual progress tracking needed - states update automatically via observers:
/// - IdentityKeyState: Tracks identity key generation and status
/// - SignedPreKeyState: Tracks signed pre key rotation and age
/// - PreKeyState: Tracks pre key count and maintenance
///
/// States are accessed through the SignalClient's KeyManager for proper
/// multi-server isolation instead of global singletons.
///
/// Usage:
/// ```dart
/// SignalSetupView(
///   onInitialize: () async {
///     final client = await ServerSettingsService.instance.getOrCreateSignalClient();
///     await client.initialize();
///     return client;
///   },
///   onComplete: () => GoRouter.of(context).go('/app/activities'),
/// )
/// ```
class SignalSetupView extends StatefulWidget {
  final Future<SignalClient> Function() onInitialize;
  final VoidCallback onComplete;
  final VoidCallback? onError;

  const SignalSetupView({
    super.key,
    required this.onInitialize,
    required this.onComplete,
    this.onError,
  });

  @override
  State<SignalSetupView> createState() => _SignalSetupViewState();
}

class _SignalSetupViewState extends State<SignalSetupView> {
  String _statusText = 'Initializing Signal Protocol...';
  double _progress = 0.0;
  bool _hasError = false;
  SignalClient? _signalClient;

  @override
  void initState() {
    super.initState();
    _triggerInitialization();
  }

  Future<void> _triggerInitialization() async {
    debugPrint('[SIGNAL_SETUP_VIEW] Starting initialization...');
    try {
      debugPrint('[SIGNAL_SETUP_VIEW] Calling onInitialize callback...');
      _signalClient = await widget.onInitialize();
      debugPrint('[SIGNAL_SETUP_VIEW] ✓ onInitialize completed');
      debugPrint('[SIGNAL_SETUP_VIEW] Setting up state listeners...');
      _setupListeners();
      debugPrint('[SIGNAL_SETUP_VIEW] Checking initial state...');
      _checkInitialState();
    } catch (e, stackTrace) {
      debugPrint('[SIGNAL_SETUP_VIEW] ❌ Initialization error: $e');
      debugPrint('[SIGNAL_SETUP_VIEW] Stack trace: $stackTrace');
      setState(() {
        _hasError = true;
        _statusText = 'Initialization failed: $e';
      });
      widget.onError?.call();
    }
  }

  void _setupListeners() {
    if (_signalClient == null) {
      debugPrint(
        '[SIGNAL_SETUP_VIEW] ⚠️ Cannot setup listeners: SignalClient not initialized',
      );
      return;
    }

    // Watch all three key states from the SignalClient's KeyManager
    _signalClient!.keyManager.identityKeyState.addListener(_onStateChanged);
    _signalClient!.keyManager.signedPreKeyState.addListener(_onStateChanged);
    _signalClient!.keyManager.preKeyState.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    if (_signalClient != null) {
      _signalClient!.keyManager.identityKeyState.removeListener(
        _onStateChanged,
      );
      _signalClient!.keyManager.signedPreKeyState.removeListener(
        _onStateChanged,
      );
      _signalClient!.keyManager.preKeyState.removeListener(_onStateChanged);
    }
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted || _signalClient == null) return;

    final identityState = _signalClient!.keyManager.identityKeyState;
    final signedPreKeyState = _signalClient!.keyManager.signedPreKeyState;
    final preKeyState = _signalClient!.keyManager.preKeyState;

    // Check for errors
    if (identityState.status == IdentityKeyStatus.error ||
        signedPreKeyState.status == SignedPreKeyStatus.error ||
        preKeyState.status == PreKeyStatus.error) {
      setState(() {
        _hasError = true;
        _statusText =
            'Error: ${identityState.errorMessage ?? signedPreKeyState.errorMessage ?? preKeyState.errorMessage ?? 'Unknown error'}';
        _progress = 0.0;
      });
      widget.onError?.call();
      return;
    }

    // Calculate progress (3 steps: Identity + SignedPreKey + PreKeys)
    int completedSteps = 0;
    String currentOperation = '';

    // Step 1: Identity Key
    if (identityState.status == IdentityKeyStatus.ready &&
        identityState.hasIdentityKey) {
      completedSteps++;
    } else if (identityState.status == IdentityKeyStatus.generating) {
      currentOperation = 'Generating identity key pair...';
    } else if (identityState.status == IdentityKeyStatus.unknown) {
      currentOperation = 'Checking identity key...';
    }

    // Step 2: SignedPreKey
    if (signedPreKeyState.status == SignedPreKeyStatus.fresh &&
        signedPreKeyState.currentKeyId != null) {
      completedSteps++;
    } else if (signedPreKeyState.status == SignedPreKeyStatus.rotating) {
      currentOperation = 'Generating signed pre key...';
    } else if (completedSteps == 1 && signedPreKeyState.currentKeyId == null) {
      currentOperation = 'Checking signed pre key...';
    }

    // Step 3: PreKeys
    final hasMinimumPreKeys = preKeyState.count >= 20;
    if (hasMinimumPreKeys &&
        (preKeyState.status == PreKeyStatus.healthy ||
            preKeyState.status == PreKeyStatus.excess)) {
      completedSteps++;
    } else if (preKeyState.status == PreKeyStatus.generating) {
      currentOperation = 'Generating pre keys (${preKeyState.count}/110)...';
    } else if (completedSteps == 2 && !hasMinimumPreKeys) {
      currentOperation = 'Checking pre keys...';
    }

    final progress = completedSteps / 3.0;

    setState(() {
      _progress = progress;
      _statusText = currentOperation.isEmpty
          ? 'Initializing Signal Protocol...'
          : currentOperation;
    });

    // Check if complete (all 3 steps done)
    if (completedSteps == 3 && !_hasError) {
      setState(() {
        _statusText = 'Verifying keys...';
        _progress = 1.0;
      });

      // Trigger post-setup verification
      debugPrint('[SIGNAL_SETUP_VIEW] Running post-setup key verification...');
      _signalClient!
          .verifyKeys()
          .then((_) {
            if (mounted) {
              setState(() {
                _statusText = 'Signal Protocol ready!';
              });
            }

            // Small delay before completion callback
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                widget.onComplete();
              }
            });
          })
          .catchError((e) {
            debugPrint(
              '[SIGNAL_SETUP_VIEW] ⚠️ Post-setup verification error: $e',
            );
            // Continue anyway - verification errors shouldn't block login
            if (mounted) {
              setState(() {
                _statusText = 'Signal Protocol ready!';
              });
            }
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                widget.onComplete();
              }
            });
          });
    }
  }

  void _checkInitialState() {
    // Trigger initial state check
    Future.microtask(() => _onStateChanged());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // PeerWave Logo
              Image.asset(
                'assets/images/peerwave.png',
                width: 200,
                height: 200,
              ),
              const SizedBox(height: 24),
              const Text(
                'Secure Collaboration Platform',
                style: TextStyle(fontSize: 18, color: Colors.grey),
              ),
              const SizedBox(height: 48),

              // Progress indicator
              if (!_hasError) ...[
                SizedBox(
                  width: 100,
                  height: 100,
                  child: CircularProgressIndicator(
                    value: _progress,
                    strokeWidth: 6,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _statusText,
                  style: const TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_progress * 100).toInt()}%',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ] else ...[
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 24),
                Text(
                  _statusText,
                  style: const TextStyle(fontSize: 16, color: Colors.red),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _hasError = false;
                      _statusText = 'Retrying...';
                      _progress = 0.0;
                    });
                    // KeyManager observers will auto-retry
                  },
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
