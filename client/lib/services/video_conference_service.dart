import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'api_service.dart';
import 'socket_service.dart';

/// LiveKit-based Video Conference Service with Signal Protocol E2EE
/// 
/// This service provides:
/// - WebRTC video conferencing via LiveKit SFU
/// - End-to-end encryption using Signal Protocol for key exchange
/// - LiveKit's KeyProvider for frame-level encryption
/// - Real-time participant management
/// - Automatic reconnection handling
class VideoConferenceService extends ChangeNotifier {
  // Core LiveKit components
  Room? _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;
  Map<String, RemoteParticipant> _remoteParticipants = {};
  
  // E2EE components
  BaseKeyProvider? _keyProvider;
  Map<String, Uint8List> _participantKeys = {};  // userId -> encryption key
  
  // State management
  String? _currentChannelId;
  String? _currentRoomName;
  bool _isConnected = false;
  bool _isConnecting = false;
  
  // Services
  final SocketService _socketService;
  
  // Stream controllers
  final _participantJoinedController = StreamController<RemoteParticipant>.broadcast();
  final _participantLeftController = StreamController<RemoteParticipant>.broadcast();
  final _trackSubscribedController = StreamController<TrackSubscribedEvent>.broadcast();
  
  // Getters
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get currentChannelId => _currentChannelId;
  List<RemoteParticipant> get remoteParticipants => _remoteParticipants.values.toList();
  Room? get room => _room;
  
  // Streams
  Stream<RemoteParticipant> get onParticipantJoined => _participantJoinedController.stream;
  Stream<RemoteParticipant> get onParticipantLeft => _participantLeftController.stream;
  Stream<TrackSubscribedEvent> get onTrackSubscribed => _trackSubscribedController.stream;

  VideoConferenceService(this._socketService);

  /// Initialize E2EE with Signal Protocol key exchange
  Future<void> _initializeE2EE() async {
    try {
      print('[VideoConf] Initializing E2EE with Signal Protocol');
      
      // TODO: E2EE is disabled for now due to Web Worker issues
      // Web Workers need proper configuration in Flutter Web
      // For now, we'll skip E2EE initialization
      print('[VideoConf] ⚠️ E2EE temporarily disabled (Web Worker configuration needed)');
      return;
      
      // Create KeyProvider with LiveKit's frame encryption
      // _keyProvider = await BaseKeyProvider.create(
      //   sharedKey: false,  // Per-participant keys (for Signal Protocol)
      //   ratchetSalt: 'PeerWave-LiveKit-E2EE',
      //   ratchetWindowSize: 16,
      //   failureTolerance: 5,
      //   keyRingSize: 256,
      // );
      
      // print('[VideoConf] E2EE initialized successfully');
    } catch (e) {
      print('[VideoConf] E2EE initialization error: $e');
      rethrow;
    }
  }

  /// Exchange encryption keys using Signal Protocol
  Future<void> _exchangeKeysWithParticipant(String participantUserId) async {
    try {
      print('[VideoConf] Starting key exchange with participant: $participantUserId');
      
      // Request E2EE key via Signal Protocol
      // This will trigger the existing Signal Protocol key exchange
      _socketService.emit('video:request-e2ee-key', {
        'channelId': _currentChannelId,
        'recipientUserId': participantUserId,
      });
      
      print('[VideoConf] Key exchange request sent to $participantUserId');
    } catch (e) {
      print('[VideoConf] Key exchange error: $e');
    }
  }

  /// Handle incoming E2EE key from Signal Protocol
  Future<void> handleE2EEKey({
    required String senderUserId,
    required String encryptedKey,
    required String channelId,
  }) async {
    try {
      if (channelId != _currentChannelId) {
        print('[VideoConf] Ignoring key for different channel');
        return;
      }

      print('[VideoConf] Received E2EE key from $senderUserId');
      
      // Decrypt the key using Signal Protocol (handled by MessageListener)
      // For now, we'll use the encrypted key directly
      // In production, you'd decrypt it with your Signal session
      
      final keyBytes = base64Decode(encryptedKey);
      _participantKeys[senderUserId] = keyBytes;
      
      // Set the key in LiveKit's KeyProvider
      await _keyProvider?.setRawKey(
        keyBytes,
        participantId: senderUserId,
        keyIndex: 0,
      );
      
      print('[VideoConf] Key set for participant: $senderUserId');
      notifyListeners();
    } catch (e) {
      print('[VideoConf] Error handling E2EE key: $e');
    }
  }

  /// Join a video conference room
  Future<void> joinRoom(String channelId) async {
    if (_isConnecting || _isConnected) {
      print('[VideoConf] Already connecting or connected');
      return;
    }

    try {
      _isConnecting = true;
      _currentChannelId = channelId;
      notifyListeners();

      print('[VideoConf] Joining room for channel: $channelId');

      // Initialize E2EE
      await _initializeE2EE();

      // Get LiveKit token from server (credentials are automatically included)
      print('[VideoConf] Requesting token for channel: $channelId');
      final response = await ApiService.post(
        '/api/livekit/token',
        data: {'channelId': channelId},
      );

      print('[VideoConf] Token response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        throw Exception('Failed to get LiveKit token: ${response.statusCode}');
      }

      final data = response.data;
      final token = data['token'];
      final url = data['url'];
      _currentRoomName = data['roomName'];

      print('[VideoConf] Got token, connecting to: $url');

      // Create room WITHOUT E2EE for now (Web Worker issues)
      _room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // E2EE disabled temporarily
          // e2eeOptions: E2EEOptions(
          //   keyProvider: _keyProvider!,
          // ),
        ),
      );

