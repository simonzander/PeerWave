import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'server_settings_service.dart';
import 'ice_config_service.dart';
import 'user_profile_service.dart';
import 'message_cleanup_service.dart';
import 'message_listener_service.dart';
import 'notification_service.dart' as desktop;
import 'notification_service_android.dart';
import 'notification_listener_service.dart';
import 'sound_service.dart';
import 'recent_conversations_service.dart';
import 'starred_channels_service.dart';
import '../providers/unread_messages_provider.dart';
import '../providers/role_provider.dart';
import '../providers/file_transfer_stats_provider.dart';
import 'storage/database_helper.dart';
import 'server_config_native.dart'
    if (dart.library.html) 'server_config_web.dart';
// Meeting and Call services
import 'meeting_service.dart';
import 'call_service.dart';
import 'presence_service.dart';
import 'external_participant_service.dart';
// P2P imports
import 'file_transfer/storage_interface.dart';
import 'file_transfer/encryption_service.dart';
import 'file_transfer/chunking_service.dart';
import 'file_transfer/download_manager.dart';
import 'file_transfer/webrtc_service.dart';
import 'file_transfer/p2p_coordinator.dart';
import 'file_transfer/file_reannounce_service.dart';
import 'file_transfer/socket_file_client.dart';
import 'file_transfer/storage_factory_web.dart'
    if (dart.library.io) 'file_transfer/storage_factory_native.dart';
// Video conference imports
import 'video_conference_service.dart';
// FCM imports (stub for desktop, real implementation for mobile)
import 'fcm_service_stub.dart' if (dart.library.io) 'fcm_service.dart';

/// Orchestrates all post-login service initialization in the correct order
///
/// This service ensures services are initialized with proper dependencies:
/// 1. Network layer (ICE config, Socket.IO)
/// 2. Core services (Database, Signal Protocol)
/// 3. Data services (Profiles, Messages, Roles) - parallel
/// 4. Communication (Message listeners, Activities)
/// 5. P2P file transfer
/// 6. Video conferencing
class PostLoginInitService {
  static final PostLoginInitService instance = PostLoginInitService._();
  PostLoginInitService._();

  bool _isInitialized = false;
  bool _isInitializing = false;
  String? _lastError;
  DateTime? _initStartTime;
  DateTime? _initCompleteTime;
  bool _wasAutostart = false;

  // P2P services (initialized during post-login)
  FileStorageInterface? _fileStorage;
  EncryptionService? _encryptionService;
  ChunkingService? _chunkingService;
  DownloadManager? _downloadManager;
  WebRTCFileService? _webrtcService;
  P2PCoordinator? _p2pCoordinator;

  // Getters for P2P services (for providers)
  FileStorageInterface? get fileStorage => _fileStorage;
  EncryptionService? get encryptionService => _encryptionService;
  ChunkingService? get chunkingService => _chunkingService;
  DownloadManager? get downloadManager => _downloadManager;
  WebRTCFileService? get webrtcService => _webrtcService;
  P2PCoordinator? get p2pCoordinator => _p2pCoordinator;

  bool get isInitialized => _isInitialized;
  bool get isInitializing => _isInitializing;
  String? get lastError => _lastError;
  Duration? get initDuration =>
      _initStartTime != null && _initCompleteTime != null
      ? _initCompleteTime!.difference(_initStartTime!)
      : null;

