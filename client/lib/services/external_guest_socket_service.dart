import 'package:flutter/foundation.dart' show debugPrint;
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../web_config.dart';

/// Socket service for external guests connecting to /external namespace
///
/// Key differences from main SocketService:
/// - Connects to /external namespace (not root)
/// - Authenticates with session_id + token (not HMAC)
/// - No device management or user UUID
/// - Rate limited to 100 messages per minute
class ExternalGuestSocketService {
  static final ExternalGuestSocketService _instance =
      ExternalGuestSocketService._internal();
  factory ExternalGuestSocketService() => _instance;
  ExternalGuestSocketService._internal();

  io.Socket? _socket;
  final Map<String, List<void Function(dynamic)>> _listeners = {};
  bool _connecting = false;
  bool _connected = false;

  String? _sessionId;
  String? _meetingId;

  // DEPRECATED: _registeredMeetingEvents removed - was only used by deprecated plaintext handlers

  /// Public getter for connection status
  bool get isConnected => _connected && (_socket?.connected ?? false);

  /// DEPRECATED: Old plaintext E2EE key response listener - DO NOT USE
  /// Use onParticipantE2EEKeySignal() with Signal Protocol instead
  @Deprecated(
    'Use onParticipantE2EEKeySignal() for encrypted Signal Protocol communication',
  )
  void onParticipantE2EEKeyForMeeting(
    String meetingId,
    void Function(Map<String, dynamic>) callback,
  ) {
    debugPrint(
      '[GUEST SOCKET] ⚠️ DEPRECATED: onParticipantE2EEKeyForMeeting called - this is insecure!',
    );
    debugPrint(
      '[GUEST SOCKET] ⚠️ Use onParticipantE2EEKeySignal() instead for Signal Protocol encryption',
    );
    // COMMENTED OUT - DO NOT USE PLAINTEXT KEY EXCHANGE
    // if (_socket == null) {
    //   debugPrint('[GUEST SOCKET] Cannot register listener - not connected');
    //   return;
    // }
    //
    // final eventName = 'guest:response_e2ee_key:$meetingId';
    // if (_registeredMeetingEvents.contains(eventName)) {
    //   debugPrint('[GUEST SOCKET] Listener for $eventName already registered');
    //   return;
    // }
    //
    // _socket!.on(eventName, (data) {
    //   debugPrint('[GUEST SOCKET] Received E2EE key response: $data');
    //   if (data is Map<String, dynamic>) {
    //     callback(data);
    //   }
    // });
    //
    // _registeredMeetingEvents.add(eventName);
    // debugPrint('[GUEST SOCKET] Registered listener for $eventName');
  }

  /// Connect to /external namespace with guest credentials
  Future<void> connect({
    required String sessionId,
    required String token,
    required String meetingId,
  }) async {
    if (_socket != null && _socket!.connected) {
      debugPrint('[GUEST SOCKET] Already connected');
      return;
    }
    if (_connecting) {
      debugPrint('[GUEST SOCKET] Connection already in progress');
      return;
    }

    _connecting = true;
    _sessionId = sessionId;
    _meetingId = meetingId;

    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }

      // Connect to /external namespace
      final namespace = '$urlString/external';
      debugPrint('[GUEST SOCKET] Connecting to namespace: $namespace');

