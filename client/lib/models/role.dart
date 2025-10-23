/// Represents a role in the PeerWave system
class Role {
  final String uuid;
  final String name;
  final String? description;
  final RoleScope scope;
  final List<String> permissions;
  final bool standard;
  final DateTime createdAt;
  final DateTime updatedAt;

  Role({
    required this.uuid,
    required this.name,
    this.description,
    required this.scope,
    required this.permissions,
    required this.standard,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates a Role from JSON data
  factory Role.fromJson(Map<String, dynamic> json) {
    return Role(
      uuid: json['uuid'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      scope: RoleScopeExtension.fromString(json['scope'] as String),
      permissions: (json['permissions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      standard: json['standard'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  /// Converts this Role to JSON
  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'name': name,
      'description': description,
      'scope': scope.value,
      'permissions': permissions,
      'standard': standard,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Checks if this role has a specific permission
  bool hasPermission(String permission) {
    // Wildcard permission grants everything
    if (permissions.contains('*')) return true;
    
    // Check for exact permission match
    if (permissions.contains(permission)) return true;
    
    // Check for wildcard permission category (e.g., 'user.*' matches 'user.manage')
    final parts = permission.split('.');
    if (parts.length > 1) {
      final category = '${parts[0]}.*';
      if (permissions.contains(category)) return true;
    }
    
    return false;
  }

  /// Creates a copy of this role with updated fields
  Role copyWith({
    String? uuid,
    String? name,
    String? description,
    RoleScope? scope,
    List<String>? permissions,
    bool? standard,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Role(
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      description: description ?? this.description,
      scope: scope ?? this.scope,
      permissions: permissions ?? this.permissions,
      standard: standard ?? this.standard,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() {
    return 'Role(uuid: $uuid, name: $name, scope: ${scope.value}, permissions: $permissions, standard: $standard)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Role &&
        other.uuid == uuid &&
        other.name == name &&
        other.scope == scope;
  }

  @override
  int get hashCode => Object.hash(uuid, name, scope);
}

/// Enum representing the different role scopes
enum RoleScope {
  server,
  channelWebRtc,
  channelSignal,
}

/// Extension methods for RoleScope enum
extension RoleScopeExtension on RoleScope {
  /// Returns the string value of this scope
  String get value {
    switch (this) {
      case RoleScope.server:
        return 'server';
      case RoleScope.channelWebRtc:
        return 'channelWebRtc';
      case RoleScope.channelSignal:
        return 'channelSignal';
    }
  }

  /// Returns a display-friendly name for this scope
  String get displayName {
    switch (this) {
      case RoleScope.server:
        return 'Server';
      case RoleScope.channelWebRtc:
        return 'WebRTC Channel';
      case RoleScope.channelSignal:
        return 'Signal Channel';
    }
  }

  /// Creates a RoleScope from a string value
  static RoleScope fromString(String value) {
    switch (value) {
      case 'server':
        return RoleScope.server;
      case 'channelWebRtc':
        return RoleScope.channelWebRtc;
      case 'channelSignal':
        return RoleScope.channelSignal;
      default:
        throw ArgumentError('Invalid role scope: $value');
    }
  }

  /// Returns all available role scopes
  static List<RoleScope> get values => RoleScope.values;
}
