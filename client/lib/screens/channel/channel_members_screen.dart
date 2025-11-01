import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/role.dart';
import '../../models/user_roles.dart';
import '../../providers/role_provider.dart';

class ChannelMembersScreen extends StatefulWidget {
  final String channelId;
  final String channelName;
  final RoleScope channelScope;

  const ChannelMembersScreen({
    Key? key,
    required this.channelId,
    required this.channelName,
    required this.channelScope,
  }) : super(key: key);

  @override
  State<ChannelMembersScreen> createState() => _ChannelMembersScreenState();
}

class _ChannelMembersScreenState extends State<ChannelMembersScreen> {
  List<ChannelMember> _members = [];
  List<Role> _availableRoles = [];
  bool _isLoading = false;
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
      final roleProvider = Provider.of<RoleProvider>(context, listen: false);
      
      // Load members and available roles in parallel
      final results = await Future.wait([
        roleProvider.getChannelMembers(widget.channelId),
        roleProvider.getRolesByScope(widget.channelScope),
      ]);

      setState(() {
        _members = results[0] as List<ChannelMember>;
        _availableRoles = results[1] as List<Role>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _showAssignRoleDialog(ChannelMember member) async {
    Role? selectedRole;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Assign Role to ${member.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select a role to assign:'),
              const SizedBox(height: 16),
              DropdownButtonFormField<Role>(
                value: selectedRole,
                hint: const Text('Select Role'),
                items: _availableRoles.map((role) {
                  return DropdownMenuItem(
                    value: role,
                    child: Text(role.name),
                  );
                }).toList(),
                onChanged: (role) {
                  setState(() {
                    selectedRole = role;
                  });
                },
              ),
              if (selectedRole != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Permissions: ${selectedRole!.permissions.join(", ")}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedRole == null
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Assign'),
            ),
          ],
        ),
      ),
    );