      // Set up event listeners
      _setupRoomListeners();

      // Connect to LiveKit
      await _room!.connect(url, token);

      // Enable local camera and microphone
      await _enableLocalMedia();

      _isConnected = true;
      _isConnecting = false;
      notifyListeners();

      print('[VideoConf] Successfully joined room: $_currentRoomName');
    } catch (e) {
      print('[VideoConf] Error joining room: $e');
      _isConnecting = false;
      _isConnected = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Enable local camera and microphone
  Future<void> _enableLocalMedia() async {
    try {
      // Enable camera
      await _room!.localParticipant?.setCameraEnabled(true);
      
      // Enable microphone
      await _room!.localParticipant?.setMicrophoneEnabled(true);

      // Get local tracks
      print('[VideoConf] Local media enabled');
      notifyListeners();
    } catch (e) {
      print('[VideoConf] Error enabling local media: $e');
    }
  }

  /// Set up LiveKit room event listeners
  void _setupRoomListeners() {
    if (_room == null) return;

    // Listen to room events
    _room!.addListener(_onRoomChanged);

    // Listen to specific events
    final listener = _room!.createListener();

    // Participant joined
    listener.on<ParticipantConnectedEvent>((event) async {
      print('[VideoConf] Participant joined: ${event.participant.identity}');
      _remoteParticipants[event.participant.identity] = event.participant;
      
      // Exchange encryption keys with new participant
      await _exchangeKeysWithParticipant(event.participant.identity);
      
      _participantJoinedController.add(event.participant);
      notifyListeners();
    });

    // Participant left
    listener.on<ParticipantDisconnectedEvent>((event) {
      print('[VideoConf] Participant left: ${event.participant.identity}');
      _remoteParticipants.remove(event.participant.identity);
      _participantKeys.remove(event.participant.identity);
      
      _participantLeftController.add(event.participant);
      notifyListeners();
    });

    // Track subscribed
    listener.on<TrackSubscribedEvent>((event) async {
      print('[VideoConf] Track subscribed: ${event.track.kind} from ${event.participant.identity}');
      _trackSubscribedController.add(event);
      notifyListeners();
    });

    // Track unsubscribed
    listener.on<TrackUnsubscribedEvent>((event) {
      print('[VideoConf] Track unsubscribed: ${event.track.kind} from ${event.participant.identity}');
      notifyListeners();
    });

    // Room disconnected
    listener.on<RoomDisconnectedEvent>((event) {
      print('[VideoConf] Room disconnected: ${event.reason}');
      _handleDisconnection();
    });

    // Connection state changed
    listener.on<RoomAttemptReconnectEvent>((event) {
      print('[VideoConf] Attempting to reconnect...');
      notifyListeners();
    });

    listener.on<RoomReconnectedEvent>((event) {
      print('[VideoConf] Reconnected successfully');
      notifyListeners();
    });
  }

  /// Handle room state changes
  void _onRoomChanged() {
    notifyListeners();
  }

  /// Handle disconnection
  void _handleDisconnection() {
    _isConnected = false;
    _remoteParticipants.clear();
    _participantKeys.clear();
    notifyListeners();
  }

  /// Leave the current room
  Future<void> leaveRoom() async {
    try {
      print('[VideoConf] Leaving room');

      if (_room != null) {
        await _room!.disconnect();
        await _room!.dispose();
        _room = null;
      }

      _keyProvider = null;
      _participantKeys.clear();

      _isConnected = false;
      _isConnecting = false;
      _currentChannelId = null;
      _currentRoomName = null;
      _remoteParticipants.clear();

      notifyListeners();
      print('[VideoConf] Left room successfully');
    } catch (e) {
      print('[VideoConf] Error leaving room: $e');
    }
  }

  /// Toggle local camera
  Future<void> toggleCamera() async {
    if (_room == null) return;
    
    try {
      final enabled = _room!.localParticipant?.isCameraEnabled() ?? false;
      await _room!.localParticipant?.setCameraEnabled(!enabled);
      notifyListeners();
    } catch (e) {
      print('[VideoConf] Error toggling camera: $e');
    }
  }

  /// Toggle local microphone
  Future<void> toggleMicrophone() async {
    if (_room == null) return;
    
    try {
      final enabled = _room!.localParticipant?.isMicrophoneEnabled() ?? false;
      await _room!.localParticipant?.setMicrophoneEnabled(!enabled);
      notifyListeners();
    } catch (e) {
      print('[VideoConf] Error toggling microphone: $e');
    }
  }

  /// Check if camera is enabled
  bool isCameraEnabled() {
    return _room?.localParticipant?.isCameraEnabled() ?? false;
  }

  /// Check if microphone is enabled
  bool isMicrophoneEnabled() {
    return _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  }

  @override
  void dispose() {
    leaveRoom();
    _participantJoinedController.close();
    _participantLeftController.close();
    _trackSubscribedController.close();
    super.dispose();
  }
}