  /// Initialize all post-login services in the correct order
  ///
  /// [serverUrl] - API server URL (e.g. http://localhost:3000)
  /// [unreadProvider] - Provider for unread message counts
  /// [roleProvider] - Provider for user roles
  /// [isAutostart] - Whether this is an autostart scenario (for enhanced retry)
  /// [onProgress] - Callback for progress updates (step, current, total)
  Future<void> initialize({
    required String serverUrl,
    required UnreadMessagesProvider unreadProvider,
    required RoleProvider roleProvider,
    bool isAutostart = false,
    FileTransferStatsProvider? statsProvider,
    Function(String step, int current, int total)? onProgress,
  }) async {
    if (_isInitialized) {
      debugPrint('[POST_LOGIN_INIT] Already initialized');
      return;
    }

    if (_isInitializing) {
      debugPrint('[POST_LOGIN_INIT] Already initializing, please wait...');
      return;
    }

    _isInitializing = true;
    _wasAutostart = isAutostart;
    _lastError = null;
    _initStartTime = DateTime.now();
    debugPrint('[POST_LOGIN_INIT] ========================================');
    debugPrint('[POST_LOGIN_INIT] Starting post-login initialization...');
    debugPrint('[POST_LOGIN_INIT] Start time: $_initStartTime');
    if (isAutostart) {
      debugPrint('[POST_LOGIN_INIT] 🚀 AUTOSTART MODE - Using enhanced retry');
    }
    debugPrint('[POST_LOGIN_INIT] ========================================');

    try {
      final totalSteps = 16; // Updated from 15 to include meeting/call services
      var currentStep = 0;

      // ========================================
      // PHASE 1: Network Foundation (SEQUENTIAL)
      // ========================================

      // Step 1: Load ICE server configuration
      currentStep++;
      onProgress?.call('Loading ICE configuration...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Loading ICE configuration...',
      );
      try {
        await IceConfigService().loadConfig(serverUrl: serverUrl);
        debugPrint('[POST_LOGIN_INIT] ✓ ICE configuration loaded');
      } catch (e) {
        debugPrint(
          '[POST_LOGIN_INIT] ⚠️ ICE config failed (using fallback): $e',
        );
      }

      // Step 2: Connect to Socket.IO servers (CRITICAL - connects to ALL configured servers)
      currentStep++;
      onProgress?.call('Connecting to servers...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Connecting to all Socket.IO servers...',
      );

      // For web: Set server URL before connecting
      if (kIsWeb) {
        debugPrint('[POST_LOGIN_INIT] Web: Setting server URL to $serverUrl');
        SocketService.instance.setServerUrl(serverUrl);
      }

      await SocketService.instance.connectAllServers();
      debugPrint('[POST_LOGIN_INIT] ✓ Socket.IO connected to all servers');

      // ========================================
      // PHASE 2: Core Services (SEQUENTIAL)
      // ========================================

      // Step 3: Initialize Database with retry logic
      currentStep++;
      onProgress?.call('Initializing database...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing database...',
      );
      try {
        await DatabaseHelper.waitUntilReady(
          maxAttempts: 3,
          retryDelay: Duration(seconds: 2),
          isAutostart: _wasAutostart,
        );
        debugPrint('[POST_LOGIN_INIT] ✓ Database initialized and ready');
      } catch (e) {
        debugPrint(
          '[POST_LOGIN_INIT] ✗ Database initialization failed after retries: $e',
        );
        _lastError = 'Database initialization failed: $e';
        throw Exception('Failed to initialize database: $e');
      }

      // Step 3.5: Initialize Starred Channels Service (uses database)
      onProgress?.call('Loading preferences...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing starred channels...',
      );
      await StarredChannelsService.instance.initialize();
      debugPrint('[POST_LOGIN_INIT] ✓ Starred channels initialized');

      // Step 4: Initialize Signal Protocol stores
      currentStep++;
      onProgress?.call('Initializing encryption...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing Signal Protocol...',
      );
      final signalClient = await ServerSettingsService.instance
          .getOrCreateSignalClient();
      if (!signalClient.isInitialized) {
        await signalClient.initialize();
      }
      debugPrint('[POST_LOGIN_INIT] ✓ Signal Protocol initialized');

      // Keys are auto-generated by observers and verified by healing service
      // No manual status check needed - system handles setup automatically

      // ========================================
      // PHASE 3: Data Services (PARALLEL)
      // ========================================

      currentStep++;
      onProgress?.call('Loading application data...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Loading data services (parallel)...',
      );

      await Future.wait([
        // User profiles
        Future(() async {
          try {
            if (!UserProfileService.instance.isLoaded) {
              await UserProfileService.instance.initProfiles();
              debugPrint('[POST_LOGIN_INIT]   ✓ User profiles loaded');
            }
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ User profiles error: $e');
          }
        }),

        // Message cleanup service
        Future(() async {
          try {
            await MessageCleanupService.instance.init();
            debugPrint('[POST_LOGIN_INIT]   ✓ Message cleanup initialized');
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ Message cleanup error: $e');
          }
        }),

        // Unread messages
        Future(() async {
          try {
            final activeServer = ServerConfigService.getActiveServer();
            if (activeServer != null) {
              await unreadProvider.loadFromStorage(activeServer.id);
              debugPrint(
                '[POST_LOGIN_INIT]   ✓ Unread messages loaded for server ${activeServer.id}',
              );
            }
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ Unread messages error: $e');
          }
        }),

        // User roles
        Future(() async {
          try {
            if (!roleProvider.isLoaded) {
              await roleProvider.loadUserRoles();
              debugPrint('[POST_LOGIN_INIT]   ✓ User roles loaded');
            }
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ User roles error: $e');
          }
        }),

        // Recent conversations
        Future(() async {
          try {
            await RecentConversationsService.getRecentConversations();
            debugPrint('[POST_LOGIN_INIT]   ✓ Recent conversations loaded');
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ Recent conversations error: $e');
          }
        }),
      ]);

      debugPrint('[POST_LOGIN_INIT] ✓ Data services loaded');

      // ========================================
      // PHASE 4: Communication Services (SEQUENTIAL)
      // ========================================

      // Step 7: Initialize Message Listener
      currentStep++;
      onProgress?.call(
        'Setting up message listeners...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing message listeners...',
      );
      MessageListenerService.instance.initialize();
      debugPrint('[POST_LOGIN_INIT] ✓ Message listeners ready');

      // Initialize notification services
      await SoundService.instance.initialize();

      // Use platform-specific notification service
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await NotificationServiceAndroid.instance.initialize();
        // Request permission on Android 13+
        await NotificationServiceAndroid.instance.requestPermission();
      } else {
        await desktop.NotificationService.instance.initialize();
        // Request permission on web
        if (kIsWeb) {
          await desktop.NotificationService.instance.requestPermission();
        }
      }

      await NotificationListenerService.instance.initialize();
      debugPrint('[POST_LOGIN_INIT] ✓ Notification services ready');

      // Step 8: Activities Service (static methods, no initialization needed)
      currentStep++;
      onProgress?.call('Activity tracking ready...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Activities service (static, no init needed)',
      );
      debugPrint('[POST_LOGIN_INIT] ✓ Activities service ready');

      // ========================================
      // PHASE 4.5: Meeting & Call Services (PARALLEL)
      // ========================================

      currentStep++;
      onProgress?.call(
        'Initializing meetings and calls...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing meeting/call services (parallel)...',
      );

      await Future.wait([
        // Meeting service
        Future(() async {
          try {
            final meetingService = MeetingService();
            meetingService.initializeListeners();
            debugPrint('[POST_LOGIN_INIT]   ✓ Meeting service initialized');
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ Meeting service error: $e');
          }
        }),

        // Call service
        Future(() async {
          try {
            final callService = CallService();
            callService.initializeListeners();
            debugPrint('[POST_LOGIN_INIT]   ✓ Call service initialized');
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ Call service error: $e');
          }
        }),

        // Presence service
        Future(() async {
          try {
            final presenceService = PresenceService();
            presenceService.initialize();
            debugPrint('[POST_LOGIN_INIT]   ✓ Presence service initialized');
          } catch (e) {
            debugPrint('[POST_LOGIN_INIT]   ⚠️ Presence service error: $e');
          }
        }),

        // External participant service
        Future(() async {
          try {
            final externalService = ExternalParticipantService();
            externalService.initializeListeners();
            debugPrint(
              '[POST_LOGIN_INIT]   ✓ External participant service initialized',
            );
          } catch (e) {
            debugPrint(
              '[POST_LOGIN_INIT]   ⚠️ External participant service error: $e',
            );
          }
        }),
      ]);

      debugPrint('[POST_LOGIN_INIT] ✓ Meeting/call services ready');

      // ========================================
      // PHASE 5: P2P File Transfer (SEQUENTIAL)
      // ========================================

      // Step 9: Initialize P2P base services (parallel possible)
      currentStep++;
      onProgress?.call('Initializing P2P services...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing P2P base services...',
      );

      _fileStorage = createFileStorage();
      await _fileStorage!.initialize();
      _encryptionService = EncryptionService();
      _chunkingService = ChunkingService();
      debugPrint('[POST_LOGIN_INIT] ✓ P2P base services ready');

      // Step 10: Download Manager
      currentStep++;
      onProgress?.call(
        'Setting up download manager...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing download manager...',
      );
      _downloadManager = DownloadManager(
        storage: _fileStorage!,
        chunkingService: _chunkingService!,
        encryptionService: _encryptionService!,
        onDownloadComplete: _handleDownloadComplete,
      );
      debugPrint('[POST_LOGIN_INIT] ✓ Download manager ready');

      // Step 11: WebRTC File Service
      currentStep++;
      onProgress?.call('Setting up WebRTC...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing WebRTC file service...',
      );
      final iceServers = IceConfigService().getIceServers();
      _webrtcService = WebRTCFileService(iceServers: iceServers);
      debugPrint('[POST_LOGIN_INIT] ✓ WebRTC file service ready');

      // Step 12: P2P Coordinator
      currentStep++;
      onProgress?.call(
        'Initializing P2P coordinator...',
        currentStep,
        totalSteps,
      );
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing P2P coordinator...',
      );

