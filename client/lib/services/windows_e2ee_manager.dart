/// Custom E2EE Manager for Windows/Linux platforms
/// 
/// This wrapper extends LiveKit's E2EEManager to skip DataPacketCryptor initialization
/// on platforms where it's not implemented (Windows/Linux).
/// 
/// The flutter_webrtc C++ backend is missing DataPacketCryptor implementation,
/// but FrameCryptor (audio/video encryption) works perfectly.
/// 
/// This allows:
/// - ✅ Audio/video frame encryption (FrameCryptor works on all platforms)
/// - ⚠️ Data channel is not encrypted (DataPacketCryptor skipped on Windows/Linux)

import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

/// E2EE Manager that works on Windows/Linux by skipping DataPacketCryptor
class WindowsCompatibleE2EEManager extends E2EEManager {
  WindowsCompatibleE2EEManager(
    BaseKeyProvider keyProvider, {
    bool dcEncryptionEnabled = false,
  }) : super(keyProvider, dcEncryptionEnabled: dcEncryptionEnabled);

  @override
  Future<void> setup(Room room) async {
    // Call parent setup but catch DataPacketCryptor errors on Windows/Linux
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      debugPrint('[WindowsE2EE] Setting up E2EE for Windows/Linux (skipping DataPacketCryptor)');
      
      try {
        await super.setup(room);
      } catch (e) {
        // Expected to fail when trying to create DataPacketCryptor
        // This is fine - FrameCryptor will still work for audio/video
        if (e.toString().contains('MissingPluginException') || 
            e.toString().contains('dataPacketCryptor')) {
          debugPrint('[WindowsE2EE] ✓ FrameCryptor setup complete (DataPacketCryptor skipped as expected)');
        } else {
          // Unexpected error - rethrow
          rethrow;
        }
      }
    } else {
      // Other platforms: use standard setup
      await super.setup(room);
    }
  }

  @override
  bool get isDataChannelEncryptionEnabled {
    // Disable data channel encryption on Windows/Linux
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      return false;
    }
    return super.isDataChannelEncryptionEnabled;
  }

  @override
  Future<Uint8List?> handleEncryptedData({
    required Uint8List data,
    required Uint8List iv,
    required String participantIdentity,
    required int keyIndex,
  }) async {
    // On Windows/Linux, data channel is not encrypted - return data as-is
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      debugPrint('[WindowsE2EE] Data channel not encrypted on Windows/Linux - passing through');
      return data;
    }
    return super.handleEncryptedData(
      data: data,
      iv: iv,
      participantIdentity: participantIdentity,
      keyIndex: keyIndex,
    );
  }

  @override
  Future<rtc.EncryptedPacket> encryptData({required Uint8List data}) async {
    // On Windows/Linux, data channel is not encrypted - return unencrypted packet
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      debugPrint('[WindowsE2EE] Data channel not encrypted on Windows/Linux - passing through');
      return rtc.EncryptedPacket(
        data: data,
        keyIndex: 0,
        iv: Uint8List(12), // Empty IV
      );
    }
    return super.encryptData(data: data);
  }
}
