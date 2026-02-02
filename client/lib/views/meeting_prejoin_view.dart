import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/meeting_service.dart';
import '../services/video_conference_service.dart';
import '../services/server_settings_service.dart';
import '../services/socket_service.dart'
    if (dart.library.io) '../services/socket_service_native.dart';
import '../services/api_service.dart';
import '../models/meeting.dart';
import '../extensions/snackbar_extensions.dart';
import '../widgets/video_prejoin_widget.dart';
import 'dart:async';
import 'package:intl/intl.dart';

/// PreJoin screen for meetings
/// Shows meeting details, device selection, and allows user to join
class MeetingPreJoinView extends StatefulWidget {
  final String meetingId;

  const MeetingPreJoinView({super.key, required this.meetingId});

  @override
  State<MeetingPreJoinView> createState() => _MeetingPreJoinViewState();
}

class _MeetingPreJoinViewState extends State<MeetingPreJoinView> {
  final _meetingService = MeetingService();
  final GlobalKey<VideoPreJoinWidgetState> _prejoinKey =
      GlobalKey<VideoPreJoinWidgetState>();

  // Meeting Data
  Meeting? _meeting;
  bool _isLoadingMeeting = true;
  String? _loadError;

  // E2EE State
  bool _isFirstParticipant = false;
  int _participantCount = 0;
  bool _isCheckingParticipants = false;
  bool _hasE2EEKey = false;
  bool _isExchangingKey = false;
  String? _keyExchangeError;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  /// Initialize prejoin
  Future<void> _initialize() async {
    await _loadMeeting();
    if (_meeting != null) {
      await _initializeE2EE();
    }
  }

