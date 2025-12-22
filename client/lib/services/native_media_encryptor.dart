import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'dart:math';

/// Native Media Encryptor for E2EE on platforms that don't support frame encryption
///
/// This provides AES-256-GCM encryption for media data when LiveKit's BaseKeyProvider
/// is not available (Windows, Linux, macOS desktop clients).
///
/// Security Model:
/// - Uses the same shared key from Signal Protocol key exchange
/// - AES-256-GCM provides authenticated encryption
/// - Each frame gets a unique IV (derived from frame counter)
/// - Authentication tag prevents tampering
class NativeMediaEncryptor {
  final Uint8List _key;
  int _frameCounter = 0;
  final Random _random = Random.secure();

  NativeMediaEncryptor(this._key) {
    if (_key.length != 32) {
      throw ArgumentError('Key must be 32 bytes (256 bits)');
    }
  }

  /// Encrypt a media frame using AES-256-GCM
  ///
  /// Format: [12-byte IV][encrypted data][16-byte auth tag]
  Uint8List encryptFrame(Uint8List plaintext) {
    try {
      // Generate unique IV for this frame
      final iv = _generateIV();

      // Create GCM cipher
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true, // encrypt
          AEADParameters(
            KeyParameter(_key),
            128, // 128-bit auth tag
            iv,
            Uint8List(0), // no additional data
          ),
        );

      // Encrypt the frame
      final ciphertext = cipher.process(plaintext);

      // Combine: IV + ciphertext (which includes auth tag)
      final output = Uint8List(iv.length + ciphertext.length);
      output.setRange(0, iv.length, iv);
      output.setRange(iv.length, output.length, ciphertext);

      return output;
    } catch (e) {
      throw Exception('Encryption failed: $e');
    }
  }

  /// Decrypt a media frame using AES-256-GCM
  ///
  /// Expected format: [12-byte IV][encrypted data][16-byte auth tag]
  Uint8List decryptFrame(Uint8List encrypted) {
    try {
      if (encrypted.length < 28) {
        // 12 (IV) + 16 (tag) = 28 minimum
        throw ArgumentError('Encrypted data too short');
      }

      // Extract IV
      final iv = encrypted.sublist(0, 12);
      final ciphertext = encrypted.sublist(12);

      // Create GCM cipher
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false, // decrypt
          AEADParameters(
            KeyParameter(_key),
            128, // 128-bit auth tag
            iv,
            Uint8List(0), // no additional data
          ),
        );

      // Decrypt and verify
      final plaintext = cipher.process(ciphertext);

      return plaintext;
    } catch (e) {
      throw Exception('Decryption failed: $e');
    }
  }

  /// Generate a unique IV for each frame
  ///
  /// Uses frame counter + random bytes to ensure uniqueness
  Uint8List _generateIV() {
    final iv = Uint8List(12);

    // First 8 bytes: frame counter (ensures uniqueness within session)
    final counterBytes = Uint8List(8);
    final counterView = ByteData.view(counterBytes.buffer);
    counterView.setUint64(0, _frameCounter++, Endian.big);
    iv.setRange(0, 8, counterBytes);

    // Last 4 bytes: random (additional entropy)
    for (int i = 8; i < 12; i++) {
      iv[i] = _random.nextInt(256);
    }

    return iv;
  }

  /// Reset frame counter (call when starting new session)
  void reset() {
    _frameCounter = 0;
  }
}
