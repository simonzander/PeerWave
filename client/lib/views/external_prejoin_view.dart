import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import '../utils/html_stub.dart' if (dart.library.html) 'dart:html' as html;
import 'dart:convert';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as signal;
import '../models/external_session.dart';
import '../services/external_participant_service.dart';
import '../services/external_guest_socket_service.dart';
import '../services/api_service.dart';
import '../widgets/video_prejoin_widget.dart';

/// Guest Flow State Machine
enum GuestFlowState {
  loading, // Initial state: generating Signal keys + loading meeting info
  discoveringParticipants, // Polling livekit-participants endpoint
  noParticipants, // No participants found (meeting not started)
  keyExchange, // Exchanging E2EE keys with participants via Signal
  partialKeyExchange, // Some keys received, some failed
  keyExchangeFailed, // All key exchanges failed
  readyToJoin, // All keys received, ready to request admission
  requestingAdmission, // Admission request sent, waiting for response
  admissionDeclined, // Admission request declined
  admitted, // Admission granted (handled by parent)
}

/// External Guest PreJoin View with Redesigned State Machine
///
/// New Flow:
/// 1. Loading → Generate Signal keys + load meeting info
/// 2. DiscoveringParticipants → Poll livekit-participants endpoint
/// 3. KeyExchange → Send key requests via WebSocket, wait for responses
/// 4. ReadyToJoin → User clicks "Join Meeting"
/// 5. RequestingAdmission → Wait for admit/decline
/// 6. Admitted/Declined → Handle result
class ExternalPreJoinView extends StatefulWidget {
  final String invitationToken;
  final VoidCallback onAdmitted;
  final VoidCallback onDeclined;

  const ExternalPreJoinView({
    super.key,
    required this.invitationToken,
    required this.onAdmitted,
    required this.onDeclined,
  });

  @override
  State<ExternalPreJoinView> createState() => _ExternalPreJoinViewState();
}

class _ExternalPreJoinViewState extends State<ExternalPreJoinView> {
  // === State Management ===
  GuestFlowState _currentState = GuestFlowState.loading;
  String? _errorMessage;

  // === Services ===
  final _externalService = ExternalParticipantService();
  final _guestSocket = ExternalGuestSocketService();

  // === Form & UI ===
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final GlobalKey<VideoPreJoinWidgetState> _prejoinKey =
      GlobalKey<VideoPreJoinWidgetState>();

  // === Signal Keys ===
  bool _isGeneratingKeys = true;
  String _keyGenStep = 'Initializing...';
  double _keyGenProgress = 0.0;
  bool _keysReady = false;

  // === Session Data ===
  ExternalSession? _session;
  String? _sessionId;

  // === Meeting Info ===
  String? _meetingId;
  String? _meetingTitle;
  String? _meetingDescription;
  DateTime? _meetingStartTime;
  DateTime? _meetingEndTime;

  // === Participant Discovery ===
  List<Map<String, dynamic>> _participants = [];
  int _participantCount = 0;
  Timer? _participantPollTimer;
  DateTime? _discoveryStartTime;

  // === Key Exchange ===
  Map<String, bool> _keyExchangeStatus = {}; // userId -> success/failure
  Timer? _keyExchangeTimeout;
  final Set<String> _receivedKeyResponses = {};

