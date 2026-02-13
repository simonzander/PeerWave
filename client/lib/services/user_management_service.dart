import 'package:dio/dio.dart';
import '../models/role.dart';
import '../screens/admin/user_management_screen.dart';
import 'api_service.dart';

class UserManagementService {
  UserManagementService() {
    ApiService.instance.init();
  }

  /// Get all users
  Future<List<UserInfo>> getUsers() async {
    try {
      final response = await ApiService.instance.get('/api/users');

      if (response.statusCode == 200) {
        final data = response.data;
        final users = (data['users'] as List)
            .map((user) => UserInfo.fromJson(user))
            .toList();
        return users;
      } else {
        throw Exception('Failed to fetch users: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching users: $e');
    }
  }

  /// Get all server roles
  Future<List<Role>> getServerRoles() async {
    try {
      final response = await ApiService.instance.get('/api/roles?scope=server');

      if (response.statusCode == 200) {
        final data = response.data;
        final roles = (data['roles'] as List)
            .map((role) => Role.fromJson(role))
            .toList();
        return roles;
      } else {
        throw Exception('Failed to fetch server roles: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching server roles: $e');
    }
  }

  /// Get roles for a specific user
  Future<List<Role>> getUserRoles(String userId) async {
    try {
      final response = await ApiService.instance.get(
        '/api/users/$userId/roles',
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final roles = (data['serverRoles'] as List)
            .map((role) => Role.fromJson(role))
            .toList();
        return roles;
      } else {
        throw Exception('Failed to fetch user roles: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error fetching user roles: $e');
    }
  }

  /// Assign a server role to a user
  Future<void> assignServerRole(String userId, String roleId) async {
    try {
      final response = await ApiService.instance.post(
        '/api/users/$userId/roles',
        data: {'roleId': roleId},
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to assign role: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error assigning role: $e');
    }
  }

  /// Remove a server role from a user
  Future<void> removeServerRole(String userId, String roleId) async {
    try {
      final response = await ApiService.instance.delete(
        '/api/users/$userId/roles/$roleId',
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to remove role: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error removing role: $e');
    }
  }

  /// Deactivate a user
  Future<void> deactivateUser(String userId) async {
    try {
      final response = await ApiService.instance.patch(
        '/api/users/$userId/deactivate',
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to deactivate user: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error deactivating user: $e');
    }
  }

  /// Activate a user
  Future<void> activateUser(String userId) async {
    try {
      final response = await ApiService.instance.patch(
        '/api/users/$userId/activate',
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to activate user: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error activating user: $e');
    }
  }

  /// Delete a user
  Future<void> deleteUser(String userId) async {
    try {
      final response = await ApiService.instance.delete('/api/users/$userId');

      if (response.statusCode != 200) {
        throw Exception('Failed to delete user: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error deleting user: $e');
    }
  }
}
