import 'dart:typed_data';
import 'dart:math';
import 'package:pointycastle/export.dart';

/// Service for encrypting and decrypting file chunks
/// 
/// Uses AES-GCM (Galois/Counter Mode) for authenticated encryption:
/// - 256-bit keys
/// - 96-bit IVs (nonces)
/// - 128-bit authentication tags
/// - Provides confidentiality AND integrity
class EncryptionService {
  static const int KEY_SIZE = 32; // 256 bits
  static const int IV_SIZE = 12; // 96 bits (recommended for GCM)
  static const int MAC_SIZE = 16; // 128 bits (authentication tag)
  
  final Random _random = Random.secure();
  
  /// Generate a random 256-bit AES key
  Uint8List generateKey() {
    final key = Uint8List(KEY_SIZE);
    for (int i = 0; i < KEY_SIZE; i++) {
      key[i] = _random.nextInt(256);
    }
    return key;
  }
  
  /// Generate a random 96-bit IV (nonce)
  /// 
  /// CRITICAL: Never reuse an IV with the same key!
  /// Generate a new IV for each chunk encryption.
  Uint8List generateIV() {
    final iv = Uint8List(IV_SIZE);
    for (int i = 0; i < IV_SIZE; i++) {
      iv[i] = _random.nextInt(256);
    }
    return iv;
  }
  
  /// Encrypt data with AES-GCM
  /// 
  /// Returns encrypted data with authentication tag appended
  /// Format: [encrypted_data][16-byte auth tag]
  Future<EncryptionResult> encrypt(
    Uint8List plaintext,
    Uint8List key,
    Uint8List iv,
  ) async {
    if (key.length != KEY_SIZE) {
      throw ArgumentError('Key must be $KEY_SIZE bytes (256 bits)');
    }
    if (iv.length != IV_SIZE) {
      throw ArgumentError('IV must be $IV_SIZE bytes (96 bits)');
    }
    
    // Create AES-GCM cipher
    final cipher = GCMBlockCipher(AESEngine());
    
    // Initialize for encryption
    final params = AEADParameters(
      KeyParameter(key),
      MAC_SIZE * 8, // MAC size in bits
      iv,
      Uint8List(0), // No additional authenticated data
    );
    
    cipher.init(true, params); // true = encrypt
    
    // Allocate output buffer (plaintext + MAC tag)
    final ciphertext = Uint8List(plaintext.length + MAC_SIZE);
    
    // Encrypt
    int offset = 0;
    offset += cipher.processBytes(
      plaintext,
      0,
      plaintext.length,
      ciphertext,
      offset,
    );
    offset += cipher.doFinal(ciphertext, offset);
    
    return EncryptionResult(
      ciphertext: ciphertext,
      iv: iv,
    );
  }
  
  /// Decrypt data with AES-GCM
  /// 
  /// Verifies authentication tag during decryption
  /// Returns null if authentication fails (data corrupted/tampered)
  Future<Uint8List?> decrypt(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List iv,
  ) async {
    if (key.length != KEY_SIZE) {
      throw ArgumentError('Key must be $KEY_SIZE bytes (256 bits)');
    }
    if (iv.length != IV_SIZE) {
      throw ArgumentError('IV must be $IV_SIZE bytes (96 bits)');
    }
    if (ciphertext.length < MAC_SIZE) {
      throw ArgumentError('Ciphertext too short (must include MAC tag)');
    }
    
    try {
      // Create AES-GCM cipher
      final cipher = GCMBlockCipher(AESEngine());
      
      // Initialize for decryption
      final params = AEADParameters(
        KeyParameter(key),
        MAC_SIZE * 8, // MAC size in bits
        iv,
        Uint8List(0), // No additional authenticated data
      );
      
      cipher.init(false, params); // false = decrypt
      
      // Allocate output buffer (ciphertext - MAC tag)
      final plaintext = Uint8List(ciphertext.length - MAC_SIZE);
      
      // Decrypt
      int offset = 0;
      offset += cipher.processBytes(
        ciphertext,
        0,
        ciphertext.length,
        plaintext,
        offset,
      );
      offset += cipher.doFinal(plaintext, offset);
      
      return plaintext;
    } catch (e) {
      // Authentication failed - data corrupted or tampered
      return null;
    }
  }
  
  /// Encrypt a chunk with automatic IV generation
  /// 
  /// Convenience method that generates IV automatically
  Future<EncryptionResult> encryptChunk(
    Uint8List chunkData,
    Uint8List fileKey,
  ) async {
    final iv = generateIV();
    return encrypt(chunkData, fileKey, iv);
  }
  
  /// Decrypt a chunk
  /// 
  /// Returns null if decryption fails (wrong key or corrupted data)
  Future<Uint8List?> decryptChunk(
    Uint8List encryptedChunk,
    Uint8List fileKey,
    Uint8List iv,
  ) async {
    return decrypt(encryptedChunk, fileKey, iv);
  }
  
  /// Derive a key from a password (PBKDF2)
  /// 
  /// NOT recommended for file encryption - use generateKey() instead
  /// This is for user-password scenarios only
  Future<Uint8List> deriveKeyFromPassword(
    String password,
    Uint8List salt, {
    int iterations = 100000,
  }) async {
    final generator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    generator.init(Pbkdf2Parameters(salt, iterations, KEY_SIZE));
    
    return generator.process(Uint8List.fromList(password.codeUnits));
  }
  
  /// Generate a random salt for PBKDF2
  Uint8List generateSalt({int size = 32}) {
    final salt = Uint8List(size);
    for (int i = 0; i < size; i++) {
      salt[i] = _random.nextInt(256);
    }
    return salt;
  }
  
  /// Validate key format
  bool isValidKey(Uint8List key) {
    return key.length == KEY_SIZE;
  }
  
  /// Validate IV format
  bool isValidIV(Uint8List iv) {
    return iv.length == IV_SIZE;
  }
}

/// Result of encryption operation
class EncryptionResult {
  /// Encrypted data with authentication tag appended
  final Uint8List ciphertext;
  
  /// Initialization vector (nonce) used for encryption
  /// Must be stored alongside ciphertext for decryption
  final Uint8List iv;
  
  EncryptionResult({
    required this.ciphertext,
    required this.iv,
  });
  
  /// Total size (ciphertext + IV for storage)
  int get totalSize => ciphertext.length + iv.length;
  
  @override
  String toString() => 'EncryptionResult(ciphertext: ${ciphertext.length} bytes, iv: ${iv.length} bytes)';
}

/// Exception thrown when encryption/decryption fails
class EncryptionException implements Exception {
  final String message;
  
  EncryptionException(this.message);
  
  @override
  String toString() => 'EncryptionException: $message';
}
