import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'e2ee_service.dart';
import 'insertable_streams_web.dart';
import 'signal_service.dart';
import 'message_listener_service.dart';

/// VideoConferenceService - Mediasoup SFU with E2EE
/// 
/// Connects to mediasoup server using Socket.IO signaling
/// Uses flutter_webrtc for WebRTC transport
/// Handles E2EE (mandatory, enforced by server) with AES-256-GCM via Insertable Streams
/// 
/// Architecture:
/// - Send Transport: Local media → Producers → SFU
/// - Recv Transport: SFU → Consumers → Remote media
/// - E2EE: Insertable Streams on Producers/Consumers
class VideoConferenceService extends ChangeNotifier {
  // Socket.IO connection
  IO.Socket? _socket;
  
  // E2EE service
  E2EEService? _e2eeService;
  InsertableStreamsManager? _insertableStreams;
  SignalService? _signalService;
  
  // Mediasoup Transports
  RTCPeerConnection? _sendTransport;
  RTCPeerConnection? _recvTransport;
  String? _sendTransportId;
  String? _recvTransportId;
  
  // Mediasoup RTP Capabilities
  Map<String, dynamic>? _rtpCapabilities;
  
  // Producers (trackId -> producerId)
  final Map<String, String> _producers = {};
  
  // Consumers (consumerId -> RTCRtpReceiver)
  final Map<String, RTCRtpReceiver> _consumers = {};
  
  // Track which producers we're already consuming (producerId -> consumerId)
  final Map<String, String> _consumedProducers = {};
  
  // Track if recv transport has been negotiated
  bool _recvTransportNegotiated = false;
  
  // Local media stream
  MediaStream? _localStream;
  
  // Remote media streams (peerId -> MediaStream)
  final Map<String, MediaStream> _remoteStreams = {};
  
  // Current room/channel
  String? _currentChannelId;
  String? _currentChannelType; // 'group' | 'direct'
  String? _myPeerId;
  
  // Peer userId mapping (peerId -> userId)
  final Map<String, String> _peerUserIds = {};
  
  // Connection state
  bool _isConnected = false;
  bool _isJoined = false;
  bool _e2eeEnabled = false;
  
  // Audio/video state
  bool _audioEnabled = true;
  bool _videoEnabled = true;
  
  // Getters
  bool get isConnected => _isConnected;
  bool get isJoined => _isJoined;
  bool get e2eeEnabled => _e2eeEnabled;
  bool get audioEnabled => _audioEnabled;
  bool get videoEnabled => _videoEnabled;
  String? get currentChannelId => _currentChannelId;
  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => _remoteStreams;
  List<String> get activePeers => _remoteStreams.keys.toList();
  E2EEService? get e2eeService => _e2eeService;
  InsertableStreamsManager? get insertableStreams => _insertableStreams;
  
  /// Initialize with Socket.IO connection and SignalService
  Future<void> initialize(IO.Socket socket, {SignalService? signalService}) async {
    _socket = socket;
    _signalService = signalService;
    _setupSocketListeners();
    _isConnected = true;
    
    // Initialize E2EE if on web
    if (kIsWeb && BrowserDetector.isInsertableStreamsSupported()) {
      try {
        _e2eeService = E2EEService();
        await _e2eeService!.initialize();
        
        _insertableStreams = InsertableStreamsManager(
          e2eeService: _e2eeService,
        );
        await _insertableStreams!.initialize();
        
        debugPrint('[VideoConference] ✓ E2EE initialized with Insertable Streams');
      } catch (e) {
        debugPrint('[VideoConference] E2EE initialization failed: $e');
        // Continue without E2EE
      }
    } else {
      debugPrint('[VideoConference] E2EE not available (browser not supported)');
    }
    
    // Register with MessageListenerService for E2EE key reception
    //MessageListenerService.instance.registerVideoConferenceService(this); commented out to avoid circular dependency
    debugPrint('[VideoConference] ✓ Registered with MessageListenerService for E2EE keys');
    
    debugPrint('[VideoConference] ✓ Initialized');
    notifyListeners();
  }
  
