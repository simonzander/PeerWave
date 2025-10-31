import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../services/video_conference_service.dart';
import '../services/socket_service.dart';
import '../services/insertable_streams_web.dart';
import '../widgets/e2ee_debug_overlay.dart';

/// VideoConferenceView - UI for video conferencing
/// 
/// Features:
/// - Video grid layout (responsive)
/// - Local video preview
/// - Audio/video toggle buttons
/// - Participant list
/// - E2EE indicator
class VideoConferenceView extends StatefulWidget {
  final String channelId;
  final String channelName;
  
  const VideoConferenceView({
    super.key,
    required this.channelId,
    required this.channelName,
  });
  
  @override
  State<VideoConferenceView> createState() => _VideoConferenceViewState();
}

class _VideoConferenceViewState extends State<VideoConferenceView> {
  VideoConferenceService? _service;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  
  bool _isInitialized = false;
  bool _isJoining = false;
  String? _errorMessage;
  
  @override
  void initState() {
    super.initState();
    _initializeRenderers();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Get service from Provider and initialize with socket
    if (_service == null) {
      try {
        _service = Provider.of<VideoConferenceService>(context, listen: false);
        
        // Get the current socket from SocketService
        final socketService = SocketService();
        final currentSocket = socketService.socket;
        
        if (currentSocket == null || !socketService.isConnected) {
          debugPrint('[VideoConferenceView] Socket not available or not connected');
          setState(() {
            _errorMessage = 'Socket connection not available. Please try again.';
          });
          return;
        }
        
        // Initialize service with current socket if not already connected
        if (!_service!.isConnected) {
          debugPrint('[VideoConferenceView] Initializing service with socket...');
          _service!.initialize(currentSocket).then((_) {
            debugPrint('[VideoConferenceView] Service initialized successfully');
          }).catchError((e) {
            debugPrint('[VideoConferenceView] Service initialization failed: $e');
            setState(() {
              _errorMessage = 'Failed to initialize: $e';
            });
          });
        } else {
          debugPrint('[VideoConferenceView] Service already connected');
        }
        
        debugPrint('[VideoConferenceView] Service obtained from Provider');
      } catch (e) {
        debugPrint('[VideoConferenceView] Failed to get service: $e');
        setState(() {
          _errorMessage = 'Service not available: $e';
        });
      }
    }
  }
  
  Future<void> _initializeRenderers() async {
    try {
      await _localRenderer.initialize();
      setState(() => _isInitialized = true);
      
      // Auto-join channel
      _joinChannel();
    } catch (e) {
      debugPrint('[VideoConferenceView] Renderer init error: $e');
      setState(() => _errorMessage = 'Failed to initialize video: $e');
    }
  }
  
  Future<void> _joinChannel() async {
    if (_isJoining) return;
    
    setState(() {
      _isJoining = true;
      _errorMessage = null;
    });
    
    try {
      // Check if service is available
      if (_service == null) {
        throw Exception('VideoConferenceService not available');
      }
      
      // Check browser support BEFORE joining
      if (kIsWeb && !BrowserDetector.isInsertableStreamsSupported()) {
        final unsupportedMessage = BrowserDetector.getUnsupportedMessage();
        
        setState(() {
          _isJoining = false;
          _errorMessage = unsupportedMessage;
        });
        
        // Show blocking dialog
        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: Row(
                children: const [
                  Icon(Icons.warning, color: Colors.orange, size: 28),
                  SizedBox(width: 12),
                  Expanded(child: Text('Browser Not Supported')),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(unsupportedMessage),
                  const SizedBox(height: 16),
                  const Text(
                    'Please use one of the following browsers:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text('• Chrome 86+'),
                  const Text('• Edge 86+'),
                  const Text('• Safari 15.4+'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context); // Close dialog
                    Navigator.pop(context); // Go back to chat
                  },
                  child: const Text('Go Back'),
                ),
              ],
            ),
          );
        }
        
