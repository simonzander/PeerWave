import 'package:flutter/foundation.dart';
import '../models/user_roles.dart';
import '../models/role.dart';
import '../services/role_api_service.dart';

/// Provider for managing user roles and permissions
class RoleProvider with ChangeNotifier {
  final RoleApiService _apiService;
  
  UserRoles? _userRoles;
  bool _isLoading = false;
  String? _errorMessage;

  RoleProvider({required RoleApiService apiService})
      : _apiService = apiService;

  /// Gets the current user's roles
  UserRoles? get userRoles => _userRoles;

  /// Checks if roles are currently being loaded
  bool get isLoading => _isLoading;

  /// Gets the current error message, if any
  String? get errorMessage => _errorMessage;

  /// Checks if user roles have been loaded
  bool get isLoaded => _userRoles != null;

  /// Checks if the current user is an administrator
  bool get isAdmin => _userRoles?.isAdmin ?? false;

  /// Checks if the current user is a moderator
  bool get isModerator => _userRoles?.isModerator ?? false;

  /// Checks if the user has a specific server permission
  bool hasServerPermission(String permission) {
    return _userRoles?.hasServerPermission(permission) ?? false;
  }

  /// Checks if the user has a specific channel permission
  bool hasChannelPermission(String channelId, String permission) {
    return _userRoles?.hasChannelPermission(channelId, permission) ?? false;
  }

  /// Checks if the user is an owner of a specific channel
  bool isChannelOwner(String channelId) {
    return _userRoles?.isChannelOwner(channelId) ?? false;
  }

  /// Checks if the user is a moderator of a specific channel
  bool isChannelModerator(String channelId) {
    return _userRoles?.isChannelModerator(channelId) ?? false;
  }

  /// Gets all roles for a specific channel
  List<Role> getRolesForChannel(String channelId) {
    return _userRoles?.getRolesForChannel(channelId) ?? [];
  }

  /// Loads the current user's roles from the API
  Future<void> loadUserRoles() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _userRoles = await _apiService.getUserRoles();
      _errorMessage = null;
    } catch (e) {
      _errorMessage = e.toString();
      debugPrint('Error loading user roles: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refreshes the user's roles from the API
  Future<void> refreshRoles() async {
    return loadUserRoles();
  }

  /// Clears the current user's roles (e.g., on logout)
  void clearRoles() {
    _userRoles = null;
    _errorMessage = null;
    notifyListeners();
  }

  /// Gets all roles filtered by scope
  Future<List<Role>> getRolesByScope(RoleScope? scope) async {
    try {
      return await _apiService.getRolesByScope(scope);
    } catch (e) {
      debugPrint('Error getting roles by scope: $e');
      rethrow;
    }
  }

  /// Creates a new role
  Future<Role> createRole({
    required String name,
    required String description,
    required RoleScope scope,
    required List<String> permissions,
  }) async {
    try {
      final role = await _apiService.createRole(
        name: name,
        description: description,
        scope: scope,
        permissions: permissions,
      );
      return role;
    } catch (e) {
      debugPrint('Error creating role: $e');
      rethrow;
    }
  }

  /// Updates an existing role
  Future<Role> updateRole({
    required String roleId,
    String? name,
    String? description,
    List<String>? permissions,
  }) async {
    try {
      final role = await _apiService.updateRole(
        roleId: roleId,
        name: name,
        description: description,
        permissions: permissions,
      );
      return role;
    } catch (e) {
      debugPrint('Error updating role: $e');
      rethrow;
    }
  }

  /// Deletes a role
  Future<void> deleteRole(String roleId) async {
    try {
      await _apiService.deleteRole(roleId);
    } catch (e) {
      debugPrint('Error deleting role: $e');
      rethrow;
    }
  }

  /// Gets users available to add to a channel
  Future<List<Map<String, String>>> getAvailableUsersForChannel(
    String channelId, {
    String? search,
  }) async {
    try {
      return await _apiService.getAvailableUsersForChannel(
        channelId,
        search: search,
      );
    } catch (e) {
      debugPrint('Error fetching available users: $e');
      rethrow;
    }
  }

  /// Adds a user to a channel with optional role
  Future<void> addUserToChannel({
    required String channelId,
    required String userId,
    String? roleId,
  }) async {
    try {
      await _apiService.addUserToChannel(
        channelId: channelId,
        userId: userId,
        roleId: roleId,
      );
    } catch (e) {
      debugPrint('Error adding user to channel: $e');
      rethrow;
    }
  }

  /// Assigns a role to a user in a specific channel
  Future<void> assignChannelRole({
    required String userId,
    required String channelId,
    required String roleId,
  }) async {
    try {
      await _apiService.assignChannelRole(
        userId: userId,
        channelId: channelId,
        roleId: roleId,
      );
    } catch (e) {
      debugPrint('Error assigning channel role: $e');
      rethrow;
    }
  }

  /// Removes a role from a user in a specific channel
  Future<void> removeChannelRole({
    required String userId,
    required String channelId,
    required String roleId,
  }) async {
    try {
      await _apiService.removeChannelRole(
        userId: userId,
        channelId: channelId,
        roleId: roleId,
      );
    } catch (e) {
      debugPrint('Error removing channel role: $e');
      rethrow;
    }
  }

  /// Gets all members of a channel with their roles
  Future<List<ChannelMember>> getChannelMembers(String channelId) async {
    try {
      return await _apiService.getChannelMembers(channelId);
    } catch (e) {
      debugPrint('Error getting channel members: $e');
      rethrow;
    }
  }

  /// Checks if the current user has a specific permission
  Future<bool> checkPermission({
    required String permission,
    String? channelId,
  }) async {
    try {
      return await _apiService.checkPermission(
        permission: permission,
        channelId: channelId,
      );
    } catch (e) {
      debugPrint('Error checking permission: $e');
      return false;
    }
  }
}
