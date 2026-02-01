import 'package:flutter/foundation.dart';
import '../state/pre_key_state.dart';
import '../core/key_manager.dart';

/// Observes PreKeyState and maintains healthy key pool
///
/// When PreKey count drops below threshold (20):
/// - Automatically triggers regeneration to 110 keys
/// - Prevents "no PreKeys available" errors during messaging
/// - Maintains healthy key pool for new sessions
///
/// Usage:
/// ```dart
/// final observer = PreKeyMaintenanceObserver(keyManager: keyManager);
/// observer.start(); // Begin observing
/// // ...
/// observer.stop(); // Stop observing (cleanup)
/// ```
class PreKeyMaintenanceObserver {
  final SignalKeyManager keyManager;
  static const int _lowThreshold = 20;
  bool _isObserving = false;
  bool _isRegenerating = false;

  PreKeyMaintenanceObserver({required this.keyManager});

  /// Start observing PreKey count
  void start() {
    if (_isObserving) {
      debugPrint('[PREKEY_OBSERVER] Already observing');
      return;
    }

    PreKeyState.instance.addListener(_onPreKeyStateChanged);
    _isObserving = true;

    final currentCount = PreKeyState.instance.count;
    debugPrint(
      '[PREKEY_OBSERVER] Started observing (current count: $currentCount)',
    );
  }

  /// Stop observing PreKey count
  void stop() {
    if (!_isObserving) return;

    PreKeyState.instance.removeListener(_onPreKeyStateChanged);
    _isObserving = false;

    debugPrint('[PREKEY_OBSERVER] Stopped observing');
  }

  /// Handle PreKey state changes
  Future<void> _onPreKeyStateChanged() async {
    final currentCount = PreKeyState.instance.count;

    // Check if count is below threshold
    if (currentCount >= _lowThreshold) {
      return; // Healthy count
    }

    // Prevent concurrent regeneration
    if (_isRegenerating) {
      debugPrint(
        '[PREKEY_OBSERVER] Regeneration already in progress, skipping...',
      );
      return;
    }

    debugPrint(
      '[PREKEY_OBSERVER] ⚠️ PreKey count low: $currentCount (threshold: $_lowThreshold)',
    );

    await _regeneratePreKeys();
  }

  /// Regenerate PreKeys to healthy level
  Future<void> _regeneratePreKeys() async {
    if (_isRegenerating) return;

    _isRegenerating = true;

    try {
      debugPrint('[PREKEY_OBSERVER] Starting PreKey regeneration...');

      await keyManager.checkPreKeys(); // Auto-generates to 110

      final newCount = PreKeyState.instance.count;
      debugPrint(
        '[PREKEY_OBSERVER] ✅ PreKeys regenerated (new count: $newCount)',
      );
    } catch (e, stackTrace) {
      debugPrint('[PREKEY_OBSERVER] ❌ Error regenerating PreKeys: $e');
      debugPrint('[PREKEY_OBSERVER] Stack trace: $stackTrace');
    } finally {
      _isRegenerating = false;
    }
  }
}
