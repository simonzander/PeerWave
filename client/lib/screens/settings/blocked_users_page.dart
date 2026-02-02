import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'package:intl/intl.dart';

class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key});

  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage> {
  List<Map<String, dynamic>> _blockedUsers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBlockedUsers();
  }

  Future<void> _loadBlockedUsers() async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiService.instance.get('/api/blocked-users');
      if (response.statusCode == 200) {
        setState(() {
          _blockedUsers = List<Map<String, dynamic>>.from(response.data);
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load blocked users: $e')),
        );
      }
    }
  }

  Future<void> _unblockUser(String blockedUuid, String displayName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unblock User'),
        content: Text(
          'Unblock $displayName? They will be able to message you again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unblock'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final response = await ApiService.instance.post(
        '/api/unblock',
        data: {'blockedUuid': blockedUuid},
      );

      if (response.statusCode == 200) {
        _loadBlockedUsers();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$displayName has been unblocked')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to unblock user: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(title: const Text('Blocked Users')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _blockedUsers.isEmpty
          ? const Center(
              child: Text(
                'No blocked users',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              itemCount: _blockedUsers.length,
              itemBuilder: (context, index) {
                final blocked = _blockedUsers[index];
                final blockedUser = blocked['blockedUser'];
                final displayName = blockedUser['displayName'] ?? 'Unknown';
                final blockedAt = DateTime.parse(blocked['blocked_at']);
                final formattedDate = DateFormat.yMMMd().format(blockedAt);

                return ListTile(
                  leading: const Icon(Icons.block, color: Colors.red),
                  title: Text(displayName),
                  subtitle: Text('Blocked on $formattedDate'),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () =>
                        _unblockUser(blockedUser['uuid'], displayName),
                    tooltip: 'Unblock',
                  ),
                );
              },
            ),
    );
  }
}
