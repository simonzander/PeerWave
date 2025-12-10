import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

/// Reusable video prejoin widget for device selection and preview
/// Used by both meeting prejoin and video conference prejoin screens
class VideoPreJoinWidget extends StatefulWidget {
  final bool showE2EEStatus;
  final bool isFirstParticipant;
  final int participantCount;
  final bool isCheckingParticipants;
  final bool hasE2EEKey;
  final bool isExchangingKey;
  final String? keyExchangeError;
  final VoidCallback? onRetryKeyExchange;
  final void Function(MediaDevice? camera, MediaDevice? microphone, bool cameraEnabled, bool micEnabled)? onDeviceChanged;
  final bool voiceOnly;

  const VideoPreJoinWidget({
    Key? key,
    this.showE2EEStatus = false,
    this.isFirstParticipant = false,
    this.participantCount = 0,
    this.isCheckingParticipants = false,
    this.hasE2EEKey = false,
    this.isExchangingKey = false,
    this.keyExchangeError,
    this.onRetryKeyExchange,
    this.onDeviceChanged,
    this.voiceOnly = false,
  }) : super(key: key);

  @override
  State<VideoPreJoinWidget> createState() => VideoPreJoinWidgetState();
}

class VideoPreJoinWidgetState extends State<VideoPreJoinWidget> {
  List<MediaDevice> _cameras = [];
  List<MediaDevice> _microphones = [];
  MediaDevice? _selectedCamera;
  MediaDevice? _selectedMicrophone;
  bool _isLoadingDevices = true;
  
  LocalVideoTrack? _previewTrack;
  bool _isCameraEnabled = true;
  bool _isMicEnabled = true;

  MediaDevice? get selectedCamera => _selectedCamera;
  MediaDevice? get selectedMicrophone => _selectedMicrophone;
  bool get isCameraEnabled => _isCameraEnabled;
  bool get isMicEnabled => _isMicEnabled;
  bool get isLoadingDevices => _isLoadingDevices;

  @override
  void initState() {
    super.initState();
    if (!widget.voiceOnly) {
      _loadMediaDevices();
    } else {
      _loadAudioDevices();
    }
  }

  @override
  void dispose() {
    _previewTrack?.dispose();
    super.dispose();
  }

  /// Load audio devices only (for voice calls)
  Future<void> _loadAudioDevices() async {
    try {
      setState(() => _isLoadingDevices = true);

      LocalAudioTrack? tempAudioTrack;

      try {
        tempAudioTrack = await LocalAudioTrack.create(const AudioCaptureOptions());
        debugPrint('[VideoPreJoin] Audio permission granted');
      } catch (e) {
        debugPrint('[VideoPreJoin] Audio permission error: $e');
      }

      final devices = await Hardware.instance.enumerateDevices();
      _microphones = devices.where((d) => d.kind == 'audioinput').toList();
      _selectedMicrophone = _microphones.isNotEmpty ? _microphones.first : null;

      await tempAudioTrack?.dispose();

      setState(() => _isLoadingDevices = false);
      _notifyDeviceChange();

      debugPrint('[VideoPreJoin] Loaded ${_microphones.length} microphones');
    } catch (e) {
      debugPrint('[VideoPreJoin] Error loading audio devices: $e');
      setState(() => _isLoadingDevices = false);
    }
  }

  /// Load video and audio devices
  Future<void> _loadMediaDevices() async {
    try {
      setState(() => _isLoadingDevices = true);

      LocalVideoTrack? tempVideoTrack;
      LocalAudioTrack? tempAudioTrack;

      try {
        final results = await Future.wait([
          LocalVideoTrack.createCameraTrack(const CameraCaptureOptions()),
          LocalAudioTrack.create(const AudioCaptureOptions()),
        ]);

        tempVideoTrack = results[0] as LocalVideoTrack;
        tempAudioTrack = results[1] as LocalAudioTrack;

        debugPrint('[VideoPreJoin] Permissions granted');
      } catch (e) {
        debugPrint('[VideoPreJoin] Permission error: $e');
      }

      final devices = await Hardware.instance.enumerateDevices();

      _cameras = devices.where((d) => d.kind == 'videoinput').toList();
      _microphones = devices.where((d) => d.kind == 'audioinput').toList();

      _selectedCamera = _cameras.isNotEmpty ? _cameras.first : null;
      _selectedMicrophone = _microphones.isNotEmpty ? _microphones.first : null;

      await tempVideoTrack?.dispose();
      await tempAudioTrack?.dispose();

      setState(() => _isLoadingDevices = false);

      if (_isCameraEnabled && _selectedCamera != null) {
        await _startCameraPreview();
      }

      _notifyDeviceChange();

      debugPrint('[VideoPreJoin] Loaded ${_cameras.length} cameras, ${_microphones.length} microphones');
    } catch (e) {
      debugPrint('[VideoPreJoin] Error loading devices: $e');
      setState(() => _isLoadingDevices = false);
    }
  }

  Future<void> _startCameraPreview() async {
    try {
      if (_selectedCamera == null) return;

      await _previewTrack?.dispose();

      _previewTrack = await LocalVideoTrack.createCameraTrack(
        CameraCaptureOptions(
          deviceId: _selectedCamera!.deviceId,
        ),
      );

      setState(() {});
      debugPrint('[VideoPreJoin] Camera preview started');
    } catch (e) {
      debugPrint('[VideoPreJoin] Error starting preview: $e');
    }
  }

