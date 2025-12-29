/// ICE Server Configuration Models
///
/// Models for STUN/TURN server configuration received from server
library;

/// Single ICE Server (STUN or TURN)
class IceServer {
  final List<String> urls;
  final String? username;
  final String? credential;

  IceServer({required this.urls, this.username, this.credential});

  factory IceServer.fromJson(Map<String, dynamic> json) {
    return IceServer(
      urls: (json['urls'] is List)
          ? List<String>.from(json['urls'])
          : [json['urls'] as String],
      username: json['username'] as String?,
      credential: json['credential'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'urls': urls};
    if (username != null) map['username'] = username;
    if (credential != null) map['credential'] = credential;
    return map;
  }

  /// Convert to WebRTC-compatible format
  Map<String, dynamic> toWebRtcFormat() {
    final map = <String, dynamic>{'urls': urls};
    if (username != null) map['username'] = username;
    if (credential != null) map['credential'] = credential;
    return map;
  }

  @override
  String toString() {
    return 'IceServer(urls: $urls, username: $username, hasCredential: ${credential != null})';
  }
}

/// Client Meta Response from /client/meta endpoint
class ClientMetaResponse {
  final String name;
  final String version;
  final List<IceServer> iceServers;

  ClientMetaResponse({
    required this.name,
    required this.version,
    required this.iceServers,
  });

  factory ClientMetaResponse.fromJson(Map<String, dynamic> json) {
    return ClientMetaResponse(
      name: json['name'] as String,
      version: json['version'] as String,
      iceServers:
          (json['iceServers'] as List<dynamic>?)
              ?.map((e) => IceServer.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'version': version,
      'iceServers': iceServers.map((e) => e.toJson()).toList(),
    };
  }

  /// Get ICE servers in WebRTC-compatible format
  Map<String, dynamic> toWebRtcConfig() {
    return {'iceServers': iceServers.map((e) => e.toWebRtcFormat()).toList()};
  }

  @override
  String toString() {
    return 'ClientMetaResponse(name: $name, version: $version, iceServers: ${iceServers.length})';
  }
}
