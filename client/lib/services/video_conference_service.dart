import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'api_service.dart';
import 'signal_service.dart';

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
  Uint8List? _channelSharedKey;  // ONE shared key for the entire channel
  Map<String, Uint8List> _participantKeys = {};  // userId -> encryption key (legacy, for backward compat)
  
  // State management
  String? _currentChannelId;
  String? _currentRoomName;
  bool _isConnected = false;
  bool _isConnecting = false;
  
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

  VideoConferenceService();

  /// Initialize E2EE with Signal Protocol key exchange
  Future<void> _initializeE2EE() async {
    try {
      print('[VideoConf] Initializing E2EE with Signal Protocol');
      
      // Generate ONE shared key for this channel
      // The first participant generates, others receive it via Signal Protocol
      final random = Random.secure();
      _channelSharedKey = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256))
      );
      
      // Create BaseKeyProvider with the compiled e2ee.worker.dart.js
      try {
        _keyProvider = await BaseKeyProvider.create();
        
        // Set the shared key in KeyProvider
        final keyBase64 = base64Encode(_channelSharedKey!);
        await _keyProvider!.setKey(keyBase64);
        
        print('[VideoConf] ✓ BaseKeyProvider created with e2ee.worker.dart.js');
        print('[VideoConf] ✓ Shared encryption key set (32 bytes AES-256)');
      } catch (e) {
        print('[VideoConf] ⚠️ Failed to create BaseKeyProvider: $e');
        print('[VideoConf] ⚠️ Falling back to transport encryption only');
        _keyProvider = null;
      }
      
      print('[VideoConf] ✓ E2EE initialized with shared channel key');
    } catch (e) {
      print('[VideoConf] E2EE initialization error: $e');
      rethrow;
    }
  }

  /// Exchange encryption keys using Signal Protocol
  /// Sends the SHARED CHANNEL KEY to new participants via Signal Protocol
  /// Uses sendGroupItem for E2EE transport layer
  Future<void> _exchangeKeysWithParticipant(String participantUserId) async {
    try {
      if (_channelSharedKey == null || _currentChannelId == null) {
        print('[VideoConf] ⚠️ Key or channel not initialized, skipping key exchange');
        return;
      }

      // Check if we're the first participant (room creator)
      final isFirstParticipant = _remoteParticipants.isEmpty || 
                                  _remoteParticipants.length == 1;
      
      final itemId = 'video_key_${DateTime.now().millisecondsSinceEpoch}';
      
      if (!isFirstParticipant) {
        print('[VideoConf] Not first participant, requesting key from $participantUserId');
        
        // Send key request via Signal Protocol (encrypted group message)
        await SignalService.instance.sendGroupItem(
          channelId: _currentChannelId!,
          message: jsonEncode({
            'type': 'video_key_request',
            'requesterId': participantUserId,
          }),
          itemId: itemId,
          type: 'video_key_request',
        );
        return;
      }

      print('[VideoConf] First participant - sending shared key to: $participantUserId');
      
      // Send the shared key via Signal Protocol (encrypted group message)
      final keyBase64 = base64Encode(_channelSharedKey!);
      
      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'type': 'video_key_response',
          'targetUserId': participantUserId,
          'encryptedKey': keyBase64,
        }),
        itemId: itemId,
        type: 'video_key_response',
      );
      
      print('[VideoConf] ✓ Shared key sent via Signal Protocol (${_channelSharedKey!.length} bytes)');
      print('[VideoConf] ✓ Key will enable frame-level encryption for all participants');
      
    } catch (e) {
      print('[VideoConf] Key exchange error: $e');
    }
  }

  /// Handle incoming E2EE key from Signal Protocol
  /// Receives the SHARED CHANNEL KEY from existing participants
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

      // If encryptedKey is empty, this is a KEY REQUEST, not a response
      if (encryptedKey.isEmpty) {
        print('[VideoConf] Received key request from $senderUserId (sending our key)');
        await handleKeyRequest(senderUserId);
        return;
      }

      print('[VideoConf] Received shared channel key from $senderUserId');
      
      // Decode the shared channel key
      final keyBytes = base64Decode(encryptedKey);
      
      // ONLY accept the key if we don't already have one OR if we're not the first participant
      // This prevents overwriting the authoritative key
      if (_channelSharedKey == null || _remoteParticipants.length > 1) {
        _channelSharedKey = keyBytes;
        
        // Set the key in BaseKeyProvider if available
        if (_keyProvider != null) {
          try {
            final keyBase64 = base64Encode(_channelSharedKey!);
            await _keyProvider!.setKey(keyBase64);
            print('[VideoConf] ✓ Shared channel key accepted and set in KeyProvider');
            print('[VideoConf] ✓ Frame-level E2EE now active with received key');
          } catch (e) {
            print('[VideoConf] ⚠️ Failed to set key in KeyProvider: $e');
          }
        } else {
          print('[VideoConf] ✓ Shared channel key stored (KeyProvider not available)');
          print('[VideoConf] ⚠️ Frame encryption unavailable without BaseKeyProvider');
        }
      } else {
        print('[VideoConf] ⚠️ Ignoring key from $senderUserId (we are first participant with authoritative key)');
      }
      
      notifyListeners();
    } catch (e) {
      print('[VideoConf] Error handling E2EE key: $e');
    }
  }

  /// Handle incoming key request from another participant
  /// Send our SHARED CHANNEL KEY to them via Signal Protocol
  Future<void> handleKeyRequest(String requesterId) async {
    try {
      if (_channelSharedKey == null || _currentChannelId == null) {
        print('[VideoConf] ⚠️ Key not initialized, cannot respond to key request');
        return;
      }

      print('[VideoConf] Received key request from $requesterId');
      
      // Send our SHARED CHANNEL KEY (not a new key!) via Signal Protocol
      final keyBase64 = base64Encode(_channelSharedKey!);
      final itemId = 'video_key_response_${DateTime.now().millisecondsSinceEpoch}';
      
      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'type': 'video_key_response',
          'targetUserId': requesterId,
          'encryptedKey': keyBase64,
        }),
        itemId: itemId,
        type: 'video_key_response',
      );
      
      print('[VideoConf] ✓ Sent shared channel key to $requesterId via Signal Protocol');
    } catch (e) {
      print('[VideoConf] Error handling key request: $e');
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

      // Request media permissions BEFORE creating room
      print('[VideoConf] Requesting camera and microphone permissions...');
      LocalVideoTrack? videoTrack;
      LocalAudioTrack? audioTrack;
      
      try {
        videoTrack = await LocalVideoTrack.createCameraTrack();
        print('[VideoConf] ✓ Camera track created');
      } catch (e) {
        print('[VideoConf] ⚠️ Failed to create camera track: $e');
      }
      
      try {
        audioTrack = await LocalAudioTrack.create(AudioCaptureOptions());
        print('[VideoConf] ✓ Microphone track created');
      } catch (e) {
        print('[VideoConf] ⚠️ Failed to create audio track: $e');
      }

      // Create room WITH E2EE if BaseKeyProvider initialized successfully
      _room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // Enable E2EE with compiled e2ee.worker.dart.js
          e2eeOptions: _keyProvider != null 
            ? E2EEOptions(keyProvider: _keyProvider!) 
            : null,
        ),
      );
      
      if (_keyProvider != null) {
        print('[VideoConf] ✓ Room created with E2EE enabled (AES-256 frame encryption)');
        print('[VideoConf] ✓ Using compiled e2ee.worker.dart.js for frame processing');
      } else {
        print('[VideoConf] ✓ Room created (DTLS/SRTP transport encryption only)');
        print('[VideoConf] ⚠️ Frame-level E2EE unavailable (BaseKeyProvider failed)');
      }

      // Set up event listeners
      _setupRoomListeners();

      // Connect to LiveKit room
      print('[VideoConf] Connecting to LiveKit room...');
      await _room!.connect(
        url, 
        token,
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // Apply same E2EE options on connect
          e2eeOptions: _keyProvider != null 
            ? E2EEOptions(keyProvider: _keyProvider!) 
            : null,
        ),
      );

      // Publish local tracks if available
      if (videoTrack != null) {
        print('[VideoConf] Publishing video track...');
        await _room!.localParticipant?.publishVideoTrack(videoTrack);
      }
      
      if (audioTrack != null) {
        print('[VideoConf] Publishing audio track...');
        await _room!.localParticipant?.publishAudioTrack(audioTrack);
      }

      // Add existing remote participants to map (for users who joined before us)
      print('[VideoConf] Checking for existing participants...');
      for (final participant in _room!.remoteParticipants.values) {
        print('[VideoConf] Found existing participant: ${participant.identity}');
        _remoteParticipants[participant.identity] = participant;
        
        // Exchange keys with existing participants
        await _exchangeKeysWithParticipant(participant.identity);
      }
      print('[VideoConf] Total remote participants: ${_remoteParticipants.length}');

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
      print('[VideoConf]   - Track SID: ${event.track.sid}');
      print('[VideoConf]   - Track muted: ${event.track.muted}');
      _trackSubscribedController.add(event);
      notifyListeners();
    });

    // Track unsubscribed
    listener.on<TrackUnsubscribedEvent>((event) {
      print('[VideoConf] Track unsubscribed: ${event.track.kind} from ${event.participant.identity}');
      notifyListeners();
    });

    // Track published (important for seeing when tracks become available)
    listener.on<TrackPublishedEvent>((event) {
      print('[VideoConf] Track published: ${event.publication.kind} from ${event.participant.identity}');
      print('[VideoConf]   - Track SID: ${event.publication.sid}');
      notifyListeners();
    });

    // Track unpublished
    listener.on<TrackUnpublishedEvent>((event) {
      print('[VideoConf] Track unpublished: ${event.publication.kind} from ${event.participant.identity}');
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

      _participantKeys.clear();
      _channelSharedKey = null;

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