      final socketService = SocketService.instance;
      if (socketService.socket != null && socketService.isConnected) {
        final socketFileClient = SocketFileClient();

        _p2pCoordinator = P2PCoordinator(
          webrtcService: _webrtcService!,
          downloadManager: _downloadManager!,
          storage: _fileStorage!,
          encryptionService: _encryptionService!,
          socketClient: socketFileClient,
          chunkingService: _chunkingService!,
          statsProvider: statsProvider,
        );
        debugPrint('[POST_LOGIN_INIT] ✓ P2P coordinator ready');
      } else {
        debugPrint(
          '[POST_LOGIN_INIT] ⚠️ Socket not connected, skipping P2P coordinator',
        );
      }

      // Step 13: File Re-announce Service
      currentStep++;
      onProgress?.call('Announcing local files...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Re-announcing local files...',
      );
      if (_p2pCoordinator != null) {
        try {
          final socketService = SocketService.instance;
          if (socketService.socket != null) {
            final socketFileClient = SocketFileClient();
            final reannounceService = FileReannounceService(
              storage: _fileStorage!,
              socketClient: socketFileClient,
            );
            final result = await reannounceService.reannounceAllFiles();
            if (result.reannounced > 0) {
              debugPrint(
                '[POST_LOGIN_INIT] ✓ Re-announced ${result.reannounced} files',
              );
            }
          }
        } catch (e) {
          debugPrint('[POST_LOGIN_INIT] ⚠️ File re-announce error: $e');
        }
      } else {
        debugPrint(
          '[POST_LOGIN_INIT] ⚠️ P2P coordinator not available, skipping file re-announce',
        );
      }

