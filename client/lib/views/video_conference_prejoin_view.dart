import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/video_conference_service.dart';
import '../services/signal_service.dart';
import '../services/socket_service.dart';
import 'dart:async';

/// PreJoin screen for video conference
/// Shows device selection and handles E2EE key exchange BEFORE joining
class VideoConferencePreJoinView extends StatefulWidget {
  final String channelId;
  final String channelName;
  final Function(Map<String, dynamic>)? onJoinReady;  // Callback when ready to join

  const VideoConferencePreJoinView({
    Key? key,
    required this.channelId,
    required this.channelName,
    this.onJoinReady,
  }) : super(key: key);  @override
  State<VideoConferencePreJoinView> createState() => _VideoConferencePreJoinViewState();
}

class _VideoConferencePreJoinViewState extends State<VideoConferencePreJoinView> {
  // Device Selection
  List<MediaDevice> _cameras = [];
  List<MediaDevice> _microphones = [];
  MediaDevice? _selectedCamera;
  MediaDevice? _selectedMicrophone;
  bool _isLoadingDevices = true;
  
  // Participant Info
  bool _isFirstParticipant = false;
  int _participantCount = 0;
  bool _isCheckingParticipants = true;
  
  // E2EE Key Exchange
  bool _hasE2EEKey = false;
  bool _isExchangingKey = false;
  String? _keyExchangeError;
  
  // Preview Track
  LocalVideoTrack? _previewTrack;
  bool _isCameraEnabled = true;
  
  @override
  void initState() {
    super.initState();
    _initializePreJoin();
  }
  
  @override
  void dispose() {
    _previewTrack?.dispose();
    super.dispose();
  }
  
  /// Initialize PreJoin flow
  Future<void> _initializePreJoin() async {
    try {
      // Step 1: Ensure Signal Service is initialized (should already be initialized by app startup)
      if (!SignalService.instance.isInitialized) {
        print('[PreJoin] ⚠️ Signal Service not initialized! This should not happen.');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Signal Service not initialized. Please restart the app.')),
          );
        }
        return;
      }
      
      // Step 2: Load available media devices
      await _loadMediaDevices();
      
      // Step 3: Register as participant (enters "waiting room")
      await _registerAsParticipant();
      
      // Step 4: Check if first participant
      await _checkParticipantStatus();
      
      // Step 5: Handle E2EE key exchange
      if (_isFirstParticipant) {
        // First participant generates key locally (not shared yet)
        setState(() {
          _hasE2EEKey = true;
          print('[PreJoin] First participant - will generate E2EE key on join');
        });
      } else {
        // Request E2EE key from existing participants
        await _requestE2EEKey();
      }
      
