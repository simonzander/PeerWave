// Web stub for ServerConfigService
// Web version doesn't use multi-server configuration

class ServerConfig {
  final String id;
  final String serverUrl;
  final String serverHash;
  final String credentials;
  final String? iconPath;
  final DateTime lastActive;
  final DateTime createdAt;
  int unreadCount;
  String? displayName;

  ServerConfig({
    required this.id,
    required this.serverUrl,
    required this.serverHash,
    required this.credentials,
    this.iconPath,
    required this.lastActive,
    required this.createdAt,
    this.unreadCount = 0,
    this.displayName,
  });

  Map<String, dynamic> toJson() => {};
  factory ServerConfig.fromJson(Map<String, dynamic> json) => throw UnimplementedError();
  String getDisplayName() => serverUrl;
  String getShortName() => 'S';
  ServerConfig copyWith({
    String? iconPath,
    DateTime? lastActive,
    int? unreadCount,
    String? displayName,
  }) => this;
}

class ServerConfigService {
  static Future<void> init() async {}
  static String generateServerHash(String serverUrl) => '';
  static String generateServerId(String serverUrl) => '';
  static Future<ServerConfig> addServer({
    required String serverUrl,
    required String credentials,
    String? displayName,
    String? iconPath,
  }) async => throw UnimplementedError('Web does not support multi-server');
  static Future<bool> removeServer(String serverId) async => false;
  static List<ServerConfig> getAllServers() => [];
  static ServerConfig? getActiveServer() => null;
  static Future<void> setActiveServer(String serverId) async {}
  static ServerConfig? getServerById(String serverId) => null;
  static Future<void> updateServerIcon(String serverId, String iconPath) async {}
  static Future<void> updateUnreadCount(String serverId, int count) async {}
  static Future<void> incrementUnreadCount(String serverId, [int amount = 1]) async {}
  static Future<void> resetUnreadCount(String serverId) async {}
  static bool hasServers() => false;
  static ServerConfig? getLastActiveServer() => null;
  static Future<void> updateDisplayName(String serverId, String displayName) async {}
  static Future<void> clearAll() async {}
}