      // ========================================
      // PHASE 6: Video Services (PARALLEL)
      // ========================================

      currentStep++;
      onProgress?.call('Finalizing...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Initializing video services (parallel)...',
      );

      await Future.wait([
        // Video conference service (no explicit init needed - lazy)
        Future(() async {
          debugPrint(
            '[POST_LOGIN_INIT]   ✓ Video conference service ready (lazy)',
          );
        }),

        // E2EE service (no explicit init needed - lazy)
        Future(() async {
          debugPrint('[POST_LOGIN_INIT]   ✓ E2EE service ready (lazy)');
        }),

        // ========================================
        // 🔔 FCM Push Notifications (Android/iOS)
        // ========================================
        Future(() async {
          if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
            try {
              debugPrint('[POST_LOGIN_INIT]   Initializing FCM service...');
              await FCMService().initialize();
              debugPrint('[POST_LOGIN_INIT]   ✓ FCM service initialized');
            } catch (e) {
              debugPrint('[POST_LOGIN_INIT]   ⚠️ FCM initialization error: $e');
              // Don't fail initialization if FCM fails
            }
          } else {
            debugPrint(
              '[POST_LOGIN_INIT]   ℹ️ FCM not available on this platform',
            );
          }
        }),
      ]);

      // ========================================
      // FINAL STEP: Check for active call to rejoin
      // ========================================
      currentStep++;
      onProgress?.call('Checking for active calls...', currentStep, totalSteps);
      debugPrint(
        '[POST_LOGIN_INIT] [$currentStep/$totalSteps] Checking for active WebRTC call to rejoin...',
      );

      try {
        final videoConferenceService = VideoConferenceService.instance;
        await videoConferenceService.checkForRejoin();
        debugPrint('[POST_LOGIN_INIT]   ✓ WebRTC rejoin check complete');
      } catch (e) {
        debugPrint('[POST_LOGIN_INIT]   ⚠️ WebRTC rejoin check failed: $e');
        // Don't fail initialization if rejoin fails
      }

      _isInitialized = true;
      _initCompleteTime = DateTime.now();
      final duration = _initCompleteTime!.difference(_initStartTime!);
      debugPrint('[POST_LOGIN_INIT] ========================================');
      debugPrint('[POST_LOGIN_INIT] ✅ All services initialized successfully!');
      debugPrint('[POST_LOGIN_INIT] Completion time: $_initCompleteTime');
      debugPrint(
        '[POST_LOGIN_INIT] Total duration: ${duration.inMilliseconds}ms',
      );
      debugPrint('[POST_LOGIN_INIT] ========================================');
    } catch (e, stackTrace) {
      _lastError = e.toString();
      _initCompleteTime = DateTime.now();
      debugPrint('[POST_LOGIN_INIT] ========================================');
      debugPrint('[POST_LOGIN_INIT] ❌ Initialization failed: $e');
      debugPrint('[POST_LOGIN_INIT] $stackTrace');
      debugPrint('[POST_LOGIN_INIT] ========================================');
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  /// Reset state on logout
  void reset() {
    debugPrint('[POST_LOGIN_INIT] Resetting state...');
    _isInitialized = false;
    _isInitializing = false;

    // Clear P2P services
    _fileStorage = null;
    _encryptionService = null;
    _chunkingService = null;
    _downloadManager = null;
    _webrtcService = null;
    _p2pCoordinator = null;

    debugPrint('[POST_LOGIN_INIT] ✓ State reset');
  }

  /// Handle download completion - Auto-export to Downloads folder on Android/iOS
  Future<void> _handleDownloadComplete(String fileId, String fileName) async {
    debugPrint('[POST_LOGIN_INIT] Download complete: $fileName ($fileId)');

    // Only auto-export on mobile platforms (Android/iOS)
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      debugPrint(
        '[POST_LOGIN_INIT] Skipping auto-export (not mobile platform)',
      );
      return;
    }

    try {
      debugPrint(
        '[POST_LOGIN_INIT] Starting auto-export to Downloads folder...',
      );

      final storage = _fileStorage;
      final encryptionService = _encryptionService;
      final chunkingService = _chunkingService;

      if (storage == null ||
          encryptionService == null ||
          chunkingService == null) {
        debugPrint(
          '[POST_LOGIN_INIT] ❌ Services not initialized, cannot export',
        );
        return;
      }

      // Get file metadata
      final metadata = await storage.getFileMetadata(fileId);
      if (metadata == null) {
        debugPrint('[POST_LOGIN_INIT] ❌ File metadata not found');
        return;
      }

      final chunkCount = metadata['chunkCount'] as int? ?? 0;
      final availableChunks = await storage.getAvailableChunks(fileId);

      if (availableChunks.length != chunkCount) {
        debugPrint(
          '[POST_LOGIN_INIT] ⚠️ Not all chunks available (${availableChunks.length}/$chunkCount)',
        );
        return;
      }

      // Get file encryption key
      final fileKey = await storage.getFileKey(fileId);
      if (fileKey == null) {
        debugPrint('[POST_LOGIN_INIT] ❌ File encryption key not found');
        return;
      }

      // Decrypt and assemble chunks
      final decryptedChunks = <ChunkData>[];
      for (final chunkIndex in availableChunks) {
        final encryptedBytes = await storage.getChunk(fileId, chunkIndex);
        final chunkMetadata = await storage.getChunkMetadata(
          fileId,
          chunkIndex,
        );

        if (encryptedBytes == null || chunkMetadata == null) continue;

        final iv = chunkMetadata['iv'] as Uint8List?;
        if (iv == null) continue;

        final decryptedBytes = await encryptionService.decryptChunk(
          encryptedBytes,
          fileKey,
          iv,
        );

        if (decryptedBytes != null) {
          final chunkHash = chunkMetadata['chunkHash'] as String? ?? '';
          decryptedChunks.add(
            ChunkData(
              chunkIndex: chunkIndex,
              data: decryptedBytes,
              hash: chunkHash,
              size: decryptedBytes.length,
            ),
          );
        }
      }

      final fileBytes = await chunkingService.assembleChunks(
        decryptedChunks,
        verifyHashes: false,
      );

      if (fileBytes == null) {
        debugPrint('[POST_LOGIN_INIT] ❌ Failed to assemble file');
        return;
      }

      // Save to Downloads directory
      await _saveToDownloads(fileBytes, fileName);
      debugPrint('[POST_LOGIN_INIT] ✅ Auto-export complete: $fileName');
    } catch (e) {
      debugPrint('[POST_LOGIN_INIT] ❌ Auto-export failed: $e');
    }
  }

  /// Save file bytes to appropriate directory (uses app-specific storage for Android)
  Future<void> _saveToDownloads(Uint8List bytes, String fileName) async {
    try {
      // Get appropriate directory based on platform
      Directory? targetDir;

      if (Platform.isAndroid) {
        // Android: Use app-specific external storage (no permissions needed)
        // Files will be visible in Files app under "Internal Storage/Android/data/com.yourapp/files"
        targetDir = await getExternalStorageDirectory();
        if (targetDir != null) {
          // Create a Downloads subdirectory within app storage
          final downloadsSubdir = Directory('${targetDir.path}/Downloads');
          if (!await downloadsSubdir.exists()) {
            await downloadsSubdir.create(recursive: true);
          }
          targetDir = downloadsSubdir;
        }
      } else if (Platform.isIOS) {
        // iOS: Use app documents directory (accessible via Files app)
        targetDir = await getApplicationDocumentsDirectory();
      } else {
        // Desktop: Use downloads directory
        targetDir = await getDownloadsDirectory();
      }

      if (targetDir == null) {
        throw Exception('Could not access storage directory');
      }

      // Create file path
      final filePath = '${targetDir.path}/$fileName';
      final file = File(filePath);

      // Write file
      await file.writeAsBytes(bytes);

      debugPrint('[POST_LOGIN_INIT] ✓ File saved to: $filePath');
    } catch (e) {
      debugPrint('[POST_LOGIN_INIT] ✗ Error saving file: $e');
      rethrow;
    }
  }
}