  // === Admission Request ===
  DateTime? _lastAdmissionRequest;
  bool _isRequestingAdmission = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _initialize();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _participantPollTimer?.cancel();
    _keyExchangeTimeout?.cancel();
    _guestSocket.disconnect();
    super.dispose();
  }

  // ========================================
  // INITIALIZATION
  // ========================================

  Future<void> _initialize() async {
    setState(() => _currentState = GuestFlowState.loading);

    try {
      // Run key generation and meeting info loading in parallel
      await Future.wait([_generateSignalKeys(), _loadMeetingInfo()]);

      // Register session and connect WebSocket
      if (_keysReady && _meetingId != null) {
        await _registerSession();
        await _connectWebSocket();
        _transitionTo(GuestFlowState.discoveringParticipants);
        _startParticipantDiscovery();
      } else {
        setState(() => _errorMessage = 'Initialization failed');
      }
    } catch (e) {
      debugPrint('[GuestPreJoin] Initialization error: $e');
      setState(() => _errorMessage = 'Failed to initialize: $e');
    }
  }

  // ========================================
  // MEETING INFO
  // ========================================

  Future<void> _loadMeetingInfo() async {
    try {
      final response = await ApiService.get(
        '/api/meetings/external/join/${widget.invitationToken}',
      );

      if (response.data != null && response.data['meeting'] != null) {
        final meeting = response.data['meeting'];
        setState(() {
          _meetingId = meeting['meeting_id'];
          _meetingTitle = meeting['title'];
          _meetingDescription = meeting['description'];
          _meetingStartTime = meeting['start_time'] != null
              ? DateTime.parse(meeting['start_time'])
              : null;
          _meetingEndTime = meeting['end_time'] != null
              ? DateTime.parse(meeting['end_time'])
              : null;
        });
      }
    } catch (e) {
      debugPrint('[GuestPreJoin] Error loading meeting info: $e');
      throw Exception('Failed to load meeting info');
    }
  }

  // ========================================
  // SIGNAL KEY GENERATION
  // ========================================

  Future<void> _generateSignalKeys() async {
    try {
      setState(() {
        _isGeneratingKeys = true;
        _keyGenStep = 'Checking existing keys...';
        _keyGenProgress = 0.1;
      });

      await Future.delayed(const Duration(milliseconds: 200));

      final storage = html.window.sessionStorage;
      final storedIdentity = storage['external_identity_key_public'];
      final storedSignedPre = storage['external_signed_pre_key'];
      final storedPreKeys = storage['external_pre_keys'];

      bool needNewIdentity = storedIdentity == null;
      bool needNewSignedPre = false;
      bool needNewPreKeys = false;

      // Check signed pre-key age (7 days max)
      if (storedSignedPre != null) {
        try {
          final signedPreJson = jsonDecode(storedSignedPre);
          final timestamp = signedPreJson['timestamp'] as int;
          final age = DateTime.now().millisecondsSinceEpoch - timestamp;
          final daysSinceCreation = age / (1000 * 60 * 60 * 24);
          needNewSignedPre = daysSinceCreation > 7;
        } catch (e) {
          needNewSignedPre = true;
        }
      } else {
        needNewSignedPre = true;
      }

      // Check pre-keys count
      if (storedPreKeys != null) {
        try {
          final preKeysJson = jsonDecode(storedPreKeys) as List;
          needNewPreKeys = preKeysJson.length < 30;
        } catch (e) {
          needNewPreKeys = true;
        }
      } else {
        needNewPreKeys = true;
      }

      // Step 2: Generate identity key if needed
      if (needNewIdentity) {
        setState(() {
          _keyGenStep = 'Generating identity keys...';
          _keyGenProgress = 0.25;
        });
        await Future.delayed(const Duration(milliseconds: 150));
        await _generateIdentityKey(storage);
      } else {
        setState(() {
          _keyGenStep = 'Identity keys found...';
          _keyGenProgress = 0.25;
        });
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Step 3: Generate signed pre-key if needed
      if (needNewSignedPre) {
        setState(() {
          _keyGenStep = 'Generating signed pre-key...';
          _keyGenProgress = 0.45;
        });
        await Future.delayed(const Duration(milliseconds: 150));
        await _generateSignedPreKey(storage);
      } else {
        setState(() {
          _keyGenStep = 'Signed pre-key valid...';
          _keyGenProgress = 0.45;
        });
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Step 4: Generate pre-keys if needed
      if (needNewPreKeys) {
        setState(() {
          _keyGenStep = 'Generating pre-keys (0/30)...';
          _keyGenProgress = 0.6;
        });
        await Future.delayed(const Duration(milliseconds: 100));
        await _generatePreKeys(storage);
      } else {
        setState(() {
          _keyGenStep = 'Pre-keys valid...';
          _keyGenProgress = 0.85;
        });
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Complete
      setState(() {
        _keyGenStep = 'Keys ready!';
        _keyGenProgress = 1.0;
        _isGeneratingKeys = false;
        _keysReady = true;
      });
    } catch (e) {
      debugPrint('[GuestPreJoin] Key generation error: $e');
      setState(() {
        _isGeneratingKeys = false;
        _keysReady = false;
        _errorMessage = 'Failed to generate encryption keys: $e';
      });
      rethrow;
    }
  }

  Future<void> _generateIdentityKey(dynamic storage) async {
    final identityKeyPair = signal.generateIdentityKeyPair();
    final publicKey = base64Encode(identityKeyPair.getPublicKey().serialize());
    final privateKey = base64Encode(
      identityKeyPair.getPrivateKey().serialize(),
    );
    storage['external_identity_key_public'] = publicKey;
    storage['external_identity_key_private'] = privateKey;
  }

  Future<void> _generateSignedPreKey(dynamic storage) async {
    final identityPublic = storage['external_identity_key_public']!;
    final identityPrivate = storage['external_identity_key_private']!;
    final publicKeyBytes = base64Decode(identityPublic);
    final privateKeyBytes = base64Decode(identityPrivate);
    final publicKey = signal.Curve.decodePoint(publicKeyBytes, 0);
    final privateKey = signal.Curve.decodePrivatePoint(privateKeyBytes);
    final identityKeyPair = signal.IdentityKeyPair(
      signal.IdentityKey(publicKey),
      privateKey,
    );
    final signedPreKey = signal.generateSignedPreKey(identityKeyPair, 1);

    final signedPreKeyData = {
      'id': 1,
      'publicKey': base64Encode(
        signedPreKey.getKeyPair().publicKey.serialize(),
      ),
      'privateKey': base64Encode(
        signedPreKey.getKeyPair().privateKey.serialize(),
      ),
      'signature': base64Encode(signedPreKey.signature),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    storage['external_signed_pre_key'] = jsonEncode(signedPreKeyData);
  }

  Future<void> _generatePreKeys(dynamic storage) async {
    final nextIdStr = storage['external_next_pre_key_id'] ?? '0';
    final startId = int.parse(nextIdStr);
    final preKeys = signal.generatePreKeys(startId, startId + 29);

    final preKeysJson = preKeys.map((pk) {
      return {
        'id': pk.id,
        'publicKey': base64Encode(pk.getKeyPair().publicKey.serialize()),
        'privateKey': base64Encode(pk.getKeyPair().privateKey.serialize()),
      };
    }).toList();

    for (int i = 0; i < preKeysJson.length; i++) {
      if (mounted) {
        setState(() {
          _keyGenStep = 'Generating pre-keys (${i + 1}/30)...';
          _keyGenProgress = 0.6 + ((i + 1) / 30) * 0.25;
        });
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }

    storage['external_pre_keys'] = jsonEncode(preKeysJson);
    storage['external_next_pre_key_id'] = (startId + 30).toString();
  }

  // ========================================
  // SESSION REGISTRATION
  // ========================================

  Future<void> _registerSession() async {
    if (!kIsWeb) return;

    try {
      final storage = html.window.sessionStorage;
      final identityPublic = storage['external_identity_key_public'];
      final signedPreKeyStr = storage['external_signed_pre_key'];
      final preKeysStr = storage['external_pre_keys'];

      if (identityPublic == null ||
          signedPreKeyStr == null ||
          preKeysStr == null) {
        throw Exception('E2EE keys not found');
      }

      final signedPreKey = jsonDecode(signedPreKeyStr);
      final preKeys = jsonDecode(preKeysStr) as List;

      final displayName = _nameController.text.trim().isNotEmpty
          ? _nameController.text.trim()
          : 'Guest';

      final session = await _externalService.joinMeeting(
        invitationToken: widget.invitationToken,
        displayName: displayName,
        identityKeyPublic: identityPublic,
        signedPreKey: signedPreKey,
        preKeys: preKeys,
      );

      storage['external_session_id'] = session.sessionId;
      storage['external_meeting_id'] = session.meetingId;
      storage['external_display_name'] = session.displayName;

      setState(() {
        _session = session;
        _sessionId = session.sessionId;
      });
    } catch (e) {
      debugPrint('[GuestPreJoin] Session registration error: $e');
      rethrow;
    }
  }

  // ========================================
  // WEBSOCKET CONNECTION
  // ========================================

  Future<void> _connectWebSocket() async {
    if (_sessionId == null || _meetingId == null) {
      debugPrint('[GuestPreJoin] Cannot connect - missing session/meeting ID');
      return;
    }

    try {
      await _guestSocket.connect(
        sessionId: _sessionId!,
        token: widget.invitationToken,
        meetingId: _meetingId!,
      );

      // Listen for participant E2EE key responses (meeting-specific event)
      _guestSocket.onParticipantE2EEKeyForMeeting(_meetingId!, (data) {
        _handleParticipantKeyResponse(data);
      });

      _guestSocket.onAdmissionGranted((data) {
        debugPrint('[GuestPreJoin] Admission granted!');
        _participantPollTimer?.cancel();
        widget.onAdmitted();
      });

      _guestSocket.onAdmissionDenied((data) {
        debugPrint('[GuestPreJoin] Admission denied');
        _transitionTo(GuestFlowState.admissionDeclined);
      });

      debugPrint('[GuestPreJoin] ✓ WebSocket connected');
    } catch (e) {
      debugPrint('[GuestPreJoin] WebSocket connection error: $e');
      setState(() => _errorMessage = 'Failed to connect to meeting server');
    }
  }

  // ========================================
  // PARTICIPANT DISCOVERY
  // ========================================

  void _startParticipantDiscovery() {
    _discoveryStartTime = DateTime.now();
    _pollParticipants(); // Immediate first poll

    _participantPollTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) {
      final elapsed = DateTime.now().difference(_discoveryStartTime!);
      if (elapsed.inMinutes >= 15) {
        // 15-minute timeout
        timer.cancel();
        setState(() {
          _errorMessage =
              'Discovery timeout: No participants found in 15 minutes';
        });
        return;
      }
      _pollParticipants();
    });
  }

  Future<void> _pollParticipants() async {
    if (_meetingId == null) return;

    try {
      final response = await ApiService.get(
        '/api/meetings/$_meetingId/livekit-participants',
        queryParameters: {'token': widget.invitationToken},
      );

      final participants = response.data['participants'] as List? ?? [];
      final endTime = response.data['end_time'];

      setState(() {
        _participants = participants.cast<Map<String, dynamic>>();
        _participantCount = participants.length;
      });

      if (_currentState == GuestFlowState.discoveringParticipants) {
        if (participants.isEmpty) {
          // Check if meeting ended vs not started
          if (endTime != null) {
            final meetingEnd = DateTime.parse(endTime);
            final now = DateTime.now();
            if (now.isAfter(meetingEnd)) {
              _transitionTo(GuestFlowState.noParticipants);
              setState(() => _errorMessage = 'This meeting has ended');
              _participantPollTimer?.cancel();
            } else {
              _transitionTo(GuestFlowState.noParticipants);
            }
          } else {
            _transitionTo(GuestFlowState.noParticipants);
          }
        } else {
          // Participants found - start key exchange
          _participantPollTimer?.cancel();
          _startKeyExchange();
        }
      }
    } catch (e) {
      debugPrint('[GuestPreJoin] Participant polling error: $e');
    }
  }

  void _retryParticipantDiscovery() {
    setState(() {
      _errorMessage = null;
      _currentState = GuestFlowState.discoveringParticipants;
    });
    _startParticipantDiscovery();
  }

  // ========================================
  // KEY EXCHANGE
  // ========================================

  void _startKeyExchange() {
    _transitionTo(GuestFlowState.keyExchange);

    // Initialize key exchange status
    _keyExchangeStatus = {};
    _receivedKeyResponses.clear();
    for (final participant in _participants) {
      final userId = participant['userId'] ?? participant['user_id'];
      if (userId != null) {
        _keyExchangeStatus[userId] = false;
      }
    }

    // Request E2EE key from all participants
    final displayName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : 'Guest';
    _guestSocket.requestE2EEKey(displayName);

    // Set 30-second timeout
    _keyExchangeTimeout = Timer(const Duration(seconds: 30), () {
      _handleKeyExchangeTimeout();
    });
  }

  void _handleParticipantKeyResponse(Map<String, dynamic> data) {
    final senderUserId = data['participant_user_id'] ?? data['sender_user_id'] ?? data['from_user_id'];
    if (senderUserId == null) {
      debugPrint('[GuestPreJoin] Received key response without sender ID');
      debugPrint('[GuestPreJoin] Response data: $data');
      _transitionTo(GuestFlowState.keyExchangeFailed);
      return;
    }

    // First-response-wins: ignore if already received from this user
    if (_receivedKeyResponses.contains(senderUserId)) {
      debugPrint('[GuestPreJoin] Ignoring duplicate key from $senderUserId');
      return;
    }

    _receivedKeyResponses.add(senderUserId);

    setState(() {
      _keyExchangeStatus[senderUserId] = true;
    });

    debugPrint(
      '[GuestPreJoin] ✓ Received E2EE key from $senderUserId (${_receivedKeyResponses.length}/${_participants.length})',
    );

    // Check if all keys received
    final allReceived = _keyExchangeStatus.values.every((received) => received);
    if (allReceived) {
      _keyExchangeTimeout?.cancel();
      _transitionTo(GuestFlowState.readyToJoin);
    }
  }

  void _handleKeyExchangeTimeout() {
    final receivedCount = _keyExchangeStatus.values
        .where((received) => received)
        .length;
    final totalCount = _keyExchangeStatus.length;

    if (receivedCount == 0) {
      // No keys received
      _transitionTo(GuestFlowState.keyExchangeFailed);
    } else if (receivedCount < totalCount) {
      // Partial keys received
      _transitionTo(GuestFlowState.partialKeyExchange);
    } else {
      // All keys received (this shouldn't happen, but handle it)
      _transitionTo(GuestFlowState.readyToJoin);
    }
  }

  void _retryKeyExchange() {
    _startKeyExchange();
  }

  // ========================================
  // ADMISSION REQUEST
  // ========================================

  Future<void> _requestAdmission() async {
    if (_sessionId == null || _meetingId == null) return;

    // Check cooldown (5 seconds)
    if (_lastAdmissionRequest != null) {
      final elapsed = DateTime.now().difference(_lastAdmissionRequest!);
      if (elapsed.inSeconds < 5) {
        final remaining = 5 - elapsed.inSeconds;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Please wait $remaining seconds before retrying'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _isRequestingAdmission = true;
      _lastAdmissionRequest = DateTime.now();
    });

    _transitionTo(GuestFlowState.requestingAdmission);

    try {
      await ApiService.post(
        '/api/meetings/$_meetingId/external/$_sessionId/request-admission',
      );

      debugPrint('[GuestPreJoin] Admission request sent');
      // Wait for socket events (admission_granted or admission_denied)
    } catch (e) {
      debugPrint('[GuestPreJoin] Admission request error: $e');
      setState(() {
        _isRequestingAdmission = false;
        _errorMessage = 'Failed to request admission: $e';
      });
      _transitionTo(GuestFlowState.readyToJoin);
    }
  }

  void _handleDeclined() {
    setState(() => _lastAdmissionRequest = null); // Reset cooldown
    _transitionTo(GuestFlowState.admissionDeclined);
  }

  // ========================================
  // STATE TRANSITIONS
  // ========================================

  void _transitionTo(GuestFlowState newState) {
    debugPrint('[GuestPreJoin] State: $_currentState → $newState');
    setState(() => _currentState = newState);
  }

  // ========================================
  // BUILD UI
  // ========================================

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Guest join is only available on web'),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Join Meeting as Guest'), elevation: 0),
      body: _buildStateView(),
    );
  }

  Widget _buildStateView() {
    switch (_currentState) {
      case GuestFlowState.loading:
        return _buildLoadingView();
      case GuestFlowState.discoveringParticipants:
        return _buildDiscoveringView();
      case GuestFlowState.noParticipants:
        return _buildNoParticipantsView();
      case GuestFlowState.keyExchange:
        return _buildKeyExchangeView();
      case GuestFlowState.partialKeyExchange:
        return _buildPartialKeyExchangeView();
      case GuestFlowState.keyExchangeFailed:
        return _buildKeyExchangeFailedView();
      case GuestFlowState.readyToJoin:
        return _buildReadyToJoinView();
      case GuestFlowState.requestingAdmission:
        return _buildRequestingAdmissionView();
      case GuestFlowState.admissionDeclined:
        return _buildAdmissionDeclinedView();
      case GuestFlowState.admitted:
        return _buildAdmittedView();
    }
  }

  Widget _buildLoadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _keyGenStep,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _keyGenProgress),
            if (_errorMessage != null) ...[
              const SizedBox(height: 24),
              Text(
                _errorMessage!,
                style: TextStyle(color: Colors.red[700]),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveringView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Discovering participants...',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Checking who\'s in the meeting',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoParticipantsView() {
    final meetingEnded = _errorMessage?.contains('ended') ?? false;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              meetingEnded ? Icons.event_busy : Icons.schedule,
              size: 64,
              color: meetingEnded ? Colors.red : Colors.orange,
            ),
            const SizedBox(height: 24),
            Text(
              meetingEnded
                  ? 'Meeting has ended'
                  : 'Meeting hasn\'t started yet',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              meetingEnded
                  ? 'This meeting is no longer active'
                  : 'Waiting for the host to join...',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (!meetingEnded)
              FilledButton.icon(
                onPressed: _retryParticipantDiscovery,
                icon: const Icon(Icons.refresh),
                label: const Text('Check Again'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyExchangeView() {
    final receivedCount = _keyExchangeStatus.values
        .where((received) => received)
        .length;
    final totalCount = _keyExchangeStatus.length;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.vpn_key,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Exchanging encryption keys',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Received $receivedCount of $totalCount keys',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            CircularProgressIndicator(value: receivedCount / totalCount),
            const SizedBox(height: 24),
            Text(
              'Please wait while we establish secure encryption with all participants...',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPartialKeyExchangeView() {
    final receivedCount = _keyExchangeStatus.values
        .where((received) => received)
        .length;
    final totalCount = _keyExchangeStatus.length;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.warning, size: 64, color: Colors.orange[700]),
            const SizedBox(height: 24),
            Text(
              'Partial key exchange',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Received $receivedCount of $totalCount keys',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.orange[700],
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Some participants did not respond. You can join with partial encryption or retry.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _retryKeyExchange,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: () => _transitionTo(GuestFlowState.readyToJoin),
                  icon: const Icon(Icons.check),
                  label: const Text('Continue Anyway'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyExchangeFailedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red[700]),
            const SizedBox(height: 24),
            Text(
              'Key exchange failed',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              'No participants responded with encryption keys',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _retryKeyExchange,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry Key Exchange'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadyToJoinView() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Success indicator
                Card(
                  color: Colors.green[50],
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green[700]),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Ready to join meeting',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.green[700],
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Meeting info
                if (_meetingTitle != null) _buildMeetingInfoCard(),
                const SizedBox(height: 16),

                // Device selection
                _buildDeviceSelectionCard(),
                const SizedBox(height: 16),

                // Name entry
                _buildNameEntryCard(),
              ],
            ),
          ),
        ),

        // Join button
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: () {
                if (_formKey.currentState!.validate()) {
                  _requestAdmission();
                }
              },
              icon: const Icon(Icons.video_call),
              label: const Text(
                'Join Meeting',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRequestingAdmissionView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(seconds: 2),
              builder: (context, value, child) {
                return Transform.scale(
                  scale: 0.8 + (value * 0.2),
                  child: child,
                );
              },
              onEnd: () {
                if (mounted) setState(() {});
              },
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.hourglass_empty,
                  size: 60,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Requesting admission...',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Waiting for the host to let you in',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildAdmissionDeclinedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.block, size: 64, color: Colors.red[700]),
            const SizedBox(height: 24),
            Text(
              'Request declined',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Your request to join was declined by the host',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    // Reload page
                    setState(() {
                      _currentState = GuestFlowState.loading;
                    });
                    _initialize();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh Page'),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: () {
                    _transitionTo(GuestFlowState.readyToJoin);
                  },
                  icon: const Icon(Icons.replay),
                  label: const Text('Try Again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdmittedView() {
    return const Center(child: CircularProgressIndicator());
  }

  // === Helper Widgets ===

  Widget _buildMeetingInfoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.videocam,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _meetingTitle!,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (_meetingDescription != null &&
                _meetingDescription!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _meetingDescription!,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              ),
            ],
            if (_participantCount > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.people, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 8),
                  Text(
                    '$_participantCount participant${_participantCount == 1 ? '' : 's'} in meeting',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceSelectionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.settings,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Device Setup',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              child: VideoPreJoinWidget(
                key: _prejoinKey,
                showE2EEStatus: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNameEntryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.person,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Your Name',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  hintText: 'Enter your display name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your name';
                  }
                  if (value.trim().length < 2) {
                    return 'Name must be at least 2 characters';
                  }
                  return null;
                },
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