      _socket = io.io(namespace, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
        'reconnection': true,
        'reconnectionDelay': 2000,
        'reconnectionAttempts': 10,
        'auth': {
          'session_id': sessionId,
          'token': token,
          'meeting_id': meetingId,
        },
      });

      _socket!.on('connect', (_) {
        debugPrint('[GUEST SOCKET] Connected to /external namespace');
        _connected = true;
        _connecting = false;
      });

      _socket!.on('authenticated', (data) {
        debugPrint('[GUEST SOCKET] Authentication response: $data');
        if (data is Map && data['success'] == true) {
          _sessionId = data['session_id'] as String?;
          _meetingId = data['meeting_id'] as String?;
          debugPrint(
            '[GUEST SOCKET] ✓ Successfully authenticated as guest (session: $_sessionId)',
          );
        } else {
          debugPrint('[GUEST SOCKET] ✗ Authentication failed: $data');
          _connected = false;
          disconnect();
        }
      });

      _socket!.on('disconnect', (reason) {
        debugPrint('[GUEST SOCKET] Disconnected: $reason');
        _connected = false;
        _connecting = false;
      });

      _socket!.on('reconnect', (attemptNumber) {
        debugPrint('[GUEST SOCKET] Reconnected after $attemptNumber attempts');
        _connected = true;
      });

      _socket!.on('reconnect_attempt', (attemptNumber) {
        debugPrint('[GUEST SOCKET] Reconnection attempt $attemptNumber');
      });

      _socket!.on('error', (error) {
        debugPrint('[GUEST SOCKET] Error: $error');
        _connecting = false;
        if (error is Map &&
            error['message']?.toString().contains('Invalid session') == true) {
          debugPrint('[GUEST SOCKET] Session expired or invalid');
          _connected = false;
          disconnect();
        }
      });

      _socket!.on('session_expired', (_) {
        debugPrint('[GUEST SOCKET] Session expired (24h limit)');
        _connected = false;
        disconnect();
      });

      _socket!.on('rate_limit_exceeded', (_) {
        debugPrint('[GUEST SOCKET] ⚠️ Rate limit exceeded (100 msg/min)');
      });

      // Register all pre-existing listeners
      _listeners.forEach((event, callbacks) {
        for (var cb in callbacks) {
          _socket!.on(event, cb);
        }
      });

      // Connect
      _socket!.connect();
    } catch (e) {
      debugPrint('[GUEST SOCKET] Connection error: $e');
      _connecting = false;
      _connected = false;
      rethrow;
    }
  }

  /// Disconnect from /external namespace
  void disconnect() {
    debugPrint('[GUEST SOCKET] Disconnecting...');
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _connected = false;
    _connecting = false;
    _sessionId = null;
    _meetingId = null;
    _listeners.clear();
  }

  /// Register event listener
  void on(String event, void Function(dynamic) callback) {
    if (!_listeners.containsKey(event)) {
      _listeners[event] = [];
    }
    _listeners[event]!.add(callback);

    // If socket is already connected, register immediately
    if (_socket != null) {
      _socket!.on(event, callback);
    }
  }

  /// Remove event listener
  void off(String event, [void Function(dynamic)? callback]) {
    if (callback != null) {
      _listeners[event]?.remove(callback);
      _socket?.off(event, callback);
    } else {
      _listeners.remove(event);
      _socket?.off(event);
    }
  }

  /// Emit event to server
  void emit(String event, [dynamic data]) {
    if (_socket == null || !_socket!.connected) {
      debugPrint('[GUEST SOCKET] Cannot emit - not connected');
      return;
    }
    _socket!.emit(event, data);
  }

  /// Send Signal message to participant (broadcast to meeting room)
  void sendSignalMessageToParticipant(
    String participantUserId,
    Map<String, dynamic> signalMessage,
  ) {
    emit('guest:signal_message', {
      'target_user_id': participantUserId,
      'message': signalMessage,
    });
    debugPrint(
      '[GUEST SOCKET] Sent Signal message to participant: $participantUserId',
    );
  }

  /// DEPRECATED: Request E2EE key via insecure plaintext - DO NOT USE
  /// Use requestE2EEKeySignal() with Signal Protocol instead
  @Deprecated(
    'Use requestE2EEKeySignal() for encrypted Signal Protocol communication',
  )
  void requestE2EEKey(String displayName) {
    debugPrint(
      '[GUEST SOCKET] ⚠️ DEPRECATED: requestE2EEKey called - this is insecure!',
    );
    debugPrint(
      '[GUEST SOCKET] ⚠️ Use requestE2EEKeySignal() instead for Signal Protocol encryption',
    );
    // COMMENTED OUT - DO NOT USE PLAINTEXT KEY EXCHANGE
    // if (_sessionId == null || _meetingId == null) {
    //   debugPrint('[GUEST SOCKET] Cannot request key - no session ID or meeting ID');
    //   return;
    // }
    //
    // final eventName = 'guest:request_e2ee_key:$_meetingId';
    // emit(eventName, {
    //   'session_id': _sessionId,
    //   'display_name': displayName,
    //   'request_id': '${_sessionId}_${DateTime.now().millisecondsSinceEpoch}',
    //   // Note: participant_user_id and participant_device_id are optional
    //   // Server will broadcast to all participants in the meeting
    // });
    // debugPrint('[GUEST SOCKET] Emitted $eventName to all participants');
  }

  /// Listen for participant Signal messages (direct to guest room)
  void onParticipantSignalMessage(
    void Function(Map<String, dynamic>) callback,
  ) {
    on('participant:signal_message_to_guest', (data) {
      if (data is Map<String, dynamic>) {
        callback(data);
      }
    });
  }

  /// DEPRECATED: Listen for participant E2EE key responses via insecure plaintext - DO NOT USE
  /// Use onParticipantE2EEKeySignal() with Signal Protocol instead
  @Deprecated(
    'Use onParticipantE2EEKeySignal() for encrypted Signal Protocol communication',
  )
  void onParticipantE2EEKey(void Function(Map<String, dynamic>) callback) {
    debugPrint(
      '[GUEST SOCKET] ⚠️ DEPRECATED: onParticipantE2EEKey called - this is insecure!',
    );
    debugPrint(
      '[GUEST SOCKET] ⚠️ Use onParticipantE2EEKeySignal() instead for Signal Protocol encryption',
    );
    // COMMENTED OUT - DO NOT USE PLAINTEXT KEY EXCHANGE
    // on('participant:send_e2ee_key_to_guest', (data) {
    //   if (data is Map<String, dynamic>) {
    //     callback(data);
    //   }
    // });
  }

  /// NEW: Listen for Signal Protocol encrypted E2EE key responses
  /// Participant sends LiveKit E2EE key encrypted with Signal Protocol
  void onParticipantE2EEKeySignal(
    void Function(Map<String, dynamic>) callback,
  ) {
    on('participant:meeting_e2ee_key_response', (data) {
      if (data is Map<String, dynamic>) {
        debugPrint(
          '[GUEST SOCKET] Received Signal-encrypted E2EE key from ${data['participant_user_id']}:${data['participant_device_id']}',
        );
        callback(data);
      }
    });
  }

  /// Request E2EE key from participants via Signal Protocol
  /// Guest encrypts request with Signal and broadcasts to meeting participants
  void requestE2EEKeySignal({
    required String participantUserId,
    required int participantDeviceId,
    required String ciphertext,
    required int messageType,
  }) {
    if (_sessionId == null || _meetingId == null) {
      debugPrint(
        '[GUEST SOCKET] Cannot request key - no session ID or meeting ID',
      );
      return;
    }

    emit('guest:meeting_e2ee_key_request', {
      'participant_user_id': participantUserId,
      'participant_device_id': participantDeviceId,
      'ciphertext': ciphertext,
      'messageType': messageType,
      'request_id': '${_sessionId}_${DateTime.now().millisecondsSinceEpoch}',
    });
    debugPrint(
      '[GUEST SOCKET] Sent Signal E2EE key request to $participantUserId:$participantDeviceId',
    );
  }

  /// Listen for admission granted event
  void onAdmissionGranted(void Function(Map<String, dynamic>) callback) {
    on('meeting:admission_granted', (data) {
      if (data is Map<String, dynamic>) {
        callback(data);
      }
    });
  }

  /// Listen for admission denied event
  void onAdmissionDenied(void Function(Map<String, dynamic>) callback) {
    on('meeting:admission_denied', (data) {
      if (data is Map<String, dynamic>) {
        callback(data);
      }
    });
  }
}
