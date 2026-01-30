import 'dart:typed_data';

/// Signal Protocol PreKey Bundle
///
/// Contains all cryptographic keys needed to establish a session with a user.
/// Retrieved from server when initiating first contact with a recipient.
class KeyBundle {
  final String userId;
  final int deviceId;
  final Uint8List identityKey;
  final int? preKeyId;
  final Uint8List? preKey;
  final int signedPreKeyId;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySignature;
  final int registrationId;

  KeyBundle({
    required this.userId,
    required this.deviceId,
    required this.identityKey,
    this.preKeyId,
    this.preKey,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    required this.registrationId,
  });

  /// Create from server response
  factory KeyBundle.fromServer(Map<String, dynamic> data) {
    return KeyBundle(
      userId: data['userId'] as String,
      deviceId: data['deviceId'] as int,
      identityKey: _decodeBase64(data['identityKey'] as String),
      preKeyId: data['preKeyId'] as int?,
      preKey: data['preKey'] != null
          ? _decodeBase64(data['preKey'] as String)
          : null,
      signedPreKeyId: data['signedPreKeyId'] as int,
      signedPreKey: _decodeBase64(data['signedPreKey'] as String),
      signedPreKeySignature: _decodeBase64(
        data['signedPreKeySignature'] as String,
      ),
      registrationId: data['registrationId'] as int,
    );
  }

  /// Convert to JSON for transmission
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'deviceId': deviceId,
      'identityKey': _encodeBase64(identityKey),
      if (preKeyId != null) 'preKeyId': preKeyId,
      if (preKey != null) 'preKey': _encodeBase64(preKey!),
      'signedPreKeyId': signedPreKeyId,
      'signedPreKey': _encodeBase64(signedPreKey),
      'signedPreKeySignature': _encodeBase64(signedPreKeySignature),
      'registrationId': registrationId,
    };
  }

  /// Check if bundle has a one-time prekey
  bool get hasPreKey => preKeyId != null && preKey != null;

  /// Get bundle identifier for caching
  String get bundleId => '$userId:$deviceId';

  static Uint8List _decodeBase64(String base64) {
    // Handle both standard and URL-safe base64
    String normalized = base64.replaceAll('-', '+').replaceAll('_', '/');
    // Add padding if needed
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    return Uint8List.fromList(
      String.fromCharCodes(
        Uri.decodeComponent(
          normalized.split('').map((c) {
            final code = c.codeUnitAt(0);
            return '%${code.toRadixString(16).padLeft(2, '0')}';
          }).join(),
        ).codeUnits,
      ).codeUnits,
    );
  }

  static String _encodeBase64(Uint8List bytes) {
    return Uri.encodeComponent(String.fromCharCodes(bytes))
        .replaceAll('%', '')
        .replaceAll('+', '-')
        .replaceAll('/', '_')
        .replaceAll('=', '');
  }

  @override
  String toString() {
    return 'KeyBundle(userId: $userId, deviceId: $deviceId, '
        'hasPreKey: $hasPreKey, signedPreKeyId: $signedPreKeyId)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyBundle && other.bundleId == bundleId;
  }

  @override
  int get hashCode => bundleId.hashCode;
}
