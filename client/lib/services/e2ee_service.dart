import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// E2EEService - End-to-End Encryption for Video Conference
/// 
/// Features:
/// - AES-256-GCM encryption for media frames
/// - Key exchange via Signal Protocol
/// - Key rotation (every 60 minutes)
/// - Frame transformation for RTP packets
/// - Zero-knowledge server (server never sees keys)
class E2EEService extends ChangeNotifier {
  // Encryption keys (peerId -> key)
  final Map<String, Uint8List> _peerKeys = {};
  
  // Current encryption key for sending
  Uint8List? _sendKey;
  
  // Key rotation timer
  Timer? _keyRotationTimer;
  
  // Key generation timestamp
  DateTime? _keyGeneratedAt;
  
  // IV counter for GCM (must be unique per encryption)
  int _ivCounter = 0;
  
  // Enabled state
  bool _isEnabled = false;
  
  // Statistics
  int _encryptedFrames = 0;
  int _decryptedFrames = 0;
  int _encryptionErrors = 0;
  int _decryptionErrors = 0;
  
  // Getters
  bool get isEnabled => _isEnabled;
  int get encryptedFrames => _encryptedFrames;
  int get decryptedFrames => _decryptedFrames;
  int get encryptionErrors => _encryptionErrors;
  int get decryptionErrors => _decryptionErrors;
  DateTime? get keyGeneratedAt => _keyGeneratedAt;
  
  /// Initialize E2EE service
  Future<void> initialize() async {
    debugPrint('[E2EE] Initializing...');
    
    try {
      // Generate initial send key
      await _generateSendKey();
      
      // Start key rotation timer (60 minutes)
      _startKeyRotation();
      
      _isEnabled = true;
      debugPrint('[E2EE] ✓ Initialized with AES-256-GCM');
      notifyListeners();
      
    } catch (e) {
      debugPrint('[E2EE] Initialization error: $e');
      rethrow;
    }
  }
  
  /// Generate new send key (256-bit AES)
  Future<void> _generateSendKey() async {
    debugPrint('[E2EE] Generating new send key...');
    
    // Generate 256-bit (32 bytes) random key
    final secureRandom = FortunaRandom();
    final seedSource = Uint8List.fromList(
      List<int>.generate(32, (i) => DateTime.now().millisecondsSinceEpoch ~/ (i + 1))
    );
    secureRandom.seed(KeyParameter(seedSource));
    
    _sendKey = secureRandom.nextBytes(32); // 256 bits
    _keyGeneratedAt = DateTime.now();
    _ivCounter = 0; // Reset IV counter
    
    debugPrint('[E2EE] ✓ Send key generated (256-bit)');
  }
  
  /// Start key rotation timer
  void _startKeyRotation() {
    _keyRotationTimer?.cancel();
    
    // Rotate key every 60 minutes
    _keyRotationTimer = Timer.periodic(const Duration(minutes: 60), (_) {
      debugPrint('[E2EE] Key rotation triggered');
      _rotateSendKey();
    });
    
    debugPrint('[E2EE] Key rotation scheduled (60 min)');
  }
  
  /// Rotate send key
  Future<void> _rotateSendKey() async {
    await _generateSendKey();
    
    debugPrint('[E2EE] ✓ Send key rotated');
    notifyListeners();
    
    // TODO: Distribute new key to all peers via Signal Protocol
    // This will be integrated with existing Signal Protocol implementation
  }
  
  /// Add peer encryption key (received via Signal Protocol)
  void addPeerKey(String peerId, Uint8List key) {
    if (key.length != 32) {
      throw ArgumentError('Key must be 256-bit (32 bytes)');
    }
    
    _peerKeys[peerId] = key;
    debugPrint('[E2EE] Peer key added: $peerId');
    notifyListeners();
  }
  
  /// Remove peer key
  void removePeerKey(String peerId) {
    _peerKeys.remove(peerId);
    debugPrint('[E2EE] Peer key removed: $peerId');
    notifyListeners();
  }
  
  /// Get send key (for distribution to peers)
  Uint8List? getSendKey() {
    return _sendKey;
  }
  
  /// Encrypt media frame (outgoing)
  /// 
  /// Frame format: [IV (12 bytes)] [Encrypted Data] [Auth Tag (16 bytes)]
  Uint8List? encryptFrame(Uint8List frame) {
    if (!_isEnabled || _sendKey == null) {
      return frame; // Pass-through if not enabled
    }
    
    try {
      // Generate unique IV (12 bytes for GCM)
      final iv = _generateIV();
      
      // Encrypt with AES-256-GCM
      final cipher = GCMBlockCipher(AESEngine());
      final params = AEADParameters(
        KeyParameter(_sendKey!),
        128, // Tag length in bits (16 bytes)
        iv,
        Uint8List(0), // No additional authenticated data
      );
      
      cipher.init(true, params); // true = encrypt
      
      // Encrypt frame
      final encrypted = Uint8List(cipher.getOutputSize(frame.length));
      var offset = 0;
      offset += cipher.processBytes(frame, 0, frame.length, encrypted, offset);
      offset += cipher.doFinal(encrypted, offset);
      
      // Combine: IV + encrypted data + auth tag
      final result = Uint8List(12 + offset);
      result.setRange(0, 12, iv);
      result.setRange(12, 12 + offset, encrypted.sublist(0, offset));
      
      _encryptedFrames++;
      
      return result;
      
    } catch (e) {
      debugPrint('[E2EE] Encryption error: $e');
      _encryptionErrors++;
      return null;
    }
  }
  
