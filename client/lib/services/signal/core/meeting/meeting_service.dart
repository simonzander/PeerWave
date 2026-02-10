import 'package:flutter/foundation.dart';

import '../../../api_service.dart';
import '../../../socket_service.dart'
    if (dart.library.io) '../../../socket_service_native.dart';
import '../encryption_service.dart';
import '../key_manager.dart';
import '../session_manager.dart';

// Import mixins
import 'mixins/meeting_key_handler_mixin.dart';
import 'mixins/guest_session_mixin.dart';

/// Meeting E2EE Service
///
/// Unified service for meeting end-to-end encryption using mixin-based architecture:
/// - MeetingKeyHandlerMixin: Meeting E2EE key request/response handling
/// - GuestSessionMixin: Guest session management and sender key distribution
///
/// Dependencies:
/// - EncryptionService: For crypto stores
/// - ApiService: For HTTP API calls (server-scoped)
/// - SocketService: For WebSocket operations (server-scoped)
///
/// Usage:
/// ```dart
/// final meetingService = MeetingService(
///   encryptionService: encryptionService,
///   apiService: apiService,
///   socketService: socketService,
///   getCurrentUserId: () => userId,
///   getCurrentDeviceId: () => deviceId,
/// );
/// ```
class MeetingService with MeetingKeyHandlerMixin, GuestSessionMixin {
  final EncryptionService encryptionService;
  final ApiService apiService;
  final SocketService socketService;
  final String? Function() getCurrentUserId;
  final int? Function() getCurrentDeviceId;

  // Delegate to EncryptionService for stores
  @override
  SessionManager get sessionStore => encryptionService.sessionStore;

  @override
  SignalKeyManager get preKeyStore => encryptionService.preKeyStore;

  @override
  SignalKeyManager get signedPreKeyStore => encryptionService.signedPreKeyStore;

  @override
  SignalKeyManager get identityStore => encryptionService.identityStore;

  @override
  SignalKeyManager get senderKeyStore => encryptionService.senderKeyStore;

  MeetingService({
    required this.encryptionService,
    required this.apiService,
    required this.socketService,
    required this.getCurrentUserId,
    required this.getCurrentDeviceId,
  }) {
    debugPrint('[MEETING_SERVICE] Initialized');
  }

  /// Dispose resources
  void dispose() {
    debugPrint('[MEETING_SERVICE] Disposed');
  }
}