  /// Setup Socket.IO event listeners
  void _setupSocketListeners() {
    if (_socket == null) return;
    
    // Peer joined
    _socket!.on('mediasoup:peer-joined', (data) async {
      final peerId = data['peerId'] ?? data['userId'];
      final userId = data['userId'] ?? peerId;
      
      debugPrint('[VideoConference] 🔔 Peer joined event:');
      debugPrint('[VideoConference]   - PeerId: $peerId');
      debugPrint('[VideoConference]   - UserId: $userId');
      
      _peerUserIds[peerId] = userId;
      
      // Send E2EE key to new peer via Signal Protocol
      if (_e2eeEnabled && _e2eeService != null && _signalService != null && _currentChannelId != null) {
        final sendKey = _e2eeService!.getSendKey();
        if (sendKey != null) {
          debugPrint('[VideoConference] 🔐 Sending E2EE key to new peer $userId');
          
          try {
            await _signalService!.sendVideoKey(
              channelId: _currentChannelId!,
              chatType: _currentChannelType ?? 'group',
              encryptedKey: sendKey,
              recipientUserIds: [userId],
            );
            debugPrint('[VideoConference] ✓ E2EE key sent to $userId');
          } catch (e) {
            debugPrint('[VideoConference] ❌ Failed to send E2EE key to $userId: $e');
          }
        }
      }
      
      notifyListeners();
    });
    
    // Peer left
    _socket!.on('mediasoup:peer-left', (data) {
      final peerId = data['peerId'] ?? data['userId'];
      debugPrint('[VideoConference] 🔔 Peer left: $peerId');
      _removePeer(peerId);
      _peerUserIds.remove(peerId);
      
      // Remove peer key from E2EE service
      if (_e2eeService != null) {
        _e2eeService!.removePeerKey(peerId);
      }
      
      notifyListeners();
    });
    
    // New producer available (another peer started sending)
    _socket!.on('mediasoup:new-producer', (data) async {
      final peerId = data['peerId'];
      final producerId = data['producerId'];
      final kind = data['kind'];
      final userId = data['userId'];
      
      debugPrint('[VideoConference] 🔔 New producer available:');
      debugPrint('[VideoConference]   - PeerId: $peerId');
      debugPrint('[VideoConference]   - UserId: $userId');
      debugPrint('[VideoConference]   - ProducerId: $producerId');
      debugPrint('[VideoConference]   - Kind: $kind');
      debugPrint('[VideoConference]   - My PeerId: $_myPeerId');
      
      // Wait for join to complete if _myPeerId is still null
      if (_myPeerId == null) {
        debugPrint('[VideoConference] ⏳ Waiting for join to complete...');
        // Wait a bit and try again
        await Future.delayed(const Duration(milliseconds: 100));
        if (_myPeerId == null) {
          debugPrint('[VideoConference] ⚠️ Join not complete, skipping producer');
          return;
        }
      }
      
      // Check if it's our own producer
      if (peerId != null && peerId != _myPeerId) {
        // Check if we're already consuming this producer
        if (_consumedProducers.containsKey(producerId)) {
          debugPrint('[VideoConference] 💡 Already consuming producer $producerId');
          return;
        }
        
        debugPrint('[VideoConference] 🎧 Creating consumer for this producer...');
        try {
          await _createConsumer(peerId, producerId, kind);
        } catch (e) {
          debugPrint('[VideoConference] ❌ Failed to create consumer: $e');
        }
      } else {
        debugPrint('[VideoConference] 💡 Ignoring own producer or invalid peer');
      }
    });
    
    // Producer closed
    _socket!.on('mediasoup:producer-closed', (data) {
      debugPrint('[VideoConference] Producer closed: ${data['producerId']}');
      notifyListeners();
    });
  }
  
