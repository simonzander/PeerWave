import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../api_service.dart';
import '../../socket_service.dart'
    if (dart.library.io) '../../socket_service_native.dart';
import '../stores/identity_key_store.dart';
import '../stores/pre_key_store.dart';
import '../stores/signed_pre_key_store.dart';
import '../stores/sender_key_store.dart';
import '../observers/identity_key_observer.dart';
import '../observers/pre_key_maintenance_observer.dart';
import '../observers/sender_key_rotation_observer.dart';
import '../state/identity_key_state.dart';
import '../state/signed_pre_key_state.dart';
import '../state/pre_key_state.dart';
import '../state/sender_key_state.dart';

/// Manages Signal Protocol cryptographic keys
///
/// Responsibilities:
/// - Key generation (Identity, SignedPreKey, PreKeys, SenderKeys)
/// - Key rotation and lifecycle management
/// - Server validation and verification
/// - Key upload via REST API
/// - Store creation and initialization
///
/// This class owns all key-related stores and uses mixins from the key/ folder
/// to provide specialized operations. This keeps code organized while providing
/// a clean, unified API.
///
/// Usage:
/// ```dart
/// // Self-initializing factory
/// final keyManager = await SignalKeyManager.create();
///
/// // Direct access to key operations
/// await keyManager.getIdentityKeyPair();
/// await keyManager.ensurePreKeys(count: 100);
/// await keyManager.validateSenderKey(groupId: id, senderAddress: addr);
/// ```
class SignalKeyManager
    with
        PermanentIdentityKeyStore,
        PermanentPreKeyStore,
        PermanentSignedPreKeyStore,
        PermanentSenderKeyStore {
  // Service dependencies - injected by SignalClient
  @override
  final ApiService apiService;

  @override
  final SocketService socketService;

  // Identity key pair - required by both mixins
  // Stored as nullable internally, exposed as non-null getter for SignedPreKeyStore
  IdentityKeyPair? _identityKeyPair;

  @override
  IdentityKeyPair get identityKeyPair {
    if (_identityKeyPair == null) {
      throw StateError('Identity key pair not initialized. Call init() first.');
    }
    return _identityKeyPair!;
  }

  /// Check if identity key pair is initialized (for mixins)
  bool get hasIdentityKeyPair => _identityKeyPair != null;

  @override
  set identityKeyPair(IdentityKeyPair? value) {
    _identityKeyPair = value;
  }

  bool _initialized = false;

  bool get isInitialized => _initialized;

  // State instances - server-scoped observables
  late final IdentityKeyState identityKeyState;
  late final SignedPreKeyState signedPreKeyState;
  late final PreKeyState preKeyState;
  late final SenderKeyState senderKeyState;

  // Observers - automatic key maintenance and rotation
  late final IdentityKeyObserver _identityObserver;
  late final PreKeyMaintenanceObserver _preKeyObserver;
  SenderKeyRotationObserver?
  _senderKeyObserver; // Nullable - requires user info

  // Private constructor for factory
  SignalKeyManager._({required this.apiService, required this.socketService}) {
    // Initialize state instances (one per KeyManager = one per server)
    identityKeyState = IdentityKeyState();
    signedPreKeyState = SignedPreKeyState();
    preKeyState = PreKeyState();
    senderKeyState = SenderKeyState();

    _identityObserver = IdentityKeyObserver(keyManager: this);
    _preKeyObserver = PreKeyMaintenanceObserver(keyManager: this);
    // SenderKeyObserver initialized later when user info available
  }

  /// Self-initializing factory - creates stores and validates keys
  static Future<SignalKeyManager> create({
    required ApiService apiService,
    required SocketService socketService,
  }) async {
    final manager = SignalKeyManager._(
      apiService: apiService,
      socketService: socketService,
    );
    await manager.init();
    return manager;
  }

  /// Initialize stores and validate keys exist
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[KEY_MANAGER] Already initialized');
      return;
    }

    debugPrint('[KEY_MANAGER] Initializing...');

    // STEP 1: Get identity key pair (auto-generates if missing) and store it for SignedPreKeyStore mixin
    debugPrint('[KEY_MANAGER] Loading identity key pair...');
    identityKeyPair = await getIdentityKeyPair();
    debugPrint('[KEY_MANAGER] ✓ Identity key pair loaded');

    // STEP 2: Initialize signed pre key store (requires identityKeyPair to be set)
    debugPrint('[KEY_MANAGER] Initializing signed pre key store...');
    await initializeSignedPreKeyStore();
    debugPrint('[KEY_MANAGER] ✓ Signed pre key store initialized');

    // STEP 3: Check pre keys (auto-maintains 110 keys)
    debugPrint('[KEY_MANAGER] Checking pre keys...');
    await checkPreKeys();
    debugPrint('[KEY_MANAGER] ✓ Pre keys checked');

    // Start observers for automatic key maintenance
    _identityObserver.start();
    _preKeyObserver.start();
    // SenderKey observer started separately via startSenderKeyObserver()
    debugPrint('[KEY_MANAGER] ✓ Observers started (identity, prekey)');

    debugPrint('[KEY_MANAGER] ✅ Initialized');
    _initialized = true;
  }

  /// Start SenderKey rotation observer (call after user info is available)
  void startSenderKeyObserver({
    required String? Function() getCurrentUserId,
    required int? Function() getCurrentDeviceId,
  }) {
    if (_senderKeyObserver != null) {
      debugPrint('[KEY_MANAGER] SenderKey observer already started');
      return;
    }

    _senderKeyObserver = SenderKeyRotationObserver(
      keyManager: this,
      getCurrentUserId: getCurrentUserId,
      getCurrentDeviceId: getCurrentDeviceId,
    );
    _senderKeyObserver!.start();
    debugPrint('[KEY_MANAGER] ? SenderKey observer started');
  }

  /// Dispose and cleanup observers
  void dispose() {
    _identityObserver.stop();
    _preKeyObserver.stop();
    _senderKeyObserver?.stop();
    debugPrint('[KEY_MANAGER] ? All observers stopped');
  }
  // ============================================================================
  // KEY GENERATION
  // ============================================================================
  // Note: generatePreKeysInRange is provided by PermanentPreKeyStore mixin
  // Note: generateSignedPreKeyManual is provided by PermanentSignedPreKeyStore mixin

  // ============================================================================
  // KEY VALIDATION & FINGERPRINTS
  // ============================================================================

  // Note: getLatestSignedPreKeyId is provided by PermanentSignedPreKeyStore mixin
  // Note: getLocalPreKeyCount is provided by PermanentPreKeyStore mixin
  // Note: getPreKeyFingerprints is provided by PermanentPreKeyStore mixin
  // Note: SignedPreKey rotation is handled automatically by getSignedPreKey() in PermanentSignedPreKeyStore mixin

  // ============================================================================
  // SERVER OPERATIONS
  // ============================================================================
  // Note: Upload methods removed - stores handle uploads automatically via storeX() methods

  /// Delete all keys on server
  Future<Map<String, dynamic>> deleteAllKeysOnServer() async {
    debugPrint('[KEY_MANAGER] Deleting all keys on server...');

    final response = await ApiService.instance.delete('/signal/keys');

    if (response.statusCode != 200) {
      throw Exception('Failed to delete keys: ${response.statusCode}');
    }

    final result = response.data as Map<String, dynamic>;
    debugPrint(
      '[KEY_MANAGER] ✓ Keys deleted: ${result['preKeysDeleted']} PreKeys, ${result['signedPreKeysDeleted']} SignedPreKeys',
    );

    return result;
  }

  // ============================================================================
  // COMPLETE KEY UPLOAD WORKFLOW
  // ============================================================================

  /// Upload all keys to server (Identity + SignedPreKey + PreKeys)
  /// Used during initialization and healing
  Future<void> uploadAllKeysToServer() async {
    debugPrint('[KEY_MANAGER] ========================================');
    debugPrint('[KEY_MANAGER] Uploading all keys to server...');

    try {
      // Get identity key (auto-generates, but doesn't upload - need manual upload for identity)
      final identityData = await getIdentityKeyPairData();
      final registrationId = await getLocalRegistrationId();

      // Upload identity via REST API
      final response = await apiService.post(
        '/signal/identity',
        data: {
          'publicKey': identityData['publicKey'],
          'registrationId': registrationId,
        },
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to upload identity key: ${response.statusCode}',
        );
      }
      debugPrint('[KEY_MANAGER] ✓ Identity key uploaded via REST API');

      // Get signed pre key (auto-generates and uploads)
      await getSignedPreKey();

      // Check pre keys (auto-generates and uploads)
      await checkPreKeys();

      debugPrint('[KEY_MANAGER] ========================================');
      debugPrint('[KEY_MANAGER] ✅ All keys uploaded successfully');
    } catch (e, stackTrace) {
      debugPrint('[KEY_MANAGER] ❌ Error uploading keys: $e');
      debugPrint('[KEY_MANAGER] Stack trace: $stackTrace');
      rethrow;
    }
  }

  // ============================================================================
  // KEY EVENT HANDLERS (Socket.IO Integration)
  // ============================================================================

  // Note: syncPreKeyIds is provided by PermanentPreKeyStore mixin

  /// Upload SignedPreKey and PreKeys only (identity already uploaded separately)
  /// Simplified - just call store methods
  Future<void> uploadSignedPreKeyAndPreKeys() async {
    await getSignedPreKey(); // Auto-generates and uploads
    await checkPreKeys(); // Auto-generates and uploads
  }
}
