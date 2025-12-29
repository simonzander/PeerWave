/// Model representing device and identity information
class DeviceInfo {
  final String userId;
  final String deviceId;
  final String clientId;
  final String identityKeyFingerprint;

  const DeviceInfo({
    required this.userId,
    required this.deviceId,
    required this.clientId,
    required this.identityKeyFingerprint,
  });

  DeviceInfo copyWith({
    String? userId,
    String? deviceId,
    String? clientId,
    String? identityKeyFingerprint,
  }) {
    return DeviceInfo(
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      clientId: clientId ?? this.clientId,
      identityKeyFingerprint:
          identityKeyFingerprint ?? this.identityKeyFingerprint,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'deviceId': deviceId,
      'clientId': clientId,
      'identityKeyFingerprint': identityKeyFingerprint,
    };
  }

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as String,
      clientId: json['clientId'] as String,
      identityKeyFingerprint: json['identityKeyFingerprint'] as String,
    );
  }

  static const empty = DeviceInfo(
    userId: 'N/A',
    deviceId: 'N/A',
    clientId: 'N/A',
    identityKeyFingerprint: 'N/A',
  );
}
