import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../state/sender_key_state.dart';
import '../core/key_manager.dart';

/// Observes SenderKeyState and maintains group key forward secrecy
///
/// Performs daily checks for stale sender keys:
/// - Keys older than 7 days
/// - Keys with 1000+ messages encrypted
///
/// When stale keys detected:
/// - Automatically rotates keys
/// - Maintains forward secrecy in group chats
/// - Prevents key compromise from affecting old messages
///
/// Usage:
/// ```dart
/// final observer = SenderKeyRotationObserver(
///   keyManager: keyManager,
///   getCurrentUserId: () => signalService.currentUserId,
///   getCurrentDeviceId: () => signalService.currentDeviceId,
/// );
/// observer.start(); // Begin observing (daily checks)
/// // ...
/// observer.stop(); // Stop observing (cleanup)
/// ```
class SenderKeyRotationObserver {
  final SignalKeyManager keyManager;
  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;
  Timer? _dailyTimer;
  bool _isObserving = false;
  bool _isRotating = false;

  // State instance from KeyManager
  SenderKeyState get senderKeyState => keyManager.senderKeyState;

  SenderKeyRotationObserver({
    required this.keyManager,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
  });

  /// Start observing and schedule daily maintenance
  void start() {
    if (_isObserving) {
      debugPrint('[SENDERKEY_OBSERVER] Already observing');
      return;
    }

    // Listen for state changes (manual triggers)
    senderKeyState.addListener(_onSenderKeyStateChanged);

    // Schedule daily automatic checks
    _dailyTimer = Timer.periodic(Duration(hours: 24), (_) async {
      await _checkAndRotateStaleKeys();
    });

    _isObserving = true;

    debugPrint('[SENDERKEY_OBSERVER] Started observing (daily checks enabled)');

    // Run initial check after 1 minute
    Timer(Duration(minutes: 1), () async {
      await _checkAndRotateStaleKeys();
    });
  }

  /// Stop observing and cancel timer
  void stop() {
    if (!_isObserving) return;

    senderKeyState.removeListener(_onSenderKeyStateChanged);
    _dailyTimer?.cancel();
    _dailyTimer = null;
    _isObserving = false;

    debugPrint('[SENDERKEY_OBSERVER] Stopped observing');
  }

  /// Handle sender key state changes
  Future<void> _onSenderKeyStateChanged() async {
    // Check if rotation is needed based on state
    if (senderKeyState.keysNeedingRotation > 0 && !_isRotating) {
      debugPrint(
        '[SENDERKEY_OBSERVER] State indicates ${senderKeyState.keysNeedingRotation} keys need rotation',
      );
      await _checkAndRotateStaleKeys();
    }
  }

  /// Check for stale keys and rotate them
  Future<void> _checkAndRotateStaleKeys() async {
    if (_isRotating) {
      debugPrint(
        '[SENDERKEY_OBSERVER] Rotation already in progress, skipping...',
      );
      return;
    }

    // Check if user info is available
    final userId = getCurrentUserId();
    final deviceId = getCurrentDeviceId();

    if (userId == null || deviceId == null) {
      debugPrint(
        '[SENDERKEY_OBSERVER] User info not available, skipping check',
      );
      return;
    }

    _isRotating = true;

    try {
      debugPrint(
        '[SENDERKEY_OBSERVER] ========================================',
      );
      debugPrint('[SENDERKEY_OBSERVER] Checking for stale sender keys...');

      final myAddress = SignalProtocolAddress(userId, deviceId);

      // Check sender keys (updates state with stale count)
      await keyManager.checkSenderKeys(myAddress);

      final staleCount = senderKeyState.keysNeedingRotation;

      if (staleCount > 0) {
        debugPrint(
          '[SENDERKEY_OBSERVER] Found $staleCount stale keys, rotating...',
        );

        // State is already updated by checkSenderKeys(), which handles rotation
        debugPrint('[SENDERKEY_OBSERVER] ✅ Stale keys rotated');
      } else {
        debugPrint('[SENDERKEY_OBSERVER] ✓ All sender keys are healthy');
      }

      debugPrint(
        '[SENDERKEY_OBSERVER] ========================================',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '[SENDERKEY_OBSERVER] ❌ Error checking/rotating sender keys: $e',
      );
      debugPrint('[SENDERKEY_OBSERVER] Stack trace: $stackTrace');

      senderKeyState.markError('Failed to rotate stale keys: $e');
    } finally {
      _isRotating = false;
    }
  }
}
