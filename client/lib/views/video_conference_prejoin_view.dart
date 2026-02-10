import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/video_conference_service.dart';
import '../services/server_settings_service.dart';
import '../services/call_service.dart';
import '../services/socket_service.dart'
    if (dart.library.io) '../services/socket_service_native.dart';
import '../extensions/snackbar_extensions.dart';
import 'dart:async';

/// PreJoin screen for video conference
/// Shows device selection and handles E2EE key exchange BEFORE joining
class VideoConferencePreJoinView extends StatefulWidget {
  final String channelId;
  final String channelName;
  final Function(Map<String, dynamic>)?
  onJoinReady; // Callback when ready to join

  // Instant call parameters
  final bool isInstantCall;
  final String? sourceChannelId; // For channel calls
  final String? sourceUserId; // For 1:1 calls
  final bool isInitiator; // True if caller, false if recipient

  const VideoConferencePreJoinView({
    super.key,
    required this.channelId,
    required this.channelName,
    this.onJoinReady,
    this.isInstantCall = false,
    this.sourceChannelId,
    this.sourceUserId,
    this.isInitiator = false,
  });
  @override
  State<VideoConferencePreJoinView> createState() =>
      _VideoConferencePreJoinViewState();
}

class _VideoConferencePreJoinViewState
    extends State<VideoConferencePreJoinView> {
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
  List<String> _activeParticipantIds = [];

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
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[PreJoin] 🚀 INITIALIZING PREJOIN');
      debugPrint('[PreJoin] Channel: ${widget.channelId}');

      // Step 0: Check socket connection status
      final socketConnected = SocketService.instance.isConnected;
      debugPrint('[PreJoin] Socket connected: $socketConnected');

      if (!socketConnected) {
        debugPrint(
          '[PreJoin] ⚠️ Socket not connected! Waiting for connection...',
        );
        // Wait up to 5 seconds for socket to connect
        int attempts = 0;
        while (!SocketService.instance.isConnected && attempts < 50) {
          await Future.delayed(Duration(milliseconds: 100));
          attempts++;
        }

        if (!SocketService.instance.isConnected) {
          debugPrint('[PreJoin] ❌ Socket connection timeout after 5 seconds');
          if (mounted) {
            context.showErrorSnackBar(
              'Not connected to server. Please check your connection.',
            );
          }
          return;
        }

        debugPrint('[PreJoin] ✓ Socket connected after ${attempts * 100}ms');
      }

      // Check user authentication status
      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();
      final userId = signalClient.getCurrentUserId();
      final deviceId = signalClient.getCurrentDeviceId();
      debugPrint('[PreJoin] User authentication status:');
      debugPrint('[PreJoin]   - userId: $userId');
      debugPrint('[PreJoin]   - deviceId: $deviceId');
      debugPrint('═══════════════════════════════════════════════════════════');

      // Step 1: Check if already in a different channel - if so, leave it first
      final videoService = VideoConferenceService.instance;
      if (videoService.isInCall &&
          videoService.currentChannelId != widget.channelId) {
        debugPrint(
          '[PreJoin] Already in a different channel (${videoService.currentChannelId}), leaving it first...',
        );
        await videoService.leaveRoom();
        debugPrint(
          '[PreJoin] Left previous channel, proceeding with prejoin for ${widget.channelId}',
        );
      }

      videoService.resetE2EEState(channelId: widget.channelId, force: true);

      // Step 1: Ensure Signal Service is initialized (should already be initialized by app startup)
      if (!signalClient.isInitialized) {
        debugPrint(
          '[PreJoin] ⚠️ Signal Client not initialized! This should not happen.',
        );
        if (mounted) {
          context.showErrorSnackBar(
            'Signal Service not initialized. Please restart the app.',
          );
        }
        return;
      }

      // Step 2: Load available media devices
      await _loadMediaDevices();
      if (!mounted) return;

      // For 1:1 instant calls as initiator, skip participant checking and sender key loading
      // The call doesn't exist yet, so we're always first
      final is1v1CallInitiator =
          widget.isInstantCall &&
          widget.isInitiator &&
          widget.sourceUserId != null;

      if (is1v1CallInitiator) {
        debugPrint('[PreJoin] 1:1 call initiator - skipping participant check');
        setState(() {
          _isFirstParticipant = true;
          _participantCount = 0;
          _isCheckingParticipants = false;
        });
      } else {
        // Step 3: Register as participant (enters "waiting room")
        await _registerAsParticipant();
        if (!mounted) return;

        // Step 4: Check if first participant
        await _checkParticipantStatus();
        if (!mounted) return;

        // Step 4.5: Pre-load sender keys for this channel (CRITICAL for decryption)
        // This ensures we can decrypt video key responses from other participants
        await _loadChannelSenderKeys();
        if (!mounted) return;
      }

      // Step 4.8: Register E2EE listeners BEFORE requesting keys
      // This ensures the handlers are ready to receive responses
      debugPrint('[PreJoin] Registering E2EE listeners before key exchange');
      VideoConferenceService.instance.registerE2EEListeners(widget.channelId);
      if (!mounted) return;

      // Step 5: Handle E2EE key exchange
      if (_isFirstParticipant) {
        // First participant generates key immediately in PreJoin
        debugPrint('[PreJoin] First participant - generating E2EE key now');
        await _generateE2EEKey();
        if (!mounted) return;
      } else {
        // Request E2EE key from existing participants
        await _requestE2EEKey();
        if (!mounted) return;
      }

      // Step 6: Start camera preview with selected device
      if (_isCameraEnabled && _selectedCamera != null) {
        await _startCameraPreview();
      }
    } catch (e) {
      debugPrint('[PreJoin] Initialization error: $e');
      if (!mounted) return;
      setState(() {
        _keyExchangeError = 'Initialization failed: $e';
      });
    }
  }

  /// Load available cameras and microphones
  Future<void> _loadMediaDevices() async {
    try {
      if (!mounted) return;
      setState(() => _isLoadingDevices = true);

      // Request both camera and microphone permissions simultaneously
      debugPrint('[PreJoin] Requesting camera and microphone permissions...');

      LocalVideoTrack? tempVideoTrack;
      LocalAudioTrack? tempAudioTrack;

      try {
        // Create temporary tracks to trigger permission dialogs
        final results =
            await Future.wait<LocalTrack>([
              LocalVideoTrack.createCameraTrack(const CameraCaptureOptions()),
              LocalAudioTrack.create(const AudioCaptureOptions()),
            ]).timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                debugPrint('[PreJoin] ⚠️ Permission prompt timeout after 5s');
                return <LocalTrack>[];
              },
            );

        if (results.length >= 2) {
          tempVideoTrack = results[0] as LocalVideoTrack;
          tempAudioTrack = results[1] as LocalAudioTrack;
          debugPrint('[PreJoin] ✅ Permissions granted');
        } else {
          debugPrint(
            '[PreJoin] ⚠️ Permission flow did not complete, continuing',
          );
        }
      } catch (e) {
        debugPrint('[PreJoin] ⚠️ Permission denied or error: $e');
        // Continue anyway to show available devices
      }

      // Now enumerate devices with real labels (after permission granted)
      final devices = await Hardware.instance.enumerateDevices();

      _cameras = devices.where((d) => d.kind == 'videoinput').toList();
      _microphones = devices.where((d) => d.kind == 'audioinput').toList();

      // Auto-select first available devices
      _selectedCamera = _cameras.isNotEmpty ? _cameras.first : null;
      _selectedMicrophone = _microphones.isNotEmpty ? _microphones.first : null;

      // Dispose temporary tracks
      await tempVideoTrack?.dispose();
      await tempAudioTrack?.dispose();

      if (!mounted) return;
      setState(() => _isLoadingDevices = false);

      debugPrint(
        '[PreJoin] Loaded ${_cameras.length} cameras, ${_microphones.length} microphones',
      );
    } catch (e) {
      debugPrint('[PreJoin] Error loading devices: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingDevices = false;
        _keyExchangeError = 'Failed to load media devices: $e';
      });
    }
  }

  /// Register as participant on server
  Future<void> _registerAsParticipant() async {
    try {
      SocketService.instance.emit('video:register-participant', {
        'channelId': widget.channelId,
      });
      debugPrint('[PreJoin] Registered as participant');
    } catch (e) {
      debugPrint('[PreJoin] Error registering participant: $e');
    }
  }

  /// Check participant status (am I first?)
  Future<void> _checkParticipantStatus() async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[PreJoin][TEST] 🔍 CHECKING PARTICIPANT STATUS');
      debugPrint('[PreJoin][TEST] Channel ID: ${widget.channelId}');

      if (!mounted) return;
      setState(() => _isCheckingParticipants = true);

      // Listen for response
      final completer = Completer<Map<String, dynamic>>();

      void listener(dynamic data) {
        if (data['channelId'] == widget.channelId) {
          debugPrint(
            '[PreJoin][TEST] 📨 Received participants info from server',
          );
          completer.complete(Map<String, dynamic>.from(data));
        }
      }

      SocketService.instance.registerListener(
        'video:participants-info',
        listener,
        registrationName: 'VideoConferencePrejoinView',
      );

      // Request participant info
      debugPrint('[PreJoin][TEST] 📤 Emitting video:check-participants...');
      SocketService.instance.emit('video:check-participants', {
        'channelId': widget.channelId,
      });

      // Wait for response (timeout 5s)
      final result = await completer.future.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[PreJoin][TEST] ❌ TIMEOUT waiting for participant info');
          return {'error': 'Timeout'};
        },
      );

      SocketService.instance.unregisterListener(
        'video:participants-info',
        registrationName: 'VideoConferencePrejoinView',
      );

      if (result.containsKey('error')) {
        throw Exception(result['error']);
      }

      if (!mounted) return;
      setState(() {
        _isFirstParticipant = result['isFirstParticipant'] ?? false;
        _participantCount = result['participantCount'] ?? 0;
        _isCheckingParticipants = false;
        _activeParticipantIds = _extractParticipantIds(result);
      });

      debugPrint('[PreJoin][TEST] ✅ PARTICIPANT STATUS RECEIVED');
      debugPrint('[PreJoin][TEST] Is First Participant: $_isFirstParticipant');
      debugPrint('[PreJoin][TEST] Participant Count: $_participantCount');
      debugPrint('═══════════════════════════════════════════════════════════');
    } catch (e) {
      debugPrint('[PreJoin][TEST] ❌ ERROR checking participants: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      if (!mounted) return;
      setState(() {
        _isCheckingParticipants = false;
        _keyExchangeError = 'Failed to check participants: $e';
      });
    }
  }

  List<String> _extractParticipantIds(Map<String, dynamic> result) {
    final participants = result['participants'] as List<dynamic>? ?? [];
    return participants
        .map((participant) => participant['userId'] as String?)
        .whereType<String>()
        .toList();
  }

  /// Exchange sender keys for the channel
  /// CRITICAL: Must be called BEFORE E2EE key exchange to decrypt responses
  /// Creates and distributes our sender key, receives keys from other participants
  ///
  /// FORCE MODE: Always redistributes sender keys to all participants regardless of
  /// deduplication metadata. This ensures all participants can decrypt our messages.
  Future<void> _loadChannelSenderKeys() async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[PreJoin] 🔑 FORCE EXCHANGING SENDER KEYS FOR CHANNEL');
      debugPrint('[PreJoin] Channel: ${widget.channelId}');

      // Get signalClient (same way as text group channels)
      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClientWithStoredCredentials();

      final currentUserId = signalClient.getCurrentUserId();
      final currentDeviceId = signalClient.getCurrentDeviceId();

      // Check if we already have a sender key for this channel
      final hasSenderKey = await signalClient.messagingService.hasSenderKey(
        widget.channelId,
        currentUserId,
        currentDeviceId,
      );

      if (!hasSenderKey) {
        debugPrint(
          '[PreJoin] Creating and distributing sender key (force=true)...',
        );
        await signalClient.messagingService.ensureSenderKeyForGroup(
          widget.channelId,
          force: true, // Force distribution to all participants
          activeMemberIds: _activeParticipantIds.isEmpty
              ? null
              : _activeParticipantIds,
        );
        debugPrint('[PreJoin] ✓ Sender key created and force-distributed');
      } else {
        debugPrint('[PreJoin] ✓ Sender key exists, force-redistributing...');
        await signalClient.messagingService.ensureSenderKeyForGroup(
          widget.channelId,
          force: true, // Force redistribution regardless of metadata
          activeMemberIds: _activeParticipantIds.isEmpty
              ? null
              : _activeParticipantIds,
        );
        debugPrint(
          '[PreJoin] ✓ Sender key force-redistributed to all participants',
        );
      }

      // Give sender key distribution MORE time to propagate
      // Increased from 500ms to 2000ms to ensure delivery across network latency
      debugPrint('[PreJoin] ⏳ Waiting 2s for sender key propagation...');
      await Future.delayed(const Duration(milliseconds: 2000));

      debugPrint('[PreJoin] ✓ Sender key exchange completed');
      debugPrint('[PreJoin] All participants should now have our sender key');
      debugPrint('═══════════════════════════════════════════════════════════');
    } catch (e) {
      debugPrint('[PreJoin] ❌ Error exchanging sender keys: $e');
      debugPrint('[PreJoin] This may cause E2EE key decryption to fail');
      // Don't rethrow - continue anyway, keys might already exist
    }
  }

  /// Generate E2EE key (first participant)
  Future<void> _generateE2EEKey() async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[PreJoin][TEST] 🔐 GENERATING E2EE KEY (FIRST PARTICIPANT)');
      debugPrint('[PreJoin][TEST] Channel: ${widget.channelId}');

      if (!mounted) return;
      setState(() {
        _isExchangingKey = true;
        _keyExchangeError = null;
      });

      // Generate key via VideoConferenceService
      debugPrint(
        '[PreJoin][TEST] 📤 Calling VideoConferenceService.generateE2EEKeyInPreJoin...',
      );
      final success = await VideoConferenceService.generateE2EEKeyInPreJoin(
        widget.channelId,
      );

      if (!mounted) return;
      setState(() {
        _hasE2EEKey = success;
        _isExchangingKey = false;

        if (!success) {
          _keyExchangeError = 'Failed to generate encryption key';
        }
      });

      if (success) {
        debugPrint('[PreJoin][TEST] ✅ E2EE KEY GENERATION SUCCESSFUL');
        debugPrint(
          '[PreJoin][TEST] Key stored in VideoConferenceService singleton',
        );
        debugPrint(
          '[PreJoin][TEST] Ready to join call AND respond to key requests',
        );
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      } else {
        debugPrint('[PreJoin][TEST] ❌ E2EE KEY GENERATION FAILED');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
    } catch (e) {
      debugPrint('[PreJoin][TEST] ❌ ERROR generating E2EE key: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      if (!mounted) return;
      setState(() {
        _hasE2EEKey = false;
        _isExchangingKey = false;
        _keyExchangeError = 'Key generation error: $e';
      });
    }
  }

  /// Request E2EE key from existing participants
  /// First tries sender key-based exchange, falls back to 1-to-1 if that fails
  Future<void> _requestE2EEKey() async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[PreJoin][TEST] 🔐 REQUESTING E2EE KEY FROM PARTICIPANTS');
      debugPrint('[PreJoin][TEST] Channel: ${widget.channelId}');

      if (!mounted) return;
      setState(() {
        _isExchangingKey = true;
        _keyExchangeError = null;
      });

      // CRITICAL: Recheck participants before requesting key
      // (They might have left since the initial check)
      debugPrint(
        '[PreJoin][TEST] 🔄 Rechecking participants before key request...',
      );
      await _checkParticipantStatus();
      if (!mounted) return;

      if (_isFirstParticipant) {
        debugPrint(
          '[PreJoin][TEST] ⚠️ Room is now empty - generating key instead',
        );
        await _generateE2EEKey();
        return;
      }

      debugPrint(
        '[PreJoin][TEST] ✓ ${_participantCount} participant(s) still present',
      );

      // Try normal sender key-based exchange first
      debugPrint('[PreJoin][TEST] 📤 Attempt 1: Sender key-based exchange...');
      bool success = await VideoConferenceService.requestE2EEKey(
        widget.channelId,
      );

      // If that failed and we have more time, wait a bit longer for sender keys
      // then try again (sender keys might arrive late)
      if (!success) {
        debugPrint('[PreJoin][TEST] ⚠️ First attempt failed');
        debugPrint(
          '[PreJoin][TEST] 📤 Attempt 2: Retry after waiting for sender keys...',
        );

        // Give sender keys more time to propagate
        await Future.delayed(const Duration(seconds: 2));

        // Retry the request
        success = await VideoConferenceService.requestE2EEKey(widget.channelId);

        if (success) {
          debugPrint(
            '[PreJoin][TEST] ✅ Retry successful - key received after delay',
          );
        } else {
          debugPrint(
            '[PreJoin][TEST] ❌ Both attempts failed - sender keys may not be available',
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _hasE2EEKey = success;
        _isExchangingKey = false;

        if (!success) {
          _keyExchangeError =
              'Failed to receive encryption key. Sender keys may not be available yet.';
        }
      });

      if (success) {
        debugPrint('[PreJoin][TEST] ✅ E2EE KEY EXCHANGE SUCCESSFUL');
        debugPrint(
          '[PreJoin][TEST] Key stored in VideoConferenceService singleton',
        );
        debugPrint('[PreJoin][TEST] Ready to join call with encryption');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      } else {
        debugPrint('[PreJoin][TEST] ❌ E2EE KEY EXCHANGE FAILED');
        debugPrint(
          '[PreJoin][TEST] Reason: Sender key exchange may be incomplete',
        );
        debugPrint(
          '[PreJoin][TEST] Suggestion: Wait longer before requesting key',
        );
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
    } catch (e) {
      debugPrint('[PreJoin][TEST] ❌ ERROR requesting E2EE key: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      if (!mounted) return;
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
        CameraCaptureOptions(deviceId: _selectedCamera!.deviceId),
      );

      if (!mounted) return;
      setState(() {});
      debugPrint('[PreJoin] Camera preview started');
    } catch (e) {
      debugPrint('[PreJoin] Error starting camera preview: $e');
    }
  }

  /// Join the video call
  Future<void> _joinChannel() async {
    if (!_hasE2EEKey) {
      context.showErrorSnackBar('Cannot join: Encryption key not ready');
      return;
    }

    try {
      String meetingId = widget.channelId;

      // If this is an instant call and user is initiator, create call first
      if (widget.isInstantCall && widget.isInitiator) {
        debugPrint('[PreJoin] Creating instant call...');

        final callService = CallService();

        if (widget.sourceChannelId != null) {
          // Channel call
          meetingId = await callService.startChannelCall(
            channelId: widget.sourceChannelId!,
            channelName: widget.channelName,
          );
          debugPrint('[PreJoin] Created channel call: $meetingId');
        } else if (widget.sourceUserId != null) {
          // 1:1 call
          meetingId = await callService.startDirectCall(
            userId: widget.sourceUserId!,
            userName: widget.channelName,
          );
          debugPrint('[PreJoin] Created 1:1 call: $meetingId');
        }

        // Note: For instant calls, we notify recipients AFTER joining LiveKit
        // to avoid ringing if the initiator fails to join.
      }

      // Confirm E2EE key status to server
      SocketService.instance.emit('video:confirm-e2ee-key', <String, dynamic>{
        'channelId': meetingId,
      });

      final joinData = {
        'channelId': meetingId,
        'channelName': widget.channelName,
        'selectedCamera': _selectedCamera,
        'selectedMicrophone': _selectedMicrophone,
        'hasE2EEKey': true,
        'isInstantCall': widget.isInstantCall,
        'sourceChannelId': widget.sourceChannelId,
        'sourceUserId': widget.sourceUserId,
        'isInitiator': widget.isInitiator,
      };

      // If callback provided (embedded mode like dashboard), use callback
      if (widget.onJoinReady != null) {
        widget.onJoinReady!(joinData);
      } else {
        // If no callback (standalone navigation mode), pop with result
        if (!mounted) return;
        Navigator.of(context).pop(joinData);
      }
    } catch (e) {
      debugPrint('[PreJoin] Error joining channel: $e');
      if (!mounted) return;
      context.showErrorSnackBar('Failed to join: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Join ${widget.channelName}')),
      body: _isLoadingDevices
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Video Preview
                Expanded(flex: 3, child: _buildVideoPreview()),

                // Controls
                Expanded(flex: 2, child: _buildControls()),
              ],
            ),
    );
  }

  /// Build video preview section
  Widget _buildVideoPreview() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: _previewTrack != null && _isCameraEnabled
          ? VideoTrackRenderer(_previewTrack!)
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.videocam_off,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _selectedCamera == null
                        ? 'Select a camera to preview'
                        : 'Camera preview starting...',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Build controls section
  Widget _buildControls() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Device Selection
          _buildDeviceSelection(),

          const SizedBox(height: 16),

          // E2EE Status
          _buildE2EEStatus(),

          const Spacer(),

          // Join Button
          _buildJoinButton(),
        ],
      ),
    );
  }

  /// Build join button
  Widget _buildJoinButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: _hasE2EEKey && !_isExchangingKey ? _joinChannel : null,
        child: Text(
          _hasE2EEKey
              ? 'Join Call'
              : (_isExchangingKey
                    ? 'Exchanging Keys...'
                    : 'Waiting for Encryption Key...'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  /// Build device selection UI
  Widget _buildDeviceSelection() {
    return Column(
      children: [
        // Camera Selection
        DropdownButtonFormField<MediaDevice>(
          initialValue: _selectedCamera,
          decoration: InputDecoration(
            labelText: 'Camera',
            prefixIcon: Icon(
              Icons.videocam,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            border: const OutlineInputBorder(),
            hintText: 'Select a camera...',
            filled: false,
          ),
          items: [
            // Add "None" option
            const DropdownMenuItem<MediaDevice>(
              value: null,
              child: Text('No camera'),
            ),
            // Add all available cameras
            ..._cameras.map((device) {
              return DropdownMenuItem(value: device, child: Text(device.label));
            }),
          ],
          onChanged: (device) async {
            setState(() {
              _selectedCamera = device;
              _isCameraEnabled = device != null;
            });

            // Stop existing preview
            await _previewTrack?.dispose();
            _previewTrack = null;

            // Start preview with selected camera
            if (device != null) {
              debugPrint('[PreJoin] Camera selected: ${device.label}');
              await _startCameraPreview();
            }
          },
        ),

        const SizedBox(height: 8),

        // Microphone Selection
        DropdownButtonFormField<MediaDevice>(
          initialValue: _selectedMicrophone,
          decoration: InputDecoration(
            labelText: 'Microphone',
            prefixIcon: Icon(
              Icons.mic,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            border: const OutlineInputBorder(),
            hintText: 'Select a microphone...',
            filled: false,
          ),
          items: [
            // Add "None" option
            const DropdownMenuItem<MediaDevice>(
              value: null,
              child: Text('No microphone'),
            ),
            // Add all available microphones
            ..._microphones.map((device) {
              return DropdownMenuItem(value: device, child: Text(device.label));
            }),
          ],
          onChanged: (device) {
            setState(() => _selectedMicrophone = device);
            if (device != null) {
              debugPrint('[PreJoin] Microphone selected: ${device.label}');
            }
          },
        ),
      ],
    );
  }

  /// Build E2EE status indicator
  Widget _buildE2EEStatus() {
    if (_isCheckingParticipants) {
      return ListTile(
        leading: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          'Checking participants...',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        subtitle: Text(
          'Verifying who else is in the call',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (_isFirstParticipant) {
      if (_hasE2EEKey) {
        return ListTile(
          leading: Icon(
            Icons.lock,
            color: Theme.of(context).colorScheme.primary,
            size: 32,
          ),
          title: Text(
            'End-to-end encryption ready',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          subtitle: Text(
            'You are the first participant - encryption key generated',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      } else if (_isExchangingKey) {
        return ListTile(
          leading: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            'Generating encryption key...',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          subtitle: Text(
            'You are the first participant',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      } else {
        return ListTile(
          leading: Icon(
            Icons.lock,
            color: Theme.of(context).colorScheme.primary,
            size: 32,
          ),
          title: const Text('You are the first participant'),
          subtitle: const Text('Encryption key will be generated'),
        );
      }
    }

    if (_isExchangingKey) {
      return ListTile(
        leading: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          'Exchanging encryption keys...',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        subtitle: Text(
          '$_participantCount ${_participantCount == 1 ? "participant" : "participants"} in call',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (_hasE2EEKey) {
      return ListTile(
        leading: Icon(
          Icons.lock,
          color: Theme.of(context).colorScheme.primary,
          size: 32,
        ),
        title: Text(
          'End-to-end encryption ready',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        subtitle: Text(
          'Keys exchanged securely via Signal Protocol',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListTile(
      leading: Icon(
        Icons.error,
        color: Theme.of(context).colorScheme.error,
        size: 32,
      ),
      title: Text(
        'Key exchange failed',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
      ),
      subtitle: Text(
        _keyExchangeError ?? 'Unknown error',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      trailing: TextButton(
        onPressed: _requestE2EEKey,
        child: const Text('Retry'),
      ),
    );
  }
}
