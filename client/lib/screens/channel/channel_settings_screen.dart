import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../services/api_service.dart';
import '../../models/role.dart';
import '../../providers/role_provider.dart';
import '../../services/signal_service.dart';

class ChannelSettingsScreen extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String channelType;
  final String? channelDescription;
  final bool isPrivate;
  final String? defaultJoinRole;
  final String host;
  final bool isOwner;

  const ChannelSettingsScreen({
    Key? key,
    required this.channelId,
    required this.channelName,
    required this.channelType,
    this.channelDescription,
    required this.isPrivate,
    this.defaultJoinRole,
    required this.host,
    required this.isOwner,
  }) : super(key: key);

  @override
  State<ChannelSettingsScreen> createState() => _ChannelSettingsScreenState();
}

class _ChannelSettingsScreenState extends State<ChannelSettingsScreen> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late bool _isPrivate;
  String? _selectedDefaultRole;
  List<Role> _availableRoles = [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.channelName);
    _descriptionController = TextEditingController(
      text: widget.channelDescription ?? '',
    );
    _isPrivate = widget.isPrivate;
    _selectedDefaultRole = widget.defaultJoinRole;

    _nameController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);

    _loadRoles();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    setState(() {
      _hasChanges =
          _nameController.text != widget.channelName ||
          _descriptionController.text != (widget.channelDescription ?? '') ||
          _isPrivate != widget.isPrivate ||
          _selectedDefaultRole != widget.defaultJoinRole;
    });
  }

  Future<void> _loadRoles() async {
    setState(() => _isLoading = true);

    try {
      final roleProvider = Provider.of<RoleProvider>(context, listen: false);
      final scope = widget.channelType == 'signal'
          ? RoleScope.channelSignal
          : RoleScope.channelWebRtc;
      final roles = await roleProvider.getRolesByScope(scope);

      setState(() {
        _availableRoles = roles;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[CHANNEL_SETTINGS] Error loading roles: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        _showError('Failed to load roles: $e');
      }
    }
  }

  Future<void> _saveSettings() async {
    if (!widget.isOwner) {
      _showError('Only channel owners can modify settings');
      return;
    }

    if (_nameController.text.trim().isEmpty) {
      _showError('Channel name cannot be empty');
      return;
    }

    setState(() => _isSaving = true);

    try {
      ApiService.init();

      final resp = await ApiService.updateChannel(
        widget.host,
        widget.channelId,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        isPrivate: _isPrivate,
        defaultRoleId: _selectedDefaultRole,
      );

      if (resp.statusCode == 200) {
        if (mounted) {
          _showSuccess('Channel settings updated successfully');
          setState(() {
            _hasChanges = false;
          });
          // Return with updated values to refresh parent
          Navigator.of(context).pop(true);
        }
      } else {
        throw Exception('Failed to update channel: ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[CHANNEL_SETTINGS] Error saving settings: $e');
      if (mounted) {
        _showError('Failed to save settings: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _deleteChannel() async {
    if (!widget.isOwner) {
      _showError('Only channel owners can delete channels');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Are you sure you want to delete this channel?',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'Channel: ${widget.channelName}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
            ),
            const SizedBox(height: 12),
            const Text(
              'This action cannot be undone. All messages and data will be permanently deleted.',
              style: TextStyle(color: Color(0xFFEF5350)),
            ),
          ],
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

    if (confirmed == true) {
      await _performDelete();
    }
  }

  Future<void> _performDelete() async {
    setState(() => _isSaving = true);

    try {
      ApiService.init();
      final hostUrl = ApiService.ensureHttpPrefix(widget.host);

      final resp = await ApiService.delete(
        '$hostUrl/client/channels/${widget.channelId}',
      );

      if (resp.statusCode == 200) {
        if (mounted) {
          // Navigate to channels overview using GoRouter
          context.go('/app/channels');
          
          // Show success toast
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Channel "${widget.channelName}" deleted successfully'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        throw Exception('Failed to delete channel: ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[CHANNEL_SETTINGS] Error deleting channel: $e');
      if (mounted) {
        _showError('Failed to delete channel: $e');
        setState(() => _isSaving = false);
      }
    }
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Channel Settings'),
        backgroundColor: colorScheme.surface,
        actions: [
          if (widget.isOwner && _hasChanges)
            TextButton(
              onPressed: _isSaving ? null : _saveSettings,
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
        ],
      ),
      backgroundColor: colorScheme.surface,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Channel Name
                  _buildSectionTitle('Channel Name'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    enabled: widget.isOwner,
                    decoration: InputDecoration(
                      hintText: 'Enter channel name',
                      filled: true,
                      fillColor: colorScheme.surfaceVariant,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(
                        widget.channelType == 'signal'
                            ? Icons.tag
                            : Icons.videocam,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Channel Description
                  _buildSectionTitle('Description'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _descriptionController,
                    enabled: widget.isOwner,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Enter channel description (optional)',
                      filled: true,
                      fillColor: colorScheme.surfaceVariant,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colorScheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colorScheme.outlineVariant),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colorScheme.primary, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Channel Type (Read-only)
                  _buildSectionTitle('Channel Type'),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceVariant.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.channelType == 'signal'
                              ? Icons.message
                              : Icons.videocam,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          widget.channelType == 'signal'
                              ? 'Text Channel (Signal)'
                              : 'Video Channel (WebRTC)',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Private Channel Toggle
                  _buildSectionTitle('Privacy'),
                  const SizedBox(height: 8),
                  Card(
                    child: SwitchListTile(
                      title: const Text('Private Channel'),
                      subtitle: Text(
                        _isPrivate
                            ? 'Only invited members can access this channel'
                            : 'Anyone can discover and join this channel',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                      ),
                      value: _isPrivate,
                      onChanged: widget.isOwner
                          ? (value) {
                              setState(() {
                                _isPrivate = value;
                                _onFieldChanged();
                              });
                            }
                          : null,
                      secondary: Icon(
                        _isPrivate ? Icons.lock : Icons.public,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Default Join Role
                  _buildSectionTitle('Default Join Role'),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceVariant.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: DropdownButtonFormField<String>(
                      value: _selectedDefaultRole,
                      hint: const Text('Select default role for new members'),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        prefixIcon: Icon(Icons.person_outline),
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                      isExpanded: true,
                      items: _availableRoles.map((role) {
                        return DropdownMenuItem(
                          value: role.uuid,
                          child: Text(
                            role.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: widget.isOwner
                          ? (value) {
                              setState(() {
                                _selectedDefaultRole = value;
                                _onFieldChanged();
                              });
                            }
                          : null,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Danger Zone
                  if (widget.isOwner) ...[
                    Divider(color: Theme.of(context).colorScheme.error.withOpacity(0.3)),
                    const SizedBox(height: 16),
                    _buildSectionTitle('Danger Zone', color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 8),
                    Card(
                      color: Theme.of(context).colorScheme.error.withOpacity(0.1),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.warning, color: Theme.of(context).colorScheme.error),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Delete this channel',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).colorScheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Once you delete a channel, there is no going back. All messages and data will be permanently deleted.',
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isSaving ? null : _deleteChannel,
                                icon: const Icon(Icons.delete_forever),
                                label: const Text('Delete Channel'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.error,
                                  foregroundColor: Theme.of(context).colorScheme.onError,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // Permission Message for non-owners
                  if (!widget.isOwner) ...[
                    const SizedBox(height: 24),
                    Card(
                      color: colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: colorScheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Only channel owners can modify settings or delete this channel.',
                                style: TextStyle(
                                  color: colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSectionTitle(String title, {Color? color}) {
    return Text(
      title,
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
    );
  }
}
