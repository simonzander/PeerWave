import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

/// MediasoupService - Manages mediasoup client connection
/// 
/// Responsibilities:
/// - Connect to mediasoup server via Socket.IO
/// - Create and manage WebRTC Device
/// - Handle Transports (send/recv)
/// - Manage Producers (local audio/video)
/// - Manage Consumers (remote audio/video)
/// - E2EE integration (mandatory)
class MediasoupService extends ChangeNotifier {
  // Socket.IO connection
  IO.Socket? _socket;
  
  // mediasoup Device
  Device? _device;
  
  // Transports
  Transport? _sendTransport;
  Transport? _recvTransport;
  
  // Producers (local media)
  final Map<String, Producer> _producers = {};
  
  // Consumers (remote media)
  final Map<String, Consumer> _consumers = {};
  
  // Local media streams
  MediaStream? _localStream;
  
  // Remote media streams (userId -> MediaStream)
  final Map<String, MediaStream> _remoteStreams = {};
  
  // Current room/channel
  String? _currentChannelId;
  String? _currentPeerId;
  
  // Connection state
  bool _isConnected = false;
  bool _isJoined = false;
  
  // E2EE state
  bool _e2eeEnabled = false; // Will be set to true by server (mandatory)
  
  // Getters
  bool get isConnected => _isConnected;
  bool get isJoined => _isJoined;
  bool get e2eeEnabled => _e2eeEnabled;
  String? get currentChannelId => _currentChannelId;
  Map<String, MediaStream> get remoteStreams => _remoteStreams;
  MediaStream? get localStream => _localStream;
  
  /// Initialize MediasoupService with Socket.IO connection
  Future<void> initialize(IO.Socket socket) async {
    _socket = socket;
    _setupSocketListeners();
    _isConnected = true;
    notifyListeners();
  }
  
  /// Setup Socket.IO event listeners for mediasoup signaling
  void _setupSocketListeners() {
    if (_socket == null) return;
    
    // Peer joined notification
    _socket!.on('mediasoup:peer-joined', (data) {
      debugPrint('[MediasoupService] Peer joined: ${data['userId']}');
      notifyListeners();
    });
    
    // Peer left notification
    _socket!.on('mediasoup:peer-left', (data) {
      debugPrint('[MediasoupService] Peer left: ${data['userId']}');
      final peerId = data['peerId'];
      _remoteStreams.remove(peerId);
      notifyListeners();
    });
    
    // New producer available
    _socket!.on('mediasoup:new-producer', (data) async {
      debugPrint('[MediasoupService] New producer: ${data['producerId']} (${data['kind']})');
      
      // Consume the new producer
      try {
        await _consumeProducer(
          data['peerId'],
          data['producerId'],
          data['kind']
        );
      } catch (e) {
        debugPrint('[MediasoupService] Error consuming producer: $e');
      }
    });
    
    // Producer closed
    _socket!.on('mediasoup:producer-closed', (data) {
      debugPrint('[MediasoupService] Producer closed: ${data['producerId']}');
      final consumerId = data['producerId']; // Simplified - should map producer->consumer
      if (_consumers.containsKey(consumerId)) {
        _consumers[consumerId]!.close();
        _consumers.remove(consumerId);
      }
      notifyListeners();
    });
  }
  
