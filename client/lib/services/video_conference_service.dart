import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'signal_service.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'message_listener_service.dart';

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
  static final VideoConferenceService _instance = VideoConferenceService._internal();
  static VideoConferenceService get instance => _instance;
  
  VideoConferenceService._internal();
  
  // Factory constructor returns singleton
  factory VideoConferenceService() => _instance;
  
  // Core LiveKit components
  Room? _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;
  Map<String, RemoteParticipant> _remoteParticipants = {};
  
  // E2EE components
  BaseKeyProvider? _keyProvider;
  Uint8List? _channelSharedKey;  // ONE shared key for the entire channel
  int? _keyTimestamp;  // Timestamp of current key (for race condition resolution)
  Map<String, Uint8List> _participantKeys = {};  // userId -> encryption key (legacy, for backward compat)
  Completer<bool>? _keyReceivedCompleter;  // For waiting on key exchange in PreJoin
  bool _isFirstParticipant = false;  // Track if this participant originated the key
  
  // Security level tracking
  String _encryptionLevel = 'none';  // 'none', 'transport', 'e2ee'
  String get encryptionLevel => _encryptionLevel;
  
  // State management
  String? _currentChannelId;
  String? _currentRoomName;
  bool _isConnected = false;
  bool _isConnecting = false;
  
  // NEW: Persistent call state for overlay
  bool _isInCall = false;
  String? _channelName;
  DateTime? _callStartTime;
  
  // NEW: Overlay state
  bool _isOverlayVisible = true;
  bool _isInFullView = false;  // Track if user is viewing full-screen (vs overlay mode)
  double _overlayPositionX = 100;
  double _overlayPositionY = 100;

  // NEW: Navigation (router) reference
  GoRouter? _router;
  
  // Stream controllers
  final _participantJoinedController = StreamController<RemoteParticipant>.broadcast();
  final _participantLeftController = StreamController<RemoteParticipant>.broadcast();
  final _trackSubscribedController = StreamController<TrackSubscribedEvent>.broadcast();
  
  // Getters
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get currentChannelId => _currentChannelId;
  List<RemoteParticipant> get remoteParticipants => _remoteParticipants.values.toList();
  Room? get room => _room;
  bool get isFirstParticipant => _isFirstParticipant;  // Check if this participant originated the key
  bool get hasE2EEKey => _keyTimestamp != null;  // Check if E2EE key is available (generated or received)
  
  // NEW: Overlay state getters
  bool get isInCall => _isInCall;
  String? get channelName => _channelName;
  DateTime? get callStartTime => _callStartTime;
  bool get isOverlayVisible => _isOverlayVisible;
  bool get isInFullView => _isInFullView;
  double get overlayPositionX => _overlayPositionX;
  double get overlayPositionY => _overlayPositionY;
  GoRouter? get router => _router;

  // NEW: Allow app root to inject the GoRouter instance once
  void attachRouter(GoRouter router) {
    _router = router;
  }
  
  // Streams
  Stream<RemoteParticipant> get onParticipantJoined => _participantJoinedController.stream;
  Stream<RemoteParticipant> get onParticipantLeft => _participantLeftController.stream;
  Stream<TrackSubscribedEvent> get onTrackSubscribed => _trackSubscribedController.stream;

  /// Wait for SignalService to have user info set (from socket authentication)
  /// This is critical for E2EE key exchange to work properly
  static Future<void> _waitForUserInfo({int maxRetries = 30, Duration retryDelay = const Duration(milliseconds: 100)}) async {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('[VideoConf] ⏳ WAITING FOR USER AUTHENTICATION');
    debugPrint('[VideoConf] Current state:');
    debugPrint('[VideoConf]   - userId: ${SignalService.instance.currentUserId}');
    debugPrint('[VideoConf]   - deviceId: ${SignalService.instance.currentDeviceId}');
    debugPrint('[VideoConf] ═══════════════════════════════════════════════════════════');
    
    for (int i = 0; i < maxRetries; i++) {
      if (SignalService.instance.currentUserId != null && 
          SignalService.instance.currentDeviceId != null) {
        debugPrint('[VideoConf] ✓ User info available after ${i + 1} attempts (${(i + 1) * retryDelay.inMilliseconds}ms)');
        debugPrint('[VideoConf]   - userId: ${SignalService.instance.currentUserId}');
        debugPrint('[VideoConf]   - deviceId: ${SignalService.instance.currentDeviceId}');
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }
      
      if (i % 10 == 0 && i > 0) {
        debugPrint('[VideoConf] ⏳ Still waiting for user info... (attempt ${i + 1}/$maxRetries, ${(i + 1) * retryDelay.inMilliseconds}ms elapsed)');
      }
      await Future.delayed(retryDelay);
    }
    
    debugPrint('[VideoConf] ❌ TIMEOUT: User info not set after ${maxRetries * retryDelay.inMilliseconds}ms');
    debugPrint('═══════════════════════════════════════════════════════════');
    throw Exception('Timeout waiting for user authentication. User info not set after ${maxRetries * retryDelay.inMilliseconds}ms');
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
      debugPrint('[PreJoin][TEST] 📝 Registering service with MessageListenerService...');
      final messageListener = MessageListenerService.instance;
      messageListener.registerVideoConferenceService(service);
      debugPrint('[PreJoin][TEST] ✓ Service registered, ready to respond to key requests');
      
      // Initialize E2EE (generate key, create KeyProvider, initialize sender key)
      await service._initializeE2EE();
      
      debugPrint('[PreJoin][TEST] ✅ E2EE KEY GENERATION SUCCESSFUL');
      debugPrint('[PreJoin][TEST] Key stored in VideoConferenceService singleton');
      debugPrint('[PreJoin][TEST] Ready to join call AND respond to key requests');
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
  static Future<bool> requestE2EEKey(String channelId) async {
    final service = VideoConferenceService.instance;
    
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[VideoConf][TEST] 🔑 REQUESTING E2EE KEY');
      debugPrint('[VideoConf][TEST] Channel: $channelId');
      
      // CRITICAL: Wait for user info to be set (socket authentication)
      await _waitForUserInfo();
      
      // ⚠️ CRITICAL: Set channel ID so response handler knows which channel this is for
      service._currentChannelId = channelId;
      debugPrint('[VideoConf][TEST] ✓ Channel ID set on service instance');
      
      // ⚠️ CRITICAL: Register this service instance with MessageListenerService
      // so it receives E2EE key responses
      debugPrint('[VideoConf][TEST] 📝 Registering service with MessageListenerService...');
      final messageListener = MessageListenerService.instance;
      messageListener.registerVideoConferenceService(service);
      debugPrint('[VideoConf][TEST] ✓ Service registered, ready to receive key responses');
      
      final requestTimestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Get current user ID from SignalService
      final userId = SignalService.instance.currentUserId ?? 'unknown';
      
      debugPrint('[VideoConf][TEST] Requester ID: $userId');
      debugPrint('[VideoConf][TEST] Request Timestamp: $requestTimestamp');
      debugPrint('[VideoConf][TEST] Message Type: video_e2ee_key_request');
      
      // ⚠️ IMPORTANT: Initialize sender key BEFORE sending request
      // WebRTC channels use Signal Protocol for E2EE key exchange
      // First message in a fresh channel needs sender key initialization
      debugPrint('[VideoConf][TEST] 🔧 Initializing sender key for channel...');
      try {
        // Validate sender key - will check server if corrupted locally
        await SignalService.instance.createGroupSenderKey(channelId);
        debugPrint('[VideoConf][TEST] ✓ Sender key initialized');
      } catch (e) {
        debugPrint('[VideoConf][TEST] ⚠️ Sender key initialization failed: $e');
        // Try to recover by loading from server
        try {
          debugPrint('[VideoConf][TEST] Attempting to load sender key from server...');
          final loaded = await SignalService.instance.loadSenderKeyFromServer(
            channelId: channelId,
            userId: SignalService.instance.currentUserId!,
            deviceId: SignalService.instance.currentDeviceId!,
            forceReload: true,
          );
          if (loaded) {
            debugPrint('[VideoConf][TEST] ✓ Sender key restored from server');
          } else {
            debugPrint('[VideoConf][TEST] ⚠️ No sender key on server - will be created on first send');
          }
        } catch (recoveryError) {
          debugPrint('[VideoConf][TEST] ⚠️ Failed to load from server: $recoveryError');
          // Will be created automatically during sendGroupItem if needed
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
        type: 'video_e2ee_key_request', // NEW itemType!
      );
      
      debugPrint('[VideoConf][TEST] ✓ Key request sent via Signal Protocol');
      debugPrint('[VideoConf][TEST] ⏳ Waiting for key response (10 second timeout)...');
      
      // Wait for key response (handled by MessageListenerService)
      service._keyReceivedCompleter = Completer<bool>();
      
      // Timeout after 10 seconds
      return await service._keyReceivedCompleter!.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[VideoConf][TEST] ❌ KEY REQUEST TIMEOUT - No response in 10 seconds');
          debugPrint('═══════════════════════════════════════════════════════════');
          return false;
        },
      );
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
        List.generate(32, (_) => random.nextInt(256))
      );
      
      // Store timestamp for race condition resolution (oldest wins)
      _keyTimestamp = DateTime.now().millisecondsSinceEpoch;
      
      // Mark this participant as the key originator (first participant)
      _isFirstParticipant = true;
      
      final keyBase64 = base64Encode(_channelSharedKey!);
      final keyPreview = keyBase64.substring(0, 16);
      
      debugPrint('[VideoConf][TEST] Key Generated: $keyPreview... (${_channelSharedKey!.length} bytes)');
      debugPrint('[VideoConf][TEST] Key Timestamp: $_keyTimestamp');
      debugPrint('[VideoConf][TEST] Is First Participant: $_isFirstParticipant');
      
      // ⚠️ IMPORTANT: Initialize sender key for responding to key requests
      // First participant needs sender key to send key responses to new joiners
      if (_currentChannelId != null) {
        debugPrint('[VideoConf][TEST] 🔧 Initializing sender key for channel...');
        try {
          // Validate sender key - will check server if corrupted locally
          await SignalService.instance.createGroupSenderKey(_currentChannelId!);
          debugPrint('[VideoConf][TEST] ✓ Sender key initialized (ready to respond to key requests)');
        } catch (e) {
          debugPrint('[VideoConf][TEST] ⚠️ Sender key initialization failed: $e');
          // Try to recover by loading from server
          try {
            debugPrint('[VideoConf][TEST] Attempting to load sender key from server...');
            final loaded = await SignalService.instance.loadSenderKeyFromServer(
              channelId: _currentChannelId!,
              userId: SignalService.instance.currentUserId!,
              deviceId: SignalService.instance.currentDeviceId!,
              forceReload: true,
            );
            if (loaded) {
              debugPrint('[VideoConf][TEST] ✓ Sender key restored from server');
            } else {
              debugPrint('[VideoConf][TEST] ⚠️ No sender key on server - will be created on first send');
            }
          } catch (recoveryError) {
            debugPrint('[VideoConf][TEST] ⚠️ Failed to load from server: $recoveryError');
            // Will be created automatically during sendGroupItem if needed
          }
        }
      }
      
      // Create BaseKeyProvider for E2EE
      // Note: Data channel encryption is web-only, but frame encryption works on all platforms
      try {
        _keyProvider = await BaseKeyProvider.create();
        
        // Set the shared key in KeyProvider
        await _keyProvider!.setKey(keyBase64);
        
        debugPrint('[VideoConf][TEST] ✓ BaseKeyProvider created successfully');
        debugPrint('[VideoConf][TEST] ✓ Key set in KeyProvider (AES-256 frame encryption ready)');
        debugPrint('[VideoConf][TEST] 📊 KEY STATE:');
        debugPrint('[VideoConf][TEST]    - Key Preview: $keyPreview...');
        debugPrint('[VideoConf][TEST]    - Timestamp: $_keyTimestamp');
        debugPrint('[VideoConf][TEST]    - Channel: $_currentChannelId');
        if (!kIsWeb) {
          debugPrint('[VideoConf][TEST] ℹ️ Native platform: Frame encryption enabled, data channel encryption disabled');
        }
      } catch (e) {
        debugPrint('[VideoConf][TEST] ⚠️ Failed to create BaseKeyProvider: $e');
        debugPrint('[VideoConf][TEST] ⚠️ Falling back to DTLS/SRTP transport encryption only');
        _keyProvider = null;
      }
      
      debugPrint('[VideoConf][TEST] ✓ E2EE INITIALIZATION COMPLETE');
      debugPrint('[VideoConf][TEST] ✓ Role: KEY ORIGINATOR (first participant)');
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
        debugPrint('[VideoConf] ⚠️ Key or channel not initialized, skipping key exchange');
        return;
      }

      // Check if we're the first participant (room creator)
      final isFirstParticipant = _remoteParticipants.isEmpty || 
                                  _remoteParticipants.length == 1;
      
      final itemId = 'video_key_${DateTime.now().millisecondsSinceEpoch}';
      
      if (!isFirstParticipant) {
        debugPrint('[VideoConf] Not first participant, requesting key from $participantUserId');
        
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

      debugPrint('[VideoConf] First participant - sending shared key to: $participantUserId');
      
      // Send the shared key via Signal Protocol (encrypted group message)
      final keyBase64 = base64Encode(_channelSharedKey!);
      
      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'targetUserId': participantUserId,
          'encryptedKey': keyBase64,
          'timestamp': _keyTimestamp,  // Include ORIGINAL timestamp
        }),
        itemId: itemId,
        type: 'video_e2ee_key_response',  // Use new format with timestamp
      );
      
      debugPrint('[VideoConf] ✓ Shared key sent via Signal Protocol (${_channelSharedKey!.length} bytes)');
      debugPrint('[VideoConf] ✓ Key will enable frame-level encryption for all participants');
      
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
    required int timestamp,  // For race condition resolution
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
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }

      // If encryptedKey is empty, this is a KEY REQUEST, not a response
      if (encryptedKey.isEmpty) {
        debugPrint('[VideoConf][TEST] 📩 This is a KEY REQUEST from $senderUserId');
        debugPrint('[VideoConf][TEST] 🔄 Sending our key in response...');
        debugPrint('═══════════════════════════════════════════════════════════');
        await handleKeyRequest(senderUserId);
        return;
      }

      debugPrint('[VideoConf][TEST] 🔑 This is a KEY RESPONSE');
      
      // RACE CONDITION RESOLUTION: Compare timestamps (oldest wins)
      if (_keyTimestamp != null && timestamp > _keyTimestamp!) {
        debugPrint('[VideoConf][TEST] ⚠️ RACE CONDITION DETECTED!');
        debugPrint('[VideoConf][TEST] Our timestamp: $_keyTimestamp (older)');
        debugPrint('[VideoConf][TEST] Received timestamp: $timestamp (newer)');
        debugPrint('[VideoConf][TEST] ✓ REJECTING NEWER KEY - Keeping our older key');
        debugPrint('[VideoConf][TEST] Rule: Oldest timestamp wins!');
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }
      
      // Decode the shared channel key
      final keyBytes = base64Decode(encryptedKey);
      final keyBase64 = base64Encode(keyBytes);
      final keyPreview = keyBase64.substring(0, 16);
      
      debugPrint('[VideoConf][TEST] 📦 Decoding received key...');
      debugPrint('[VideoConf][TEST] Key Preview: $keyPreview... (${keyBytes.length} bytes)');
      
      // Accept the key and update timestamp
      _channelSharedKey = keyBytes;
      _keyTimestamp = timestamp;
      _isFirstParticipant = false;  // We received the key, so we're NOT the first participant
      
      debugPrint('[VideoConf][TEST] ✓ KEY ACCEPTED');
      debugPrint('[VideoConf][TEST] Updated Timestamp: $_keyTimestamp');
      debugPrint('[VideoConf][TEST] Is First Participant: $_isFirstParticipant');
      
      // Set the key in BaseKeyProvider if available
      if (_keyProvider != null) {
        try {
          await _keyProvider!.setKey(keyBase64);
          debugPrint('[VideoConf][TEST] ✓ Key set in BaseKeyProvider (KeyProvider available)');
          debugPrint('[VideoConf][TEST] ✓ Frame-level AES-256 E2EE now ACTIVE');
          debugPrint('[VideoConf][TEST] ✓ Role: KEY RECEIVER (non-first participant)');
          debugPrint('[VideoConf][TEST] 📊 KEY STATE:');
          debugPrint('[VideoConf][TEST]    - Key Preview: $keyPreview...');
          debugPrint('[VideoConf][TEST]    - Timestamp: $_keyTimestamp');
          debugPrint('[VideoConf][TEST]    - Channel: $_currentChannelId');
          
          // The KeyProvider will automatically encrypt/decrypt frames once the key is set
          // No additional action needed - LiveKit handles the rest
          if (_room != null && _isConnected) {
            debugPrint('[VideoConf][TEST] ✓ Room already connected - KeyProvider will now decrypt incoming frames');
            debugPrint('[VideoConf][TEST] ✓ All participants should now use the same key: timestamp=$_keyTimestamp');
          }
        } catch (e) {
          debugPrint('[VideoConf][TEST] ❌ Failed to set key in KeyProvider: $e');
        }
      } else {
        debugPrint('[VideoConf][TEST] ⚠️ KeyProvider not available - frame encryption disabled');
        debugPrint('[VideoConf][TEST] ⚠️ Only DTLS/SRTP transport encryption active');
      }
      
      // Complete the key received completer if PreJoin is waiting
      if (_keyReceivedCompleter != null && !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.complete(true);
        debugPrint('[VideoConf][TEST] ✓ PreJoin screen notified - key exchange complete!');
      }
      
      debugPrint('[VideoConf][TEST] ✅ KEY EXCHANGE SUCCESSFUL');
      debugPrint('═══════════════════════════════════════════════════════════');
      
      notifyListeners();
    } catch (e) {
      debugPrint('[VideoConf][TEST] ❌ ERROR handling E2EE key: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      // Complete with error if PreJoin is waiting
      if (_keyReceivedCompleter != null && !_keyReceivedCompleter!.isCompleted) {
        _keyReceivedCompleter!.completeError(e);
      }
    }
  }

  /// Handle incoming key request from another participant
  /// Send our SHARED CHANNEL KEY to them via Signal Protocol
  Future<void> handleKeyRequest(String requesterId) async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[VideoConf][TEST] 📬 HANDLING KEY REQUEST');
      debugPrint('[VideoConf][TEST] Requester: $requesterId');
      debugPrint('[VideoConf][TEST] Our Timestamp: $_keyTimestamp');
      debugPrint('[VideoConf][TEST] Is First Participant: $_isFirstParticipant');
      
      if (_channelSharedKey == null || _currentChannelId == null) {
        debugPrint('[VideoConf][TEST] ❌ Key not initialized, cannot respond');
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }
      
      if (_keyTimestamp == null) {
        debugPrint('[VideoConf][TEST] ❌ Key timestamp not available, cannot respond');
        debugPrint('═══════════════════════════════════════════════════════════');
        return;
      }

      // ⚠️ IMPORTANT: Ensure sender key exists before responding
      debugPrint('[VideoConf][TEST] 🔧 Ensuring sender key exists...');
      try {
        // Validate sender key - will check server if corrupted locally
        await SignalService.instance.createGroupSenderKey(_currentChannelId!);
        debugPrint('[VideoConf][TEST] ✓ Sender key ready');
      } catch (e) {
        debugPrint('[VideoConf][TEST] ⚠️ Sender key initialization failed: $e');
        // Try to recover by loading from server
        try {
          debugPrint('[VideoConf][TEST] Attempting to load sender key from server...');
          final loaded = await SignalService.instance.loadSenderKeyFromServer(
            channelId: _currentChannelId!,
            userId: SignalService.instance.currentUserId!,
            deviceId: SignalService.instance.currentDeviceId!,
            forceReload: true,
          );
          if (loaded) {
            debugPrint('[VideoConf][TEST] ✓ Sender key restored from server');
          } else {
            debugPrint('[VideoConf][TEST] ⚠️ No sender key on server - will be created on first send');
          }
        } catch (recoveryError) {
          debugPrint('[VideoConf][TEST] ⚠️ Failed to load from server: $recoveryError');
          // Will be created automatically during sendGroupItem if needed
        }
      }

      // Send our SHARED CHANNEL KEY (not a new key!) with ORIGINAL timestamp via Signal Protocol
      final keyBase64 = base64Encode(_channelSharedKey!);
      final keyPreview = keyBase64.substring(0, 16);
      final itemId = 'video_key_response_${DateTime.now().millisecondsSinceEpoch}';
      
      debugPrint('[VideoConf][TEST] 📤 Sending key response...');
      debugPrint('[VideoConf][TEST] Key Preview: $keyPreview...');
      debugPrint('[VideoConf][TEST] ORIGINAL Timestamp: $_keyTimestamp (NOT new timestamp!)');
      debugPrint('[VideoConf][TEST] Message Type: video_e2ee_key_response');
      
      await SignalService.instance.sendGroupItem(
        channelId: _currentChannelId!,
        message: jsonEncode({
          'targetUserId': requesterId,
          'encryptedKey': keyBase64,
          'timestamp': _keyTimestamp,  // Use ORIGINAL timestamp for race condition resolution
        }),
        itemId: itemId,
        type: 'video_e2ee_key_response',
      );
      
      debugPrint('[VideoConf][TEST] ✓ Key response sent via Signal Protocol');
      debugPrint('[VideoConf][TEST] ✓ Requester $requesterId will receive key with timestamp $_keyTimestamp');
      debugPrint('═══════════════════════════════════════════════════════════');
    } catch (e) {
      debugPrint('[VideoConf][TEST] ❌ ERROR handling key request: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
    }
  }

  /// Join a video conference room
  Future<void> joinRoom(
    String channelId, {
    MediaDevice? cameraDevice,      // NEW: Optional pre-selected camera
    MediaDevice? microphoneDevice,  // NEW: Optional pre-selected microphone
    String? channelName,            // NEW: Channel name for display
  }) async {
    if (_isConnecting || _isConnected) {
      debugPrint('[VideoConf] Already connecting or connected');
      return;
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
      if (!SignalService.instance.isInitialized) {
        throw Exception(
          'Signal Service must be initialized before joining video call. '
          'Key exchange requires Signal Protocol encryption.'
        );
      }
      debugPrint('[VideoConf] ✓ Signal Service ready for E2EE key exchange');

      // Initialize E2EE ONLY if we don't already have a key
      // (non-first participants receive key in PreJoin before joining)
      if (_keyTimestamp == null) {
        debugPrint('[VideoConf] No existing E2EE key - initializing as first participant');
        await _initializeE2EE();
      } else {
        debugPrint('[VideoConf] E2EE key already received (timestamp: $_keyTimestamp)');
        debugPrint('[VideoConf] Skipping initialization - will use existing key');
        
        // Still need to ensure sender key exists for this participant
        if (_currentChannelId != null) {
          debugPrint('[VideoConf] 🔧 Ensuring sender key exists for channel...');
          try {
            await SignalService.instance.createGroupSenderKey(_currentChannelId!);
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
            await _keyProvider!.setKey(keyBase64);
            debugPrint('[VideoConf] ✓ BaseKeyProvider created with received key');
            if (!kIsWeb) {
              debugPrint('[VideoConf] ℹ️ Native platform: Frame encryption enabled, data channel encryption disabled');
            }
          } catch (e) {
            debugPrint('[VideoConf] ⚠️ Failed to create KeyProvider: $e');
            _keyProvider = null;
          }
        }
      }

      // Get LiveKit token from server (credentials are automatically included)
      debugPrint('[VideoConf] Requesting token for channel: $channelId');
      final response = await ApiService.post(
        '/api/livekit/token',
        data: {'channelId': channelId},
      );

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
        // Use pre-selected camera device if available
        if (cameraDevice != null) {
          debugPrint('[VideoConf] Using pre-selected camera: ${cameraDevice.label}');
          videoTrack = await LocalVideoTrack.createCameraTrack(
            CameraCaptureOptions(deviceId: cameraDevice.deviceId),
          );
        } else {
          videoTrack = await LocalVideoTrack.createCameraTrack();
        }
        debugPrint('[VideoConf] ✓ Camera track created');
      } catch (e) {
        debugPrint('[VideoConf] ⚠️ Failed to create camera track: $e');
      }
      
      try {
        // Use pre-selected microphone device if available
        if (microphoneDevice != null) {
          debugPrint('[VideoConf] Using pre-selected microphone: ${microphoneDevice.label}');
          audioTrack = await LocalAudioTrack.create(
            AudioCaptureOptions(deviceId: microphoneDevice.deviceId),
          );
        } else {
          audioTrack = await LocalAudioTrack.create(AudioCaptureOptions());
        }
        debugPrint('[VideoConf] ✓ Microphone track created');
      } catch (e) {
        debugPrint('[VideoConf] ⚠️ Failed to create audio track: $e');
      }

      // Create room WITHOUT E2EE options initially to avoid E2EEManager bug
      // We'll manually set up frame encryption after connection (workaround for SDK bug)
      _room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // Note: E2EE disabled here - we'll add frame cryptors manually after connect
        ),
      );
      
      if (_keyProvider != null) {
        debugPrint('[VideoConf] ✓ Room created (E2EE will be set up after connection)');
        debugPrint('[VideoConf] ℹ️ Workaround: Manual frame encryption to bypass SDK bug');
      } else {
        debugPrint('[VideoConf] ✓ Room created (DTLS/SRTP transport encryption only)');
        debugPrint('[VideoConf] ⚠️ Frame-level E2EE unavailable (BaseKeyProvider failed)');
      }

      // Set up event listeners
      _setupRoomListeners();

      // Connect to LiveKit room
      debugPrint('[VideoConf] Connecting to LiveKit room...');
      await _room!.connect(
        url, 
        token,
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // No E2EE options - we'll set up frame encryption after tracks are published
        ),
      );

      // Publish local tracks if available
      if (videoTrack != null) {
        debugPrint('[VideoConf] Publishing video track...');
        await _room!.localParticipant?.publishVideoTrack(videoTrack);
      }
      
      if (audioTrack != null) {
        debugPrint('[VideoConf] Publishing audio track...');
        await _room!.localParticipant?.publishAudioTrack(audioTrack);
      }

      // Manual E2EE setup after tracks are published (workaround for SDK bug)
      if (_keyProvider != null && !kIsWeb) {
        await _setupManualFrameEncryption();
      } else if (_keyProvider != null && kIsWeb) {
        debugPrint('[VideoConf] ℹ️ Web E2EE: Should use standard E2EE options');
        debugPrint('[VideoConf] ⚠️ Manual setup not implemented for web - falling back to DTLS/SRTP');
      }

      // Add existing remote participants to map (for users who joined before us)
      debugPrint('[VideoConf] Checking for existing participants...');
      for (final participant in _room!.remoteParticipants.values) {
        debugPrint('[VideoConf] Found existing participant: ${participant.identity}');
        _remoteParticipants[participant.identity] = participant;
        
        // Exchange keys with existing participants
        await _exchangeKeysWithParticipant(participant.identity);
      }
      debugPrint('[VideoConf] Total remote participants: ${_remoteParticipants.length}');

      _isConnected = true;
      _isConnecting = false;
      
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
      debugPrint('[VideoConf] Participant joined: ${event.participant.identity}');
      _remoteParticipants[event.participant.identity] = event.participant;
      
      // Exchange encryption keys with new participant
      await _exchangeKeysWithParticipant(event.participant.identity);
      
      _participantJoinedController.add(event.participant);
      notifyListeners();
    });

    // Participant left
    listener.on<ParticipantDisconnectedEvent>((event) {
      debugPrint('[VideoConf] Participant left: ${event.participant.identity}');
      _remoteParticipants.remove(event.participant.identity);
      _participantKeys.remove(event.participant.identity);
      
      _participantLeftController.add(event.participant);
      notifyListeners();
    });

    // Track subscribed
    listener.on<TrackSubscribedEvent>((event) async {
      debugPrint('[VideoConf] Track subscribed: ${event.track.kind} from ${event.participant.identity}');
      debugPrint('[VideoConf]   - Track SID: ${event.track.sid}');
      debugPrint('[VideoConf]   - Track muted: ${event.track.muted}');
      _trackSubscribedController.add(event);
      notifyListeners();
    });

    // Track unsubscribed
    listener.on<TrackUnsubscribedEvent>((event) {
      debugPrint('[VideoConf] Track unsubscribed: ${event.track.kind} from ${event.participant.identity}');
      notifyListeners();
    });

    // Track published (important for seeing when tracks become available)
    listener.on<TrackPublishedEvent>((event) {
      debugPrint('[VideoConf] Track published: ${event.publication.kind} from ${event.participant.identity}');
      debugPrint('[VideoConf]   - Track SID: ${event.publication.sid}');
      notifyListeners();
    });

    // Track unpublished
    listener.on<TrackUnpublishedEvent>((event) {
      debugPrint('[VideoConf] Track unpublished: ${event.publication.kind} from ${event.participant.identity}');
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
        debugPrint('[VideoConf] ✓ Emitted video:leave-channel after disconnection');
      } catch (e) {
        debugPrint('[VideoConf] ⚠️ Failed to emit leave event on disconnection: $e');
      }
    }
    
    _isConnected = false;
    _remoteParticipants.clear();
    _participantKeys.clear();
    
    // Clean up E2EE state on disconnection
    _channelSharedKey = null;
    _keyTimestamp = null;
    _isFirstParticipant = false;
    _keyReceivedCompleter = null;
    _currentChannelId = null;
    
    notifyListeners();
    debugPrint('[VideoConf] ✓ Disconnection handled (E2EE state cleared)');
  }

  /// Leave the current room
  Future<void> leaveRoom() async {
    try {
      debugPrint('[VideoConf] Leaving room');

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
      _keyReceivedCompleter = null;

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
    _isInFullView = false;  // Exiting full-view
    _savePersistence();
    notifyListeners();
  }
  
  /// NEW: Enter full-view mode (hides TopBar and overlay)
  void enterFullView() {
    _isInFullView = true;
    _isOverlayVisible = false;  // Hide overlay when in full-view
    _savePersistence();
    notifyListeners();
  }
  
  /// NEW: Exit full-view mode (back to overlay mode)
  void exitFullView() {
    _isInFullView = false;
    _isOverlayVisible = true;  // Show overlay when exiting full-view
    _savePersistence();
    notifyListeners();
  }

  /// NEW: Navigate to the current channel's full-view page via GoRouter
  void navigateToCurrentChannelFullView() {
    if (_router == null) {
      debugPrint('[VideoConferenceService] navigateToCurrentChannelFullView: router is null');
      return;
    }
    final channelId = _currentChannelId;
    if (channelId == null) {
      debugPrint('[VideoConferenceService] navigateToCurrentChannelFullView: currentChannelId is null');
      return;
    }

    debugPrint('[VideoConferenceService] Entering full-view mode BEFORE navigation');
    // Enter full-view mode IMMEDIATELY to hide TopBar/overlay before navigation
    enterFullView();
    
    debugPrint('[VideoConferenceService] Navigating to full-view for channel: $channelId');
    _router!.go('/app/channels/$channelId', extra: {
      'host': '',
      'name': _channelName ?? 'Channel',
      'type': 'webrtc',
    });
  }
  /// Manual frame encryption setup for native platforms (workaround for SDK bug)
  /// This bypasses the E2EEManager which tries to create dataPacketCryptor
  Future<void> _setupManualFrameEncryption() async {
    if (_keyProvider == null || _room == null) {
      debugPrint('[VideoConf] ⚠️ Cannot setup manual E2EE - missing keyProvider or room');
      return;
    }

    try {
      debugPrint('[VideoConf] 🔧 Setting up manual frame encryption...');
      
      // Get local participant's published tracks
      final localParticipant = _room!.localParticipant;
      if (localParticipant == null) {
        debugPrint('[VideoConf] ⚠️ No local participant found');
        return;
      }

      // Set up frame cryptors for each published track
      int cryptorCount = 0;
      
      for (final publication in localParticipant.trackPublications.values) {
        final track = publication.track;
        if (track == null || track.sender == null) continue;
        
        try {
          // Create frame cryptor for this track's sender
          final frameCryptor = await rtc.frameCryptorFactory.createFrameCryptorForRtpSender(
            participantId: localParticipant.identity,
            sender: track.sender!,
            algorithm: rtc.Algorithm.kAesGcm,
            keyProvider: _keyProvider!.keyProvider,
          );
          
          // Enable the cryptor
          await frameCryptor.setEnabled(true);
          
          debugPrint('[VideoConf] ✓ Frame cryptor created for ${track.kind} track');
          cryptorCount++;
        } catch (e) {
          debugPrint('[VideoConf] ⚠️ Failed to create frame cryptor for ${track.kind}: $e');
        }
      }
      
      if (cryptorCount > 0) {
        debugPrint('[VideoConf] ✓ Manual E2EE setup complete ($cryptorCount cryptors)');
        debugPrint('[VideoConf] ✓ AES-256-GCM frame encryption active for audio/video');
        _encryptionLevel = 'e2ee';
      } else {
        debugPrint('[VideoConf] ⚠️ No frame cryptors created - using DTLS/SRTP only');
        _encryptionLevel = 'transport';
      }
      
    } catch (e) {
      debugPrint('[VideoConf] ❌ Manual E2EE setup failed: $e');
      _encryptionLevel = 'transport';
    }
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
          await prefs.setString('callStartTime', _callStartTime!.toIso8601String());
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
        debugPrint('[VideoConf] 🔄 Auto-rejoin detected for channel: $lastChannelId');
        
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

  @override
  void dispose() {
    leaveRoom();
    _participantJoinedController.close();
    _participantLeftController.close();
    _trackSubscribedController.close();
    super.dispose();
  }
}