  /// Load meeting details
  Future<void> _loadMeeting() async {
    try {
      if (!mounted) return;
      setState(() {
        _isLoadingMeeting = true;
        _loadError = null;
      });

      final meeting = await _meetingService.getMeeting(widget.meetingId);

      if (!mounted) return;
      setState(() {
        _meeting = meeting;
        _isLoadingMeeting = false;
      });

      debugPrint('[MeetingPreJoin] Loaded meeting: ${meeting.title}');
    } catch (e) {
      debugPrint('[MeetingPreJoin] Error loading meeting: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingMeeting = false;
        _loadError = 'Failed to load meeting: $e';
      });
    }
  }

  /// Initialize E2EE key exchange for meeting
  /// All meetings support video via on-demand LiveKit rooms (room name = meeting_id)
  Future<void> _initializeE2EE() async {
    try {
      debugPrint(
        '[MeetingPreJoin] Initializing E2EE for meeting ${widget.meetingId}',
      );
      debugPrint(
        '[MeetingPreJoin] LiveKit room will be created on-demand: ${_meeting!.meetingId}',
      );

      // Check socket connection (increased timeout for slower networks)
      if (!SocketService.instance.isConnected) {
        debugPrint('[MeetingPreJoin] Waiting for socket connection...');
        int attempts = 0;
        while (!SocketService.instance.isConnected && attempts < 150) {
          await Future.delayed(const Duration(milliseconds: 100));
          attempts++;
        }
        if (!SocketService.instance.isConnected) {
          throw Exception('Socket connection timeout after 15 seconds');
        }
      }

      // Register as participant using meeting ID as room identifier
      // This will trigger on-demand LiveKit room creation
      SocketService.instance.emit('video:register-participant', {
        'channelId': _meeting!.meetingId, // Use meeting ID as room identifier
      });

      // Check participant status
      await _checkParticipantStatus();

      // Load sender keys for the channel
      await _loadChannelSenderKeys();

      // Handle E2EE key exchange
      if (_isFirstParticipant) {
        await _generateE2EEKey();
      } else {
        await _requestE2EEKey();
      }
    } catch (e) {
      debugPrint('[MeetingPreJoin] E2EE initialization error: $e');
      if (!mounted) return;
      setState(() {
        _keyExchangeError = 'E2EE initialization failed: $e';
      });
    }
  }

  /// Check participant status
  Future<void> _checkParticipantStatus() async {
    try {
      if (!mounted) return;
      setState(() => _isCheckingParticipants = true);

      final completer = Completer<Map<String, dynamic>>();

      void listener(dynamic data) {
        if (data['channelId'] == _meeting!.meetingId) {
          completer.complete(Map<String, dynamic>.from(data));
        }
      }

      SocketService.instance.registerListener(
        'video:participants-info',
        listener,
        registrationName: 'MeetingPrejoinView',
      );

      SocketService.instance.emit('video:check-participants', {
        'channelId': _meeting!.meetingId, // Use meeting ID as room identifier
      });

      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => {'error': 'Timeout'},
      );

      SocketService.instance.unregisterListener(
        'video:participants-info',
        registrationName: 'MeetingPrejoinView',
      );

      if (result.containsKey('error')) {
        throw Exception(result['error']);
      }

      if (!mounted) return;
      setState(() {
        _isFirstParticipant = result['isFirstParticipant'] ?? false;
        _participantCount = result['participantCount'] ?? 0;
        _isCheckingParticipants = false;
      });

      debugPrint(
        '[MeetingPreJoin] Is first: $_isFirstParticipant, Count: $_participantCount',
      );
    } catch (e) {
      debugPrint('[MeetingPreJoin] Error checking participants: $e');
      if (!mounted) return;
      setState(() {
        _isCheckingParticipants = false;
        _keyExchangeError = 'Failed to check participants: $e';
      });
    }
  }

  /// Load sender keys for meeting participants
  Future<void> _loadChannelSenderKeys() async {
    try {
      // Get meeting participants instead of channel participants
      final response = await ApiService.instance.get(
        '/api/meetings/${_meeting!.meetingId}/participants',
      );

      if (response.data == null) return;

      final participants =
          response.data['participants'] as List<dynamic>? ?? [];

      for (final participant in participants) {
        final userId = participant['uuid'] as String?;
        final deviceId = participant['deviceId'] as int?;

        if (userId == null || deviceId == null) continue;

        // Skip our own device
        final signalClient = await ServerSettingsService.instance
            .getOrCreateSignalClient();
        if (userId == signalClient.getCurrentUserId?.call() &&
            deviceId == signalClient.getCurrentDeviceId?.call()) {
          continue;
        }

        // Note: Sender keys are now loaded on-demand when messages are received
        // in the new SignalClient architecture. Pre-loading is no longer needed.
        // The ensureSenderKeyForGroup method will handle this automatically.
        debugPrint(
          '[MeetingPreJoin] Participant registered: $userId:$deviceId (sender key will load on-demand)',
        );
      }
    } catch (e) {
      debugPrint('[MeetingPreJoin] Error loading sender keys: $e');
    }
  }

  /// Generate E2EE key (first participant)
  Future<void> _generateE2EEKey() async {
    try {
      if (!mounted) return;
      setState(() {
        _isExchangingKey = true;
        _keyExchangeError = null;
      });

      final success = await VideoConferenceService.generateE2EEKeyInPreJoin(
        _meeting!.meetingId,
      );

      if (!mounted) return;
      setState(() {
        _hasE2EEKey = success;
        _isExchangingKey = false;
        if (!success) _keyExchangeError = 'Failed to generate encryption key';
      });
    } catch (e) {
      debugPrint('[MeetingPreJoin] Error generating E2EE key: $e');
      if (!mounted) return;
      setState(() {
        _hasE2EEKey = false;
        _isExchangingKey = false;
        _keyExchangeError = 'Key generation error: $e';
      });
    }
  }

  /// Request E2EE key from existing participants
  Future<void> _requestE2EEKey() async {
    try {
      if (!mounted) return;
      setState(() {
        _isExchangingKey = true;
        _keyExchangeError = null;
      });

      final success = await VideoConferenceService.requestE2EEKey(
        _meeting!.meetingId,
      );

      if (!mounted) return;
      setState(() {
        _hasE2EEKey = success;
        _isExchangingKey = false;
        if (!success) _keyExchangeError = 'Failed to receive encryption key';
      });
    } catch (e) {
      debugPrint('[MeetingPreJoin] Error requesting E2EE key: $e');
      if (!mounted) return;
      setState(() {
        _hasE2EEKey = false;
        _isExchangingKey = false;
        _keyExchangeError = 'Key exchange error: $e';
      });
    }
  }

  /// Join the meeting
  Future<void> _joinMeeting() async {
    if (_meeting == null) return;

    // Check E2EE key (all meetings support video now)
    if (!_hasE2EEKey) {
      if (mounted) {
        context.showErrorSnackBar('Cannot join: Encryption key not ready');
      }
      return;
    }

    try {
      // Confirm E2EE key for meeting
      SocketService.instance.emit('video:confirm-e2ee-key', {
        'channelId': _meeting!.meetingId, // Use meeting ID as room identifier
      });

      // Get selected devices from VideoPreJoinWidget
      final selectedCamera = _prejoinKey.currentState?.selectedCamera;
      final selectedMicrophone = _prejoinKey.currentState?.selectedMicrophone;

      // Navigate to MeetingVideoConferenceView
      if (mounted) {
        context.push(
          '/meeting/video/${_meeting!.meetingId}',
          extra: {
            'meetingTitle': _meeting!.title,
            'selectedCamera': selectedCamera,
            'selectedMicrophone': selectedMicrophone,
          },
        );
      }
    } catch (e) {
      debugPrint('[MeetingPreJoin] Error joining: $e');
      if (mounted) {
        context.showErrorSnackBar('Failed to join: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingMeeting) {
      return Scaffold(
        appBar: AppBar(title: const Text('Join Meeting')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null || _meeting == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Join Meeting')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text(
                _loadError ?? 'Meeting not found',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final showE2EE = true; // All meetings support video with E2EE
    final canJoin = _hasE2EEKey;

    return Scaffold(
      appBar: AppBar(title: Text('Join ${_meeting!.title}')),
      body: Column(
        children: [
          // Meeting Info
          _buildMeetingInfo(),

          // Video PreJoin Widget (flexible, scrollable)
          Expanded(
            child: VideoPreJoinWidget(
              key: _prejoinKey,
              voiceOnly: _meeting!.voiceOnly,
              showE2EEStatus: showE2EE,
              isFirstParticipant: _isFirstParticipant,
              participantCount: _participantCount,
              isCheckingParticipants: _isCheckingParticipants,
              hasE2EEKey: _hasE2EEKey,
              isExchangingKey: _isExchangingKey,
              keyExchangeError: _keyExchangeError,
              onRetryKeyExchange: _requestE2EEKey,
            ),
          ),

          // Join Button (fixed at bottom)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: canJoin ? _joinMeeting : null,
                icon: const Icon(Icons.video_call),
                label: Text(
                  canJoin
                      ? 'Join Meeting'
                      : (_isExchangingKey
                            ? 'Exchanging Keys...'
                            : 'Waiting for Encryption...'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build meeting info section
  Widget _buildMeetingInfo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _meeting!.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),

          if (_meeting!.description != null) ...[
            const SizedBox(height: 4),
            Text(
              _meeting!.description!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
              ),
            ),
          ],

          const SizedBox(height: 8),

          // Meeting time
          if (_meeting!.scheduledStart != null)
            Row(
              children: [
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 4),
                Text(
                  DateFormat(
                    'EEEE, MMMM d, y \'at\' h:mm a',
                  ).format(_meeting!.scheduledStart!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),

          // Meeting settings
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (_meeting!.voiceOnly) _buildInfoChip(Icons.mic, 'Voice Only'),
              if (_meeting!.allowExternal)
                _buildInfoChip(Icons.link, 'External Guests'),
              if (_meeting!.muteOnJoin)
                _buildInfoChip(Icons.mic_off, 'Muted on Join'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Theme.of(context).colorScheme.onSurface),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