  /// Join a channel for video conferencing
  Future<void> joinChannel(String channelId, {String? channelType}) async {
    if (_socket == null || !_isConnected) {
      throw Exception('Socket not connected');
    }
    
    if (_isJoined) {
      debugPrint('[VideoConference] Already joined');
      return;
    }
    
    debugPrint('[VideoConference] 📞 Joining channel: $channelId (type: ${channelType ?? "unknown"})');
    
    try {
      // Send join request
      debugPrint('[VideoConference] >>> Sending mediasoup:join request...');
      final response = await _socketRequest('mediasoup:join', {
        'channelId': channelId,
      });
      
      debugPrint('[VideoConference] <<< mediasoup:join response: $response');
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      _currentChannelId = channelId;
      _currentChannelType = channelType ?? 'group'; // Default to group
      _myPeerId = response['peerId'];
      _isJoined = true;
      _e2eeEnabled = response['e2eeEnabled'] ?? false;
      
      // Store RTP capabilities for consuming
      _rtpCapabilities = response['rtpCapabilities'];
      
      final existingProducers = response['existingProducers'] as List?;
      
      debugPrint('[VideoConference] ✓ Joined channel');
      debugPrint('[VideoConference]   - PeerId: $_myPeerId');
      debugPrint('[VideoConference]   - E2EE: $_e2eeEnabled');
      debugPrint('[VideoConference]   - RTP Capabilities: ${_rtpCapabilities != null ? "Received" : "Missing"}');
      debugPrint('[VideoConference]   - Existing Producers: ${existingProducers?.length ?? 0}');
      
      // Get existing peers and build recipient list
      final List<String> recipientUserIds = [];
      
      if (existingProducers != null && existingProducers.isNotEmpty) {
        debugPrint('[VideoConference] 👥 Processing ${existingProducers.length} existing producers:');
        for (final producer in existingProducers) {
          final producerPeerId = producer['peerId'];
          final producerId = producer['producerId'];
          final kind = producer['kind'];
          debugPrint('[VideoConference]   - Producer: $producerId ($kind) from peer: $producerPeerId');
          
          // Create consumer for existing producer
          if (producerPeerId != null && producerPeerId != _myPeerId) {
            final userId = producerPeerId.split('-').first; // Extract userId from peerId format
            if (!recipientUserIds.contains(userId)) {
              _peerUserIds[producerPeerId] = userId;
              recipientUserIds.add(userId);
            }
            
            // Consume this producer
            try {
              await _createConsumer(producerPeerId, producerId, kind);
            } catch (e) {
              debugPrint('[VideoConference] Failed to consume producer $producerId: $e');
            }
          }
        }
      } else {
        debugPrint('[VideoConference] 👥 No existing producers in channel (first to join)');
      }
      
      // Share E2EE key with existing peers via Signal Protocol
      if (_e2eeEnabled && _e2eeService != null && _signalService != null && recipientUserIds.isNotEmpty) {
        final sendKey = _e2eeService!.getSendKey();
        if (sendKey != null) {
          debugPrint('[VideoConference] Distributing E2EE key to ${recipientUserIds.length} peers via Signal Protocol');
          
          try {
            await _signalService!.sendVideoKey(
              channelId: channelId,
              chatType: _currentChannelType!,
              encryptedKey: sendKey,
              recipientUserIds: recipientUserIds,
            );
            debugPrint('[VideoConference] ✓ E2EE key distributed');
          } catch (e) {
            debugPrint('[VideoConference] Failed to distribute E2EE key: $e');
          }
        }
      }
      
      notifyListeners();
      
    } catch (e) {
      debugPrint('[VideoConference] Error joining: $e');
      rethrow;
    }
  }
  