  void _toggleCamera() {
    setState(() => _isCameraEnabled = !_isCameraEnabled);

    if (_isCameraEnabled && _selectedCamera != null) {
      _startCameraPreview();
    } else {
      _previewTrack?.dispose();
      _previewTrack = null;
    }
    
    _notifyDeviceChange();
  }

  void _toggleMic() {
    setState(() => _isMicEnabled = !_isMicEnabled);
    _notifyDeviceChange();
  }

  void _notifyDeviceChange() {
    widget.onDeviceChanged?.call(
      _selectedCamera,
      _selectedMicrophone,
      _isCameraEnabled,
      _isMicEnabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingDevices) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Video Preview (if not voice only)
        if (!widget.voiceOnly)
          Expanded(
            flex: 3,
            child: _buildVideoPreview(),
          ),

        // Controls
        Expanded(
          flex: widget.voiceOnly ? 4 : 2,
          child: _buildControls(),
        ),
      ],
    );
  }

  Widget _buildVideoPreview() {
    return Container(
      color: Colors.black,
      child: _previewTrack != null && _isCameraEnabled
          ? VideoTrackRenderer(_previewTrack!)
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.videocam_off,
                    size: 64,
                    color: Colors.white.withOpacity(0.7),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _selectedCamera == null
                        ? 'Select a camera to preview'
                        : 'Camera off',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Device selection
          if (!widget.voiceOnly) ...[
            _buildDeviceSelection(),
            const SizedBox(height: 16),
          ] else ...[
            _buildMicrophoneSelection(),
            const SizedBox(height: 16),
          ],

          // Camera/Mic toggle buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!widget.voiceOnly)
                IconButton.filledTonal(
                  onPressed: _toggleCamera,
                  icon: Icon(_isCameraEnabled ? Icons.videocam : Icons.videocam_off),
                  iconSize: 28,
                ),
              if (!widget.voiceOnly) const SizedBox(width: 16),
              IconButton.filledTonal(
                onPressed: _toggleMic,
                icon: Icon(_isMicEnabled ? Icons.mic : Icons.mic_off),
                iconSize: 28,
              ),
            ],
          ),

          // E2EE Status (if enabled)
          if (widget.showE2EEStatus) ...[
            const SizedBox(height: 16),
            _buildE2EEStatus(),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceSelection() {
    return Column(
      children: [
        DropdownButtonFormField<MediaDevice>(
          value: _selectedCamera,
          decoration: const InputDecoration(
            labelText: 'Camera',
            prefixIcon: Icon(Icons.videocam),
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('No camera')),
            ..._cameras.map((d) => DropdownMenuItem(value: d, child: Text(d.label))),
          ],
          onChanged: (device) async {
            setState(() {
              _selectedCamera = device;
              _isCameraEnabled = device != null;
            });
            if (device != null) {
              await _startCameraPreview();
            } else {
              await _previewTrack?.dispose();
              _previewTrack = null;
            }
            _notifyDeviceChange();
          },
        ),
        const SizedBox(height: 8),
        _buildMicrophoneSelection(),
      ],
    );
  }

  Widget _buildMicrophoneSelection() {
    return DropdownButtonFormField<MediaDevice>(
      value: _selectedMicrophone,
      decoration: const InputDecoration(
        labelText: 'Microphone',
        prefixIcon: Icon(Icons.mic),
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('No microphone')),
        ..._microphones.map((d) => DropdownMenuItem(value: d, child: Text(d.label))),
      ],
      onChanged: (device) {
        setState(() => _selectedMicrophone = device);
        _notifyDeviceChange();
      },
    );
  }

  Widget _buildE2EEStatus() {
    if (widget.isCheckingParticipants) {
      return ListTile(
        leading: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
        title: Text('Checking participants...', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
        subtitle: Text('Verifying who else is in the call', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }

    if (widget.isFirstParticipant) {
      if (widget.hasE2EEKey) {
        return ListTile(
          leading: Icon(Icons.lock, color: Theme.of(context).colorScheme.primary, size: 32),
          title: Text('End-to-end encryption ready', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
          subtitle: Text('You are the first participant - encryption key generated', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        );
      } else if (widget.isExchangingKey) {
        return ListTile(
          leading: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
          title: Text('Generating encryption key...', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
          subtitle: Text('You are the first participant', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        );
      }
    }

    if (widget.isExchangingKey) {
      return ListTile(
        leading: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
        title: Text('Exchanging encryption keys...', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
        subtitle: Text('${widget.participantCount} ${widget.participantCount == 1 ? "participant" : "participants"} in call', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }

    if (widget.hasE2EEKey) {
      return ListTile(
        leading: Icon(Icons.lock, color: Theme.of(context).colorScheme.primary, size: 32),
        title: Text('End-to-end encryption ready', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
        subtitle: Text('Keys exchanged securely via Signal Protocol', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }

    return ListTile(
      leading: Icon(Icons.error, color: Theme.of(context).colorScheme.error, size: 32),
      title: Text('Key exchange failed', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
      subtitle: Text(widget.keyExchangeError ?? 'Unknown error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      trailing: widget.onRetryKeyExchange != null
          ? TextButton(
              onPressed: widget.onRetryKeyExchange,
              child: const Text('Retry'),
            )
          : null,
    );
  }
}
