import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'api_service.dart';
import 'signal_service.dart';
import 'socket_service.dart';
import 'message_listener_service.dart';

/// LiveKit-based Video Conference Service with Signal Protocol E2EE
/// 
/// This service provides:
/// - WebRTC video conferencing via LiveKit SFU
/// - End-to-end encryption using Signal Protocol for key exchange
/// - LiveKit's KeyProvider for frame-level encryption
/// - Real-time participant management
/// - Automatic reconnection handling
class VideoConferenceService extends ChangeNotifier {
  // Singleton pattern
  static final VideoConferenceService _instance = VideoConferenceService._internal();
  static VideoConferenceService get instance => _instance;
  
  VideoConferenceService._internal();
  
  // Factory constructor returns singleton
  factory VideoConferenceService() => _instance;
  
  // Core LiveKit components
  Room? _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;
  Map<String, RemoteParticipant> _remoteParticipants = {};
  
  // E2EE components
  BaseKeyProvider? _keyProvider;
  Uint8List? _channelSharedKey;  // ONE shared key for the entire channel
  int? _keyTimestamp;  // Timestamp of current key (for race condition resolution)
  Map<String, Uint8List> _participantKeys = {};  // userId -> encryption key (legacy, for backward compat)
  Completer<bool>? _keyReceivedCompleter;  // For waiting on key exchange in PreJoin
  bool _isFirstParticipant = false;  // Track if this participant originated the key
  
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
  bool get isFirstParticipant => _isFirstParticipant;  // Check if this participant originated the key
  
  // Streams
  Stream<RemoteParticipant> get onParticipantJoined => _participantJoinedController.stream;
  Stream<RemoteParticipant> get onParticipantLeft => _participantLeftController.stream;
  Stream<TrackSubscribedEvent> get onTrackSubscribed => _trackSubscribedController.stream;