  /// Leave current channel
  Future<void> leaveChannel() async {
    if (!_isJoined) return;
    
    debugPrint('[VideoConference] Leaving channel: $_currentChannelId');
    
    try {
      // Stop local stream
      await stopLocalStream();
      
      // Close all producers
      for (final producerId in _producers.values) {
        try {
          await _socketRequest('mediasoup:close-producer', {
            'producerId': producerId,
          });
        } catch (e) {
          debugPrint('[VideoConference] Error closing producer: $e');
        }
      }
      _producers.clear();
      
      // Close transports
      await _sendTransport?.close();
      await _recvTransport?.close();
      _sendTransport = null;
      _recvTransport = null;
      _sendTransportId = null;
      _recvTransportId = null;
      
      // Clear remote streams
      _remoteStreams.clear();
      _consumers.clear();
      
      // Cleanup E2EE
      if (_e2eeService != null) {
        _e2eeService!.resetStats();
        debugPrint('[VideoConference] E2EE stats reset');
      }
      
      // Notify server
      await _socketRequest('mediasoup:leave', {});
      
      _isJoined = false;
      _currentChannelId = null;
      _myPeerId = null;
      _rtpCapabilities = null;
      
      debugPrint('[VideoConference] ✓ Left channel');
      notifyListeners();
      
    } catch (e) {
      debugPrint('[VideoConference] Error leaving: $e');
    }
  }
  
  /// Start local media stream and create mediasoup producers
  Future<void> startLocalStream({bool audio = true, bool video = true}) async {
    if (_localStream != null) {
      debugPrint('[VideoConference] Local stream already started');
      return;
    }
    
    if (!_isJoined) {
      throw Exception('Must join channel before starting stream');
    }
    
    debugPrint('[VideoConference] 🎥 Starting local stream (audio: $audio, video: $video)');
    
    try {
      final constraints = {
        'audio': audio,
        'video': video
            ? {
                'mandatory': {
                  'minWidth': '640',
                  'minHeight': '480',
                  'minFrameRate': '30',
                },
                'facingMode': 'user',
              }
            : false,
      };
      
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      _audioEnabled = audio;
      _videoEnabled = video;
      
      debugPrint('[VideoConference] ✓ Local stream started');
      debugPrint('[VideoConference]   - Audio tracks: ${_localStream!.getAudioTracks().length}');
      debugPrint('[VideoConference]   - Video tracks: ${_localStream!.getVideoTracks().length}');
      notifyListeners();
      
      // Create send transport if not exists
      if (_sendTransport == null) {
        await _createSendTransport();
      }
      
      // Create producers for each track
      for (final track in _localStream!.getTracks()) {
        await _createProducer(track);
      }
      
      debugPrint('[VideoConference] ✓ All producers created');
      
    } catch (e) {
      debugPrint('[VideoConference] ❌ Error starting stream: $e');
      rethrow;
    }
  }
  
  /// Stop local media stream
  Future<void> stopLocalStream() async {
    if (_localStream == null) return;
    
    debugPrint('[VideoConference] Stopping local stream');
    
    _localStream!.getTracks().forEach((track) {
      track.stop();
    });
    await _localStream!.dispose();
    _localStream = null;
    
    notifyListeners();
  }
  
