import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/video_quality_preset.dart';
import '../models/audio_settings.dart';
import 'video_quality_manager.dart';
import 'audio_processor_service.dart';
import 'api_service.dart';
import 'signal_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'message_listener_service.dart';
import 'windows_e2ee_manager.dart';
import 'sound_service.dart';

/// LiveKit-based Video Conference Service with Signal Protocol E2EE
///
/// This service provides:
/// - WebRTC video conferencing via LiveKit SFU
/// - End-to-end encryption using Signal Protocol for key exchange
/// - LiveKit's KeyProvider for frame-level encryption
/// - Real-time participant management
/// - Automatic reconnection handling
class VideoConferenceService extends ChangeNotifier {
  // Singleton pattern
  static final VideoConferenceService _instance =
      VideoConferenceService._internal();
  static VideoConferenceService get instance => _instance;

  VideoConferenceService._internal();

  // Factory constructor returns singleton
  factory VideoConferenceService() => _instance;

  // Core LiveKit components
  Room? _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;
  final Map<String, RemoteParticipant> _remoteParticipants = {};

  // E2EE components
  BaseKeyProvider? _keyProvider;
  Uint8List? _channelSharedKey; // ONE shared key for the entire channel
  int?
  _keyTimestamp; // Timestamp of current key (for race condition resolution)
  final Map<String, Uint8List> _participantKeys =
      {}; // userId -> encryption key (legacy, for backward compat)
  Completer<bool>?
  _keyReceivedCompleter; // For waiting on key exchange in PreJoin
  bool _isFirstParticipant =
      false; // Track if this participant originated the key

  // Security level tracking
  final String _encryptionLevel = 'none'; // 'none', 'transport', 'e2ee'
  String get encryptionLevel => _encryptionLevel;

  // Video quality settings
  VideoQualitySettings _videoQualitySettings = VideoQualitySettings.defaults();
  VideoQualitySettings get videoQualitySettings => _videoQualitySettings;

  // Audio settings
  AudioSettings _audioSettings = AudioSettings.defaults();
  AudioSettings get audioSettings => _audioSettings;

  // Per-participant audio state
  final Map<String, ParticipantAudioState> _participantAudioStates = {};

  // Service integrations
  final VideoQualityManager _qualityManager = VideoQualityManager.instance;
  final AudioProcessorService _audioProcessor = AudioProcessorService.instance;

  // State management
  String? _currentChannelId;
  String? _currentRoomName;
  bool _isConnected = false;
  bool _isConnecting = false;

  // NEW: Persistent call state for overlay
  bool _isInCall = false;
  String? _channelName;
  DateTime? _callStartTime;

  // NEW: Screen share state
  String? _currentScreenShareParticipantId;

  // NEW: Overlay state
  bool _isOverlayVisible = true;
  bool _isInFullView =
      false; // Track if user is viewing full-screen (vs overlay mode)
  double _overlayPositionX = 100;
  double _overlayPositionY = 100;

  // Stream controllers
  final _participantJoinedController =
      StreamController<RemoteParticipant>.broadcast();
  final _participantLeftController =
      StreamController<RemoteParticipant>.broadcast();
  final _trackSubscribedController =
      StreamController<TrackSubscribedEvent>.broadcast();

  // Getters
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get currentChannelId => _currentChannelId;
  List<RemoteParticipant> get remoteParticipants =>
      _remoteParticipants.values.toList();
  Room? get room => _room;
  bool get isFirstParticipant =>
      _isFirstParticipant; // Check if this participant originated the key
  bool get hasE2EEKey =>
      _keyTimestamp !=
      null; // Check if E2EE key is available (generated or received)
  Uint8List? get channelSharedKey =>
      _channelSharedKey; // E2EE key for the meeting

  // NEW: Overlay state getters
  bool get isInCall => _isInCall;
  String? get channelName => _channelName;
  DateTime? get callStartTime => _callStartTime;
  bool get isMeeting =>
      _currentChannelId != null &&
      (_currentChannelId!.startsWith('mtg_') ||
          _currentChannelId!.startsWith('call_'));
  bool get isOverlayVisible => _isOverlayVisible;
  bool get isInFullView => _isInFullView;
  double get overlayPositionX => _overlayPositionX;
  double get overlayPositionY => _overlayPositionY;

  // NEW: Screen share state getters
  String? get currentScreenShareParticipantId =>
      _currentScreenShareParticipantId;
  bool get hasActiveScreenShare => _currentScreenShareParticipantId != null;

  /// Check if a channel ID is a meeting (not a permanent channel)
  static bool _isMeetingChannel(String channelId) {
    return channelId.startsWith('mtg_') || channelId.startsWith('call_');
  }

  // Streams
  Stream<RemoteParticipant> get onParticipantJoined =>
      _participantJoinedController.stream;
  Stream<RemoteParticipant> get onParticipantLeft =>
      _participantLeftController.stream;
  Stream<TrackSubscribedEvent> get onTrackSubscribed =>
      _trackSubscribedController.stream;

  /// Wait for SignalService to have user info set (from socket authentication)
  /// This is critical for E2EE key exchange to work properly
  static Future<void> _waitForUserInfo({
    int maxRetries = 30,
    Duration retryDelay = const Duration(milliseconds: 100),
  }) async {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('[VideoConf] ⏳ WAITING FOR USER AUTHENTICATION');
    debugPrint('[VideoConf] Current state:');
    debugPrint(
      '[VideoConf]   - userId: ${SignalService.instance.currentUserId}',
    );
    debugPrint(
      '[VideoConf]   - deviceId: ${SignalService.instance.currentDeviceId}',
    );
    debugPrint(
      '[VideoConf] ═══════════════════════════════════════════════════════════',
    );

    for (int i = 0; i < maxRetries; i++) {
      if (SignalService.instance.currentUserId != null &&
          SignalService.instance.currentDeviceId != null) {
        debugPrint(
          '[VideoConf] ✓ User info available after ${i + 1} attempts (${(i + 1) * retryDelay.inMilliseconds}ms)',
        );
        debugPrint(
          '[VideoConf]   - userId: ${SignalService.instance.currentUserId}',
        );
        debugPrint(
          '[VideoConf]   - deviceId: ${SignalService.instance.currentDeviceId}',
        );
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        return;
      }

      if (i % 10 == 0 && i > 0) {
        debugPrint(
          '[VideoConf] ⏳ Still waiting for user info... (attempt ${i + 1}/$maxRetries, ${(i + 1) * retryDelay.inMilliseconds}ms elapsed)',
        );
      }
      await Future.delayed(retryDelay);
    }

    debugPrint(
      '[VideoConf] ❌ TIMEOUT: User info not set after ${maxRetries * retryDelay.inMilliseconds}ms',
    );
    debugPrint('═══════════════════════════════════════════════════════════');
    throw Exception(
      'Timeout waiting for user authentication. User info not set after ${maxRetries * retryDelay.inMilliseconds}ms',
    );
  }

  /// Get meeting participants who have E2EE key (for key request targeting)
  static Future<List<String>> _getMeetingParticipantsWithKey(
    String meetingId,
  ) async {
    try {
      debugPrint(
        '[VideoConf] 🔍 Getting participants with E2EE key for: $meetingId',
      );
      final completer = Completer<List<String>>();

      void listener(dynamic data) {
        debugPrint('[VideoConf] 📥 Received video:participants-info: $data');
        if (data['channelId'] == meetingId) {
          final participants = data['participants'] as List<dynamic>? ?? [];
          debugPrint('[VideoConf] All participants: ${participants.length}');
          final withKey = participants
              .where((p) => p['hasE2EEKey'] == true)
              .map((p) => p['userId'] as String)
              .toList();
          debugPrint(
            '[VideoConf] ✓ Participants with E2EE key: ${withKey.length} - $withKey',
          );
          completer.complete(withKey);
        } else {
          debugPrint(
            '[VideoConf] ⚠️ Ignoring participants-info for different channel: ${data['channelId']}',
          );
        }
      }

      SocketService().registerListener(
        'video:participants-info',
        listener,
        registrationName: 'VideoConferenceService',
      );

      debugPrint(
        '[VideoConf] 📤 Emitting video:check-participants for: $meetingId',
      );
      SocketService().emit('video:check-participants', {
        'channelId': meetingId,
      });

      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[VideoConf] ⏱️ Timeout waiting for participants info');
          return <String>[];
        },
      );

      SocketService().unregisterListener(
        'video:participants-info',
        registrationName: 'VideoConferenceService',
      );

