/// Model representing server configuration and connection status
class ServerConfig {
  final String serverUrl;
  final String socketUrl;
  final bool isConnected;
  final String connectionStatus;

  const ServerConfig({
    required this.serverUrl,
    required this.socketUrl,
    required this.isConnected,
    required this.connectionStatus,
  });

  ServerConfig copyWith({
    String? serverUrl,
    String? socketUrl,
    bool? isConnected,
    String? connectionStatus,
  }) {
    return ServerConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      socketUrl: socketUrl ?? this.socketUrl,
      isConnected: isConnected ?? this.isConnected,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverUrl': serverUrl,
      'socketUrl': socketUrl,
      'isConnected': isConnected,
      'connectionStatus': connectionStatus,
    };
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      serverUrl: json['serverUrl'] as String,
      socketUrl: json['socketUrl'] as String,
      isConnected: json['isConnected'] as bool,
      connectionStatus: json['connectionStatus'] as String,
    );
  }

  static const empty = ServerConfig(
    serverUrl: 'N/A',
    socketUrl: 'N/A',
    isConnected: false,
    connectionStatus: 'Unknown',
  );
}