  /// Toggle audio on/off
  Future<void> toggleAudio() async {
    if (_localStream == null) return;
    
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isNotEmpty) {
      _audioEnabled = !_audioEnabled;
      audioTracks.first.enabled = _audioEnabled;
      debugPrint('[VideoConference] Audio: $_audioEnabled');
      notifyListeners();
    }
  }
  
  /// Toggle video on/off
  Future<void> toggleVideo() async {
    if (_localStream == null) return;
    
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      _videoEnabled = !_videoEnabled;
      videoTracks.first.enabled = _videoEnabled;
      debugPrint('[VideoConference] Video: $_videoEnabled');
      notifyListeners();
    }
  }
  
  /// Create send transport for producing media
  Future<void> _createSendTransport() async {
    debugPrint('[VideoConference] 📤 Creating send transport...');
    
    try {
      // Request transport from server
      final response = await _socketRequest('mediasoup:create-transport', {
        'direction': 'send',
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      final transportParams = response['transport'];
      _sendTransportId = transportParams['id'];
      
      debugPrint('[VideoConference]   - Transport ID: $_sendTransportId');
      debugPrint('[VideoConference]   - ICE Parameters: ${transportParams['iceParameters'] != null ? "✓" : "✗"}');
      debugPrint('[VideoConference]   - ICE Candidates: ${transportParams['iceCandidates']?.length ?? 0}');
      debugPrint('[VideoConference]   - DTLS Parameters: ${transportParams['dtlsParameters'] != null ? "✓" : "✗"}');
      
      // Create simple RTCPeerConnection (mediasoup handles the rest)
      // TODO: is here also our coturn server needed with mediasoup?
      final configuration = {
        'iceServers': [],
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
      };
      
      _sendTransport = await createPeerConnection(configuration);
      
      // Setup ICE candidate handling
      _sendTransport!.onIceCandidate = (RTCIceCandidate candidate) async {
        debugPrint('[VideoConference] Send transport ICE candidate generated');
        // In mediasoup, ICE candidates are provided by the server, not generated locally
        // So we typically don't need to send them back
      };
      
      // Setup connection monitoring
      _sendTransport!.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('[VideoConference] Send transport connection state: $state');
      };
      
      _sendTransport!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('[VideoConference] Send transport ICE state: $state');
        
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          debugPrint('[VideoConference] ❌ Send transport ICE failed');
        }
      };
      
      debugPrint('[VideoConference] ✓ Send transport created (simplified - no SDP negotiation needed)');
      
    } catch (e) {
      debugPrint('[VideoConference] ❌ Failed to create send transport: $e');
      rethrow;
    }
  }
  
  /// Create recv transport for consuming media
  Future<void> _createRecvTransport() async {
    debugPrint('[VideoConference] 📥 Creating recv transport...');
    
    try {
      // Request transport from server
      final response = await _socketRequest('mediasoup:create-transport', {
        'direction': 'recv',
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      final transportParams = response['transport'];
      _recvTransportId = transportParams['id'];
      
      debugPrint('[VideoConference]   - Transport ID: $_recvTransportId');
      
      // Create simple RTCPeerConnection
      final configuration = {
        'iceServers': [],
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
      };
      
      _recvTransport = await createPeerConnection(configuration);
      
      // Setup ICE candidate handling
      _recvTransport!.onIceCandidate = (RTCIceCandidate candidate) async {
        debugPrint('[VideoConference] Recv transport ICE candidate');
      };
      
      // Setup connection monitoring
      _recvTransport!.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('[VideoConference] Recv transport connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          debugPrint('[VideoConference] ✓ Recv transport CONNECTED - media should flow now');
        }
      };
      
      _recvTransport!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('[VideoConference] Recv transport ICE state: $state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
          debugPrint('[VideoConference] ✓ ICE CONNECTED');
        }
      };
      
      // Handle incoming tracks (from consumers)
      _recvTransport!.onTrack = (RTCTrackEvent event) {
        debugPrint('[VideoConference] 🎬 Track received: ${event.track.kind}');
        
        if (event.streams.isNotEmpty) {
          final stream = event.streams[0];
          final streamId = stream.id;
          
          debugPrint('[VideoConference]   - Stream ID: $streamId');
          debugPrint('[VideoConference]   - Track ID: ${event.track.id}');
          
          // Associate stream with peer
          _remoteStreams[streamId] = stream;
          notifyListeners();
        }
      };
      
      debugPrint('[VideoConference] ✓ Recv transport created (simplified - no SDP negotiation needed)');
      
      // Note: Don't negotiate here - wait until after first transceiver is added
      // Negotiation happens in _createConsumer after adding transceiver
      
    } catch (e) {
      debugPrint('[VideoConference] ❌ Failed to create recv transport: $e');
      rethrow;
    }
  }
  
  /// Create producer for a track
  Future<void> _createProducer(MediaStreamTrack track) async {
    if (_sendTransport == null) {
      throw Exception('Send transport not created');
    }
    
    debugPrint('[VideoConference] 🎤 Creating producer for ${track.kind} track...');
    
    try {
      // Add track to send transport
      final sender = await _sendTransport!.addTrack(track, _localStream!);
      
      // Attach E2EE transform if enabled
      if (_e2eeEnabled && _insertableStreams != null && kIsWeb) {
        try {
          await _insertableStreams!.attachSenderTransform(sender);
          debugPrint('[VideoConference] 🔐 E2EE transform attached to ${track.kind} sender');
        } catch (e) {
          debugPrint('[VideoConference] ⚠️ Failed to attach E2EE to sender: $e');
        }
      }
      
      // Get RTP parameters from sender
      final parameters = sender.parameters;
      final trackKind = track.kind ?? 'video'; // Default to video if null
      final rtpParameters = _convertToMediasoupRTP(parameters, trackKind);
      
      debugPrint('[VideoConference]   - RTP Parameters prepared with ${rtpParameters['codecs']?.length ?? 0} codecs');
      
      // Tell server to create producer
      final response = await _socketRequest('mediasoup:produce', {
        'transportId': _sendTransportId,
        'kind': track.kind,
        'rtpParameters': rtpParameters,
        'appData': {
          'trackId': track.id,
        },
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      final producerId = response['producerId'];
      if (track.id != null) {
        _producers[track.id!] = producerId;
      }
      
      debugPrint('[VideoConference] ✓ Producer created: $producerId (${track.kind})');
      
    } catch (e) {
      debugPrint('[VideoConference] ❌ Failed to create producer: $e');
      rethrow;
    }
  }
  
  /// Create consumer for a remote producer
  Future<void> _createConsumer(String producerPeerId, String producerId, String kind) async {
    if (_recvTransport == null) {
      await _createRecvTransport();
    }
    
    debugPrint('[VideoConference] 🎧 Creating consumer for producer $producerId ($kind)...');
    
    try {
      // Mark as being consumed to prevent duplicates
      _consumedProducers[producerId] = 'pending';
      
      // Request consumer from server
      final response = await _socketRequest('mediasoup:consume', {
        'producerPeerId': producerPeerId,
        'producerId': producerId,
        'rtpCapabilities': _rtpCapabilities,
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      final consumerParams = response['consumer'];
      final consumerId = consumerParams['id'];
      // RTP parameters from server (not used directly in flutter_webrtc)
      // final rtpParameters = consumerParams['rtpParameters'];
      
      debugPrint('[VideoConference]   - Consumer ID: $consumerId');
      
      // Add transceiver to recv transport
      final init = RTCRtpTransceiverInit(
        direction: TransceiverDirection.RecvOnly,
      );
      
      final transceiver = await _recvTransport!.addTransceiver(
        kind: kind == 'audio' ? RTCRtpMediaType.RTCRtpMediaTypeAudio : RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: init,
      );
      
      final receiver = transceiver.receiver;
      
      // Wait a bit for the track to be ready
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Get the track from the receiver
      final track = receiver.track;
      if (track != null) {
        debugPrint('[VideoConference]   - Track: ${track.kind} (${track.id})');
        debugPrint('[VideoConference]   - Track enabled: ${track.enabled}');
        debugPrint('[VideoConference]   - Track muted: ${track.muted}');
        
        // Create or get MediaStream for this peer
        MediaStream? peerStream = _remoteStreams[producerPeerId];
        if (peerStream == null) {
          peerStream = await createLocalMediaStream(producerPeerId);
          _remoteStreams[producerPeerId] = peerStream;
          debugPrint('[VideoConference]   - Created new stream for peer: $producerPeerId');
        }
        
        // Add track to the peer's stream
        peerStream.addTrack(track);
        debugPrint('[VideoConference]   - Added ${track.kind} track to stream');
      } else {
        debugPrint('[VideoConference]   ⚠️ No track available from receiver');
      }
      
      // Attach E2EE transform if enabled
      if (_e2eeEnabled && _insertableStreams != null && kIsWeb) {
        try {
          await _insertableStreams!.attachReceiverTransform(receiver, producerPeerId);
          debugPrint('[VideoConference] 🔐 E2EE transform attached to $kind receiver');
        } catch (e) {
          debugPrint('[VideoConference] ⚠️ Failed to attach E2EE to receiver: $e');
        }
      }
      
      // Store consumer
      _consumers[consumerId] = receiver;
      _consumedProducers[producerId] = consumerId;
      
      // Resume consumer on server
      await _socketRequest('mediasoup:resume-consumer', {
        'consumerId': consumerId,
      });
      
      debugPrint('[VideoConference] ✓ Consumer created and resumed: $consumerId');
      
      // Notify listeners that we have a new remote stream
      notifyListeners();
      
      // CRITICAL: Negotiate transport ONCE after first transceiver is added
      if (!_recvTransportNegotiated) {
        _recvTransportNegotiated = true;
        await _negotiateRecvTransport();
      }
      
    } catch (e) {
      // Remove from consumed list if failed
      _consumedProducers.remove(producerId);
      debugPrint('[VideoConference] ❌ Failed to create consumer: $e');
      rethrow;
    }
  }
  
  /// Convert RTCRtpParameters to mediasoup format
  Map<String, dynamic> _convertToMediasoupRTP(RTCRtpParameters parameters, String kind) {
    debugPrint('[VideoConference] Converting RTP parameters for $kind track');
    debugPrint('[VideoConference]   - Codecs from RTCRtpParameters: ${parameters.codecs?.length ?? 0}');
    debugPrint('[VideoConference]   - Encodings: ${parameters.encodings?.length ?? 0}');
    
    // Get codecs from the router's RTP capabilities (received during join)
    List<Map<String, dynamic>> codecs = [];
    
    if (_rtpCapabilities != null) {
      final routerCodecs = (_rtpCapabilities!['codecs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      
      // Filter codecs by kind (audio or video)
      codecs = routerCodecs.where((codec) {
        final mimeType = codec['mimeType'] as String?;
        if (mimeType == null) return false;
        
        // Match kind: audio codecs start with 'audio/', video with 'video/'
        return mimeType.toLowerCase().startsWith('$kind/');
      }).map((codec) => {
        'mimeType': codec['mimeType'],
        'payloadType': codec['preferredPayloadType'] ?? codec['payloadType'],
        'clockRate': codec['clockRate'],
        'channels': codec['channels'],
        'parameters': codec['parameters'] ?? {},
        'rtcpFeedback': codec['rtcpFeedback'] ?? [],
      }).toList();
      
      debugPrint('[VideoConference]   - Matched ${codecs.length} codecs from router capabilities');
    }
    
    // If we couldn't get codecs from router capabilities, try from parameters
    if (codecs.isEmpty && parameters.codecs != null && parameters.codecs!.isNotEmpty) {
      codecs = parameters.codecs!.map((codec) => {
        'mimeType': codec.name ?? (kind == 'audio' ? 'audio/opus' : 'video/VP8'),
        'clockRate': codec.clockRate ?? (kind == 'audio' ? 48000 : 90000),
        'channels': codec.numChannels,
        'payloadType': codec.payloadType,
        'parameters': codec.parameters ?? {},
        'rtcpFeedback': [],
      }).toList();
      
      debugPrint('[VideoConference]   - Using ${codecs.length} codecs from RTCRtpParameters');
    }
    
    // Build encodings - ensure each has a valid SSRC
    List<Map<String, dynamic>> encodings = [];
    
    if (parameters.encodings != null && parameters.encodings!.isNotEmpty) {
      for (final encoding in parameters.encodings!) {
        // Get or generate SSRC
        final ssrc = encoding.ssrc ?? _generateSSRC();
        
        final encodingMap = <String, dynamic>{
          'ssrc': ssrc,
        };
        
        // Add optional fields if present
        if (encoding.scalabilityMode != null) {
          encodingMap['scalabilityMode'] = encoding.scalabilityMode;
        }
        if (encoding.maxBitrate != null) {
          encodingMap['maxBitrate'] = encoding.maxBitrate;
        }
        
        encodings.add(encodingMap);
        debugPrint('[VideoConference]   - Encoding SSRC: $ssrc');
      }
    } else {
      // No encodings provided, create default one
      final ssrc = _generateSSRC();
      encodings.add({'ssrc': ssrc});
      debugPrint('[VideoConference]   - Generated default encoding with SSRC: $ssrc');
    }
    
    // Build header extensions  
    final headerExtensions = parameters.headerExtensions?.map((ext) => {
      'uri': ext.uri,
      'id': ext.id,
      'encrypt': false,
    }).toList() ?? [];
    
    return {
      'codecs': codecs,
      'encodings': encodings,
      'headerExtensions': headerExtensions,
      'rtcp': {
        'cname': parameters.rtcp?.cname ?? 'flutter-webrtc-${DateTime.now().millisecondsSinceEpoch}',
        'reducedSize': parameters.rtcp?.reducedSize ?? true,
      },
    };
  }
  
  /// Remove peer and cleanup associated resources
  void _removePeer(String peerId) {
    debugPrint('[VideoConference] Removing peer: $peerId');
    
    _remoteStreams.remove(peerId);
    notifyListeners();
  }
  
  /// Negotiate recv transport to establish WebRTC connection
  /// This is CRITICAL - without it, tracks remain muted
  Future<void> _negotiateRecvTransport() async {
    if (_recvTransport == null || _recvTransportId == null) return;
    
    try {
      debugPrint('[VideoConference] 🤝 Negotiating recv transport connection...');
      
      // Create offer to generate local SDP with DTLS parameters
      final offer = await _recvTransport!.createOffer();
      await _recvTransport!.setLocalDescription(offer);
      
      // Extract DTLS parameters from the SDP
      final sdp = offer.sdp;
      if (sdp != null) {
        // Parse DTLS fingerprint from SDP
        final fingerprintMatch = RegExp(r'a=fingerprint:(\S+) (\S+)').firstMatch(sdp);
        final setupMatch = RegExp(r'a=setup:(\S+)').firstMatch(sdp);
        
        if (fingerprintMatch != null) {
          final algorithm = fingerprintMatch.group(1);
          final fingerprint = fingerprintMatch.group(2);
          final role = setupMatch?.group(1) ?? 'auto';
          
          debugPrint('[VideoConference]   - DTLS fingerprint: $algorithm $fingerprint');
          debugPrint('[VideoConference]   - DTLS role: $role');
          
          // Connect the transport on the server with DTLS parameters
          final dtlsParameters = {
            'role': role == 'actpass' ? 'auto' : role,
            'fingerprints': [
              {
                'algorithm': algorithm,
                'value': fingerprint,
              }
            ],
          };
          
          await _socketRequest('mediasoup:connect-transport', {
            'transportId': _recvTransportId,
            'dtlsParameters': dtlsParameters,
          });
          
          debugPrint('[VideoConference] ✓ Recv transport connected on server');
        } else {
          debugPrint('[VideoConference] ⚠️ Could not extract DTLS parameters from SDP');
        }
      }
      
      debugPrint('[VideoConference] ✓ Recv transport negotiation complete');
      
    } catch (e) {
      debugPrint('[VideoConference] ⚠️ Failed to negotiate recv transport: $e');
      // Continue anyway - might work without it
    }
  }
  
  /// Generate a random SSRC (Synchronization Source)
  /// SSRC is a 32-bit unsigned integer used to identify the source of an RTP stream
  int _generateSSRC() {
    // Generate random 32-bit value (1 to 0xFFFFFFFF)
    // Avoid 0 as it's reserved
    final random = DateTime.now().microsecondsSinceEpoch % 0xFFFFFFFF;
    return random == 0 ? 1 : random;
  }
  
  /// Socket.IO request helper
  Future<Map<String, dynamic>> _socketRequest(
    String event,
    Map<String, dynamic> data,
  ) {
    final completer = Completer<Map<String, dynamic>>();
    
    _socket!.emitWithAck(event, data, ack: (response) {
      if (response is Map) {
        completer.complete(Map<String, dynamic>.from(response));
      } else {
        completer.completeError('Invalid response');
      }
    });
    
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('Socket request timeout'),
    );
  }
  
  @override
  void dispose() {
    // Unregister from MessageListenerService
    MessageListenerService.instance.unregisterVideoConferenceService();
    
    leaveChannel();
    _e2eeService?.dispose();
    _insertableStreams?.dispose();
    super.dispose();
  }
}
