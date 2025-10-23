import 'role.dart';

/// Represents a user's roles in the system
class UserRoles {
  final List<Role> serverRoles;
  final Map<String, List<Role>> channelRoles; // channelId (UUID) -> roles

  UserRoles({
    required this.serverRoles,
    required this.channelRoles,
  });

  /// Creates a UserRoles from JSON data
  factory UserRoles.fromJson(Map<String, dynamic> json) {
    final serverRolesList = (json['serverRoles'] as List<dynamic>?)
            ?.map((e) => Role.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    final channelRolesMap = <String, List<Role>>{};
    final channelRolesJson = json['channelRoles'] as Map<String, dynamic>?;
    
    if (channelRolesJson != null) {
      channelRolesJson.forEach((key, value) {
        final channelId = key; // Already a String (UUID)
        final roles = (value as List<dynamic>)
            .map((e) => Role.fromJson(e as Map<String, dynamic>))
            .toList();
        channelRolesMap[channelId] = roles;
      });
    }

    return UserRoles(
      serverRoles: serverRolesList,
      channelRoles: channelRolesMap,
    );
  }

  /// Converts this UserRoles to JSON
  Map<String, dynamic> toJson() {
    final channelRolesJson = <String, dynamic>{};
    channelRoles.forEach((channelId, roles) {
      channelRolesJson[channelId] =
          roles.map((r) => r.toJson()).toList();
    });

    return {
      'serverRoles': serverRoles.map((r) => r.toJson()).toList(),
      'channelRoles': channelRolesJson,
    };
  }

  /// Checks if the user has a specific server permission
  bool hasServerPermission(String permission) {
    return serverRoles.any((role) => role.hasPermission(permission));
  }

  /// Checks if the user has a specific channel permission
  bool hasChannelPermission(String channelId, String permission) {
    final roles = channelRoles[channelId];
    if (roles == null) return false;
    return roles.any((role) => role.hasPermission(permission));
  }

  /// Checks if the user is an administrator
  bool get isAdmin {
    return serverRoles
        .any((role) => role.name == 'Administrator' && role.hasPermission('*'));
  }

  /// Checks if the user is a server moderator
  bool get isModerator {
    return serverRoles.any((role) =>
        role.name == 'Moderator' || role.hasPermission('user.manage'));
  }

  /// Checks if the user is an owner of a specific channel
  bool isChannelOwner(String channelId) {
    final roles = channelRoles[channelId];
    if (roles == null) return false;
    return roles.any((role) => role.name == 'Channel Owner' && role.hasPermission('*'));
  }

  /// Checks if the user is a moderator of a specific channel
  bool isChannelModerator(String channelId) {
    final roles = channelRoles[channelId];
    if (roles == null) return false;
    return roles.any((role) =>
        role.name == 'Channel Moderator' || 
        role.hasPermission('user.kick') || 
        role.hasPermission('user.mute'));
  }

  /// Gets all roles for a specific channel
  List<Role> getRolesForChannel(String channelId) {
    return channelRoles[channelId] ?? [];
  }

  /// Gets all channel IDs where the user has roles
  List<String> get channelIds => channelRoles.keys.toList();

  /// Checks if the user has any server roles
  bool get hasServerRoles => serverRoles.isNotEmpty;

  /// Checks if the user has any channel roles
  bool get hasChannelRoles => channelRoles.isNotEmpty;

  /// Gets all unique permissions across all server roles
  Set<String> get allServerPermissions {
    final permissions = <String>{};
    for (final role in serverRoles) {
      permissions.addAll(role.permissions);
    }
    return permissions;
  }

  /// Gets all unique permissions for a specific channel
  Set<String> getChannelPermissions(String channelId) {
    final permissions = <String>{};
    final roles = channelRoles[channelId];
    if (roles != null) {
      for (final role in roles) {
        permissions.addAll(role.permissions);
      }
    }
    return permissions;
  }

  /// Creates a copy of this UserRoles with updated fields
  UserRoles copyWith({
    List<Role>? serverRoles,
    Map<String, List<Role>>? channelRoles,
  }) {
    return UserRoles(
      serverRoles: serverRoles ?? this.serverRoles,
      channelRoles: channelRoles ?? this.channelRoles,
    );
  }

  @override
  String toString() {
    return 'UserRoles(serverRoles: ${serverRoles.length}, channels: ${channelRoles.length})';
  }
}

/// Represents a channel member with their roles
class ChannelMember {
  final String userId;
  final String username;
  final String? displayName;
  final List<Role> roles;

  ChannelMember({
    required this.userId,
    required this.username,
    this.displayName,
    required this.roles,
  });

  /// Creates a ChannelMember from JSON data
  factory ChannelMember.fromJson(Map<String, dynamic> json) {
    return ChannelMember(
      userId: json['userId'] as String,
      username: json['username'] as String,
      displayName: json['displayName'] as String?,
      roles: (json['roles'] as List<dynamic>?)
              ?.map((e) => Role.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// Converts this ChannelMember to JSON
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'username': username,
      'displayName': displayName,
      'roles': roles.map((r) => r.toJson()).toList(),
    };
  }

  /// Gets the display name or username
  String get name => displayName ?? username;

  /// Checks if the member has a specific permission
  bool hasPermission(String permission) {
    return roles.any((role) => role.hasPermission(permission));
  }

  /// Checks if the member is the channel owner
  bool get isOwner {
    return roles.any((role) => role.name == 'Channel Owner' && role.hasPermission('*'));
  }

  /// Checks if the member is a channel moderator
  bool get isModerator {
    return roles.any((role) => role.name == 'Channel Moderator');
  }

  @override
  String toString() {
    return 'ChannelMember(userId: $userId, username: $username, roles: ${roles.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChannelMember && other.userId == userId;
  }

  @override
  int get hashCode => userId.hashCode;
}