      return result;
    } catch (e) {
      debugPrint('[VideoConf] ❌ Error getting meeting participants: $e');
      return [];
    }
  }

  /// Generate E2EE Key in PreJoin (called by FIRST participant from PreJoin)
  /// This is a static method so PreJoin screen can call it before joining
  /// Returns true if key was generated successfully, false otherwise
  static Future<bool> generateE2EEKeyInPreJoin(String channelId) async {
    final service = VideoConferenceService.instance;

    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[PreJoin][TEST] 🔐 GENERATING E2EE KEY (FIRST PARTICIPANT)');
      debugPrint('[PreJoin][TEST] Channel: $channelId');

      // CRITICAL: Wait for user info to be set (socket authentication)
      await _waitForUserInfo();

      // Set channel ID
      service._currentChannelId = channelId;
      debugPrint('[PreJoin][TEST] ✓ Channel ID set on service instance');

      // Register service with MessageListenerService to handle key requests
      debugPrint(
        '[PreJoin][TEST] 📝 Registering service with MessageListenerService...',
      );
      final messageListener = MessageListenerService.instance;
      messageListener.registerVideoConferenceService(service);
      debugPrint(
        '[PreJoin][TEST] ✓ Service registered, ready to respond to key requests',
      );

      // Initialize E2EE (generate key, create KeyProvider, initialize sender key)
      await service._initializeE2EE();

      debugPrint('[PreJoin][TEST] ✅ E2EE KEY GENERATION SUCCESSFUL');
      debugPrint(
        '[PreJoin][TEST] Key stored in VideoConferenceService singleton',
      );
      debugPrint(
        '[PreJoin][TEST] Ready to join call AND respond to key requests',
      );
      debugPrint('═══════════════════════════════════════════════════════════');

      return true;
    } catch (e) {
      debugPrint('[PreJoin][TEST] ❌ ERROR generating E2EE key: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      return false;
    }
  }

  /// Request E2EE Key from existing participants (called by NON-first participants from PreJoin)
  /// This is a static method so PreJoin screen can call it before joining
  /// Returns true if key was received successfully, false otherwise
  ///
  /// For meetings (mtg_*, call_*): Uses sendItem (1-to-1 Signal) to request key from participants
  /// For video channels: Uses sendGroupItem with SignalSenderKey
  static Future<bool> requestE2EEKey(String channelId) async {
    final service = VideoConferenceService.instance;
    final isMeeting = _isMeetingChannel(channelId);

    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[VideoConf][TEST] 🔑 REQUESTING E2EE KEY');
      debugPrint('[VideoConf][TEST] Channel: $channelId');
      debugPrint('[VideoConf][TEST] Is Meeting: $isMeeting');

      // CRITICAL: Wait for user info to be set (socket authentication)
      await _waitForUserInfo();

      // ⚠️ CRITICAL: Set channel ID so response handler knows which channel this is for
      service._currentChannelId = channelId;
      debugPrint('[VideoConf][TEST] ✓ Channel ID set on service instance');

      // ⚠️ CRITICAL: Register this service instance with MessageListenerService
      // so it receives E2EE key responses
      debugPrint(
        '[VideoConf][TEST] 📝 Registering service with MessageListenerService...',
      );
      final messageListener = MessageListenerService.instance;
      messageListener.registerVideoConferenceService(service);
      debugPrint(
        '[VideoConf][TEST] ✓ Service registered, ready to receive key responses',
      );

      final requestTimestamp = DateTime.now().millisecondsSinceEpoch;

      // Get current user ID from SignalService
      final userId = SignalService.instance.currentUserId ?? 'unknown';

      debugPrint('[VideoConf][TEST] Requester ID: $userId');
      debugPrint('[VideoConf][TEST] Request Timestamp: $requestTimestamp');
      debugPrint('[VideoConf][TEST] Message Type: meeting_e2ee_key_request');

      if (isMeeting) {
        // For meetings: Use sendItem (1-to-1 Signal encrypted messages)
        // Get participants with E2EE key from server
        debugPrint(
          '[VideoConf][TEST] 🔍 Getting meeting participants with E2EE key...',
        );

        final participants = await _getMeetingParticipantsWithKey(channelId);

        if (participants.isEmpty) {
          debugPrint(
            '[VideoConf][TEST] ⚠️ No participants with E2EE key found',
          );
          return false;
        }

        debugPrint(
          '[VideoConf][TEST] Found ${participants.length} participant(s) with key',
        );

        // Send key request to each participant via Signal sendItem
        for (final participantUserId in participants) {
          if (participantUserId == userId) continue; // Skip self

          debugPrint(
            '[VideoConf][TEST] 📤 Sending key request to $participantUserId via Signal sendItem',
          );

          await SignalService.instance.sendItem(
            recipientUserId: participantUserId,
            type: 'meeting_e2ee_key_request', // Special type, not stored
            payload: jsonEncode({
              'meetingId': channelId,
              'requesterId': userId,
              'timestamp': requestTimestamp,
            }),
            itemId: 'mtg_key_req_${requestTimestamp}_$participantUserId',
          );
        }

        debugPrint(
          '[VideoConf][TEST] ✓ Key requests sent via Signal Protocol (1-to-1)',
        );
      } else {
        // For video channels: Use sendGroupItem with SignalSenderKey
        debugPrint(
          '[VideoConf][TEST] 🔧 Initializing sender key for channel...',
        );
        try {
          await SignalService.instance.createGroupSenderKey(channelId);
          debugPrint('[VideoConf][TEST] ✓ Sender key initialized');
        } catch (e) {
          debugPrint(
            '[VideoConf][TEST] ⚠️ Sender key initialization failed: $e',
          );
          try {
            final loaded = await SignalService.instance.loadSenderKeyFromServer(
              channelId: channelId,
              userId: SignalService.instance.currentUserId!,
              deviceId: SignalService.instance.currentDeviceId!,
              forceReload: true,
            );
            if (loaded) {
              debugPrint('[VideoConf][TEST] ✓ Sender key restored from server');
            }
          } catch (recoveryError) {
            debugPrint(
              '[VideoConf][TEST] ⚠️ Failed to load from server: $recoveryError',
            );
          }
        }

        // Send key request via Signal Protocol (encrypted group message)
        await SignalService.instance.sendGroupItem(
          channelId: channelId,
          message: jsonEncode({
            'requesterId': userId,
            'timestamp': requestTimestamp,
          }),
          itemId: 'video_key_req_$requestTimestamp',
          type: 'video_e2ee_key_request',
        );

        debugPrint(
          '[VideoConf][TEST] ✓ Key request sent via Signal Protocol (group)',
        );
      }

      debugPrint(
        '[VideoConf][TEST] ⏳ Waiting for key response (10 second timeout)...',
      );

      // Clean up any existing completer before creating a new one
      if (service._keyReceivedCompleter != null) {
        debugPrint(
          '[VideoConf][TEST] ⚠️ Existing completer found - cleaning up...',
        );
        if (!service._keyReceivedCompleter!.isCompleted) {
          service._keyReceivedCompleter!.completeError(
            Exception('New key request initiated'),
          );
        }
        service._keyReceivedCompleter = null;
      }

      // Wait for key response (handled by MessageListenerService)
      service._keyReceivedCompleter = Completer<bool>();

      // Timeout after 10 seconds
      try {
        return await service._keyReceivedCompleter!.future.timeout(
          Duration(seconds: 10),
          onTimeout: () {
            debugPrint(
              '[VideoConf][TEST] ❌ KEY REQUEST TIMEOUT - No response in 10 seconds',
            );
            debugPrint(
              '═══════════════════════════════════════════════════════════',
            );
            return false;
          },
        );
      } finally {
        // Always clean up the completer after waiting
        service._keyReceivedCompleter = null;
      }
    } catch (e) {
      debugPrint('[VideoConf][TEST] ❌ ERROR requesting E2EE key: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      return false;
    }
  }

  /// Initialize E2EE with Signal Protocol key exchange
  Future<void> _initializeE2EE() async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[VideoConf][TEST] 🔐 INITIALIZING E2EE (FIRST PARTICIPANT)');

      // Generate ONE shared key for this channel
      // The first participant generates, others receive it via Signal Protocol
      final random = Random.secure();
      _channelSharedKey = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      );

      // Store timestamp for race condition resolution (oldest wins)
      _keyTimestamp = DateTime.now().millisecondsSinceEpoch;

      // Mark this participant as the key originator (first participant)
      _isFirstParticipant = true;

      final keyBase64 = base64Encode(_channelSharedKey!);
      final keyPreview = keyBase64.substring(0, 16);

      debugPrint(
        '[VideoConf][TEST] Key Generated: $keyPreview... (${_channelSharedKey!.length} bytes)',
      );
      debugPrint('[VideoConf][TEST] Key Timestamp: $_keyTimestamp');
      debugPrint(
        '[VideoConf][TEST] Is First Participant: $_isFirstParticipant',
      );

      // ⚠️ IMPORTANT: Initialize sender key for responding to key requests
      // First participant needs sender key to send key responses to new joiners
      // For meetings: Skip sender key - we use 1-to-1 Signal messages instead
      if (_currentChannelId != null && !_isMeetingChannel(_currentChannelId!)) {
        debugPrint(
          '[VideoConf][TEST] 🔧 Initializing sender key for channel (video channel)...',
        );
        try {
          // Validate sender key - will check server if corrupted locally
          await SignalService.instance.createGroupSenderKey(_currentChannelId!);
          debugPrint(
            '[VideoConf][TEST] ✓ Sender key initialized (ready to respond to key requests)',
          );
        } catch (e) {
          debugPrint(
            '[VideoConf][TEST] ⚠️ Sender key initialization failed: $e',
          );
          // Try to recover by loading from server
          try {
            debugPrint(
              '[VideoConf][TEST] Attempting to load sender key from server...',
            );
            final loaded = await SignalService.instance.loadSenderKeyFromServer(
              channelId: _currentChannelId!,
              userId: SignalService.instance.currentUserId!,
              deviceId: SignalService.instance.currentDeviceId!,
              forceReload: true,
            );
            if (loaded) {
              debugPrint('[VideoConf][TEST] ✓ Sender key restored from server');
            } else {
              debugPrint(
                '[VideoConf][TEST] ⚠️ No sender key on server - will be created on first send',
              );
            }
          } catch (recoveryError) {
            debugPrint(
              '[VideoConf][TEST] ⚠️ Failed to load from server: $recoveryError',
            );
            // Will be created automatically during sendGroupItem if needed
          }
        }
      } else if (_currentChannelId != null) {
        debugPrint(
          '[VideoConf][TEST] ℹ️ Meeting detected - skipping sender key (using 1-to-1 Signal)',
        );
      }

      // Create BaseKeyProvider for E2EE
      // Use LiveKit's built-in E2EE support properly
      try {
        _keyProvider = await BaseKeyProvider.create();

        // Set the shared key in KeyProvider (setKey auto-calls setSharedKey in shared mode)
        await _keyProvider!.setKey(keyBase64);

        debugPrint('[VideoConf][TEST] ✓ BaseKeyProvider created successfully');
        debugPrint(
          '[VideoConf][TEST] ✓ Key set in KeyProvider (AES-256 frame encryption ready)',
        );
        debugPrint('[VideoConf][TEST] 📊 KEY STATE:');
        debugPrint('[VideoConf][TEST]    - Key Preview: $keyPreview...');
        debugPrint('[VideoConf][TEST]    - Timestamp: $_keyTimestamp');
        debugPrint('[VideoConf][TEST]    - Channel: $_currentChannelId');
        if (!kIsWeb) {
          debugPrint(
            '[VideoConf][TEST] ℹ️ Native platform: Frame encryption enabled',
          );
        }
      } catch (e) {
        debugPrint('[VideoConf][TEST] ⚠️ Failed to create BaseKeyProvider: $e');
        rethrow;
      }

      debugPrint('[VideoConf][TEST] ✓ E2EE INITIALIZATION COMPLETE');
      debugPrint(
        '[VideoConf][TEST] ✓ Role: KEY ORIGINATOR (first participant)',
      );
      debugPrint('═══════════════════════════════════════════════════════════');
    } catch (e) {
      debugPrint('[VideoConf] E2EE initialization error: $e');
      rethrow;
    }
  }

  /// Exchange encryption keys using Signal Protocol
  /// Sends the SHARED CHANNEL KEY to new participants via Signal Protocol
  /// Uses sendGroupItem for E2EE transport layer
  Future<void> _exchangeKeysWithParticipant(String participantUserId) async {
    try {
      if (_channelSharedKey == null || _currentChannelId == null) {
        debugPrint(
          '[VideoConf] ⚠️ Key or channel not initialized, skipping key exchange',
        );
        return;
      }

      // Check if we're the first participant (room creator)
      final isFirstParticipant =
          _remoteParticipants.isEmpty || _remoteParticipants.length == 1;

      final itemId = 'video_key_${DateTime.now().millisecondsSinceEpoch}';

      if (!isFirstParticipant) {
        debugPrint(
          '[VideoConf] Not first participant, requesting key from $participantUserId',
        );

        // Send key request via Signal Protocol (encrypted group message)
        await SignalService.instance.sendGroupItem(
          channelId: _currentChannelId!,
          message: jsonEncode({
            'type': 'video_key_request',
            'requesterId': participantUserId,
          }),
          itemId: itemId,
          type: 'video_key_request',
        );
        return;
      }

      debugPrint(
        '[VideoConf] First participant - sending shared key to: $participantUserId',
      );

      // Send the shared key via Signal Protocol (encrypted group message)
      final keyBase64 = base64Encode(_channelSharedKey!);

      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'targetUserId': participantUserId,
          'encryptedKey': keyBase64,
          'timestamp': _keyTimestamp, // Include ORIGINAL timestamp
        }),
        itemId: itemId,
        type: 'video_e2ee_key_response', // Use new format with timestamp
      );

      debugPrint(
        '[VideoConf] ✓ Shared key sent via Signal Protocol (${_channelSharedKey!.length} bytes)',
      );
      debugPrint(
        '[VideoConf] ✓ Key will enable frame-level encryption for all participants',
      );
    } catch (e) {
      debugPrint('[VideoConf] Key exchange error: $e');
    }
  }

  /// Handle incoming E2EE key from Signal Protocol
  /// Receives the SHARED CHANNEL KEY from existing participants
  Future<void> handleE2EEKey({
    required String senderUserId,
    required String encryptedKey,
    required String channelId,
    required int timestamp, // For race condition resolution
  }) async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[VideoConf][TEST] 📨 RECEIVED E2EE KEY MESSAGE');
      debugPrint('[VideoConf][TEST] Sender: $senderUserId');
      debugPrint('[VideoConf][TEST] Channel: $channelId');
      debugPrint('[VideoConf][TEST] Timestamp: $timestamp');
      debugPrint('[VideoConf][TEST] Current Channel: $_currentChannelId');
      debugPrint('[VideoConf][TEST] Current Timestamp: $_keyTimestamp');

      if (channelId != _currentChannelId) {
        debugPrint('[VideoConf][TEST] ❌ Ignoring key for different channel');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        return;
      }

      // If encryptedKey is empty, this is a KEY REQUEST, not a response
      if (encryptedKey.isEmpty) {
        debugPrint(
          '[VideoConf][TEST] 📩 This is a KEY REQUEST from $senderUserId',
        );
        debugPrint('[VideoConf][TEST] 🔄 Sending our key in response...');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        await handleKeyRequest(senderUserId);
        return;
      }

      debugPrint('[VideoConf][TEST] 🔑 This is a KEY RESPONSE');

      // RACE CONDITION RESOLUTION: Compare timestamps (oldest wins)
      if (_keyTimestamp != null && timestamp > _keyTimestamp!) {
        debugPrint('[VideoConf][TEST] ⚠️ RACE CONDITION DETECTED!');
        debugPrint('[VideoConf][TEST] Our timestamp: $_keyTimestamp (older)');
        debugPrint('[VideoConf][TEST] Received timestamp: $timestamp (newer)');
        debugPrint(
          '[VideoConf][TEST] ✓ REJECTING NEWER KEY - Keeping our older key',
        );
        debugPrint('[VideoConf][TEST] Rule: Oldest timestamp wins!');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        return;
      }

      // Decode the shared channel key
      final keyBytes = base64Decode(encryptedKey);
      final keyBase64 = base64Encode(keyBytes);
      final keyPreview = keyBase64.substring(0, 16);

      debugPrint('[VideoConf][TEST] 📦 Decoding received key...');
      debugPrint(
        '[VideoConf][TEST] Key Preview: $keyPreview... (${keyBytes.length} bytes)',
      );

      // Accept the key and update timestamp
      _channelSharedKey = keyBytes;
      _keyTimestamp = timestamp;
      _isFirstParticipant =
          false; // We received the key, so we're NOT the first participant

      debugPrint('[VideoConf][TEST] ✓ KEY ACCEPTED');
      debugPrint('[VideoConf][TEST] Updated Timestamp: $_keyTimestamp');
      debugPrint(
        '[VideoConf][TEST] Is First Participant: $_isFirstParticipant',
      );

      // Set the key in BaseKeyProvider if available
      if (_keyProvider != null) {
        try {
          // Use setKey() which auto-calls setSharedKey() in shared key mode
          await _keyProvider!.setKey(keyBase64);
          debugPrint(
            '[VideoConf][TEST] ✓ Key set in BaseKeyProvider (KeyProvider available)',
          );
          debugPrint(
            '[VideoConf][TEST] ✓ Shared key set (consistent with all participants)',
          );
          debugPrint('[VideoConf][TEST] ✓ Frame-level AES-256 E2EE now ACTIVE');
          debugPrint(
            '[VideoConf][TEST] ✓ Role: KEY RECEIVER (non-first participant)',
          );
          debugPrint('[VideoConf][TEST] 📊 KEY STATE:');
          debugPrint('[VideoConf][TEST]    - Key Preview: $keyPreview...');
          debugPrint('[VideoConf][TEST]    - Timestamp: $_keyTimestamp');
          debugPrint('[VideoConf][TEST]    - Channel: $_currentChannelId');

          // The KeyProvider will automatically encrypt/decrypt frames once the key is set
          // No additional action needed - LiveKit handles the rest
          if (_room != null && _isConnected) {
            debugPrint(
              '[VideoConf][TEST] ✓ Room already connected - KeyProvider will now decrypt incoming frames',
            );
            debugPrint(
              '[VideoConf][TEST] ✓ All participants should now use the same key: timestamp=$_keyTimestamp',
            );
          }
        } catch (e) {
          debugPrint(
            '[VideoConf][TEST] ❌ Failed to set key in KeyProvider: $e',
          );
        }
      } else {
        debugPrint(
          '[VideoConf][TEST] ⚠️ KeyProvider not available - frame encryption disabled',
        );
        debugPrint(
          '[VideoConf][TEST] ⚠️ Only DTLS/SRTP transport encryption active',
        );
      }

      // Complete the key received completer if PreJoin is waiting
      if (_keyReceivedCompleter != null &&
          !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.complete(true);
        debugPrint(
          '[VideoConf][TEST] ✓ PreJoin screen notified - key exchange complete!',
        );
      }

      debugPrint('[VideoConf][TEST] ✅ KEY EXCHANGE SUCCESSFUL');
      debugPrint('═══════════════════════════════════════════════════════════');

      notifyListeners();
    } catch (e) {
      debugPrint('[VideoConf][TEST] ❌ ERROR handling E2EE key: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      // Complete with error if PreJoin is waiting
      if (_keyReceivedCompleter != null &&
          !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.completeError(e);
      }
    }
  }

  /// Handle incoming key request from another participant
  /// Send our SHARED CHANNEL KEY to them via Signal Protocol
  /// For meetings: Uses sendItem (1-to-1 Signal)
  /// For video channels: Uses sendGroupItem with SignalSenderKey
  Future<void> handleKeyRequest(String requesterId, {String? meetingId}) async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[VideoConf][TEST] 📬 HANDLING KEY REQUEST');
      debugPrint('[VideoConf][TEST] Requester: $requesterId');
      debugPrint('[VideoConf][TEST] Meeting ID: $meetingId');
      debugPrint('[VideoConf][TEST] Our Timestamp: $_keyTimestamp');
      debugPrint(
        '[VideoConf][TEST] Is First Participant: $_isFirstParticipant',
      );

      if (_channelSharedKey == null || _currentChannelId == null) {
        debugPrint('[VideoConf][TEST] ❌ Key not initialized, cannot respond');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        return;
      }

      if (_keyTimestamp == null) {
        debugPrint(
          '[VideoConf][TEST] ❌ Key timestamp not available, cannot respond',
        );
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        return;
      }

      // Send our SHARED CHANNEL KEY (not a new key!) with ORIGINAL timestamp via Signal Protocol
      final keyBase64 = base64Encode(_channelSharedKey!);
      final keyPreview = keyBase64.substring(0, 16);
      final itemId =
          'video_key_response_${DateTime.now().millisecondsSinceEpoch}';

      debugPrint('[VideoConf][TEST] 📤 Sending key response...');
      debugPrint('[VideoConf][TEST] Key Preview: $keyPreview...');
      debugPrint(
        '[VideoConf][TEST] ORIGINAL Timestamp: $_keyTimestamp (NOT new timestamp!)',
      );

      // Check if this is a meeting key request
      final isMeeting =
          meetingId != null || _isMeetingChannel(_currentChannelId!);

      if (isMeeting) {
        // For meetings: Use sendItem (1-to-1 Signal encrypted messages)
        debugPrint(
          '[VideoConf][TEST] Message Type: meeting_e2ee_key_response (1-to-1)',
        );

        await SignalService.instance.sendItem(
          recipientUserId: requesterId,
          type: 'meeting_e2ee_key_response', // Special type, not stored
          payload: jsonEncode({
            'meetingId': meetingId ?? _currentChannelId,
            'encryptedKey': keyBase64,
            'timestamp': _keyTimestamp,
          }),
          itemId: itemId,
        );

        debugPrint(
          '[VideoConf][TEST] ✓ Key response sent via Signal Protocol (1-to-1)',
        );
      } else {
        // For video channels: Use sendGroupItem with SignalSenderKey
        debugPrint(
          '[VideoConf][TEST] Message Type: video_e2ee_key_response (group)',
        );

        // ⚠️ IMPORTANT: Ensure sender key exists before responding
        debugPrint('[VideoConf][TEST] 🔧 Ensuring sender key exists...');
        try {
          await SignalService.instance.createGroupSenderKey(_currentChannelId!);
          debugPrint('[VideoConf][TEST] ✓ Sender key ready');
        } catch (e) {
          debugPrint(
            '[VideoConf][TEST] ⚠️ Sender key initialization failed: $e',
          );
          try {
            final loaded = await SignalService.instance.loadSenderKeyFromServer(
              channelId: _currentChannelId!,
              userId: SignalService.instance.currentUserId!,
              deviceId: SignalService.instance.currentDeviceId!,
              forceReload: true,
            );
            if (loaded) {
              debugPrint('[VideoConf][TEST] ✓ Sender key restored from server');
            }
          } catch (recoveryError) {
            debugPrint(
              '[VideoConf][TEST] ⚠️ Failed to load from server: $recoveryError',
            );
          }
        }

        await SignalService.instance.sendGroupItem(
          channelId: _currentChannelId!,
          message: jsonEncode({
            'targetUserId': requesterId,
            'encryptedKey': keyBase64,
            'timestamp': _keyTimestamp,
          }),
          itemId: itemId,
          type: 'video_e2ee_key_response',
        );

        debugPrint(
          '[VideoConf][TEST] ✓ Key response sent via Signal Protocol (group)',
        );
      }

      debugPrint(
        '[VideoConf][TEST] ✓ Requester $requesterId will receive key with timestamp $_keyTimestamp',
      );
      debugPrint('═══════════════════════════════════════════════════════════');
    } catch (e) {
      debugPrint('[VideoConf][TEST] ❌ ERROR handling key request: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
    }
  }

  /// Handle meeting E2EE key request callback (from SignalService)
  /// Called when another meeting participant requests our E2EE key via 1-to-1 Signal
  void _handleMeetingE2EEKeyRequest(Map<String, dynamic> data) {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('[VideoConf] 📨 Meeting E2EE key request callback received');
    debugPrint('[VideoConf] Data: $data');

    final requesterId = data['requesterId'] as String?;
    final meetingId = data['meetingId'] as String?;
    final senderId = data['senderId'] as String?;
    final senderDeviceId = data['senderDeviceId'];

    // Skip our own requests
    final currentUserId = SignalService.instance.currentUserId;
    final currentDeviceId = SignalService.instance.currentDeviceId;
    if (senderId == currentUserId && senderDeviceId == currentDeviceId) {
      debugPrint('[VideoConf] ℹ️ Ignoring own key request (same device)');
      debugPrint('═══════════════════════════════════════════════════════════');
      return;
    }

    // Check if we have a key to share
    if (_channelSharedKey == null) {
      debugPrint('[VideoConf] ⚠️ No E2EE key available to share');
      debugPrint('═══════════════════════════════════════════════════════════');
      return;
    }

    // Send our key to the requester
    debugPrint('[VideoConf] ✓ Responding with our E2EE key...');
    handleKeyRequest(requesterId ?? senderId ?? '', meetingId: meetingId);
  }

  /// Handle meeting E2EE key response callback (from SignalService)
  /// Called when another meeting participant sends us the E2EE key via 1-to-1 Signal
  void _handleMeetingE2EEKeyResponse(Map<String, dynamic> data) {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('[VideoConf] 🔑 Meeting E2EE key response callback received');
    debugPrint('[VideoConf] Data: $data');

    final meetingId = data['meetingId'] as String?;
    final encryptedKey = data['encryptedKey'] as String?;
    final timestamp = data['timestamp'] as int?;
    final senderId = data['senderId'] as String?;

    if (encryptedKey == null || timestamp == null) {
      debugPrint('[VideoConf] ⚠️ Missing key data in response');
      debugPrint('═══════════════════════════════════════════════════════════');
      return;
    }

    // Forward to the existing handleE2EEKey method
    debugPrint('[VideoConf] ✓ Forwarding to handleE2EEKey...');
    handleE2EEKey(
      senderUserId: senderId ?? '',
      encryptedKey: encryptedKey,
      channelId: meetingId ?? _currentChannelId ?? '',
      timestamp: timestamp,
    );
  }

  /// Join a video conference room
  Future<void> joinRoom(
    String channelId, {
    MediaDevice? cameraDevice, // NEW: Optional pre-selected camera
    MediaDevice? microphoneDevice, // NEW: Optional pre-selected microphone
    String? channelName, // NEW: Channel name for display
    bool isExternalGuest =
        false, // NEW: Skip Signal Protocol for external guests
    String? guestSessionId, // NEW: Guest session ID for token request
  }) async {
    // SESSION EXCLUSIVITY: If already in a session, leave it before joining new one
    if (_isConnecting || _isConnected) {
      debugPrint(
        '[VideoConf] 🔄 Already in a session ($_currentChannelId), leaving before joining new session ($channelId)',
      );
      await leaveRoom();
      debugPrint(
        '[VideoConf] ✓ Left previous session, now joining new session',
      );
    }

    try {
      _isConnecting = true;
      _currentChannelId = channelId;

      // NEW: Set call state
      _isInCall = true;
      _channelName = channelName;
      _callStartTime = DateTime.now();
      _isOverlayVisible = false; // Start hidden - user is in full-view

      notifyListeners();

      debugPrint('[VideoConf] Joining room for channel: $channelId');

      // CRITICAL: Signal Service must be initialized for E2EE key exchange
      // Skip for external guests who don't have Signal Protocol
      if (!isExternalGuest && !SignalService.instance.isInitialized) {
        throw Exception(
          'Signal Service must be initialized before joining video call. '
          'Key exchange requires Signal Protocol encryption.',
        );
      }

      if (!isExternalGuest) {
        debugPrint('[VideoConf] ✓ Signal Service ready for E2EE key exchange');

        // For meetings: Register callbacks for E2EE key exchange via 1-to-1 Signal messages
        if (_isMeetingChannel(channelId)) {
          debugPrint(
            '[VideoConf] 📝 Registering meeting E2EE callbacks for: $channelId',
          );
          SignalService.instance.registerMeetingE2EEKeyRequestCallback(
            channelId,
            (data) => _handleMeetingE2EEKeyRequest(data),
          );
          SignalService.instance.registerMeetingE2EEKeyResponseCallback(
            channelId,
            (data) => _handleMeetingE2EEKeyResponse(data),
          );
          debugPrint('[VideoConf] ✓ Meeting E2EE callbacks registered');
        }
      } else {
        debugPrint(
          '[VideoConf] 🔓 External guest mode - skipping Signal Protocol setup',
        );
      }

      // Initialize E2EE ONLY if we don't already have a key AND not an external guest
      // (non-first participants receive key in PreJoin before joining)
      if (!isExternalGuest && _keyTimestamp == null) {
        debugPrint(
          '[VideoConf] No existing E2EE key - initializing as first participant',
        );
        await _initializeE2EE();
      } else {
        debugPrint(
          '[VideoConf] E2EE key already received (timestamp: $_keyTimestamp)',
        );
        debugPrint(
          '[VideoConf] Skipping initialization - will use existing key',
        );

        // Still need to ensure sender key exists for this participant
        if (_currentChannelId != null) {
          debugPrint(
            '[VideoConf] 🔧 Ensuring sender key exists for channel...',
          );
          try {
            await SignalService.instance.createGroupSenderKey(
              _currentChannelId!,
            );
            debugPrint('[VideoConf] ✓ Sender key ready');
          } catch (e) {
            if (e.toString().contains('already exists')) {
              debugPrint('[VideoConf] ℹ️ Sender key already exists (OK)');
            } else {
              debugPrint('[VideoConf] ⚠️ Sender key error (continuing): $e');
            }
          }
        }

        // Create KeyProvider with existing key
        // Note: Data channel encryption is web-only, but frame encryption works on all platforms
        if (_keyProvider == null && _channelSharedKey != null) {
          try {
            _keyProvider = await BaseKeyProvider.create();
            final keyBase64 = base64Encode(_channelSharedKey!);
            // Use setKey() which auto-calls setSharedKey() in shared key mode
            await _keyProvider!.setKey(keyBase64);
            debugPrint(
              '[VideoConf] ✓ BaseKeyProvider created with received key',
            );
            debugPrint(
              '[VideoConf] ✓ Shared key set (same method as first participant)',
            );
            if (!kIsWeb) {
              debugPrint(
                '[VideoConf] ℹ️ Native platform: Frame encryption enabled, data channel encryption disabled',
              );
            }
          } catch (e) {
            debugPrint('[VideoConf] ⚠️ Failed to create KeyProvider: $e');
            _keyProvider = null;
          }
        }
      }

      // Get LiveKit token from server
      // For external guests, use guest endpoint with session ID
      // For meetings (ID starts with mtg_ or call_), use meeting-token endpoint
      final isMeeting =
          channelId.startsWith('mtg_') || channelId.startsWith('call_');

      String tokenEndpoint;
      Map<String, dynamic> requestData;

      if (isExternalGuest && guestSessionId != null) {
        // Guest token endpoint
        tokenEndpoint = '/api/livekit/guest-token';
        requestData = <String, dynamic>{
          'meetingId': channelId,
          'sessionId': guestSessionId,
        };
        debugPrint(
          '[VideoConf] Requesting GUEST token for meeting: $channelId (session: $guestSessionId)',
        );
      } else if (isMeeting) {
        tokenEndpoint = '/api/livekit/meeting-token';
        requestData = <String, dynamic>{'meetingId': channelId};
        debugPrint('[VideoConf] Requesting token for meeting: $channelId');
      } else {
        tokenEndpoint = '/api/livekit/token';
        requestData = <String, dynamic>{'channelId': channelId};
        debugPrint('[VideoConf] Requesting token for channel: $channelId');
      }

      final response = await ApiService.post(tokenEndpoint, data: requestData);

      debugPrint('[VideoConf] Token response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        throw Exception('Failed to get LiveKit token: ${response.statusCode}');
      }

      final data = response.data;
      final token = data['token'];
      final url = data['url'];
      _currentRoomName = data['roomName'];

      debugPrint('[VideoConf] Got token, connecting to: $url');

      // Request media permissions BEFORE creating room
      debugPrint('[VideoConf] Requesting camera and microphone permissions...');
      LocalVideoTrack? videoTrack;
      LocalAudioTrack? audioTrack;

      try {
        // Get current quality settings
        final cameraPreset = _videoQualitySettings.cameraPreset;
        debugPrint('[VideoConf] Using camera quality: ${cameraPreset.name}');

        // Use pre-selected camera device if available
        if (cameraDevice != null) {
          debugPrint(
            '[VideoConf] Using pre-selected camera: ${cameraDevice.label}',
          );
          videoTrack = await LocalVideoTrack.createCameraTrack(
            CameraCaptureOptions(
              deviceId: cameraDevice.deviceId,
              params: cameraPreset.parameters,
            ),
          );
        } else {
          videoTrack = await LocalVideoTrack.createCameraTrack(
            CameraCaptureOptions(params: cameraPreset.parameters),
          );
        }
        debugPrint('[VideoConf] ✓ Camera track created');
      } catch (e) {
        debugPrint('[VideoConf] ⚠️ Failed to create camera track: $e');
      }

      try {
        // Use audio settings for microphone
        debugPrint('[VideoConf] Applying audio settings...');

        // Use pre-selected microphone device if available
        if (microphoneDevice != null) {
          debugPrint(
            '[VideoConf] Using pre-selected microphone: ${microphoneDevice.label}',
          );
          audioTrack = await LocalAudioTrack.create(
            AudioCaptureOptions(
              deviceId: microphoneDevice.deviceId,
              noiseSuppression: _audioSettings.noiseSuppression,
              echoCancellation: _audioSettings.echoCancellation,
              autoGainControl: _audioSettings.autoGainControl,
            ),
          );
        } else {
          audioTrack = await LocalAudioTrack.create(
            AudioCaptureOptions(
              noiseSuppression: _audioSettings.noiseSuppression,
              echoCancellation: _audioSettings.echoCancellation,
              autoGainControl: _audioSettings.autoGainControl,
            ),
          );
        }
        debugPrint(
          '[VideoConf] ✓ Microphone track created with audio processing',
        );
      } catch (e) {
        debugPrint('[VideoConf] ⚠️ Failed to create audio track: $e');
      }

      // CRITICAL: Create KeyProvider RIGHT BEFORE Room creation (matching LiveKit example pattern)
      // Create E2EE Manager with Windows/Linux compatibility
      E2EEManager? e2eeManager;
      if (_channelSharedKey != null) {
        try {
          final keyProvider = await BaseKeyProvider.create();
          final keyBase64 = base64Encode(_channelSharedKey!);
          await keyProvider.setKey(keyBase64);
          _keyProvider = keyProvider;

          // Use custom E2EE manager that handles Windows/Linux gracefully
          e2eeManager = WindowsCompatibleE2EEManager(keyProvider);

          debugPrint(
            '[VideoConf] ✓ KeyProvider created and configured for E2EE',
          );
          if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
            debugPrint(
              '[VideoConf] ℹ️ Windows/Linux: FrameCryptor enabled, DataPacketCryptor disabled',
            );
          } else {
            debugPrint(
              '[VideoConf] ℹ️ Full E2EE enabled (FrameCryptor + DataPacketCryptor)',
            );
          }
        } catch (e) {
          debugPrint('[VideoConf] ⚠️ Failed to create KeyProvider: $e');
          e2eeManager = null;
          _keyProvider = null;
        }
      }

      // Create Room with encryption parameter (not deprecated)
      _room = Room(
        roomOptions: RoomOptions(adaptiveStream: true, dynacast: true),
      );

      // Setup E2EE manager if available
      if (e2eeManager != null) {
        await e2eeManager.setup(_room!);
        _room!.engine.setE2eeManager(e2eeManager);
        debugPrint('[VideoConf] ✓ E2EE Manager configured');
      } else {
        debugPrint(
          '[VideoConf] ✓ Room created (DTLS/SRTP transport encryption only)',
        );
      }

      // Set up event listeners
      _setupRoomListeners();

      // Connect to LiveKit room
      debugPrint('[VideoConf] Connecting to LiveKit room...');
      await _room!.connect(url, token);

      // Publish local tracks if available
      if (videoTrack != null) {
        debugPrint('[VideoConf] Publishing video track...');

        // Use simulcast if enabled in settings
        if (_videoQualitySettings.simulcastEnabled) {
          final simulcastLayers = _videoQualitySettings.cameraPreset
              .generateSimulcastLayers();
          debugPrint(
            '[VideoConf] 📡 Publishing with simulcast (${simulcastLayers.length} layers)',
          );

          await _room!.localParticipant?.publishVideoTrack(
            videoTrack,
            publishOptions: VideoPublishOptions(
              simulcast: true,
              videoSimulcastLayers: simulcastLayers,
            ),
          );
        } else {
          debugPrint('[VideoConf] Publishing without simulcast');
          await _room!.localParticipant?.publishVideoTrack(videoTrack);
        }
      }

      if (audioTrack != null) {
        debugPrint('[VideoConf] Publishing audio track...');
        await _room!.localParticipant?.publishAudioTrack(audioTrack);
      }

      // Verify E2EE is actually enabled
      if (_keyProvider != null) {
        debugPrint(
          '[VideoConf] ✓ E2EEManager active - frame encryption enabled',
        );

        // Check if room has E2EE enabled
        final e2eeEnabled = _room!.e2eeManager != null;
        debugPrint('[VideoConf] 🔍 E2EE Manager exists: $e2eeEnabled');

        if (e2eeEnabled) {
          debugPrint('[VideoConf] ✅ E2EE VERIFIED - Encryption is active!');
        } else {
          debugPrint(
            '[VideoConf] ⚠️ WARNING: E2EE Manager not found despite having key provider!',
          );
        }
      } else {
        debugPrint(
          '[VideoConf] ℹ️ No key provider - only transport encryption (DTLS/SRTP)',
        );
      }

      // Add existing remote participants to map (for users who joined before us)
      debugPrint('[VideoConf] Checking for existing participants...');
      for (final participant in _room!.remoteParticipants.values) {
        debugPrint(
          '[VideoConf] Found existing participant: ${participant.identity}',
        );
        _remoteParticipants[participant.identity] = participant;

        // Check if this participant is already sharing screen
        final hasScreenShare = participant.videoTrackPublications.any(
          (pub) => pub.source == TrackSource.screenShareVideo,
        );
        if (hasScreenShare) {
          debugPrint(
            '[VideoConf] 📺 Existing screen share detected from: ${participant.identity}',
          );
          _currentScreenShareParticipantId = participant.identity;
        }

        // Exchange keys with existing participants
        await _exchangeKeysWithParticipant(participant.identity);
      }
      debugPrint(
        '[VideoConf] Total remote participants: ${_remoteParticipants.length}',
      );

      _isConnected = true;
      _isConnecting = false;

      // Initialize video quality manager
      _qualityManager.initialize(_room!);
      debugPrint('[VideoConf] ✅ VideoQualityManager initialized');

      // Update audio processor settings
      _audioProcessor.updateSettings(_audioSettings);
      debugPrint('[VideoConf] ✅ AudioProcessorService initialized');

      // NEW: Save persistence for rejoin
      await _savePersistence();

      notifyListeners();

      debugPrint('[VideoConf] Successfully joined room: $_currentRoomName');
    } catch (e) {
      debugPrint('[VideoConf] Error joining room: $e');
      _isConnecting = false;
      _isConnected = false;

      // NEW: Reset call state on error
      _isInCall = false;
      _channelName = null;
      _callStartTime = null;

      notifyListeners();
      rethrow;
    }
  }

  /// Set up LiveKit room event listeners
  void _setupRoomListeners() {
    if (_room == null) return;

    // Listen to room events
    _room!.addListener(_onRoomChanged);

    // Listen to specific events
    final listener = _room!.createListener();

    // Participant joined
    listener.on<ParticipantConnectedEvent>((event) async {
      debugPrint(
        '[VideoConf] Participant joined: ${event.participant.identity}',
      );
      _remoteParticipants[event.participant.identity] = event.participant;

      // Exchange encryption keys with new participant
      await _exchangeKeysWithParticipant(event.participant.identity);

      // Play join sound
      SoundService.instance.playParticipantJoined();

      _participantJoinedController.add(event.participant);
      notifyListeners();
    });

    // Participant left
    listener.on<ParticipantDisconnectedEvent>((event) {
      debugPrint('[VideoConf] Participant left: ${event.participant.identity}');
      _remoteParticipants.remove(event.participant.identity);
      _participantKeys.remove(event.participant.identity);

      // Clear screen share state if the sharer left
      if (event.participant.identity == _currentScreenShareParticipantId) {
        debugPrint(
          '[VideoConf] 👋 Screen sharer left, clearing screen share state',
        );
        _currentScreenShareParticipantId = null;
      }

      // Play leave sound
      SoundService.instance.playParticipantLeft();

      _participantLeftController.add(event.participant);
      notifyListeners();
    });

    // Track subscribed
    listener.on<TrackSubscribedEvent>((event) async {
      debugPrint(
        '[VideoConf] Track subscribed: ${event.track.kind} from ${event.participant.identity}',
      );
      debugPrint('[VideoConf]   - Track SID: ${event.track.sid}');
      debugPrint('[VideoConf]   - Track muted: ${event.track.muted}');

      // E2EEManager handles frame decryption automatically when encryption is enabled

      _trackSubscribedController.add(event);
      notifyListeners();
    });

    // Track unsubscribed
    listener.on<TrackUnsubscribedEvent>((event) {
      debugPrint(
        '[VideoConf] Track unsubscribed: ${event.track.kind} from ${event.participant.identity}',
      );
      notifyListeners();
    });

    // Track published (important for seeing when tracks become available)
    listener.on<TrackPublishedEvent>((event) {
      debugPrint(
        '[VideoConf] Track published: ${event.publication.kind} from ${event.participant.identity}',
      );
      debugPrint('[VideoConf]   - Track SID: ${event.publication.sid}');

      // Track screen share state
      if (event.publication.source == TrackSource.screenShareVideo) {
        debugPrint(
          '[VideoConf] 📺 Screen share started by: ${event.participant.identity}',
        );
        _currentScreenShareParticipantId = event.participant.identity;

        // Play screen share started sound
        SoundService.instance.playScreenShareStarted();
      }

      notifyListeners();
    });

    // Track unpublished
    listener.on<TrackUnpublishedEvent>((event) {
      debugPrint(
        '[VideoConf] Track unpublished: ${event.publication.kind} from ${event.participant.identity}',
      );

      // Clear screen share state if the sharer stopped
      if (event.publication.source == TrackSource.screenShareVideo &&
          event.participant.identity == _currentScreenShareParticipantId) {
        debugPrint(
          '[VideoConf] 🛑 Screen share stopped by: ${event.participant.identity}',
        );
        _currentScreenShareParticipantId = null;

        // Play screen share stopped sound
        SoundService.instance.playScreenShareStopped();
      }

      notifyListeners();
    });

    // Room disconnected
    listener.on<RoomDisconnectedEvent>((event) {
      debugPrint('[VideoConf] Room disconnected: ${event.reason}');
      _handleDisconnection();
    });

    // Connection state changed
    listener.on<RoomAttemptReconnectEvent>((event) {
      debugPrint('[VideoConf] Attempting to reconnect...');
      notifyListeners();
    });

    listener.on<RoomReconnectedEvent>((event) {
      debugPrint('[VideoConf] Reconnected successfully');
      notifyListeners();
    });
  }

  /// Handle room state changes
  void _onRoomChanged() {
    notifyListeners();
  }

  /// Handle disconnection
  void _handleDisconnection() {
    debugPrint('[VideoConf] Handling disconnection - cleaning up state');

    // Emit Socket.IO leave event on unexpected disconnection
    if (_currentChannelId != null) {
      try {
        SocketService().emit('video:leave-channel', {
          'channelId': _currentChannelId,
        });
        debugPrint(
          '[VideoConf] ✓ Emitted video:leave-channel after disconnection',
        );
      } catch (e) {
        debugPrint(
          '[VideoConf] ⚠️ Failed to emit leave event on disconnection: $e',
        );
      }
    }

    _isConnected = false;
    _remoteParticipants.clear();
    _participantKeys.clear();

    // Clean up E2EE state on disconnection
    _channelSharedKey = null;
    _keyTimestamp = null;
    _isFirstParticipant = false;

    // Clean up completer if still waiting
    if (_keyReceivedCompleter != null) {
      if (!_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.completeError(
          Exception('Disconnected while waiting for key'),
        );
      }
      _keyReceivedCompleter = null;
    }

    // Clean up KeyProvider
    if (_keyProvider != null) {
      debugPrint('[VideoConf] ✓ Clearing KeyProvider reference on disconnect');
      _keyProvider = null;
    }

    _currentChannelId = null;

    notifyListeners();
    debugPrint('[VideoConf] ✓ Disconnection handled (E2EE state cleared)');
  }

  /// Leave the current room
  Future<void> leaveRoom() async {
    try {
      debugPrint('[VideoConf] Leaving room');

      // Unregister meeting E2EE callbacks if this was a meeting
      if (_currentChannelId != null && _isMeetingChannel(_currentChannelId!)) {
        debugPrint(
          '[VideoConf] 📝 Unregistering meeting E2EE callbacks for: $_currentChannelId',
        );
        SignalService.instance.unregisterMeetingE2EECallbacks(
          _currentChannelId!,
        );
      }

      // Emit Socket.IO leave event BEFORE disconnecting from LiveKit
      if (_currentChannelId != null) {
        try {
          SocketService().emit('video:leave-channel', {
            'channelId': _currentChannelId,
          });
          debugPrint('[VideoConf] ✓ Emitted video:leave-channel to server');
        } catch (e) {
          debugPrint('[VideoConf] ⚠️ Failed to emit leave event: $e');
        }
      }

      if (_room != null) {
        await _room!.disconnect();
        await _room!.dispose();
        _room = null;
      }

      // Clean up E2EE state (key rotation on session end)
      _participantKeys.clear();
      _channelSharedKey = null;
      _keyTimestamp = null;
      _isFirstParticipant = false;

      // Clean up completer if still waiting
      if (_keyReceivedCompleter != null) {
        if (!_keyReceivedCompleter!.isCompleted) {
          _keyReceivedCompleter!.completeError(
            Exception('Room left while waiting for key'),
          );
        }
        _keyReceivedCompleter = null;
      }

      // Clean up KeyProvider to prevent state leakage
      if (_keyProvider != null) {
        debugPrint('[VideoConf] ✓ Clearing KeyProvider reference');
        _keyProvider = null;
      }

      _isConnected = false;
      _isConnecting = false;
      _currentChannelId = null;
      _currentRoomName = null;
      _remoteParticipants.clear();

      // NEW: Reset overlay state
      _isInCall = false;
      _channelName = null;
      _callStartTime = null;
      _isOverlayVisible = false;

      // Clear persistence
      await _clearPersistence();

      notifyListeners();
      debugPrint('[VideoConf] ✓ Left room successfully (E2EE state cleared)');
    } catch (e) {
      debugPrint('[VideoConf] Error leaving room: $e');
    }
  }

  /// NEW: Toggle overlay visibility
  void toggleOverlayVisible() {
    _isOverlayVisible = !_isOverlayVisible;
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Hide overlay (call continues)
  void hideOverlay() {
    _isOverlayVisible = false;
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Show overlay
  void showOverlay() {
    _isOverlayVisible = true;
    _isInFullView = false; // Exiting full-view
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Enter full-view mode (hides TopBar and overlay)
  void enterFullView() {
    _isInFullView = true;
    _isOverlayVisible = false; // Hide overlay when in full-view
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Exit full-view mode (back to overlay mode)
  void exitFullView() {
    _isInFullView = false;
    _isOverlayVisible = true; // Show overlay when exiting full-view
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Update overlay position
  void updateOverlayPosition(double x, double y) {
    _overlayPositionX = x;
    _overlayPositionY = y;
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Save state to LocalStorage for rejoin
  Future<void> _savePersistence() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (_isInCall && _currentChannelId != null) {
        await prefs.setBool('shouldRejoin', true);
        await prefs.setString('lastChannelId', _currentChannelId!);
        if (_channelName != null) {
          await prefs.setString('lastChannelName', _channelName!);
        }
        if (_callStartTime != null) {
          await prefs.setString(
            'callStartTime',
            _callStartTime!.toIso8601String(),
          );
        }
        await prefs.setBool('overlayVisible', _isOverlayVisible);
        await prefs.setDouble('overlayPositionX', _overlayPositionX);
        await prefs.setDouble('overlayPositionY', _overlayPositionY);

        debugPrint('[VideoConf] ✓ State persisted to LocalStorage');
      }
    } catch (e) {
      debugPrint('[VideoConf] ⚠️ Failed to save persistence: $e');
    }
  }

  /// NEW: Clear persistence from LocalStorage
  Future<void> _clearPersistence() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('shouldRejoin');
      await prefs.remove('lastChannelId');
      await prefs.remove('lastChannelName');
      await prefs.remove('callStartTime');
      await prefs.remove('overlayVisible');
      await prefs.remove('overlayPositionX');
      await prefs.remove('overlayPositionY');

      debugPrint('[VideoConf] ✓ Persistence cleared');
    } catch (e) {
      debugPrint('[VideoConf] ⚠️ Failed to clear persistence: $e');
    }
  }

  /// NEW: Check for rejoin on app start
  Future<void> checkForRejoin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final shouldRejoin = prefs.getBool('shouldRejoin') ?? false;
      final lastChannelId = prefs.getString('lastChannelId');

      if (shouldRejoin && lastChannelId != null) {
        debugPrint(
          '[VideoConf] 🔄 Auto-rejoin detected for channel: $lastChannelId',
        );

        // Restore state
        _channelName = prefs.getString('lastChannelName');
        final callStartTimeStr = prefs.getString('callStartTime');
        if (callStartTimeStr != null) {
          _callStartTime = DateTime.parse(callStartTimeStr);
        }
        // Always show overlay after rejoin so user knows call is active
        _isOverlayVisible = true;
        _overlayPositionX = prefs.getDouble('overlayPositionX') ?? 100;
        _overlayPositionY = prefs.getDouble('overlayPositionY') ?? 100;

        try {
          // Attempt rejoin
          await joinRoom(lastChannelId, channelName: _channelName);
          await prefs.setBool('shouldRejoin', false);
          debugPrint('[VideoConf] ✅ Auto-rejoin successful');
        } catch (e) {
          debugPrint('[VideoConf] ❌ Auto-rejoin failed: $e');
          await _clearPersistence();
        }
      }
    } catch (e) {
      debugPrint('[VideoConf] ⚠️ checkForRejoin error: $e');
    }
  }

  /// Toggle local camera
  Future<void> toggleCamera() async {
    if (_room == null) return;

    try {
      final enabled = _room!.localParticipant?.isCameraEnabled() ?? false;
      await _room!.localParticipant?.setCameraEnabled(!enabled);
      notifyListeners();
    } catch (e) {
      debugPrint('[VideoConf] Error toggling camera: $e');
    }
  }

  /// Toggle local microphone
  Future<void> toggleMicrophone() async {
    if (_room == null) return;

    try {
      final enabled = _room!.localParticipant?.isMicrophoneEnabled() ?? false;
      await _room!.localParticipant?.setMicrophoneEnabled(!enabled);
      notifyListeners();
    } catch (e) {
      debugPrint('[VideoConf] Error toggling microphone: $e');
    }
  }

  /// Check if camera is enabled
  bool isCameraEnabled() {
    return _room?.localParticipant?.isCameraEnabled() ?? false;
  }

  /// Check if microphone is enabled
  bool isMicrophoneEnabled() {
    return _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  }

  /// Check if screen share is enabled
  bool isScreenShareEnabled() {
    final localParticipant = _room?.localParticipant;
    if (localParticipant == null) return false;

    // Check if we have an active screen share track
    return localParticipant.videoTrackPublications.any(
      (pub) => pub.source == TrackSource.screenShareVideo,
    );
  }

  /// Toggle screen share on/off
  /// Check if screen sharing is supported on current platform
  bool get isScreenShareSupported {
    // Screen sharing is supported on web and desktop platforms
    return true;
  }

  /// For desktop platforms, this should be set before calling toggleScreenShare(true)
  String? _selectedDesktopSourceId;

  /// Set the desktop screen source ID (Windows/Linux/macOS only)
  /// Call this after user selects from ScreenSelectDialog
  void setDesktopScreenSource(String sourceId) {
    _selectedDesktopSourceId = sourceId;
  }

  Future<bool> toggleScreenShare() async {
    if (_room == null) {
      debugPrint('[VideoConf] ❌ Cannot toggle screen share: Room is null');
      return false;
    }

    try {
      final isCurrentlySharing = isScreenShareEnabled();
      final localIdentity = _room!.localParticipant?.identity;

      if (isCurrentlySharing) {
        // Stop screen sharing
        debugPrint('[VideoConf] 🚫 Stopping screen share');
        await _room!.localParticipant?.setScreenShareEnabled(false);

        // Clear screen share state if we were the one sharing
        if (_currentScreenShareParticipantId == localIdentity) {
          _currentScreenShareParticipantId = null;
        }

        notifyListeners();
        return false;
      } else {
        // Check if someone else is sharing
        if (_currentScreenShareParticipantId != null &&
            _currentScreenShareParticipantId != localIdentity) {
          final sharingParticipant =
              _remoteParticipants[_currentScreenShareParticipantId];
          final sharerName =
              sharingParticipant?.name ?? _currentScreenShareParticipantId;

          debugPrint(
            '[VideoConf] ⚠️ User $sharerName is already sharing. Taking over...',
          );

          // Return false to trigger UI warning, but don't block
          // The caller should show a warning and then call this again to confirm
        }

        // Start screen sharing - platform specific
        debugPrint('[VideoConf] 💻 Starting screen share');

        if (kIsWeb) {
          // Web: Use browser's native getDisplayMedia
          await _room!.localParticipant?.setScreenShareEnabled(true);
        } else {
          // Desktop (Windows/Linux/macOS): Use sourceId from screen picker
          if (_selectedDesktopSourceId == null) {
            throw Exception(
              'No screen source selected. Call setDesktopScreenSource() first.',
            );
          }

          // Get screenshare quality settings
          final screensharePreset = _videoQualitySettings.screensharePreset;
          debugPrint(
            '[VideoConf] Using screenshare quality: ${screensharePreset.name}',
          );

          final track = await LocalVideoTrack.createScreenShareTrack(
            ScreenShareCaptureOptions(
              sourceId: _selectedDesktopSourceId,
              maxFrameRate:
                  (screensharePreset.parameters.encoding?.maxFramerate ?? 15)
                      .toDouble(),
              params: screensharePreset.parameters,
            ),
          );

          // Publish with simulcast if enabled
          if (_videoQualitySettings.simulcastEnabled) {
            final simulcastLayers = screensharePreset.generateSimulcastLayers();
            debugPrint(
              '[VideoConf] 📡 Publishing screenshare with simulcast (${simulcastLayers.length} layers)',
            );

            await _room!.localParticipant?.publishVideoTrack(
              track,
              publishOptions: VideoPublishOptions(
                simulcast: true,
                videoSimulcastLayers: simulcastLayers,
              ),
            );
          } else {
            await _room!.localParticipant?.publishVideoTrack(track);
          }

          debugPrint(
            '[VideoConf] ✅ Desktop screen share track published: $track',
          );

          // Clear the selected source after use
          _selectedDesktopSourceId = null;
        }

        // Set ourselves as the current sharer
        _currentScreenShareParticipantId = localIdentity;

        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('[VideoConf] ❌ Error toggling screen share: $e');
      rethrow;
    }
  }

  /// Switch to a different camera device
  Future<void> switchCamera(MediaDevice device) async {
    if (_room == null) {
      throw Exception('Not in a room');
    }

    try {
      debugPrint('[VideoConf] 🔄 Starting camera switch to: ${device.label}');

      // Get current camera state
      final wasCameraEnabled = isCameraEnabled();
      debugPrint('[VideoConf]   Camera was enabled: $wasCameraEnabled');

      // Get old video track publications
      final oldVideoPubs =
          _room!.localParticipant?.videoTrackPublications.toList() ?? [];
      debugPrint(
        '[VideoConf]   Found ${oldVideoPubs.length} old video publications',
      );

      // Remove old tracks
      for (final pub in oldVideoPubs) {
        try {
          debugPrint('[VideoConf]   Removing track: ${pub.sid}');
          await _room!.localParticipant?.removePublishedTrack(pub.sid);
        } catch (e) {
          debugPrint('[VideoConf]   ⚠️ Error removing ${pub.sid}: $e');
        }
      }

      // Wait for device release
      await Future.delayed(const Duration(milliseconds: 200));

      // Create new track with selected device (EXACT same as initial join)
      debugPrint(
        '[VideoConf]   Creating new camera track with device: ${device.deviceId}',
      );
      final videoTrack = await LocalVideoTrack.createCameraTrack(
        CameraCaptureOptions(deviceId: device.deviceId),
      );
      debugPrint(
        '[VideoConf]   ✓ New track created: ${videoTrack.mediaStreamTrack.id}',
      );

      // Publish via room (EXACT same as initial join)
      debugPrint('[VideoConf]   Publishing video track...');
      await _room!.localParticipant?.publishVideoTrack(videoTrack);
      debugPrint('[VideoConf]   ✓ Track published');

      // Restore enabled state
      if (!wasCameraEnabled) {
        await _room!.localParticipant?.setCameraEnabled(false);
      }

      notifyListeners();
      debugPrint('[VideoConf] ✅ Camera switch complete: ${device.label}');
    } catch (e, stackTrace) {
      debugPrint('[VideoConf] ❌ Error switching camera: $e');
      debugPrint('[VideoConf] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Switch to a different microphone device
  Future<void> switchMicrophone(MediaDevice device) async {
    if (_room == null) {
      throw Exception('Not in a room');
    }

    try {
      debugPrint(
        '[VideoConf] 🔄 Starting microphone switch to: ${device.label}',
      );

      // Get current microphone state
      final wasMicEnabled = isMicrophoneEnabled();
      debugPrint('[VideoConf]   Microphone was enabled: $wasMicEnabled');

      // Get old audio track publications
      final oldAudioPubs =
          _room!.localParticipant?.audioTrackPublications.toList() ?? [];
      debugPrint(
        '[VideoConf]   Found ${oldAudioPubs.length} old audio publications',
      );

      // Remove old tracks
      for (final pub in oldAudioPubs) {
        try {
          debugPrint('[VideoConf]   Removing track: ${pub.sid}');
          await _room!.localParticipant?.removePublishedTrack(pub.sid);
        } catch (e) {
          debugPrint('[VideoConf]   ⚠️ Error removing ${pub.sid}: $e');
        }
      }

      // Wait for device release
      await Future.delayed(const Duration(milliseconds: 200));

      // Create new track with selected device (EXACT same as initial join)
      debugPrint(
        '[VideoConf]   Creating new audio track with device: ${device.deviceId}',
      );
      final audioTrack = await LocalAudioTrack.create(
        AudioCaptureOptions(
          deviceId: device.deviceId,
          noiseSuppression: _audioSettings.noiseSuppression,
          echoCancellation: _audioSettings.echoCancellation,
          autoGainControl: _audioSettings.autoGainControl,
        ),
      );
      debugPrint(
        '[VideoConf]   ✓ New track created: ${audioTrack.mediaStreamTrack.id}',
      );

      // Publish via room (EXACT same as initial join)
      debugPrint('[VideoConf]   Publishing audio track...');
      await _room!.localParticipant?.publishAudioTrack(audioTrack);
      debugPrint('[VideoConf]   ✓ Track published');

      // Restore enabled state
      if (!wasMicEnabled) {
        await _room!.localParticipant?.setMicrophoneEnabled(false);
      }

      notifyListeners();
      debugPrint('[VideoConf] ✅ Microphone switch complete: ${device.label}');
    } catch (e, stackTrace) {
      debugPrint('[VideoConf] ❌ Error switching microphone: $e');
      debugPrint('[VideoConf] Stack trace: $stackTrace');
      rethrow;
    }
  }

  // ============================================================================
  // VIDEO & AUDIO QUALITY SETTINGS
  // ============================================================================

  /// Load video quality settings from storage
  Future<void> loadVideoQualitySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('video_quality_settings');
      if (json != null) {
        _videoQualitySettings = VideoQualitySettings.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
        debugPrint('[VideoConf] ✓ Loaded video quality settings');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[VideoConf] Failed to load video quality settings: $e');
    }
  }

  /// Update video quality settings
  Future<void> updateVideoQualitySettings(VideoQualitySettings settings) async {
    _videoQualitySettings = settings;
    notifyListeners();

    // Save to storage
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'video_quality_settings',
        jsonEncode(settings.toJson()),
      );
      debugPrint('[VideoConf] ✓ Saved video quality settings');
    } catch (e) {
      debugPrint('[VideoConf] Failed to save video quality settings: $e');
    }
  }

  /// Load audio settings from storage
  Future<void> loadAudioSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('audio_settings');
      if (json != null) {
        _audioSettings = AudioSettings.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
        debugPrint('[VideoConf] ✓ Loaded audio settings');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[VideoConf] Failed to load audio settings: $e');
    }
  }

  /// Update audio settings
  Future<void> updateAudioSettings(AudioSettings settings) async {
    _audioSettings = settings;
    _audioProcessor.updateSettings(settings);
    notifyListeners();

    // Save to storage
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('audio_settings', jsonEncode(settings.toJson()));
      debugPrint('[VideoConf] ✓ Saved audio settings');
    } catch (e) {
      debugPrint('[VideoConf] Failed to save audio settings: $e');
    }
  }

  /// Get per-participant audio state
  ParticipantAudioState getParticipantAudioState(String participantId) {
    return _participantAudioStates[participantId] ??
        ParticipantAudioState(participantId: participantId);
  }

  /// Update per-participant audio state
  Future<void> updateParticipantAudioState(ParticipantAudioState state) async {
    _participantAudioStates[state.participantId] = state;
    notifyListeners();

    // Save to storage
    try {
      final prefs = await SharedPreferences.getInstance();
      final allStates = _participantAudioStates.values
          .map((s) => s.toJson())
          .toList();
      await prefs.setString('participant_audio_states', jsonEncode(allStates));
      debugPrint(
        '[VideoConf] ✓ Saved participant audio state for ${state.participantId}',
      );
    } catch (e) {
      debugPrint('[VideoConf] Failed to save participant audio state: $e');
    }
  }

  /// Load per-participant audio states from storage
  Future<void> loadParticipantAudioStates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('participant_audio_states');
      if (json != null) {
        final list = jsonDecode(json) as List<dynamic>;
        for (final item in list) {
          final state = ParticipantAudioState.fromJson(
            item as Map<String, dynamic>,
          );
          _participantAudioStates[state.participantId] = state;
        }
        debugPrint(
          '[VideoConf] ✓ Loaded ${_participantAudioStates.length} participant audio states',
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[VideoConf] Failed to load participant audio states: $e');
    }
  }

  @override
  void dispose() {
    leaveRoom();
    _qualityManager.dispose();
    _audioProcessor.dispose();
    _participantJoinedController.close();
    _participantLeftController.close();
    _trackSubscribedController.close();
    super.dispose();
  }
}