        // Stop here - don't proceed with join
        return;
      }
      
      // Join channel
      await _service!.joinChannel(widget.channelId);
      
      // Start local stream
      await _service!.startLocalStream(audio: true, video: true);
      
      // Set local stream to renderer
      if (_service!.localStream != null) {
        _localRenderer.srcObject = _service!.localStream;
      }
      
      // Listen for remote streams
      _service!.addListener(_onServiceUpdate);
      
      setState(() => _isJoining = false);
      
    } catch (e) {
      debugPrint('[VideoConferenceView] Join error: $e');
      setState(() {
        _isJoining = false;
        _errorMessage = 'Failed to join: $e';
      });
    }
  }
  
  void _onServiceUpdate() {
    if (!mounted || _service == null) return;
    
    // Update remote renderers
    final remoteStreams = _service!.remoteStreams;
    
    // Remove old renderers
    for (final peerId in _remoteRenderers.keys.toList()) {
      if (!remoteStreams.containsKey(peerId)) {
        _remoteRenderers[peerId]?.dispose();
        _remoteRenderers.remove(peerId);
      }
    }
    
    // Add new renderers
    for (final entry in remoteStreams.entries) {
      if (!_remoteRenderers.containsKey(entry.key)) {
        final renderer = RTCVideoRenderer();
        renderer.initialize().then((_) {
          renderer.srcObject = entry.value;
          setState(() {
            _remoteRenderers[entry.key] = renderer;
          });
        });
      }
    }
    
    setState(() {});
  }
  
  Future<void> _leaveChannel() async {
    if (_service == null) return;
    
    try {
      await _service!.leaveChannel();
      
      // Dispose renderers
      for (final renderer in _remoteRenderers.values) {
        await renderer.dispose();
      }
      _remoteRenderers.clear();
      
      // Go back
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[VideoConferenceView] Leave error: $e');
    }
  }
  
  @override
  void dispose() {
    _service?.removeListener(_onServiceUpdate);
    _localRenderer.dispose();
    for (final renderer in _remoteRenderers.values) {
      renderer.dispose();
    }
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.channelName),
            if (_service?.e2eeEnabled ?? false)
              Row(
                children: [
                  Icon(Icons.lock, size: 14, color: Colors.green[300]),
                  const SizedBox(width: 4),
                  Text(
                    'E2EE Enabled',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green[300],
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          // Participant count
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${(_service?.activePeers.length ?? 0) + 1} participants',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          // Leave button
          IconButton(
            icon: const Icon(Icons.call_end),
            color: Colors.red,
            onPressed: _leaveChannel,
            tooltip: 'Leave Call',
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          // E2EE Debug Overlay (only in debug mode)
          if (_service?.e2eeEnabled ?? false)
            E2EEDebugOverlay(
              e2eeService: _service!.e2eeService,
              insertableStreams: _service!.insertableStreams,
            ),
        ],
      ),
      bottomNavigationBar: _buildControls(),
    );
  }
  
  Widget _buildBody() {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (_isJoining) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Joining video call...'),
          ],
        ),
      );
    }
    
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go Back'),
            ),
          ],
        ),
      );
    }
    
    return _buildVideoGrid();
  }
  
  Widget _buildVideoGrid() {
    final totalParticipants = _remoteRenderers.length + 1; // +1 for local
    
    // Calculate grid dimensions
    int columns = 1;
    if (totalParticipants > 1) columns = 2;
    if (totalParticipants > 4) columns = 3;
    
    final crossAxisCount = columns;
    final childAspectRatio = 16 / 9;
    
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: totalParticipants,
      itemBuilder: (context, index) {
        if (index == 0) {
          // Local video (always first)
          return _buildVideoTile(
            renderer: _localRenderer,
            isLocal: true,
            label: 'You',
          );
        } else {
          // Remote videos
          final peerIds = _remoteRenderers.keys.toList();
          final peerId = peerIds[index - 1];
          final renderer = _remoteRenderers[peerId];
          
          if (renderer == null) {
            return const Card(child: Center(child: CircularProgressIndicator()));
          }
          
          return _buildVideoTile(
            renderer: renderer,
            isLocal: false,
            label: 'Peer ${index}',
          );
        }
      },
    );
  }
  
  Widget _buildVideoTile({
    required RTCVideoRenderer renderer,
    required bool isLocal,
    required String label,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video
          RTCVideoView(
            renderer,
            mirror: isLocal,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
          
          // Label overlay
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isLocal ? Icons.person : Icons.person_outline,
                    size: 14,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Muted indicators
          if (isLocal && !(_service?.audioEnabled ?? true))
            const Positioned(
              top: 8,
              right: 8,
              child: Icon(Icons.mic_off, color: Colors.red, size: 24),
            ),
          if (isLocal && !(_service?.videoEnabled ?? true))
            const Positioned(
              top: 8,
              left: 8,
              child: Icon(Icons.videocam_off, color: Colors.red, size: 24),
            ),
        ],
      ),
    );
  }
  
  Widget _buildControls() {
    if (_service == null) return const SizedBox.shrink();
    
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Toggle Audio
          _buildControlButton(
            icon: _service!.audioEnabled ? Icons.mic : Icons.mic_off,
            label: 'Audio',
            onPressed: () => _service!.toggleAudio(),
            isActive: _service!.audioEnabled,
          ),
          
          // Toggle Video
          _buildControlButton(
            icon: _service!.videoEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Video',
            onPressed: () => _service!.toggleVideo(),
            isActive: _service!.videoEnabled,
          ),
          
          // Leave Call
          _buildControlButton(
            icon: Icons.call_end,
            label: 'Leave',
            onPressed: _leaveChannel,
            isActive: false,
            color: Colors.red,
          ),
        ],
      ),
    );
  }
  
  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool isActive,
    Color? color,
  }) {
    final buttonColor = color ?? (isActive ? Colors.blue : Colors.grey[700]);
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          onPressed: onPressed,
          backgroundColor: buttonColor,
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    );
  }
}
