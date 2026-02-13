import 'package:flutter/foundation.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../core/session_manager.dart';
import '../core/key_manager.dart';

/// Socket.IO listeners for session and key management
///
/// Handles:
/// - signalStatus: Server key status and validation
/// - preKeyIdsSyncResponse: PreKey ID synchronization
/// - sessionInvalidated: Session invalidation by remote party
/// - identityKeyChanged: Remote identity key rotation
///
/// These listeners maintain session integrity and key synchronization.
class SessionListeners {
  static const String _registrationName = 'SessionListeners';
  static bool _registered = false;

  /// Register all session/key management listeners
  static Future<void> register({
    required SessionManager sessionManager,
    required SignalKeyManager keyManager,
  }) async {
    if (_registered) {
      debugPrint('[SESSION_LISTENERS] Already registered');
      return;
    }

    final socket = SocketService.instance;

    // Signal status check response (key validation)
    // Backend emits: signalStatusResponse (not signalStatus)
    socket.registerListener('signalStatusResponse', (data) async {
      try {
        debugPrint('[SESSION_LISTENERS] Received signalStatusResponse');
        await _handleSignalStatus(data, keyManager);
      } catch (e, stack) {
        debugPrint(
          '[SESSION_LISTENERS] Error processing signalStatusResponse: $e',
        );
        debugPrint('[SESSION_LISTENERS] Stack: $stack');
        _handleError('signalStatusResponse', e, stack);
      }
    }, registrationName: _registrationName);

    // PreKey IDs sync response (server confirms which PreKeys exist)
    // Backend emits: myPreKeyIdsResponse
    socket.registerListener('myPreKeyIdsResponse', (data) async {
      try {
        debugPrint('[SESSION_LISTENERS] Received myPreKeyIdsResponse');
        await _handlePreKeyIdsSync(data, keyManager);
      } catch (e, stack) {
        debugPrint(
          '[SESSION_LISTENERS] Error processing myPreKeyIdsResponse: $e',
        );
        debugPrint('[SESSION_LISTENERS] Stack: $stack');
        _handleError('myPreKeyIdsResponse', e, stack);
      }
    }, registrationName: _registrationName);

    // Session invalidated by remote party
    socket.registerListener('sessionInvalidated', (data) async {
      try {
        final userId = data['userId'] as String;
        final deviceId = data['deviceId'] as int;
        debugPrint(
          '[SESSION_LISTENERS] Session invalidated: $userId:$deviceId',
        );
        await sessionManager.handleSessionInvalidation(userId, deviceId);
      } catch (e, stack) {
        debugPrint(
          '[SESSION_LISTENERS] Error processing sessionInvalidated: $e',
        );
        debugPrint('[SESSION_LISTENERS] Stack: $stack');
        _handleError('sessionInvalidated', e, stack);
      }
    }, registrationName: _registrationName);

    // Remote identity key changed (key rotation detected)
    socket.registerListener('identityKeyChanged', (data) async {
      try {
        final userId = data['userId'] as String;
        debugPrint('[SESSION_LISTENERS] Identity key changed: $userId');
        await sessionManager.handleIdentityKeyChange(userId);
      } catch (e, stack) {
        debugPrint(
          '[SESSION_LISTENERS] Error processing identityKeyChanged: $e',
        );
        debugPrint('[SESSION_LISTENERS] Stack: $stack');
        _handleError('identityKeyChanged', e, stack);
      }
    }, registrationName: _registrationName);

    _registered = true;
    debugPrint('[SESSION_LISTENERS] ✓ Registered 4 listeners');
  }

  /// Unregister all session/key listeners
  static Future<void> unregister() async {
    if (!_registered) return;

    final socket = SocketService.instance;
    socket.unregisterListener(
      'signalStatusResponse',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'myPreKeyIdsResponse',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'sessionInvalidated',
      registrationName: _registrationName,
    );
    socket.unregisterListener(
      'identityKeyChanged',
      registrationName: _registrationName,
    );

    _registered = false;
    debugPrint('[SESSION_LISTENERS] ✓ Unregistered');
  }

  /// Handle signalStatus response
  static Future<void> _handleSignalStatus(
    Map<String, dynamic> data,
    SignalKeyManager keyManager,
  ) async {
    // Check if keys are present
    final hasIdentity = data['hasIdentity'] as bool? ?? false;
    final hasSignedPreKey = data['hasSignedPreKey'] as bool? ?? false;
    final preKeyCount = data['preKeyCount'] as int? ?? 0;

    debugPrint(
      '[SESSION_LISTENERS] Key status - Identity: $hasIdentity, '
      'SignedPreKey: $hasSignedPreKey, PreKeys: $preKeyCount',
    );

    // If keys are missing, trigger key generation
    if (!hasIdentity || !hasSignedPreKey || preKeyCount < 10) {
      debugPrint('[SESSION_LISTENERS] Keys missing or low, triggering upload');
      await keyManager.uploadAllKeysToServer();
      debugPrint('[SESSION_LISTENERS] ✓ Key upload complete');
    } else {
      debugPrint('[SESSION_LISTENERS] ✓ All keys present and sufficient');
    }
  }

  /// Handle PreKey IDs sync response
  static Future<void> _handlePreKeyIdsSync(
    Map<String, dynamic> data,
    SignalKeyManager keyManager,
  ) async {
    final serverKeyIds = (data['preKeyIds'] as List?)?.cast<int>() ?? [];
    debugPrint('[SESSION_LISTENERS] Server has ${serverKeyIds.length} PreKeys');

    // Sync local PreKeys with server state
    await keyManager.syncPreKeyIds(serverKeyIds);
  }

  /// Handle listener errors
  static void _handleError(String listener, dynamic error, StackTrace stack) {
    debugPrint('[SESSION_LISTENERS] ✗ Error in $listener: $error');
    // TODO: Integrate with error tracking system when implemented
  }
}