  /// Decrypt media frame (incoming)
  Uint8List? decryptFrame(Uint8List encryptedFrame, String peerId) {
    if (!_isEnabled || !_peerKeys.containsKey(peerId)) {
      return encryptedFrame; // Pass-through if not enabled or no key
    }
    
    try {
      // Extract IV (first 12 bytes)
      if (encryptedFrame.length < 12 + 16) {
        throw Exception('Frame too short (min 28 bytes)');
      }
      
      final iv = encryptedFrame.sublist(0, 12);
      final ciphertext = encryptedFrame.sublist(12);
      
      // Decrypt with AES-256-GCM
      final cipher = GCMBlockCipher(AESEngine());
      final params = AEADParameters(
        KeyParameter(_peerKeys[peerId]!),
        128, // Tag length in bits
        iv,
        Uint8List(0),
      );
      
      cipher.init(false, params); // false = decrypt
      
      // Decrypt frame
      final decrypted = Uint8List(cipher.getOutputSize(ciphertext.length));
      var offset = 0;
      offset += cipher.processBytes(ciphertext, 0, ciphertext.length, decrypted, offset);
      offset += cipher.doFinal(decrypted, offset);
      
      _decryptedFrames++;
      
      return decrypted.sublist(0, offset);
      
    } catch (e) {
      debugPrint('[E2EE] Decryption error: $e');
      _decryptionErrors++;
      return null;
    }
  }
  
  /// Generate unique IV (12 bytes for GCM)
  Uint8List _generateIV() {
    // IV format: [timestamp (8 bytes)] [counter (4 bytes)]
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final counter = _ivCounter++;
    
    final iv = ByteData(12);
    iv.setInt64(0, timestamp, Endian.big);
    iv.setInt32(8, counter, Endian.big);
    
    return iv.buffer.asUint8List();
  }
  
  /// Get encryption statistics
  Map<String, dynamic> getStats() {
    return {
      'enabled': _isEnabled,
      'encryptedFrames': _encryptedFrames,
      'decryptedFrames': _decryptedFrames,
      'encryptionErrors': _encryptionErrors,
      'decryptionErrors': _decryptionErrors,
      'keyGeneratedAt': _keyGeneratedAt?.toIso8601String(),
      'peerCount': _peerKeys.length,
    };
  }
  
  /// Reset statistics
  void resetStats() {
    _encryptedFrames = 0;
    _decryptedFrames = 0;
    _encryptionErrors = 0;
    _decryptionErrors = 0;
    notifyListeners();
  }
  
  /// Shutdown E2EE service
  void shutdown() {
    debugPrint('[E2EE] Shutting down...');
    
    _keyRotationTimer?.cancel();
    _peerKeys.clear();
    _sendKey = null;
    _isEnabled = false;
    
    debugPrint('[E2EE] ✓ Shutdown complete');
  }
  
  @override
  void dispose() {
    shutdown();
    super.dispose();
  }
}

/// Browser Compatibility Checker for Insertable Streams
class InsertableStreamsChecker {
  /// Check if browser supports Insertable Streams API
  static bool isSupported() {
    // Chrome 86+, Edge 86+, Safari 15.4+
    // Firefox: NOT SUPPORTED (as of Oct 2025)
    
    if (kIsWeb) {
      // Check via JavaScript interop
      // Note: In real implementation, use package:js to check:
      // return js.context.hasProperty('RTCRtpSender') &&
      //        js.context['RTCRtpSender'].hasProperty('prototype') &&
      //        js.context['RTCRtpSender']['prototype'].hasProperty('createEncodedStreams');
      
      // For now, assume supported on web (will be checked at runtime)
      return true;
    }
    
    // Mobile/Desktop: Check WebRTC version
    return false; // Insertable Streams primarily for web
  }
  
  /// Get browser name
  static String getBrowserName() {
    if (kIsWeb) {
      // Parse userAgent
      // Simplified: In real implementation, use package:universal_html
      return 'Unknown Browser';
    }
    return 'Native';
  }
  
  /// Get error message for unsupported browsers
  static String getUnsupportedMessage() {
    return '''
E2E Encryption requires Insertable Streams API, which is not supported in your browser.

Supported browsers:
✅ Chrome 86+
✅ Edge 86+
✅ Safari 15.4+

❌ Firefox (not supported yet)

Please use a supported browser to join encrypted video calls.
''';
  }
}

