import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'e2ee_service.dart';
import 'insertable_streams_web.dart';
import 'signal_service.dart';

/// VideoConferenceService - Direct mediasoup integration with E2EE
/// 
/// Connects to mediasoup server using Socket.IO signaling
/// Uses flutter_webrtc for WebRTC transport
/// Handles E2EE (mandatory, enforced by server) with AES-256-GCM
class VideoConferenceService extends ChangeNotifier {
  // Socket.IO connection
  IO.Socket? _socket;
  
  // E2EE service
  E2EEService? _e2eeService;
  InsertableStreamsManager? _insertableStreams;
  SignalService? _signalService;
  
  // WebRTC PeerConnections (peerId -> RTCPeerConnection)
  final Map<String, RTCPeerConnection> _peerConnections = {};
  
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
    
    debugPrint('[VideoConference] ✓ Initialized');
    notifyListeners();
  }
  
  /// Setup Socket.IO event listeners
  void _setupSocketListeners() {
    if (_socket == null) return;
    
    // Peer joined
    _socket!.on('mediasoup:peer-joined', (data) async {
      debugPrint('[VideoConference] Peer joined: ${data['userId']}');
      final peerId = data['peerId'] ?? data['userId'];
      final userId = data['userId'] ?? peerId;
      
      _peerUserIds[peerId] = userId;
      await _initializePeerConnection(peerId);
      
      // Send E2EE key to new peer via Signal Protocol
      if (_e2eeEnabled && _e2eeService != null && _signalService != null && _currentChannelId != null) {
        final sendKey = _e2eeService!.getSendKey();
        if (sendKey != null) {
          debugPrint('[VideoConference] Sending E2EE key to new peer $userId');
          
          try {
            await _signalService!.sendVideoKey(
              channelId: _currentChannelId!,
              chatType: _currentChannelType ?? 'group',
              encryptedKey: sendKey,
              recipientUserIds: [userId],
            );
            debugPrint('[VideoConference] ✓ E2EE key sent to $userId');
          } catch (e) {
            debugPrint('[VideoConference] Failed to send E2EE key to $userId: $e');
          }
        }
      }
      
      notifyListeners();
    });
    
    // Peer left
    _socket!.on('mediasoup:peer-left', (data) {
      final peerId = data['peerId'] ?? data['userId'];
      debugPrint('[VideoConference] Peer left: $peerId');
      _removePeer(peerId);
      _peerUserIds.remove(peerId);
      
      // Remove peer key from E2EE service
      if (_e2eeService != null) {
        _e2eeService!.removePeerKey(peerId);
      }
      
      notifyListeners();
    });
    
    // New producer available (another peer started sending)
    _socket!.on('mediasoup:new-producer', (data) {
      debugPrint('[VideoConference] New producer: ${data['producerId']} (${data['kind']})');
      final peerId = data['peerId'];
      if (peerId != null && peerId != _myPeerId) {
        _requestRemoteStream(peerId);
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
    
    debugPrint('[VideoConference] Joining channel: $channelId (type: ${channelType ?? "unknown"})');
    
    try {
      // Send join request
      final response = await _socketRequest('mediasoup:join', {
        'channelId': channelId,
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      _currentChannelId = channelId;
      _currentChannelType = channelType ?? 'group'; // Default to group
      _myPeerId = response['peerId'];
      _isJoined = true;
      _e2eeEnabled = response['e2eeEnabled'] ?? false;
      
      debugPrint('[VideoConference] ✓ Joined (PeerId: $_myPeerId, E2EE: $_e2eeEnabled)');
      
      // Get existing peers and build recipient list
      final existingPeers = response['existingPeers'] as List?;
      final List<String> recipientUserIds = [];
      
      if (existingPeers != null) {
        for (final peer in existingPeers) {
          final peerId = peer['peerId'] ?? peer['userId'];
          final userId = peer['userId'] ?? peerId;
          
          if (peerId != _myPeerId) {
            _peerUserIds[peerId] = userId;
            recipientUserIds.add(userId);
            await _initializePeerConnection(peerId);
          }
        }
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
      
      // Close all peer connections
      for (final pc in _peerConnections.values) {
        await pc.close();
      }
      _peerConnections.clear();
      
      // Clear remote streams
      _remoteStreams.clear();
      
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
      
      debugPrint('[VideoConference] ✓ Left channel');
      notifyListeners();
      
    } catch (e) {
      debugPrint('[VideoConference] Error leaving: $e');
    }
  }
  
  /// Start local media stream
  Future<void> startLocalStream({bool audio = true, bool video = true}) async {
    if (_localStream != null) {
      debugPrint('[VideoConference] Local stream already started');
      return;
    }
    
    debugPrint('[VideoConference] Starting local stream (audio: $audio, video: $video)');
    
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
      notifyListeners();
      
      // Send to all existing peers
      for (final peerId in _peerConnections.keys) {
        await _sendStreamToPeer(peerId);
      }
      
    } catch (e) {
      debugPrint('[VideoConference] Error starting stream: $e');
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
  
  /// Initialize peer connection for remote peer
  Future<void> _initializePeerConnection(String peerId) async {
    if (_peerConnections.containsKey(peerId)) {
      debugPrint('[VideoConference] Peer connection already exists: $peerId');
      return;
    }
    
    debugPrint('[VideoConference] Initializing peer connection: $peerId');
    
    try {
      final configuration = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      };
      
      final pc = await createPeerConnection(configuration);
      _peerConnections[peerId] = pc;
      
      // Setup remote stream
      final remoteStream = await createLocalMediaStream('remote_$peerId');
      _remoteStreams[peerId] = remoteStream;
      
      // Handle incoming tracks
      pc.onTrack = (RTCTrackEvent event) {
        debugPrint('[VideoConference] Track received from $peerId: ${event.track.kind}');
        if (event.streams.isNotEmpty) {
          _remoteStreams[peerId] = event.streams[0];
          notifyListeners();
        }
      };
      
      // Handle ICE candidates
      pc.onIceCandidate = (RTCIceCandidate candidate) {
        debugPrint('[VideoConference] ICE candidate for $peerId');
        // In production: send via signaling server
        // For now: direct exchange handled by mediasoup server
      };
      
      // Handle connection state
      pc.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('[VideoConference] Connection state $peerId: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _removePeer(peerId);
        }
      };
      
      // Add local stream if available
      if (_localStream != null) {
        await _sendStreamToPeer(peerId);
      }
      
      debugPrint('[VideoConference] ✓ Peer connection ready: $peerId');
      notifyListeners();
      
    } catch (e) {
      debugPrint('[VideoConference] Error initializing peer: $e');
    }
  }
  
  /// Send local stream to peer
  Future<void> _sendStreamToPeer(String peerId) async {
    final pc = _peerConnections[peerId];
    if (pc == null || _localStream == null) return;
    
    debugPrint('[VideoConference] Sending stream to $peerId');
    
    try {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    } catch (e) {
      debugPrint('[VideoConference] Error sending stream: $e');
    }
  }
  
  /// Request remote stream from peer
  Future<void> _requestRemoteStream(String peerId) async {
    debugPrint('[VideoConference] Requesting stream from $peerId');
    
    // Initialize peer connection if not exists
    if (!_peerConnections.containsKey(peerId)) {
      await _initializePeerConnection(peerId);
    }
    
    // Create offer (SDP negotiation)
    final pc = _peerConnections[peerId];
    if (pc != null) {
      try {
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        
        // Send offer to server
        // In production: handle SDP exchange via signaling
        // For now: simplified direct connection
        
      } catch (e) {
        debugPrint('[VideoConference] Error creating offer: $e');
      }
    }
  }
  
  /// Remove peer connection
  void _removePeer(String peerId) {
    debugPrint('[VideoConference] Removing peer: $peerId');
    
    final pc = _peerConnections.remove(peerId);
    pc?.close();
    
    _remoteStreams.remove(peerId);
    notifyListeners();
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
    leaveChannel();
    _e2eeService?.dispose();
    _insertableStreams?.dispose();
    super.dispose();
  }
}
