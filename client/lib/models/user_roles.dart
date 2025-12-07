import 'dart:convert';
import 'dart:typed_data';
import 'role.dart';
import 'package:flutter/foundation.dart';

/// Represents a user's roles in the system
class UserRoles {
  final List<Role> serverRoles;
  final Map<String, List<Role>> channelRoles; // channelId (UUID) -> roles
  final Set<String> ownedChannelIds; // Set of channel IDs user owns

  UserRoles({
    required this.serverRoles,
    required this.channelRoles,
    Set<String>? ownedChannelIds,
  }) : ownedChannelIds = ownedChannelIds ?? {};

  /// Creates a UserRoles from JSON data
  factory UserRoles.fromJson(Map<String, dynamic> json) {
    final serverRolesList =
        (json['serverRoles'] as List<dynamic>?)
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

    // Parse owned channel IDs (new field from API)
    final ownedChannelIdsList =
        (json['ownedChannelIds'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toSet() ??
        {};

    return UserRoles(
      serverRoles: serverRolesList,
      channelRoles: channelRolesMap,
      ownedChannelIds: ownedChannelIdsList,
    );
  }

  /// Converts this UserRoles to JSON
  Map<String, dynamic> toJson() {
    final channelRolesJson = <String, dynamic>{};
    channelRoles.forEach((channelId, roles) {
      channelRolesJson[channelId] = roles.map((r) => r.toJson()).toList();
    });

    return {
      'serverRoles': serverRoles.map((r) => r.toJson()).toList(),
      'channelRoles': channelRolesJson,
      'ownedChannelIds': ownedChannelIds.toList(),
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
    return serverRoles.any(
      (role) => role.name == 'Administrator' && role.hasPermission('*'),
    );
  }

  /// Checks if the user is a server moderator
  bool get isModerator {
    return serverRoles.any(
      (role) => role.name == 'Moderator' || role.hasPermission('user.manage'),
    );
  }

  /// Checks if the user is an owner of a specific channel
  bool isChannelOwner(String channelId) {
    // First check if user owns the channel directly (from ownedChannelIds)
    if (ownedChannelIds.contains(channelId)) {
      return true;
    }

    // Fallback: Check if user has "Channel Owner" role with full permissions
    final roles = channelRoles[channelId];
    if (roles == null) return false;
    return roles.any(
      (role) => role.name == 'Channel Owner' && role.hasPermission('*'),
    );
  }

  /// Checks if the user is a moderator of a specific channel
  bool isChannelModerator(String channelId) {
    final roles = channelRoles[channelId];
    if (roles == null) return false;
    return roles.any(
      (role) =>
          role.name == 'Channel Moderator' ||
          role.hasPermission('user.kick') ||
          role.hasPermission('user.mute'),
    );
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
    Set<String>? ownedChannelIds,
  }) {
    return UserRoles(
      serverRoles: serverRoles ?? this.serverRoles,
      channelRoles: channelRoles ?? this.channelRoles,
      ownedChannelIds: ownedChannelIds ?? this.ownedChannelIds,
    );
  }

  @override
  String toString() {
    return 'UserRoles(serverRoles: ${serverRoles.length}, channels: ${channelRoles.length}, ownedChannels: ${ownedChannelIds.length})';
  }
}

/// Represents a channel member with their roles
class ChannelMember {
  final String userId;
  final String username;
  final String? displayName;
  final String? profilePicture;
  final List<Role> roles;
  final bool isOwner;

  ChannelMember({
    required this.userId,
    required this.username,
    this.displayName,
    this.profilePicture,
    required this.roles,
    this.isOwner = false,
  });

  /// Creates a ChannelMember from JSON data
  factory ChannelMember.fromJson(Map<String, dynamic> json) {
    try {
      // Debug: Print the raw JSON to see what we're receiving
      debugPrint('[ChannelMember.fromJson] Raw JSON: $json');

      // Handle profile picture which might be a String or a Map
      String? profilePictureData;
      final picture = json['profilePicture'];
      debugPrint(
        '[ChannelMember.fromJson] profilePicture type: ${picture.runtimeType}',
      );

      if (picture is String) {
        profilePictureData = picture;
      } else if (picture is Map && picture['data'] != null) {
        // Handle Buffer format from server {type: 'Buffer', data: [bytes]}
        final data = picture['data'];
        if (data is List) {
          // Convert byte array to base64 data URI
          final bytes = Uint8List.fromList(data.cast<int>());
          final base64String = base64Encode(bytes);
          // Assume JPEG format (most common), could be enhanced to detect type
          profilePictureData = 'data:image/jpeg;base64,$base64String';
        } else if (data is String) {
          profilePictureData = data;
        }
      }

      // Debug other fields
      debugPrint(
        '[ChannelMember.fromJson] userId type: ${json['userId'].runtimeType}',
      );
      debugPrint(
        '[ChannelMember.fromJson] username type: ${json['username']?.runtimeType}',
      );
      debugPrint(
        '[ChannelMember.fromJson] email type: ${json['email']?.runtimeType}',
      );
      debugPrint(
        '[ChannelMember.fromJson] displayName type: ${json['displayName']?.runtimeType}',
      );
      debugPrint(
        '[ChannelMember.fromJson] roles type: ${json['roles']?.runtimeType}',
      );
      debugPrint(
        '[ChannelMember.fromJson] isOwner type: ${json['isOwner']?.runtimeType}',
      );

      // Helper function to safely extract String from various types
      String? extractString(dynamic value) {
        if (value == null) return null;
        if (value is String) return value;
        if (value is List && value.isNotEmpty) {
          return value.first?.toString();
        }
        return value.toString();
      }

      final userId = extractString(json['userId']) ?? 'unknown';
      final username = extractString(json['username']);
      final email = extractString(json['email']);
      final displayName = extractString(json['displayName']);

      return ChannelMember(
        userId: userId,
        username: username ?? email ?? displayName ?? 'Unknown',
        displayName: displayName,
        profilePicture: profilePictureData,
        isOwner: json['isOwner'] as bool? ?? false,
        roles:
            (json['roles'] as List<dynamic>?)
                ?.map((e) => Role.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
    } catch (e, stackTrace) {
      debugPrint('[ChannelMember.fromJson] ERROR: $e');
      debugPrint('[ChannelMember.fromJson] StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Converts this ChannelMember to JSON
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'username': username,
      'displayName': displayName,
      'profilePicture': profilePicture,
      'isOwner': isOwner,
      'roles': roles.map((r) => r.toJson()).toList(),
    };
  }

  /// Gets the display name or username
  String get name => displayName ?? username;

  /// Checks if the member has a specific permission
  bool hasPermission(String permission) {
    return roles.any((role) => role.hasPermission(permission));
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
