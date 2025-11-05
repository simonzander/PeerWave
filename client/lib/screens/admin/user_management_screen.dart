import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/role.dart';
import '../../providers/role_provider.dart';
import '../../services/user_management_service.dart';
import '../../extensions/snackbar_extensions.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({Key? key}) : super(key: key);

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final UserManagementService _userService = UserManagementService();
  List<UserInfo> _users = [];
  List<Role> _serverRoles = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final users = await _userService.getUsers();
      final roles = await _userService.getServerRoles();

      setState(() {
        _users = users;
        _serverRoles = roles;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadUserRoles(String userId) async {
    try {
      final roles = await _userService.getUserRoles(userId);
      setState(() {
        final userIndex = _users.indexWhere((u) => u.uuid == userId);
        if (userIndex != -1) {
          _users[userIndex] = _users[userIndex].copyWith(roles: roles);
        }
      });
    } catch (e) {
      _showError('Failed to load user roles: $e');
    }
  }

  Future<void> _assignRole(UserInfo user, Role role) async {
    try {
      await _userService.assignServerRole(user.uuid, role.uuid);
      _showSuccess('Role "${role.name}" assigned to ${user.displayName ?? user.email}');
      await _loadUserRoles(user.uuid);
    } catch (e) {
      _showError('Failed to assign role: $e');
    }
  }

  Future<void> _removeRole(UserInfo user, Role role) async {
    try {
      await _userService.removeServerRole(user.uuid, role.uuid);
      _showSuccess('Role "${role.name}" removed from ${user.displayName ?? user.email}');
      await _loadUserRoles(user.uuid);
    } catch (e) {
      _showError('Failed to remove role: $e');
    }
  }

  void _showManageRolesDialog(UserInfo user) async {
    // Load user roles if not already loaded
    if (user.roles == null) {
      await _loadUserRoles(user.uuid);
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => _ManageUserRolesDialog(
        user: _users.firstWhere((u) => u.uuid == user.uuid),
        availableRoles: _serverRoles,
        onAssignRole: (role) => _assignRole(user, role),
        onRemoveRole: (role) => _removeRole(user, role),
      ),
    );
  }

  void _showActivateDeactivateDialog(UserInfo user) {
    final isActive = user.active;
    final action = isActive ? 'deactivate' : 'activate';
    final actionTitle = isActive ? 'Deactivate' : 'Activate';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$actionTitle User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to $action this user?'),
            const SizedBox(height: 16),
            Text(
              'User: ${user.displayName ?? user.email}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (isActive) ...[
              const Text('When deactivated, this user will:'),
              const Text('• Not be able to log in'),
              const Text('• Lose access to all channels'),
              const Text('• Not receive notifications'),
            ] else ...[
              const Text('When activated, this user will:'),
              const Text('• Be able to log in again'),
              const Text('• Regain access to their channels'),
              const Text('• Receive notifications'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: isActive ? Theme.of(context).colorScheme.tertiary : Theme.of(context).colorScheme.primary,
            ),
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                if (isActive) {
                  await _userService.deactivateUser(user.uuid);
                } else {
                  await _userService.activateUser(user.uuid);
                }
                _showSuccess('User ${action}d successfully');
                _loadData();
              } catch (e) {
                _showError('Failed to $action user: $e');
              }
            },
            child: Text(actionTitle),
          ),
        ],
      ),
    );
  }

  void _showDeleteUserDialog(UserInfo user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '⚠️ WARNING: This action cannot be undone!',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'User: ${user.displayName ?? user.email}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text('Deleting this user will:'),
            const Text('• Permanently remove the account'),
            const Text('• Remove from all channels'),
            const Text('• Delete all user data'),
            const Text('• Remove all role assignments'),
            const SizedBox(height: 16),
            const Text(
              'Are you absolutely sure you want to delete this user?',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await _userService.deleteUser(user.uuid);
                _showSuccess('User deleted successfully');
                _loadData();
              } catch (e) {
                _showError('Failed to delete user: $e');
              }
            },
            child: const Text('Delete User'),
          ),
        ],
      ),
    );
  }

  void _showSuccess(String message) {
    context.showSuccessSnackBar(message);
  }

  void _showError(String message) {
    context.showErrorSnackBar(message);
  }

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    // Check if user has permission to manage users
    if (!roleProvider.hasServerPermission('user.manage')) {
      return Scaffold(
        appBar: AppBar(title: const Text('User Management')),
        body: const Center(
          child: Text('You do not have permission to manage users'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Error: $_errorMessage'),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadData,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _users.isEmpty
                  ? const Center(child: Text('No users found'))
                  : ListView.builder(
                      itemCount: _users.length,
                      itemBuilder: (context, index) {
                        final user = _users[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: user.active ? null : Theme.of(context).colorScheme.surfaceVariant,
                              child: Text(
                                (user.displayName ?? user.email)
                                    .substring(0, 1)
                                    .toUpperCase(),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    user.displayName ?? user.email,
                                    style: TextStyle(
                                      color: user.active ? null : Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                if (!user.active)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      'INACTIVE',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.email,
                                  style: TextStyle(
                                    color: user.active ? null : Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (user.roles != null && user.roles!.isNotEmpty)
                                  Wrap(
                                    spacing: 4,
                                    children: user.roles!
                                        .map((role) => Chip(
                                              label: Text(
                                                role.name,
                                                style: const TextStyle(fontSize: 12),
                                              ),
                                              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                            ))
                                        .toList(),
                                  ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (roleProvider.hasServerPermission('role.assign'))
                                  IconButton(
                                    icon: const Icon(Icons.admin_panel_settings),
                                    onPressed: () => _showManageRolesDialog(user),
                                    tooltip: 'Manage Roles',
                                  ),
                                if (roleProvider.hasServerPermission('user.manage'))
                                  IconButton(
                                    icon: Icon(
                                      user.active ? Icons.person_off : Icons.person_add,
                                      color: user.active ? Theme.of(context).colorScheme.tertiary : Theme.of(context).colorScheme.primary,
                                    ),
                                    onPressed: () => _showActivateDeactivateDialog(user),
                                    tooltip: user.active ? 'Deactivate User' : 'Activate User',
                                  ),
                                if (roleProvider.hasServerPermission('user.manage'))
                                  IconButton(
                                    icon: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                                    onPressed: () => _showDeleteUserDialog(user),
                                    tooltip: 'Delete User',
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class _ManageUserRolesDialog extends StatelessWidget {
  final UserInfo user;
  final List<Role> availableRoles;
  final Function(Role) onAssignRole;
  final Function(Role) onRemoveRole;

  const _ManageUserRolesDialog({
    Key? key,
    required this.user,
    required this.availableRoles,
    required this.onAssignRole,
    required this.onRemoveRole,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final userRoleIds = user.roles?.map((r) => r.uuid).toSet() ?? {};

    return AlertDialog(
      title: Text('Manage Roles: ${user.displayName ?? user.email}'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: availableRoles.length,
          itemBuilder: (context, index) {
            final role = availableRoles[index];
            final hasRole = userRoleIds.contains(role.uuid);

            return CheckboxListTile(
              title: Text(role.name),
              subtitle: role.description != null && role.description!.isNotEmpty
                  ? Text(role.description!)
                  : null,
              value: hasRole,
              onChanged: (value) {
                if (value == true) {
                  onAssignRole(role);
                } else {
                  onRemoveRole(role);
                }
                Navigator.of(context).pop();
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class UserInfo {
  final String uuid;
  final String email;
  final String? displayName;
  final bool verified;
  final bool active;
  final DateTime createdAt;
  final List<Role>? roles;

  UserInfo({
    required this.uuid,
    required this.email,
    this.displayName,
    required this.verified,
    required this.active,
    required this.createdAt,
    this.roles,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      uuid: json['uuid'],
      email: json['email'],
      displayName: json['displayName'],
      verified: json['verified'] ?? false,
      active: json['active'] ?? true,
      createdAt: DateTime.parse(json['createdAt']),
      roles: json['roles'] != null
          ? (json['roles'] as List).map((r) => Role.fromJson(r)).toList()
          : null,
    );
  }

  UserInfo copyWith({
    String? uuid,
    String? email,
    String? displayName,
    bool? verified,
    bool? active,
    DateTime? createdAt,
    List<Role>? roles,
  }) {
    return UserInfo(
      uuid: uuid ?? this.uuid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      verified: verified ?? this.verified,
      active: active ?? this.active,
      createdAt: createdAt ?? this.createdAt,
      roles: roles ?? this.roles,
    );
  }
}