  /// Request E2EE Key from existing participants (called by NON-first participants from PreJoin)
  /// This is a static method so PreJoin screen can call it before joining
  /// Returns true if key was received successfully, false otherwise
  static Future<bool> requestE2EEKey(String channelId) async {
    final service = VideoConferenceService.instance;
    
    try {
      print('═══════════════════════════════════════════════════════════');
      print('[VideoConf][TEST] 🔑 REQUESTING E2EE KEY');
      print('[VideoConf][TEST] Channel: $channelId');
      
      // ⚠️ CRITICAL: Set channel ID so response handler knows which channel this is for
      service._currentChannelId = channelId;
      print('[VideoConf][TEST] ✓ Channel ID set on service instance');
      
      // ⚠️ CRITICAL: Register this service instance with MessageListenerService
      // so it receives E2EE key responses
      print('[VideoConf][TEST] 📝 Registering service with MessageListenerService...');
      final messageListener = MessageListenerService.instance;
      messageListener.registerVideoConferenceService(service);
      print('[VideoConf][TEST] ✓ Service registered, ready to receive key responses');
      
      final requestTimestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Get current user ID from SignalService
      final userId = SignalService.instance.currentUserId ?? 'unknown';
      
      print('[VideoConf][TEST] Requester ID: $userId');
      print('[VideoConf][TEST] Request Timestamp: $requestTimestamp');
      print('[VideoConf][TEST] Message Type: video_e2ee_key_request');
      
      // ⚠️ IMPORTANT: Initialize sender key BEFORE sending request
      // WebRTC channels use Signal Protocol for E2EE key exchange
      // First message in a fresh channel needs sender key initialization
      print('[VideoConf][TEST] 🔧 Initializing sender key for channel...');
      try {
        await SignalService.instance.createGroupSenderKey(channelId);
        print('[VideoConf][TEST] ✓ Sender key initialized');
      } catch (e) {
        // Sender key might already exist - that's OK
        if (e.toString().contains('already exists')) {
          print('[VideoConf][TEST] ℹ️ Sender key already exists (OK)');
        } else {
          print('[VideoConf][TEST] ⚠️ Sender key init error (continuing): $e');
        }
      }
      
      // Send key request via Signal Protocol (encrypted group message)
      await SignalService.instance.sendGroupItem(
        channelId: channelId,
        message: jsonEncode({
          'requesterId': userId,
          'timestamp': requestTimestamp,
        }),
        itemId: 'video_key_req_$requestTimestamp',
        type: 'video_e2ee_key_request', // NEW itemType!
      );
      
      print('[VideoConf][TEST] ✓ Key request sent via Signal Protocol');
      print('[VideoConf][TEST] ⏳ Waiting for key response (10 second timeout)...');
      
      // Wait for key response (handled by MessageListenerService)
      service._keyReceivedCompleter = Completer<bool>();
      
      // Timeout after 10 seconds
      return await service._keyReceivedCompleter!.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          print('[VideoConf][TEST] ❌ KEY REQUEST TIMEOUT - No response in 10 seconds');
          print('═══════════════════════════════════════════════════════════');
          return false;
        },
      );
    } catch (e) {
      print('[VideoConf][TEST] ❌ ERROR requesting E2EE key: $e');
      print('═══════════════════════════════════════════════════════════');
      return false;
    }
  }

  /// Initialize E2EE with Signal Protocol key exchange
  Future<void> _initializeE2EE() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('[VideoConf][TEST] 🔐 INITIALIZING E2EE (FIRST PARTICIPANT)');
      
      // Generate ONE shared key for this channel
      // The first participant generates, others receive it via Signal Protocol
      final random = Random.secure();
      _channelSharedKey = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256))
      );
      
      // Store timestamp for race condition resolution (oldest wins)
      _keyTimestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Mark this participant as the key originator (first participant)
      _isFirstParticipant = true;
      
      final keyBase64 = base64Encode(_channelSharedKey!);
      final keyPreview = keyBase64.substring(0, 16);
      
      print('[VideoConf][TEST] Key Generated: $keyPreview... (${_channelSharedKey!.length} bytes)');
      print('[VideoConf][TEST] Key Timestamp: $_keyTimestamp');
      print('[VideoConf][TEST] Is First Participant: $_isFirstParticipant');
      
      // ⚠️ IMPORTANT: Initialize sender key for responding to key requests
      // First participant needs sender key to send key responses to new joiners
      if (_currentChannelId != null) {
        print('[VideoConf][TEST] 🔧 Initializing sender key for channel...');
        try {
          await SignalService.instance.createGroupSenderKey(_currentChannelId!);
          print('[VideoConf][TEST] ✓ Sender key initialized (ready to respond to key requests)');
        } catch (e) {
          // Sender key might already exist - that's OK
          if (e.toString().contains('already exists')) {
            print('[VideoConf][TEST] ℹ️ Sender key already exists (OK)');
          } else {
            print('[VideoConf][TEST] ⚠️ Sender key init error (continuing): $e');
          }
        }
      }
      
      // Create BaseKeyProvider with the compiled e2ee.worker.dart.js
      try {
        _keyProvider = await BaseKeyProvider.create();
        
        // Set the shared key in KeyProvider
        await _keyProvider!.setKey(keyBase64);
        
        print('[VideoConf][TEST] ✓ BaseKeyProvider created with e2ee.worker.dart.js');
        print('[VideoConf][TEST] ✓ Key set in KeyProvider (AES-256 frame encryption ready)');
      } catch (e) {
        print('[VideoConf][TEST] ⚠️ Failed to create BaseKeyProvider: $e');
        print('[VideoConf][TEST] ⚠️ Falling back to DTLS/SRTP transport encryption only');
        _keyProvider = null;
      }
      
      print('[VideoConf][TEST] ✓ E2EE INITIALIZATION COMPLETE');
      print('[VideoConf][TEST] ✓ Role: KEY ORIGINATOR (first participant)');
      print('═══════════════════════════════════════════════════════════');
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
    required int timestamp,  // For race condition resolution
  }) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE');
      print('[VideoConf][TEST] Sender: $senderUserId');
      print('[VideoConf][TEST] Channel: $channelId');
      print('[VideoConf][TEST] Timestamp: $timestamp');
      print('[VideoConf][TEST] Current Channel: $_currentChannelId');
      print('[VideoConf][TEST] Current Timestamp: $_keyTimestamp');
      
      if (channelId != _currentChannelId) {
        print('[VideoConf][TEST] ❌ Ignoring key for different channel');
        print('═══════════════════════════════════════════════════════════');
        return;
      }

      // If encryptedKey is empty, this is a KEY REQUEST, not a response
      if (encryptedKey.isEmpty) {
        print('[VideoConf][TEST] 📩 This is a KEY REQUEST from $senderUserId');
        print('[VideoConf][TEST] 🔄 Sending our key in response...');
        print('═══════════════════════════════════════════════════════════');
        await handleKeyRequest(senderUserId);
        return;
      }

      print('[VideoConf][TEST] 🔑 This is a KEY RESPONSE');
      
      // RACE CONDITION RESOLUTION: Compare timestamps (oldest wins)
      if (_keyTimestamp != null && timestamp > _keyTimestamp!) {
        print('[VideoConf][TEST] ⚠️ RACE CONDITION DETECTED!');
        print('[VideoConf][TEST] Our timestamp: $_keyTimestamp (older)');
        print('[VideoConf][TEST] Received timestamp: $timestamp (newer)');
        print('[VideoConf][TEST] ✓ REJECTING NEWER KEY - Keeping our older key');
        print('[VideoConf][TEST] Rule: Oldest timestamp wins!');
        print('═══════════════════════════════════════════════════════════');
        return;
      }
      
      // Decode the shared channel key
      final keyBytes = base64Decode(encryptedKey);
      final keyBase64 = base64Encode(keyBytes);
      final keyPreview = keyBase64.substring(0, 16);
      
      print('[VideoConf][TEST] 📦 Decoding received key...');
      print('[VideoConf][TEST] Key Preview: $keyPreview... (${keyBytes.length} bytes)');
      
      // Accept the key and update timestamp
      _channelSharedKey = keyBytes;
      _keyTimestamp = timestamp;
      _isFirstParticipant = false;  // We received the key, so we're NOT the first participant
      
      print('[VideoConf][TEST] ✓ KEY ACCEPTED');
      print('[VideoConf][TEST] Updated Timestamp: $_keyTimestamp');
      print('[VideoConf][TEST] Is First Participant: $_isFirstParticipant');
      
      // Set the key in BaseKeyProvider if available
      if (_keyProvider != null) {
        try {
          await _keyProvider!.setKey(keyBase64);
          print('[VideoConf][TEST] ✓ Key set in BaseKeyProvider (KeyProvider available)');
          print('[VideoConf][TEST] ✓ Frame-level AES-256 E2EE now ACTIVE');
          print('[VideoConf][TEST] ✓ Role: KEY RECEIVER (non-first participant)');
        } catch (e) {
          print('[VideoConf][TEST] ❌ Failed to set key in KeyProvider: $e');
        }
      } else {
        print('[VideoConf][TEST] ⚠️ KeyProvider not available - frame encryption disabled');
        print('[VideoConf][TEST] ⚠️ Only DTLS/SRTP transport encryption active');
      }
      
      // Complete the key received completer if PreJoin is waiting
      if (_keyReceivedCompleter != null && !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.complete(true);
        print('[VideoConf][TEST] ✓ PreJoin screen notified - key exchange complete!');
      }
      
      print('[VideoConf][TEST] ✅ KEY EXCHANGE SUCCESSFUL');
      print('═══════════════════════════════════════════════════════════');
      
      notifyListeners();
    } catch (e) {
      print('[VideoConf][TEST] ❌ ERROR handling E2EE key: $e');
      print('═══════════════════════════════════════════════════════════');
      // Complete with error if PreJoin is waiting
      if (_keyReceivedCompleter != null && !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.completeError(e);
      }
    }
  }

  /// Handle incoming key request from another participant
  /// Send our SHARED CHANNEL KEY to them via Signal Protocol
  Future<void> handleKeyRequest(String requesterId) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('[VideoConf][TEST] 📬 HANDLING KEY REQUEST');
      print('[VideoConf][TEST] Requester: $requesterId');
      print('[VideoConf][TEST] Our Timestamp: $_keyTimestamp');
      print('[VideoConf][TEST] Is First Participant: $_isFirstParticipant');
      
      if (_channelSharedKey == null || _currentChannelId == null) {
        print('[VideoConf][TEST] ❌ Key not initialized, cannot respond');
        print('═══════════════════════════════════════════════════════════');
        return;
      }
      
      if (_keyTimestamp == null) {
        print('[VideoConf][TEST] ❌ Key timestamp not available, cannot respond');
        print('═══════════════════════════════════════════════════════════');
        return;
      }

      // ⚠️ IMPORTANT: Ensure sender key exists before responding
      print('[VideoConf][TEST] 🔧 Ensuring sender key exists...');
      try {
        await SignalService.instance.createGroupSenderKey(_currentChannelId!);
        print('[VideoConf][TEST] ✓ Sender key ready');
      } catch (e) {
        // Sender key might already exist - that's OK
        if (e.toString().contains('already exists')) {
          print('[VideoConf][TEST] ℹ️ Sender key already exists (OK)');
        } else {
          print('[VideoConf][TEST] ⚠️ Sender key init error (continuing): $e');
        }
      }

      // Send our SHARED CHANNEL KEY (not a new key!) with ORIGINAL timestamp via Signal Protocol
      final keyBase64 = base64Encode(_channelSharedKey!);
      final keyPreview = keyBase64.substring(0, 16);
      final itemId = 'video_key_response_${DateTime.now().millisecondsSinceEpoch}';
      
      print('[VideoConf][TEST] 📤 Sending key response...');
      print('[VideoConf][TEST] Key Preview: $keyPreview...');
      print('[VideoConf][TEST] ORIGINAL Timestamp: $_keyTimestamp (NOT new timestamp!)');
      print('[VideoConf][TEST] Message Type: video_e2ee_key_response');
      
      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'type': 'video_key_response',
          'targetUserId': requesterId,
          'encryptedKey': keyBase64,
          'timestamp': _keyTimestamp,  // Use ORIGINAL timestamp for race condition resolution
        }),
        itemId: itemId,
        type: 'video_e2ee_key_response',
      );
      
      print('[VideoConf][TEST] ✓ Key response sent via Signal Protocol');
      print('[VideoConf][TEST] ✓ Requester $requesterId will receive key with timestamp $_keyTimestamp');
      print('═══════════════════════════════════════════════════════════');
    } catch (e) {
      print('[VideoConf][TEST] ❌ ERROR handling key request: $e');
      print('═══════════════════════════════════════════════════════════');
    }
  }

  /// Join a video conference room
  Future<void> joinRoom(
    String channelId, {
    MediaDevice? cameraDevice,      // NEW: Optional pre-selected camera
    MediaDevice? microphoneDevice,  // NEW: Optional pre-selected microphone
  }) async {
    if (_isConnecting || _isConnected) {
      print('[VideoConf] Already connecting or connected');
      return;
    }

    try {
      _isConnecting = true;
      _currentChannelId = channelId;
      notifyListeners();

      print('[VideoConf] Joining room for channel: $channelId');

      // CRITICAL: Signal Service must be initialized for E2EE key exchange
      if (!SignalService.instance.isInitialized) {
        throw Exception(
          'Signal Service must be initialized before joining video call. '
          'Key exchange requires Signal Protocol encryption.'
        );
      }
      print('[VideoConf] ✓ Signal Service ready for E2EE key exchange');

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
        // Use pre-selected camera device if available
        if (cameraDevice != null) {
          print('[VideoConf] Using pre-selected camera: ${cameraDevice.label}');
          videoTrack = await LocalVideoTrack.createCameraTrack(
            CameraCaptureOptions(deviceId: cameraDevice.deviceId),
          );
        } else {
          videoTrack = await LocalVideoTrack.createCameraTrack();
        }
        print('[VideoConf] ✓ Camera track created');
      } catch (e) {
        print('[VideoConf] ⚠️ Failed to create camera track: $e');
      }
      
      try {
        // Use pre-selected microphone device if available
        if (microphoneDevice != null) {
          print('[VideoConf] Using pre-selected microphone: ${microphoneDevice.label}');
          audioTrack = await LocalAudioTrack.create(
            AudioCaptureOptions(deviceId: microphoneDevice.deviceId),
          );
        } else {
          audioTrack = await LocalAudioTrack.create(AudioCaptureOptions());
        }
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
    print('[VideoConf] Handling disconnection - cleaning up state');
    
    // Emit Socket.IO leave event on unexpected disconnection
    if (_currentChannelId != null) {
      try {
        SocketService().emit('video:leave-channel', {
          'channelId': _currentChannelId,
        });
        print('[VideoConf] ✓ Emitted video:leave-channel after disconnection');
      } catch (e) {
        print('[VideoConf] ⚠️ Failed to emit leave event on disconnection: $e');
      }
    }
    
    _isConnected = false;
    _remoteParticipants.clear();
    _participantKeys.clear();
    
    // Clean up E2EE state on disconnection
    _channelSharedKey = null;
    _keyTimestamp = null;
    _isFirstParticipant = false;
    _keyReceivedCompleter = null;
    _currentChannelId = null;
    
    notifyListeners();
    print('[VideoConf] ✓ Disconnection handled (E2EE state cleared)');
  }

  /// Leave the current room
  Future<void> leaveRoom() async {
    try {
      print('[VideoConf] Leaving room');

      // Emit Socket.IO leave event BEFORE disconnecting from LiveKit
      if (_currentChannelId != null) {
        try {
          SocketService().emit('video:leave-channel', {
            'channelId': _currentChannelId,
          });
          print('[VideoConf] ✓ Emitted video:leave-channel to server');
        } catch (e) {
          print('[VideoConf] ⚠️ Failed to emit leave event: $e');
        }
      }

      if (_room != null) {
        await _room!.disconnect();
        await _room!.dispose();
        _room = null;
      }

      // Clean up E2EE state (key rotation on session end)
      _participantKeys.clear();
      _channelSharedKey = null;
      _keyTimestamp = null;
      _isFirstParticipant = false;
      _keyReceivedCompleter = null;

      _isConnected = false;
      _isConnecting = false;
      _currentChannelId = null;
      _currentRoomName = null;
      _remoteParticipants.clear();

      notifyListeners();
      print('[VideoConf] ✓ Left room successfully (E2EE state cleared)');
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
