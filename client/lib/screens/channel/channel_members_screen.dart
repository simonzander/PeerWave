import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/role.dart';
import '../../models/user_roles.dart';
import '../../providers/role_provider.dart';
import '../../services/user_profile_service.dart';
import 'dart:convert';

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

  // Track loaded profiles from UserProfileService for reactive updates
  final Map<String, Map<String, dynamic>?> _loadedProfiles = {};

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

      final members = results[0] as List<ChannelMember>;
      debugPrint('[MEMBERS_SCREEN] Loaded ${members.length} members:');
      members.forEach(
        (m) => debugPrint('[MEMBERS_SCREEN] - ${m.name} (${m.userId})'),
      );

      setState(() {
        _members = members;
        _availableRoles = results[1] as List<Role>;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[MEMBERS_SCREEN] Error loading data: $e');
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
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: const OutlineInputBorder(),
                ),
                items: _availableRoles.map((role) {
                  return DropdownMenuItem(value: role, child: Text(role.name));
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
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
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
        content: Text('Remove the role "${role.name}" from ${member.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.tertiary,
              foregroundColor: Theme.of(context).colorScheme.onTertiary,
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
      SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
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
                  decoration: InputDecoration(
                    labelText: 'Search Users',
                    hintText: 'Enter name or email',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onChanged: (value) async {
                    searchQuery = value;
                    if (value.length >= 2) {
                      setState(() => isLoading = true);
                      try {
                        debugPrint('[ADD_USER_DIALOG] Searching for: $value');
                        final roleProvider = Provider.of<RoleProvider>(
                          context,
                          listen: false,
                        );
                        final users = await roleProvider
                            .getAvailableUsersForChannel(
                              widget.channelId,
                              search: value,
                            );
                        debugPrint(
                          '[ADD_USER_DIALOG] Found ${users.length} users',
                        );
                        users.forEach(
                          (u) => debugPrint(
                            '[ADD_USER_DIALOG] - ${u['displayName']} (${u['email']})',
                          ),
                        );
                        setState(() {
                          availableUsers = users;
                          isLoading = false;
                        });
                      } catch (e) {
                        debugPrint('[ADD_USER_DIALOG] Error: $e');
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
                        final isSelected =
                            selectedUser?['uuid'] == user['uuid'];
                        return ListTile(
                          selected: isSelected,
                          leading: _buildUserSearchAvatar(user),
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
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: const OutlineInputBorder(),
                    ),
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
                        final roleProvider = Provider.of<RoleProvider>(
                          context,
                          listen: false,
                        );
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

  Future<void> _showLeaveChannelDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Channel'),
        content: Text('Are you sure you want to leave ${widget.channelName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.tertiary,
              foregroundColor: Theme.of(context).colorScheme.onTertiary,
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.leaveChannel(widget.channelId);
        if (mounted) {
          _showSuccess('Left channel successfully');
          Navigator.of(context).pop(); // Go back to previous screen
        }
      } catch (e) {
        if (mounted) {
          _showError(e.toString());
        }
      }
    }
  }

  Future<void> _showDeleteChannelDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Channel'),
        content: Text(
          'Are you sure you want to delete ${widget.channelName}? This action cannot be undone and will remove all members and data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.deleteChannel(widget.channelId);
        if (mounted) {
          _showSuccess('Channel deleted successfully');
          Navigator.of(context).pop(); // Go back to previous screen
        }
      } catch (e) {
        if (mounted) {
          _showError(e.toString());
        }
      }
    }
  }

  Future<void> _showKickUserDialog(ChannelMember member) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove User'),
        content: Text('Remove ${member.name} from ${widget.channelName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final roleProvider = Provider.of<RoleProvider>(context, listen: false);
        await roleProvider.kickUserFromChannel(
          channelId: widget.channelId,
          userId: member.userId,
        );
        _showSuccess('User removed from channel');
        _loadData();
      } catch (e) {
        _showError(e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final roleProvider = Provider.of<RoleProvider>(context);

    // Debug logging
    debugPrint('[ChannelMembers] Channel ID: ${widget.channelId}');
    debugPrint('[ChannelMembers] isAdmin: ${roleProvider.isAdmin}');
    debugPrint(
      '[ChannelMembers] isChannelOwner: ${roleProvider.isChannelOwner(widget.channelId)}',
    );
    debugPrint(
      '[ChannelMembers] has role.assign: ${roleProvider.hasChannelPermission(widget.channelId, 'role.assign')}',
    );
    debugPrint(
      '[ChannelMembers] has user.add: ${roleProvider.hasChannelPermission(widget.channelId, 'user.add')}',
    );

    final canManageRoles =
        roleProvider.isAdmin ||
        roleProvider.isChannelOwner(widget.channelId) ||
        roleProvider.hasChannelPermission(widget.channelId, 'role.assign');

    final canAddUsers =
        roleProvider.isAdmin ||
        roleProvider.isChannelOwner(widget.channelId) ||
        roleProvider.hasChannelPermission(widget.channelId, 'user.add');

    final canKickUsers =
        roleProvider.isAdmin ||
        roleProvider.isChannelOwner(widget.channelId) ||
        roleProvider.hasChannelPermission(widget.channelId, 'user.kick');

    final isOwner = roleProvider.isChannelOwner(widget.channelId);

    debugPrint('[ChannelMembers] canManageRoles: $canManageRoles');
    debugPrint('[ChannelMembers] canAddUsers: $canAddUsers');
    debugPrint('[ChannelMembers] canKickUsers: $canKickUsers');
    debugPrint('[ChannelMembers] isOwner: $isOwner');

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text('${widget.channelName} - Members'),
        actions: [
          if (canAddUsers)
            IconButton(
              icon: const Icon(Icons.person_add),
              onPressed: _showAddUserDialog,
              tooltip: 'Add User',
            ),
          if (!isOwner)
            IconButton(
              icon: const Icon(Icons.exit_to_app),
              onPressed: _showLeaveChannelDialog,
              tooltip: 'Leave Channel',
            ),
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _showDeleteChannelDialog,
              tooltip: 'Delete Channel',
              color: Theme.of(context).colorScheme.error,
            ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadData),
        ],
      ),
      body: Column(
        children: [
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
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
                      leading: _buildMemberAvatar(member),
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
                              ? Theme.of(context).colorScheme.primary
                              : member.isModerator
                              ? Theme.of(context).colorScheme.tertiary
                              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (canManageRoles)
                            IconButton(
                              icon: const Icon(Icons.add_circle),
                              onPressed: () => _showAssignRoleDialog(member),
                              tooltip: 'Assign Role',
                            ),
                          if (canKickUsers && !member.isOwner)
                            IconButton(
                              icon: const Icon(Icons.person_remove),
                              onPressed: () => _showKickUserDialog(member),
                              tooltip: 'Remove from Channel',
                              color: Theme.of(context).colorScheme.error,
                            ),
                        ],
                      ),
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
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                              trailing: canManageRoles && !role.standard
                                  ? IconButton(
                                      icon: Icon(
                                        Icons.remove_circle,
                                        color: Theme.of(context).colorScheme.error,
                                      ),
                                      onPressed: () =>
                                          _showRemoveRoleDialog(member, role),
                                      tooltip: 'Remove Role',
                                    )
                                  : role.standard
                                  ? Chip(
                                      label: Text(
                                        'Standard',
                                        style: TextStyle(
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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

  /// Build square avatar for member using UserProfileService
  Widget _buildMemberAvatar(ChannelMember member) {
    final profile =
        _loadedProfiles[member.userId] ??
        UserProfileService.instance.getProfileOrLoad(
          member.userId,
          onLoaded: (profile) {
            if (mounted && profile != null) {
              setState(() {
                _loadedProfiles[member.userId] = profile;
              });
            }
          },
        );

    final effectivePicture = profile?['picture'] as String?;
    final displayName = profile?['displayName'] as String? ?? member.name;

    return _buildSquareAvatar(
      pictureData: effectivePicture,
      fallbackInitial: displayName.isNotEmpty
          ? displayName[0].toUpperCase()
          : '?',
    );
  }

  /// Build square avatar for user in search results
  Widget _buildUserSearchAvatar(Map<String, String> user) {
    final userId = user['uuid'];
    if (userId == null) {
      return _buildSquareAvatar(
        pictureData: null,
        fallbackInitial: user['displayName']!.isNotEmpty
            ? user['displayName']![0].toUpperCase()
            : '?',
      );
    }

    final profile =
        _loadedProfiles[userId] ??
        UserProfileService.instance.getProfileOrLoad(
          userId,
          onLoaded: (profile) {
            if (mounted && profile != null) {
              setState(() {
                _loadedProfiles[userId] = profile;
              });
            }
          },
        );

    final effectivePicture = profile?['picture'] as String?;
    final displayName =
        profile?['displayName'] as String? ?? user['displayName']!;

    return _buildSquareAvatar(
      pictureData: effectivePicture,
      fallbackInitial: displayName.isNotEmpty
          ? displayName[0].toUpperCase()
          : '?',
    );
  }

  /// Build square avatar widget
  Widget _buildSquareAvatar({
    required String? pictureData,
    required String fallbackInitial,
  }) {
    ImageProvider? imageProvider;

    if (pictureData != null && pictureData.isNotEmpty) {
      try {
        if (pictureData.startsWith('data:image/')) {
          // Base64 encoded image
          final base64Data = pictureData.split(',').last;
          final bytes = base64Decode(base64Data);
          imageProvider = MemoryImage(bytes);
        } else if (pictureData.startsWith('http://') ||
            pictureData.startsWith('https://')) {
          // URL
          imageProvider = NetworkImage(pictureData);
        } else if (pictureData.startsWith('/')) {
          // Relative path - would need host, skip for now
          imageProvider = null;
        }
      } catch (e) {
        debugPrint('[CHANNEL_MEMBERS] Error parsing picture: $e');
      }
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: imageProvider == null
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
        borderRadius: BorderRadius.circular(4), // Slightly rounded corners
        image: imageProvider != null
            ? DecorationImage(
                image: imageProvider,
                fit: BoxFit.cover,
                onError: (_, __) {
                  // Error handled by falling back to initials
                },
              )
            : null,
      ),
      child: imageProvider == null
          ? Center(
              child: Text(
                fallbackInitial,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            )
          : null,
    );
  }
}