    if (result == true && selectedRole != null) {
      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.assignChannelRole(
          userId: member.userId,
          channelId: widget.channelId,
          roleId: selectedRole!.uuid,
        );
        _showSuccess('Role assigned successfully');
        _loadData();
      } catch (e) {
        _showError(e.toString());
      }
    }
  }

  Future<void> _showRemoveRoleDialog(ChannelMember member, Role role) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Role'),
        content: Text(
          'Remove the role "${role.name}" from ${member.name}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.removeChannelRole(
          userId: member.userId,
          channelId: widget.channelId,
          roleId: role.uuid,
        );
        _showSuccess('Role removed successfully');
        _loadData();
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

  Future<void> _showAddUserDialog() async {
    String searchQuery = '';
    List<Map<String, String>> availableUsers = [];
    bool isLoading = false;
    Map<String, String>? selectedUser;
    Role? selectedRole;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add User to Channel'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search Users',
                    hintText: 'Enter name or email',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) async {
                    searchQuery = value;
                    if (value.length >= 2) {
                      setState(() => isLoading = true);
                      try {
                        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
                        final users = await roleProvider.getAvailableUsersForChannel(
                          widget.channelId,
                          search: value,
                        );
                        setState(() {
                          availableUsers = users;
                          isLoading = false;
                        });
                      } catch (e) {
                        setState(() => isLoading = false);
                        if (context.mounted) {
                          _showError(e.toString());
                        }
                      }
                    } else {
                      setState(() => availableUsers = []);
                    }
                  },
                ),
                const SizedBox(height: 16),
                if (isLoading)
                  const Center(child: CircularProgressIndicator())
                else if (availableUsers.isNotEmpty)
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: availableUsers.length,
                      itemBuilder: (context, index) {
                        final user = availableUsers[index];
                        final isSelected = selectedUser?['uuid'] == user['uuid'];
                        return ListTile(
                          selected: isSelected,
                          leading: CircleAvatar(
                            child: Text(
                              user['displayName']!.isNotEmpty
                                  ? user['displayName']![0].toUpperCase()
                                  : '?',
                            ),
                          ),
                          title: Text(user['displayName']!),
                          subtitle: Text(user['email']!),
                          onTap: () {
                            setState(() => selectedUser = user);
                          },
                        );
                      },
                    ),
                  )
                else if (searchQuery.length >= 2)
                  const Center(child: Text('No users found')),
                if (selectedUser != null) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text('Assign Role (optional):'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<Role>(
                    value: selectedRole,
                    hint: const Text('Select Role'),
                    items: _availableRoles.map((role) {
                      return DropdownMenuItem(
                        value: role,
                        child: Text(role.name),
                      );
                    }).toList(),
                    onChanged: (role) {
                      setState(() => selectedRole = role);
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedUser == null
                  ? null
                  : () async {
                      try {
                        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
                        await roleProvider.addUserToChannel(
                          channelId: widget.channelId,
                          userId: selectedUser!['uuid']!,
                          roleId: selectedRole?.uuid,
                        );
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          _showSuccess('User added to channel successfully');
                          _loadData();
                        }
                      } catch (e) {
                        if (context.mounted) {
                          Navigator.of(context).pop();
                          _showError(e.toString());
                        }
                      }
                    },
              child: const Text('Add User'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);
    
    // Debug logging
    debugPrint('[ChannelMembers] Channel ID: ${widget.channelId}');
    debugPrint('[ChannelMembers] isAdmin: ${roleProvider.isAdmin}');
    debugPrint('[ChannelMembers] isChannelOwner: ${roleProvider.isChannelOwner(widget.channelId)}');
    debugPrint('[ChannelMembers] has role.assign: ${roleProvider.hasChannelPermission(widget.channelId, 'role.assign')}');
    debugPrint('[ChannelMembers] has user.add: ${roleProvider.hasChannelPermission(widget.channelId, 'user.add')}');
    
    final canManageRoles = roleProvider.isAdmin ||
        roleProvider.isChannelOwner(widget.channelId) ||
        roleProvider.hasChannelPermission(widget.channelId, 'role.assign');
    
    final canAddUsers = roleProvider.isAdmin ||
        roleProvider.isChannelOwner(widget.channelId) ||
        roleProvider.hasChannelPermission(widget.channelId, 'user.add');
    
    debugPrint('[ChannelMembers] canManageRoles: $canManageRoles');
    debugPrint('[ChannelMembers] canAddUsers: $canAddUsers');

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.channelName} - Members'),
        actions: [
          if (canAddUsers)
            IconButton(
              icon: const Icon(Icons.person_add),
              onPressed: _showAddUserDialog,
              tooltip: 'Add User',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: Column(
        children: [
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
                itemCount: _members.length,
                itemBuilder: (context, index) {
                  final member = _members[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: ExpansionTile(
                      leading: CircleAvatar(
                        child: Text(
                          member.name.isNotEmpty
                              ? member.name[0].toUpperCase()
                              : '?',
                        ),
                      ),
                      title: Text(
                        member.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        member.isOwner
                            ? 'Owner'
                            : member.isModerator
                                ? 'Moderator'
                                : 'Member',
                        style: TextStyle(
                          color: member.isOwner
                              ? Colors.purple
                              : member.isModerator
                                  ? Colors.blue
                                  : Colors.grey,
                        ),
                      ),
                      trailing: canManageRoles
                          ? IconButton(
                              icon: const Icon(Icons.add_circle),
                              onPressed: () => _showAssignRoleDialog(member),
                              tooltip: 'Assign Role',
                            )
                          : null,
                      children: [
                        if (member.roles.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16.0),
                            child: Text('No roles assigned'),
                          )
                        else
                          ...member.roles.map((role) {
                            return ListTile(
                              leading: const Icon(Icons.badge),
                              title: Text(role.name),
                              subtitle: Text(
                                role.permissions.join(', '),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              trailing: canManageRoles && !role.standard
                                  ? IconButton(
                                      icon: const Icon(
                                        Icons.remove_circle,
                                        color: Colors.red,
                                      ),
                                      onPressed: () =>
                                          _showRemoveRoleDialog(member, role),
                                      tooltip: 'Remove Role',
                                    )
                                  : role.standard
                                      ? Chip(
                                          label: const Text('Standard'),
                                          backgroundColor: Colors.grey[300],
                                        )
                                      : null,
                            );
                          }).toList(),
                      ],
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
