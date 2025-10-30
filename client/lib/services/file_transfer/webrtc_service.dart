import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';

/// WebRTC Service for P2P File Transfer
/// 
/// Manages WebRTC connections for chunk transfer between peers
class WebRTCFileService extends ChangeNotifier {
  // Buffer management constants
  static const int MAX_BUFFERED_AMOUNT = 16 * 1024 * 1024; // 16 MB
  static const int HIGH_WATER_MARK = 8 * 1024 * 1024;      // 8 MB (50%)
  static const int LOW_WATER_MARK = 2 * 1024 * 1024;       // 2 MB (12.5%)
  static const int BACKPRESSURE_WAIT_MS = 10;              // 10ms wait interval
  static const int BACKPRESSURE_TIMEOUT_SEC = 30;          // 30s timeout
  
  // Buffer statistics for monitoring
  final Map<String, BufferStats> _bufferStats = {};
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
  final Map<String, Function(String peerId)> _dataChannelOpenCallbacks = {};
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
      debugPrint('[WebRTC ICE] Candidate discovered for $peerId: ${candidate.candidate?.substring(0, 50) ?? "null"}...');
      if (_iceCandidateCallback == null) {
        debugPrint('[WebRTC ICE] ❌ WARNING: No ICE candidate callback registered!');
      } else {
        debugPrint('[WebRTC ICE] ✓ Calling ICE candidate callback for $peerId');
        _iceCandidateCallback?.call(peerId, candidate);
      }
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
    debugPrint('[WebRTC] sendData called for $peerId');
    debugPrint('[WebRTC] Available data channels: ${_dataChannels.keys.toList()}');
    
    final channel = _dataChannels[peerId];
    if (channel == null) {
      debugPrint('[WebRTC] ERROR: No data channel for $peerId');
      throw Exception('No data channel for $peerId');
    }
    
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      debugPrint('[WebRTC] ERROR: Data channel not open for $peerId: ${channel.state}');
      throw Exception('Data channel not open for $peerId: ${channel.state}');
    }
    
    // Serialize data
    debugPrint('[WebRTC] Serializing and sending message...');
    final message = jsonEncode(data);
    final buffer = RTCDataChannelMessage(message);
    
    await channel.send(buffer);
    debugPrint('[WebRTC] Message sent successfully to $peerId');
  }
  
  /// Send binary data (for chunks) with backpressure management
  Future<void> sendBinary(String peerId, Uint8List data) async {
    final channel = _dataChannels[peerId];
    if (channel == null) {
      throw Exception('No data channel for $peerId');
    }

    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception('Data channel not open for $peerId: ${channel.state}');
    }

    // Initialize buffer stats for this peer if needed
    _bufferStats[peerId] ??= BufferStats();
    final stats = _bufferStats[peerId]!;
    
    // ✅ BACKPRESSURE: Wait if buffer is filling up
    int waitCount = 0;
    final maxWaits = (BACKPRESSURE_TIMEOUT_SEC * 1000) ~/ BACKPRESSURE_WAIT_MS;
    final startTime = DateTime.now();
    
    while (channel.bufferedAmount != null && 
           channel.bufferedAmount! > HIGH_WATER_MARK) {
      
      // Timeout check
      if (waitCount++ > maxWaits) {
        stats.recordTimeout(channel.bufferedAmount ?? 0);
        throw TimeoutException(
          'Backpressure timeout: Buffer not draining (${channel.bufferedAmount} bytes) after ${BACKPRESSURE_TIMEOUT_SEC}s'
        );
      }
      
      // Log every 1 second (100 * 10ms = 1000ms)
      if (waitCount % 100 == 0) {
        debugPrint('[WebRTC Backpressure] $peerId: Waiting for buffer to drain: '
                   '${(channel.bufferedAmount! / 1024 / 1024).toStringAsFixed(2)} MB buffered');
      }
      
      await Future.delayed(Duration(milliseconds: BACKPRESSURE_WAIT_MS));
    }
    
    // Record wait statistics
    if (waitCount > 0) {
      final waitTime = DateTime.now().difference(startTime);
      stats.recordWait(channel.bufferedAmount ?? 0, waitTime);
    }
    
    // Send when buffer is below high water mark
    final buffer = RTCDataChannelMessage.fromBinary(data);
    await channel.send(buffer);
    
    // Update max buffered amount
    if (channel.bufferedAmount != null) {
      stats.updateMaxBuffered(channel.bufferedAmount!);
      
      // Log if getting close to limit
      if (channel.bufferedAmount! > LOW_WATER_MARK) {
        debugPrint('[WebRTC Buffer] $peerId: ${(channel.bufferedAmount! / 1024 / 1024).toStringAsFixed(2)} MB buffered');
      }
    }
    
    stats.recordSend(data.length);
  }
  
  /// Get buffer statistics for a peer
  BufferStats? getBufferStats(String peerId) {
    return _bufferStats[peerId];
  }
  
  /// Print buffer statistics for all peers
  void printAllBufferStats() {
    debugPrint('═══════════════════════════════════════');
    debugPrint('WebRTC Buffer Statistics Summary');
    debugPrint('═══════════════════════════════════════');
    
    if (_bufferStats.isEmpty) {
      debugPrint('No buffer statistics available');
      return;
    }
    
    for (final entry in _bufferStats.entries) {
      final peerId = entry.key;
      final stats = entry.value;
      
      debugPrint('\nPeer: $peerId');
      stats.printStats();
    }
    
    debugPrint('═══════════════════════════════════════');
  }
  
  /// Register message callback
  void onMessage(String peerId, Function(String peerId, dynamic data) callback) {
    debugPrint('[WebRTC] Registering message callback for $peerId');
    _messageCallbacks[peerId] = callback;
    debugPrint('[WebRTC] Message callback registered. Total callbacks: ${_messageCallbacks.length}');
  }
  
  /// Register connection callback
  void onConnected(String peerId, Function(String peerId) callback) {
    _connectionCallbacks[peerId] = callback;
  }
  
  /// Register data channel open callback
  void onDataChannelOpen(String peerId, Function(String peerId) callback) {
    debugPrint('[WebRTC] Registering data channel open callback for $peerId');
    _dataChannelOpenCallbacks[peerId] = callback;
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
      
      // Notify when data channel is open
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        debugPrint('[WebRTC] Data channel $peerId is now OPEN, calling callback');
        _dataChannelOpenCallbacks[peerId]?.call(peerId);
      }
      
      notifyListeners();
    };
  }
  
  void _onDataChannelMessage(String peerId, RTCDataChannelMessage message) {
    try {
      debugPrint('[WebRTC] _onDataChannelMessage called for $peerId, isBinary: ${message.isBinary}');
      
      if (message.isBinary) {
        // Binary data (chunk)
        debugPrint('[WebRTC] Calling binary callback for $peerId (${message.binary.length} bytes)');
        _messageCallbacks[peerId]?.call(peerId, message.binary);
        if (_messageCallbacks[peerId] == null) {
          debugPrint('[WebRTC] WARNING: No message callback registered for $peerId');
        }
      } else {
        // Text data (JSON)
        debugPrint('[WebRTC] Calling JSON callback for $peerId');
        final data = jsonDecode(message.text);
        debugPrint('[WebRTC] JSON data: $data');
        _messageCallbacks[peerId]?.call(peerId, data);
        if (_messageCallbacks[peerId] == null) {
          debugPrint('[WebRTC] WARNING: No message callback registered for $peerId');
        }
      }
    } catch (e) {
      debugPrint('[WebRTC] Error handling message from $peerId: $e');
    }
  }
  
  /// Set ICE candidate callback (to send via Socket.IO)
  void setIceCandidateCallback(Function(String peerId, RTCIceCandidate candidate) callback) {
    debugPrint('[WebRTC ICE] ✅ ICE candidate callback registered');
    _iceCandidateCallback = callback;
  }
}

