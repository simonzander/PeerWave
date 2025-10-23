import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/role.dart';
import '../../providers/role_provider.dart';

class RoleManagementScreen extends StatefulWidget {
  const RoleManagementScreen({Key? key}) : super(key: key);

  @override
  State<RoleManagementScreen> createState() => _RoleManagementScreenState();
}

class _RoleManagementScreenState extends State<RoleManagementScreen> {
  RoleScope _selectedScope = RoleScope.server;
  List<Role> _roles = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadRoles();
  }

  Future<void> _loadRoles() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final roleProvider = Provider.of<RoleProvider>(context, listen: false);
      final roles = await roleProvider.getRolesByScope(_selectedScope);
      setState(() {
        _roles = roles;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _showCreateRoleDialog() async {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final permissionsController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Role'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Role Name',
                  hintText: 'e.g., Custom Moderator',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Brief description of the role',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: permissionsController,
                decoration: const InputDecoration(
                  labelText: 'Permissions (comma-separated)',
                  hintText: 'e.g., user.manage, channel.create',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              Text(
                'Scope: ${_selectedScope.displayName}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true) {
      final name = nameController.text.trim();
      final description = descriptionController.text.trim();
      final permissionsText = permissionsController.text.trim();
      final permissions = permissionsText
          .split(',')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();

      if (name.isEmpty) {
        _showError('Role name is required');
        return;
      }

      if (permissions.isEmpty) {
        _showError('At least one permission is required');
        return;
      }

      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.createRole(
          name: name,
          description: description,
          scope: _selectedScope,
          permissions: permissions,
        );
        _showSuccess('Role created successfully');
        _loadRoles();
      } catch (e) {
        _showError(e.toString());
      }
    }
  }

  Future<void> _showEditRoleDialog(Role role) async {
    if (role.standard) {
      _showError('Cannot edit standard roles');
      return;
    }

    final nameController = TextEditingController(text: role.name);
    final descriptionController = TextEditingController(text: role.description ?? '');
    final permissionsController = TextEditingController(text: role.permissions.join(', '));

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Role'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Role Name',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: permissionsController,
                decoration: const InputDecoration(
                  labelText: 'Permissions (comma-separated)',
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );

    if (result == true) {
      final name = nameController.text.trim();
      final description = descriptionController.text.trim();
      final permissionsText = permissionsController.text.trim();
      final permissions = permissionsText
          .split(',')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();

      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.updateRole(
          roleId: role.uuid,
          name: name.isNotEmpty ? name : null,
          description: description.isNotEmpty ? description : null,
          permissions: permissions.isNotEmpty ? permissions : null,
        );
        _showSuccess('Role updated successfully');
        _loadRoles();
      } catch (e) {
        _showError(e.toString());
      }
    }
  }

  Future<void> _showDeleteRoleDialog(Role role) async {
    if (role.standard) {
      _showError('Cannot delete standard roles');
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Role'),
        content: Text('Are you sure you want to delete the role "${role.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.deleteRole(role.uuid);
        _showSuccess('Role deleted successfully');
        _loadRoles();
      } catch (e) {
        _showError(e.toString());
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Role Management'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<RoleScope>(
                    segments: const [
                      ButtonSegment(
                        value: RoleScope.server,
                        label: Text('Server'),
                      ),
                      ButtonSegment(
                        value: RoleScope.channelWebRtc,
                        label: Text('WebRTC'),
                      ),
                      ButtonSegment(
                        value: RoleScope.channelSignal,
                        label: Text('Signal'),
                      ),
                    ],
                    selected: {_selectedScope},
                    onSelectionChanged: (Set<RoleScope> newSelection) {
                      setState(() {
                        _selectedScope = newSelection.first;
                      });
                      _loadRoles();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                FloatingActionButton(
                  onPressed: _showCreateRoleDialog,
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          if (_isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _roles.length,
                itemBuilder: (context, index) {
                  final role = _roles[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: ListTile(
                      title: Text(
                        role.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: role.standard ? Colors.grey : null,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (role.description != null)
                            Text(role.description!),
                          const SizedBox(height: 4),
                          Text(
                            'Permissions: ${role.permissions.join(", ")}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                      trailing: role.standard
                          ? Chip(
                              label: const Text('Standard'),
                              backgroundColor: Colors.grey[300],
                            )
                          : PopupMenuButton(
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit),
                                      SizedBox(width: 8),
                                      Text('Edit'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete, color: Colors.red),
                                      SizedBox(width: 8),
                                      Text('Delete', style: TextStyle(color: Colors.red)),
                                    ],
                                  ),
                                ),
                              ],
                              onSelected: (value) {
                                if (value == 'edit') {
                                  _showEditRoleDialog(role);
                                } else if (value == 'delete') {
                                  _showDeleteRoleDialog(role);
                                }
                              },
                            ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