      // Step 6: Start camera preview
      if (_isCameraEnabled && _selectedCamera != null) {
        await _startCameraPreview();
      }
      
    } catch (e) {
      print('[PreJoin] Initialization error: $e');
      setState(() {
        _keyExchangeError = 'Initialization failed: $e';
      });
    }
  }
  
  /// Load available cameras and microphones
  Future<void> _loadMediaDevices() async {
    try {
      setState(() => _isLoadingDevices = true);
      
      final devices = await Hardware.instance.enumerateDevices();
      
      _cameras = devices.where((d) => d.kind == 'videoinput').toList();
      _microphones = devices.where((d) => d.kind == 'audioinput').toList();
      
      // Select first available devices
      _selectedCamera = _cameras.isNotEmpty ? _cameras.first : null;
      _selectedMicrophone = _microphones.isNotEmpty ? _microphones.first : null;
      
      setState(() => _isLoadingDevices = false);
      
      print('[PreJoin] Loaded ${_cameras.length} cameras, ${_microphones.length} microphones');
    } catch (e) {
      print('[PreJoin] Error loading devices: $e');
      setState(() {
        _isLoadingDevices = false;
        _keyExchangeError = 'Failed to load media devices: $e';
      });
    }
  }
  
  /// Register as participant on server
  Future<void> _registerAsParticipant() async {
    try {
      SocketService().emit('video:register-participant', {
        'channelId': widget.channelId,
      });
      print('[PreJoin] Registered as participant');
    } catch (e) {
      print('[PreJoin] Error registering participant: $e');
    }
  }
  
  /// Check participant status (am I first?)
  Future<void> _checkParticipantStatus() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('[PreJoin][TEST] 🔍 CHECKING PARTICIPANT STATUS');
      print('[PreJoin][TEST] Channel ID: ${widget.channelId}');
      
      setState(() => _isCheckingParticipants = true);
      
      // Listen for response
      final completer = Completer<Map<String, dynamic>>();
      
      void listener(dynamic data) {
        if (data['channelId'] == widget.channelId) {
          print('[PreJoin][TEST] 📨 Received participants info from server');
          completer.complete(Map<String, dynamic>.from(data));
        }
      }
      
      SocketService().registerListener('video:participants-info', listener);
      
      // Request participant info
      print('[PreJoin][TEST] 📤 Emitting video:check-participants...');
      SocketService().emit('video:check-participants', {
        'channelId': widget.channelId,
      });
      
      // Wait for response (timeout 5s)
      final result = await completer.future.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          print('[PreJoin][TEST] ❌ TIMEOUT waiting for participant info');
          return {'error': 'Timeout'};
        },
      );
      
      SocketService().unregisterListener('video:participants-info', listener);
      
      if (result.containsKey('error')) {
        throw Exception(result['error']);
      }
      
      setState(() {
        _isFirstParticipant = result['isFirstParticipant'] ?? false;
        _participantCount = result['participantCount'] ?? 0;
        _isCheckingParticipants = false;
      });
      
      print('[PreJoin][TEST] ✅ PARTICIPANT STATUS RECEIVED');
      print('[PreJoin][TEST] Is First Participant: $_isFirstParticipant');
      print('[PreJoin][TEST] Participant Count: $_participantCount');
      print('═══════════════════════════════════════════════════════════');
    } catch (e) {
      print('[PreJoin][TEST] ❌ ERROR checking participants: $e');
      print('═══════════════════════════════════════════════════════════');
      setState(() {
        _isCheckingParticipants = false;
        _keyExchangeError = 'Failed to check participants: $e';
      });
    }
  }
  
  /// Request E2EE key from existing participants
  Future<void> _requestE2EEKey() async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('[PreJoin][TEST] 🔐 REQUESTING E2EE KEY FROM PARTICIPANTS');
      print('[PreJoin][TEST] Channel: ${widget.channelId}');
      
      setState(() {
        _isExchangingKey = true;
        _keyExchangeError = null;
      });
      
      // Send key request via Signal Protocol
      // The VideoConferenceService singleton will register itself to receive the response
      print('[PreJoin][TEST] 📤 Sending key request...');
      final success = await VideoConferenceService.requestE2EEKey(widget.channelId);
      
      setState(() {
        _hasE2EEKey = success;
        _isExchangingKey = false;
        
        if (!success) {
          _keyExchangeError = 'Failed to receive encryption key from other participants';
        }
      });
      
      if (success) {
        print('[PreJoin][TEST] ✅ E2EE KEY EXCHANGE SUCCESSFUL');
        print('[PreJoin][TEST] Key stored in VideoConferenceService singleton');
        print('[PreJoin][TEST] Ready to join call with encryption');
        print('═══════════════════════════════════════════════════════════');
      } else {
        print('[PreJoin][TEST] ❌ E2EE KEY EXCHANGE FAILED');
        print('[PreJoin][TEST] Reason: Timeout or no response from participants');
        print('═══════════════════════════════════════════════════════════');
      }
    } catch (e) {
      print('[PreJoin][TEST] ❌ ERROR requesting E2EE key: $e');
      print('═══════════════════════════════════════════════════════════');
      setState(() {
        _hasE2EEKey = false;
        _isExchangingKey = false;
        _keyExchangeError = 'Key exchange error: $e';
      });
    }
  }
  
  /// Start camera preview
  Future<void> _startCameraPreview() async {
    try {
      if (_selectedCamera == null) return;
      
      _previewTrack = await LocalVideoTrack.createCameraTrack(
        CameraCaptureOptions(
          deviceId: _selectedCamera!.deviceId,
        ),
      );
      
      setState(() {});
      print('[PreJoin] Camera preview started');
    } catch (e) {
      print('[PreJoin] Error starting camera preview: $e');
    }
  }
  
  /// Join the video call
  Future<void> _joinChannel() async {
    if (!_hasE2EEKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot join: Encryption key not ready')),
      );
      return;
    }
    
    try {
      // Confirm E2EE key status to server
      SocketService().emit('video:confirm-e2ee-key', {
        'channelId': widget.channelId,
      });
      
      final joinData = {
        'channelId': widget.channelId,
        'channelName': widget.channelName,
        'selectedCamera': _selectedCamera,
        'selectedMicrophone': _selectedMicrophone,
        'hasE2EEKey': true,
      };
      
      // If callback provided (embedded mode like dashboard), use callback
      if (widget.onJoinReady != null) {
        widget.onJoinReady!(joinData);
      } else {
        // If no callback (standalone navigation mode), pop with result
        Navigator.of(context).pop(joinData);
      }
    } catch (e) {
      print('[PreJoin] Error joining channel: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to join: $e')),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Join ${widget.channelName}'),
      ),
      body: _isLoadingDevices
          ? Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Video Preview
                Expanded(
                  flex: 3,
                  child: Container(
                    color: Colors.black,
                    child: _previewTrack != null && _isCameraEnabled
                        ? VideoTrackRenderer(_previewTrack!)
                        : Center(
                            child: Icon(
                              Icons.videocam_off,
                              size: 64,
                              color: Colors.white54,
                            ),
                          ),
                  ),
                ),
                
                // Controls
                Expanded(
                  flex: 2,
                  child: Container(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // Device Selection
                        _buildDeviceSelection(),
                        
                        SizedBox(height: 16),
                        
                        // E2EE Status
                        _buildE2EEStatus(),
                        
                        Spacer(),
                        
                        // Join Button
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _hasE2EEKey && !_isExchangingKey ? _joinChannel : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                            ),
                            child: Text(
                              _hasE2EEKey 
                                  ? 'Join Call' 
                                  : (_isExchangingKey ? 'Exchanging Keys...' : 'Waiting for Encryption Key...'),
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
  
  /// Build device selection UI
  Widget _buildDeviceSelection() {
    return Column(
      children: [
        // Camera Selection
        if (_cameras.isNotEmpty)
          DropdownButtonFormField<MediaDevice>(
            value: _selectedCamera,
            decoration: InputDecoration(
              labelText: 'Camera',
              prefixIcon: Icon(Icons.videocam),
              border: OutlineInputBorder(),
            ),
            items: _cameras.map((device) {
              return DropdownMenuItem(
                value: device,
                child: Text(device.label),
              );
            }).toList(),
            onChanged: (device) async {
              setState(() => _selectedCamera = device);
              // Restart preview with new camera
              await _previewTrack?.dispose();
              if (_isCameraEnabled) {
                await _startCameraPreview();
              }
            },
          ),
        
        SizedBox(height: 8),
        
        // Microphone Selection
        if (_microphones.isNotEmpty)
          DropdownButtonFormField<MediaDevice>(
            value: _selectedMicrophone,
            decoration: InputDecoration(
              labelText: 'Microphone',
              prefixIcon: Icon(Icons.mic),
              border: OutlineInputBorder(),
            ),
            items: _microphones.map((device) {
              return DropdownMenuItem(
                value: device,
                child: Text(device.label),
              );
            }).toList(),
            onChanged: (device) {
              setState(() => _selectedMicrophone = device);
            },
          ),
      ],
    );
  }
  
  /// Build E2EE status indicator
  Widget _buildE2EEStatus() {
    if (_isCheckingParticipants) {
      return ListTile(
        leading: CircularProgressIndicator(),
        title: Text('Checking participants...'),
        subtitle: Text('Verifying who else is in the call'),
      );
    }
    
    if (_isFirstParticipant) {
      return ListTile(
        leading: Icon(Icons.lock, color: Colors.green, size: 32),
        title: Text('You are the first participant'),
        subtitle: Text('Encryption key will be generated when you join'),
      );
    }
    
    if (_isExchangingKey) {
      return ListTile(
        leading: CircularProgressIndicator(),
        title: Text('Exchanging encryption keys...'),
        subtitle: Text('$_participantCount ${_participantCount == 1 ? "participant" : "participants"} in call'),
      );
    }
    
    if (_hasE2EEKey) {
      return ListTile(
        leading: Icon(Icons.lock, color: Colors.green, size: 32),
        title: Text('End-to-end encryption ready'),
        subtitle: Text('Keys exchanged securely via Signal Protocol'),
      );
    }
    
    return ListTile(
      leading: Icon(Icons.error, color: Colors.red, size: 32),
      title: Text('Key exchange failed'),
      subtitle: Text(_keyExchangeError ?? 'Unknown error'),
      trailing: TextButton(
        onPressed: _requestE2EEKey,
        child: Text('Retry'),
      ),
    );
  }
}