/// Buffer Statistics for monitoring WebRTC DataChannel performance
class BufferStats {
  int totalSends = 0;
  int totalBytesSent = 0;
  int totalWaits = 0;
  int maxBufferedAmount = 0;
  int timeouts = 0;
  Duration totalWaitTime = Duration.zero;
  
  void recordSend(int bytes) {
    totalSends++;
    totalBytesSent += bytes;
  }
  
  void recordWait(int bufferedAmount, Duration waitTime) {
    totalWaits++;
    maxBufferedAmount = maxBufferedAmount > bufferedAmount ? maxBufferedAmount : bufferedAmount;
    totalWaitTime += waitTime;
  }
  
  void updateMaxBuffered(int bufferedAmount) {
    if (bufferedAmount > maxBufferedAmount) {
      maxBufferedAmount = bufferedAmount;
    }
  }
  
  void recordTimeout(int bufferedAmount) {
    timeouts++;
    debugPrint('[BufferStats] ❌ TIMEOUT! Buffer stuck at ${(bufferedAmount / 1024 / 1024).toStringAsFixed(2)} MB');
  }
  
  void printStats() {
    final avgWaitMs = totalWaits > 0 ? totalWaitTime.inMilliseconds / totalWaits : 0;
    final totalMB = totalBytesSent / 1024 / 1024;
    final maxBufferedMB = maxBufferedAmount / 1024 / 1024;
    
    debugPrint('  Total sends: $totalSends');
    debugPrint('  Total data: ${totalMB.toStringAsFixed(2)} MB');
    debugPrint('  Backpressure waits: $totalWaits');
    debugPrint('  Total wait time: ${totalWaitTime.inMilliseconds}ms');
    debugPrint('  Average wait: ${avgWaitMs.toStringAsFixed(1)}ms');
    debugPrint('  Max buffered: ${maxBufferedMB.toStringAsFixed(2)} MB');
    debugPrint('  Timeouts: $timeouts');
    
    if (timeouts > 0) {
      debugPrint('  ⚠️  WARNING: Connection had buffer timeouts!');
    }
    
    if (totalWaits > totalSends * 0.1) {
      debugPrint('  ⚠️  High backpressure detected (${((totalWaits / totalSends) * 100).toStringAsFixed(1)}% of sends)');
    }
  }
}
