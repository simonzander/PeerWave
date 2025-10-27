import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';

/// WebRTC Service for P2P File Transfer
/// 
/// Manages WebRTC connections for chunk transfer between peers
class WebRTCFileService extends ChangeNotifier {
  // Active peer connections: peerId -> RTCPeerConnection
  final Map<String, RTCPeerConnection> _peerConnections = {};
  
  // Active data channels: peerId -> RTCDataChannel
  final Map<String, RTCDataChannel> _dataChannels = {};
  
  // Connection state: peerId -> ConnectionState
  final Map<String, RTCPeerConnectionState> _connectionStates = {};
  
  // Pending ICE candidates (buffered until remote description is set)
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};
  
  // Callbacks
  final Map<String, Function(String peerId, dynamic data)> _messageCallbacks = {};
  final Map<String, Function(String peerId)> _connectionCallbacks = {};
  Function(String peerId, RTCIceCandidate candidate)? _iceCandidateCallback;
  
  // STUN/TURN servers
  final Map<String, dynamic> iceServers;
  
  WebRTCFileService({
    this.iceServers = const {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    },
  });
  
  /// Create a peer connection for a specific peer
  Future<RTCPeerConnection> _createPeerConnectionForPeer(String peerId) async {
    if (_peerConnections.containsKey(peerId)) {
      return _peerConnections[peerId]!;
    }
    
    final pc = await createPeerConnection(iceServers);
    
    // Connection state monitoring
    pc.onConnectionState = (state) {
      _connectionStates[peerId] = state;
      debugPrint('[WebRTC] Peer $peerId connection state: $state');
      
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectionCallbacks[peerId]?.call(peerId);
      }
      
      notifyListeners();
    };
    
    // ICE candidate handling (will be sent via Socket.IO)
    pc.onIceCandidate = (candidate) {
      _iceCandidateCallback?.call(peerId, candidate);
    };
    
    // Track creation (not used for data channels, but required)
    pc.onTrack = (event) {
      debugPrint('[WebRTC] Track received from $peerId');
    };
    
    _peerConnections[peerId] = pc;
    return pc;
  }
  
  /// Create a data channel for file transfer
  Future<RTCDataChannel> createDataChannel(
    String peerId, {
    String label = 'file-transfer',
  }) async {
    final pc = await _createPeerConnectionForPeer(peerId);
    
    final dataChannel = await pc.createDataChannel(label, RTCDataChannelInit()
      ..ordered = true
      ..maxRetransmits = 3);
    
    _setupDataChannel(peerId, dataChannel);
    _dataChannels[peerId] = dataChannel;
    
    return dataChannel;
  }
  
  /// Create offer for initiating connection
  Future<RTCSessionDescription> createOffer(String peerId) async {
    final pc = await _createPeerConnectionForPeer(peerId);
    
    // Create data channel before offer (as initiator)
    if (!_dataChannels.containsKey(peerId)) {
      await createDataChannel(peerId);
    }
    
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    
    return offer;
  }
  
  /// Handle incoming offer and create answer
  Future<RTCSessionDescription> handleOffer(
    String peerId,
    RTCSessionDescription offer,
  ) async {
    final pc = await _createPeerConnectionForPeer(peerId);
    
    // Data channel will be received via onDataChannel
    pc.onDataChannel = (channel) {
      debugPrint('[WebRTC] Data channel received from $peerId');
      _setupDataChannel(peerId, channel);
      _dataChannels[peerId] = channel;
    };
    
    await pc.setRemoteDescription(offer);
    
    // Process pending ICE candidates
    if (_pendingIceCandidates.containsKey(peerId)) {
      for (final candidate in _pendingIceCandidates[peerId]!) {
        await pc.addCandidate(candidate);
      }
      _pendingIceCandidates.remove(peerId);
    }
    
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    
    return answer;
  }
  
  /// Handle incoming answer
  Future<void> handleAnswer(
    String peerId,
    RTCSessionDescription answer,
  ) async {
    final pc = _peerConnections[peerId];
    if (pc == null) {
      throw Exception('No peer connection for $peerId');
    }
    
    await pc.setRemoteDescription(answer);
    
    // Process pending ICE candidates
    if (_pendingIceCandidates.containsKey(peerId)) {
      for (final candidate in _pendingIceCandidates[peerId]!) {
        await pc.addCandidate(candidate);
      }
      _pendingIceCandidates.remove(peerId);
    }
  }
  
  /// Handle incoming ICE candidate
  Future<void> handleIceCandidate(
    String peerId,
    RTCIceCandidate candidate,
  ) async {
    final pc = _peerConnections[peerId];
    
    if (pc == null) {
      // Peer connection not yet created - buffer candidate
      _pendingIceCandidates.putIfAbsent(peerId, () => []);
      _pendingIceCandidates[peerId]!.add(candidate);
      return;
    }
    
    // Check if remote description is set
    final remoteDesc = await pc.getRemoteDescription();
    if (remoteDesc == null) {
      // Buffer until remote description is set
      _pendingIceCandidates.putIfAbsent(peerId, () => []);
      _pendingIceCandidates[peerId]!.add(candidate);
      return;
    }
    
    await pc.addCandidate(candidate);
  }
  
  /// Send data via data channel
  Future<void> sendData(String peerId, dynamic data) async {
    final channel = _dataChannels[peerId];
    if (channel == null) {
      throw Exception('No data channel for $peerId');
    }
    
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception('Data channel not open for $peerId: ${channel.state}');
    }
    
    // Serialize data
    final message = jsonEncode(data);
    final buffer = RTCDataChannelMessage(message);
    
    await channel.send(buffer);
  }
  
  /// Send binary data (for chunks)
  Future<void> sendBinary(String peerId, Uint8List data) async {
    final channel = _dataChannels[peerId];
    if (channel == null) {
      throw Exception('No data channel for $peerId');
    }
    
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception('Data channel not open for $peerId: ${channel.state}');
    }
    
    final buffer = RTCDataChannelMessage.fromBinary(data);
    await channel.send(buffer);
  }
  
  /// Register message callback
  void onMessage(String peerId, Function(String peerId, dynamic data) callback) {
    _messageCallbacks[peerId] = callback;
  }
  
  /// Register connection callback
  void onConnected(String peerId, Function(String peerId) callback) {
    _connectionCallbacks[peerId] = callback;
  }
  
  /// Get connection state
  RTCPeerConnectionState? getConnectionState(String peerId) {
    return _connectionStates[peerId];
  }
  
  /// Check if connected to peer
  bool isConnected(String peerId) {
    return _connectionStates[peerId] == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  }
  
  /// Close connection to peer
  Future<void> closePeerConnection(String peerId) async {
    final channel = _dataChannels[peerId];
    if (channel != null) {
      await channel.close();
      _dataChannels.remove(peerId);
    }
    
    final pc = _peerConnections[peerId];
    if (pc != null) {
      await pc.close();
      _peerConnections.remove(peerId);
    }
    
    _connectionStates.remove(peerId);
    _messageCallbacks.remove(peerId);
    _connectionCallbacks.remove(peerId);
    _pendingIceCandidates.remove(peerId);
    
    notifyListeners();
  }
  
  /// Close all connections
  Future<void> closeAll() async {
    final peerIds = _peerConnections.keys.toList();
    for (final peerId in peerIds) {
      await closePeerConnection(peerId);
    }
  }
  
  /// Get list of connected peers
  List<String> getConnectedPeers() {
    return _connectionStates.entries
        .where((e) => e.value == RTCPeerConnectionState.RTCPeerConnectionStateConnected)
        .map((e) => e.key)
        .toList();
  }
  
  @override
  void dispose() {
    closeAll();
    super.dispose();
  }
  
  // ============================================
  // PRIVATE METHODS
  // ============================================
  
  void _setupDataChannel(String peerId, RTCDataChannel channel) {
    channel.onMessage = (message) {
      _onDataChannelMessage(peerId, message);
    };
    
    channel.onDataChannelState = (state) {
      debugPrint('[WebRTC] Data channel $peerId state: $state');
      notifyListeners();
    };
  }
  
  void _onDataChannelMessage(String peerId, RTCDataChannelMessage message) {
    try {
      if (message.isBinary) {
        // Binary data (chunk)
        _messageCallbacks[peerId]?.call(peerId, message.binary);
      } else {
        // Text data (JSON)
        final data = jsonDecode(message.text);
        _messageCallbacks[peerId]?.call(peerId, data);
      }
    } catch (e) {
      debugPrint('[WebRTC] Error handling message from $peerId: $e');
    }
  }
  
  /// Set ICE candidate callback (to send via Socket.IO)
  void setIceCandidateCallback(Function(String peerId, RTCIceCandidate candidate) callback) {
    _iceCandidateCallback = callback;
  }
}
