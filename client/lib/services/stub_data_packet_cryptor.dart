/// Stub DataPacketCryptor implementation for Windows/Linux platforms
/// 
/// flutter_webrtc package is missing DataPacketCryptor C++ implementation for desktop platforms.
/// This stub prevents crashes when E2EEManager tries to create DataPacketCryptor.
/// 
/// Platforms affected: Windows, Linux
/// Working platforms: Android, iOS, macOS, Web
/// 
/// See: https://github.com/flutter-webrtc/flutter-webrtc/tree/main/common/cpp/src
library;

import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Stub factory that returns stub DataPacketCryptor
class StubDataPacketCryptorFactory implements DataPacketCryptorFactory {
  @override
  Future<DataPacketCryptor> createDataPacketCryptor({
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async {
    return StubDataPacketCryptor();
  }
}

/// Stub implementation that does nothing (prevents crashes)
class StubDataPacketCryptor implements DataPacketCryptor {
  @override
  Future<Uint8List> decrypt({
    required String participantId,
    required EncryptedPacket encryptedPacket,
  }) async {
    // Return data unchanged (no decryption on Windows)
    return encryptedPacket.data;
  }

  @override
  Future<void> dispose() async {
    // Nothing to dispose
  }

  @override
  Future<EncryptedPacket> encrypt({
    required String participantId,
    required int keyIndex,
    required Uint8List data,
  }) async {
    // Return data unchanged (no encryption on Windows)
    return EncryptedPacket(
      data: data,
      keyIndex: keyIndex,
      iv: Uint8List(12), // Empty IV
    );
  }
}
