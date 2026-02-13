import 'dart:convert';
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
  final DateTime? signedPreKeyCreatedAt;

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
    this.signedPreKeyCreatedAt,
  });

  /// Create from server response
  factory KeyBundle.fromServer(Map<String, dynamic> data) {
    // Parse nested signedPreKey and preKey objects from server response
    final signedPreKeyObj = data['signedPreKey'] as Map<String, dynamic>?;
    final preKeyObj = data['preKey'] as Map<String, dynamic>?;

    if (signedPreKeyObj == null) {
      throw Exception('Missing signedPreKey in server response');
    }

    // Handle device_id and registration_id as String or int
    final deviceIdRaw = data['device_id'];
    final deviceId = deviceIdRaw is int
        ? deviceIdRaw
        : int.parse(deviceIdRaw.toString());

    final regIdRaw = data['registration_id'];
    final registrationId = regIdRaw is int
        ? regIdRaw
        : int.parse(regIdRaw.toString());

    final signedPreKeyCreatedAt = _parseDateTime(
      signedPreKeyObj['createdAt'] ??
          signedPreKeyObj['updatedAt'] ??
          signedPreKeyObj['lastUpdated'] ??
          signedPreKeyObj['uploadedAt'],
    );

    return KeyBundle(
      userId: data['userId'] as String,
      deviceId: deviceId,
      identityKey: _decodeBase64(data['public_key'] as String),
      preKeyId: preKeyObj?['prekey_id'] as int?,
      preKey: preKeyObj != null && preKeyObj['prekey_data'] != null
          ? _decodeBase64(preKeyObj['prekey_data'] as String)
          : null,
      signedPreKeyId: signedPreKeyObj['signed_prekey_id'] as int,
      signedPreKey: _decodeBase64(
        signedPreKeyObj['signed_prekey_data'] as String,
      ),
      signedPreKeySignature: _decodeBase64(
        signedPreKeyObj['signed_prekey_signature'] as String,
      ),
      registrationId: registrationId,
      signedPreKeyCreatedAt: signedPreKeyCreatedAt,
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

  static Uint8List _decodeBase64(String base64String) {
    return base64Decode(base64String);
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  static String _encodeBase64(Uint8List bytes) {
    return base64Encode(bytes);
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