  /// Join a channel/room for video conferencing
  Future<void> joinChannel(String channelId) async {
    if (_socket == null || !_isConnected) {
      throw Exception('Socket not connected');
    }
    
    if (_isJoined) {
      debugPrint('[MediasoupService] Already joined a channel');
      return;
    }
    
    debugPrint('[MediasoupService] Joining channel: $channelId');
    
    try {
      // Send join request to server
      final response = await _socketRequest('mediasoup:join', {
        'channelId': channelId,
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      _currentChannelId = channelId;
      _isJoined = true;
      _e2eeEnabled = response['e2eeEnabled'] ?? false; // Server enforces true
      
      debugPrint('[MediasoupService] ✓ Joined channel (E2EE: $_e2eeEnabled)');
      
      // Load mediasoup Device
      await _loadDevice(response['rtpCapabilities']);
      
      // Create transports
      await _createTransports();
      
      // Consume existing producers in room
      final existingProducers = response['existingProducers'] as List?;
      if (existingProducers != null) {
        for (final producer in existingProducers) {
          await _consumeProducer(
            producer['peerId'],
            producer['producerId'],
            producer['kind']
          );
        }
      }
      
      notifyListeners();
      
    } catch (e) {
      debugPrint('[MediasoupService] Error joining channel: $e');
      rethrow;
    }
  }
  
  /// Leave current channel/room
  Future<void> leaveChannel() async {
    if (_socket == null || !_isJoined) {
      return;
    }
    
    debugPrint('[MediasoupService] Leaving channel: $_currentChannelId');
    
    try {
      // Close all producers
      for (final producer in _producers.values) {
        producer.close();
      }
      _producers.clear();
      
      // Close all consumers
      for (final consumer in _consumers.values) {
        consumer.close();
      }
      _consumers.clear();
      
      // Close transports
      _sendTransport?.close();
      _recvTransport?.close();
      _sendTransport = null;
      _recvTransport = null;
      
      // Stop local stream
      if (_localStream != null) {
        _localStream!.getTracks().forEach((track) => track.stop());
        _localStream!.dispose();
        _localStream = null;
      }
      
      // Clear remote streams
      _remoteStreams.clear();
      
      // Notify server
      await _socketRequest('mediasoup:leave', {});
      
      _isJoined = false;
      _currentChannelId = null;
      _currentPeerId = null;
      
      debugPrint('[MediasoupService] ✓ Left channel');
      notifyListeners();
      
    } catch (e) {
      debugPrint('[MediasoupService] Error leaving channel: $e');
    }
  }
  
  /// Load mediasoup Device with RTP capabilities
  Future<void> _loadDevice(Map<String, dynamic> rtpCapabilities) async {
    debugPrint('[MediasoupService] Loading Device...');
    
    _device = Device();
    
    final rtpCaps = RtpCapabilities.fromMap(rtpCapabilities);
    await _device!.load(routerRtpCapabilities: rtpCaps);
    
    debugPrint('[MediasoupService] ✓ Device loaded');
  }
  
  /// Create send and receive transports
  Future<void> _createTransports() async {
    if (_device == null) {
      throw Exception('Device not loaded');
    }
    
    debugPrint('[MediasoupService] Creating transports...');
    
    // Create send transport
    final sendTransportData = await _socketRequest('mediasoup:create-transport', {
      'direction': 'send',
    });
    
    if (sendTransportData['error'] != null) {
      throw Exception(sendTransportData['error']);
    }
    
    final sendTransportParams = sendTransportData['transport'];
    _sendTransport = _device!.createSendTransportFromMap(
      sendTransportParams,
      producerCallback: _onProduce,
    );
    
    // Setup send transport events
    _sendTransport!.on('connect', (data) async {
      debugPrint('[MediasoupService] Send transport connecting...');
      await _connectTransport(_sendTransport!.id, data['dtlsParameters']);
      data['callback']();
    });
    
    _sendTransport!.on('connectionstatechange', (state) {
      debugPrint('[MediasoupService] Send transport state: $state');
    });
    
    // Create receive transport
    final recvTransportData = await _socketRequest('mediasoup:create-transport', {
      'direction': 'recv',
    });
    
    if (recvTransportData['error'] != null) {
      throw Exception(recvTransportData['error']);
    }
    
    final recvTransportParams = recvTransportData['transport'];
    _recvTransport = _device!.createRecvTransportFromMap(
      recvTransportParams,
    );
    
    // Setup recv transport events
    _recvTransport!.on('connect', (data) async {
      debugPrint('[MediasoupService] Recv transport connecting...');
      await _connectTransport(_recvTransport!.id, data['dtlsParameters']);
      data['callback']();
    });
    
    _recvTransport!.on('connectionstatechange', (state) {
      debugPrint('[MediasoupService] Recv transport state: $state');
    });
    
    debugPrint('[MediasoupService] ✓ Transports created');
  }
  
  /// Connect transport with DTLS parameters
  Future<void> _connectTransport(String transportId, dynamic dtlsParameters) async {
    final response = await _socketRequest('mediasoup:connect-transport', {
      'transportId': transportId,
      'dtlsParameters': dtlsParameters,
    });
    
    if (response['error'] != null) {
      throw Exception(response['error']);
    }
  }
  
  /// Producer callback - called when producing media
  Future<Map<String, dynamic>> _onProduce(
    Transport transport,
    String kind,
    RtpParameters rtpParameters,
    dynamic appData,
  ) async {
    debugPrint('[MediasoupService] Producing $kind...');
    
    final response = await _socketRequest('mediasoup:produce', {
      'transportId': transport.id,
      'kind': kind,
      'rtpParameters': rtpParameters.toMap(),
      'appData': appData,
    });
    
    if (response['error'] != null) {
      throw Exception(response['error']);
    }
    
    return {'id': response['producerId']};
  }
  
  /// Start producing local media (audio/video)
  Future<void> startProducing({
    bool audio = true,
    bool video = true,
  }) async {
    if (_sendTransport == null) {
      throw Exception('Send transport not created');
    }
    
    debugPrint('[MediasoupService] Starting to produce media...');
    
    try {
      // Get local media stream
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
      
      // Produce audio track
      if (audio && _localStream!.getAudioTracks().isNotEmpty) {
        final audioTrack = _localStream!.getAudioTracks()[0];
        final audioProducer = await _sendTransport!.produce(
          track: audioTrack,
          codecOptions: ProducerCodecOptions(
            opusStereo: true,
            opusDtx: true,
          ),
        );
        _producers['audio'] = audioProducer;
        debugPrint('[MediasoupService] ✓ Audio producer created');
      }
      
      // Produce video track
      if (video && _localStream!.getVideoTracks().isNotEmpty) {
        final videoTrack = _localStream!.getVideoTracks()[0];
        final videoProducer = await _sendTransport!.produce(
          track: videoTrack,
          encodings: [
            RTCRtpEncoding(maxBitrate: 500000), // 500 kbps
          ],
        );
        _producers['video'] = videoProducer;
        debugPrint('[MediasoupService] ✓ Video producer created');
      }
      
      notifyListeners();
      
    } catch (e) {
      debugPrint('[MediasoupService] Error producing media: $e');
      rethrow;
    }
  }
  
  /// Stop producing media
  Future<void> stopProducing() async {
    debugPrint('[MediasoupService] Stopping production...');
    
    for (final entry in _producers.entries) {
      final producerId = entry.value.id;
      
      // Close producer locally
      entry.value.close();
      
      // Notify server
      await _socketRequest('mediasoup:close-producer', {
        'producerId': producerId,
      });
    }
    
    _producers.clear();
    
    // Stop local stream
    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      _localStream!.dispose();
      _localStream = null;
    }
    
    notifyListeners();
  }
  
  /// Consume producer (receive media from another peer)
  Future<void> _consumeProducer(
    String producerPeerId,
    String producerId,
    String kind,
  ) async {
    if (_recvTransport == null || _device == null) {
      debugPrint('[MediasoupService] Recv transport or device not ready');
      return;
    }
    
    debugPrint('[MediasoupService] Consuming producer: $producerId ($kind)');
    
    try {
      final response = await _socketRequest('mediasoup:consume', {
        'producerPeerId': producerPeerId,
        'producerId': producerId,
        'rtpCapabilities': _device!.rtpCapabilities.toMap(),
      });
      
      if (response['error'] != null) {
        throw Exception(response['error']);
      }
      
      final consumerData = response['consumer'];
      
      // Create consumer
      final consumer = await _recvTransport!.consume(
        id: consumerData['id'],
        producerId: consumerData['producerId'],
        kind: consumerData['kind'],
        rtpParameters: RtpParameters.fromMap(consumerData['rtpParameters']),
      );
      
      _consumers[consumer.id] = consumer;
      
      // Add track to remote stream
      if (!_remoteStreams.containsKey(producerPeerId)) {
        _remoteStreams[producerPeerId] = await createLocalMediaStream(producerPeerId);
      }
      
      _remoteStreams[producerPeerId]!.addTrack(consumer.track!);
      
      // Resume consumer
      await _socketRequest('mediasoup:resume-consumer', {
        'consumerId': consumer.id,
      });
      
      debugPrint('[MediasoupService] ✓ Consumer created and resumed');
      notifyListeners();
      
    } catch (e) {
      debugPrint('[MediasoupService] Error consuming producer: $e');
    }
  }
  
  /// Toggle audio mute
  Future<void> toggleAudio() async {
    final audioProducer = _producers['audio'];
    if (audioProducer == null) return;
    
    if (audioProducer.paused) {
      await audioProducer.resume();
    } else {
      await audioProducer.pause();
    }
    
    notifyListeners();
  }
  
  /// Toggle video mute
  Future<void> toggleVideo() async {
    final videoProducer = _producers['video'];
    if (videoProducer == null) return;
    
    if (videoProducer.paused) {
      await videoProducer.resume();
    } else {
      await videoProducer.pause();
    }
    
    notifyListeners();
  }
  
  /// Socket.IO request-response helper
  Future<Map<String, dynamic>> _socketRequest(String event, Map<String, dynamic> data) {
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
    super.dispose();
  }
}
