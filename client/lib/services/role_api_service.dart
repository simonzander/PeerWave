import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/role.dart';
import '../models/user_roles.dart';

/// Service for role-related API calls
class RoleApiService {
  final String baseUrl;
  final http.Client? client;

  RoleApiService({required this.baseUrl, this.client});

  http.Client get _client => client ?? http.Client();

  /// Gets the current user's roles (server and channel roles)
  Future<UserRoles> getUserRoles() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/user/roles'),
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      return UserRoles.fromJson(data);
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else {
      throw Exception('Failed to get user roles: ${response.body}');
    }
  }

  /// Gets all roles filtered by scope
  Future<List<Role>> getRolesByScope(RoleScope? scope) async {
    final uri = scope != null
        ? Uri.parse('$baseUrl/api/roles?scope=${scope.value}')
        : Uri.parse('$baseUrl/api/roles');

    final response = await _client.get(
      uri,
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final roles = data['roles'] as List<dynamic>;
      return roles.map((e) => Role.fromJson(e as Map<String, dynamic>)).toList();
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else {
      throw Exception('Failed to get roles: ${response.body}');
    }
  }

  /// Creates a new role (requires 'role.create' permission)
  Future<Role> createRole({
    required String name,
    required String description,
    required RoleScope scope,
    required List<String> permissions,
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/roles'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'name': name,
        'description': description,
        'scope': scope.value,
        'permissions': permissions,
      }),
    );

    if (response.statusCode == 201) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      return Role.fromJson(data['role'] as Map<String, dynamic>);
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else if (response.statusCode == 403) {
      throw Exception('Forbidden: You do not have permission to create roles');
    } else if (response.statusCode == 400) {
      final error = json.decode(response.body);
      throw Exception('Bad request: ${error['error']}');
    } else {
      throw Exception('Failed to create role: ${response.body}');
    }
  }

  /// Updates an existing role (requires 'role.edit' permission)
  Future<Role> updateRole({
    required String roleId,
    String? name,
    String? description,
    List<String>? permissions,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    if (permissions != null) body['permissions'] = permissions;

    final response = await _client.put(
      Uri.parse('$baseUrl/api/roles/$roleId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      return Role.fromJson(data['role'] as Map<String, dynamic>);
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else if (response.statusCode == 403) {
      throw Exception('Forbidden: Cannot edit standard roles or insufficient permissions');
    } else if (response.statusCode == 404) {
      throw Exception('Role not found');
    } else {
      throw Exception('Failed to update role: ${response.body}');
    }
  }

  /// Deletes a role (requires 'role.delete' permission)
  Future<void> deleteRole(String roleId) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/roles/$roleId'),
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      return;
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else if (response.statusCode == 403) {
      throw Exception('Forbidden: Cannot delete standard roles or insufficient permissions');
    } else if (response.statusCode == 404) {
      throw Exception('Role not found');
    } else {
      throw Exception('Failed to delete role: ${response.body}');
    }
  }

  /// Assigns a role to a user in a specific channel (requires 'role.assign' permission in that channel)
  Future<void> assignChannelRole({
    required String userId,
    required String channelId,
    required String roleId,
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/users/$userId/channels/$channelId/roles'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'roleId': roleId}),
    );

    if (response.statusCode == 200) {
      return;
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else if (response.statusCode == 403) {
      throw Exception('Forbidden: Insufficient permissions to assign roles in this channel');
    } else if (response.statusCode == 400) {
      final error = json.decode(response.body);
      throw Exception('Bad request: ${error['error']}');
    } else if (response.statusCode == 404) {
      throw Exception('User, channel, or role not found');
    } else {
      throw Exception('Failed to assign role: ${response.body}');
    }
  }

  /// Removes a role from a user in a specific channel
  Future<void> removeChannelRole({
    required String userId,
    required String channelId,
    required String roleId,
  }) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/users/$userId/channels/$channelId/roles/$roleId'),
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      return;
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else if (response.statusCode == 403) {
      throw Exception('Forbidden: Insufficient permissions to remove roles in this channel');
    } else if (response.statusCode == 404) {
      throw Exception('User, channel, or role not found');
    } else {
      throw Exception('Failed to remove role: ${response.body}');
    }
  }

  /// Gets all members of a channel with their roles (requires 'member.view' permission)
  Future<List<ChannelMember>> getChannelMembers(String channelId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/channels/$channelId/members'),
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final members = data['members'] as List<dynamic>;
      return members
          .map((e) => ChannelMember.fromJson(e as Map<String, dynamic>))
          .toList();
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else if (response.statusCode == 403) {
      throw Exception('Forbidden: You do not have permission to view members');
    } else if (response.statusCode == 404) {
      throw Exception('Channel not found');
    } else {
      throw Exception('Failed to get channel members: ${response.body}');
    }
  }

  /// Checks if the current user has a specific permission
  Future<bool> checkPermission({
    required String permission,
    String? channelId,
  }) async {
    final body = <String, dynamic>{'permission': permission};
    if (channelId != null) body['channelId'] = channelId;

    final response = await _client.post(
      Uri.parse('$baseUrl/api/user/check-permission'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['hasPermission'] as bool;
    } else if (response.statusCode == 401) {
      throw Exception('Unauthorized: Please log in');
    } else {
      throw Exception('Failed to check permission: ${response.body}');
    }
  }
}
