import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import '../models/meeting.dart';
import '../services/meeting_service.dart';
import '../services/api_service.dart';
import '../web_config.dart';
import '../services/server_config_web.dart'
    if (dart.library.io) '../services/server_config_native.dart';

/// Dialog for creating or editing meetings
///
/// Features:
/// - Title and description fields
/// - Date and time pickers for start/end
/// - Settings toggles (voice only, mute on join, external guests)
/// - Max participants limit
/// - Form validation
/// - Create/Update API integration
class MeetingDialog extends StatefulWidget {
  final Meeting? meeting; // null for create, non-null for edit

  const MeetingDialog({super.key, this.meeting});

  @override
  State<MeetingDialog> createState() => _MeetingDialogState();
}

class _MeetingDialogState extends State<MeetingDialog> {
  final _formKey = GlobalKey<FormState>();
  final _meetingService = MeetingService();

  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late TextEditingController _participantSearchController;
  late TextEditingController _emailController;

  late DateTime _startDate;
  late TimeOfDay _startTime;
  late DateTime _endDate;
  late TimeOfDay _endTime;

  bool _allowExternal = false;
  bool _voiceOnly = false;
  bool _muteOnJoin = false;
  bool _isSubmitting = false;

  // Participant management
  List<Map<String, String>> _selectedParticipants = [];
  List<Map<String, String>> _searchResults = [];
  bool _isSearching = false;

  // External email invitations
  List<String> _emailInvitations = [];

  @override
  void initState() {
    super.initState();

    final meeting = widget.meeting;

    _titleController = TextEditingController(text: meeting?.title ?? '');
    _descriptionController = TextEditingController(
      text: meeting?.description ?? '',
    );
    _participantSearchController = TextEditingController();
    _emailController = TextEditingController();

    if (meeting != null &&
        meeting.scheduledStart != null &&
        meeting.scheduledEnd != null) {
      // Edit mode - scheduled meeting
      _startDate = meeting.scheduledStart!;
      _startTime = TimeOfDay.fromDateTime(meeting.scheduledStart!);
      _endDate = meeting.scheduledEnd!;
      _endTime = TimeOfDay.fromDateTime(meeting.scheduledEnd!);
      _allowExternal = meeting.allowExternal;
      _voiceOnly = meeting.voiceOnly;
      _muteOnJoin = meeting.muteOnJoin;

      // Load existing participants
      _loadExistingParticipants();
    } else {
      // Create mode - default to 1 hour from now
      final now = DateTime.now();
      _startDate = now.add(const Duration(hours: 1));
      _startTime = TimeOfDay(hour: _startDate.hour, minute: 0);
      _endDate = _startDate.add(const Duration(hours: 1));
      _endTime = TimeOfDay(hour: _endDate.hour, minute: 0);
    }
  }

  Future<void> _loadExistingParticipants() async {
    try {
      final participants = await _meetingService.getParticipants(
        widget.meeting!.meetingId,
      );

      // Fetch user details for each participant
      for (final participant in participants) {
        // Get API server
        String? apiServer;
        if (kIsWeb) {
          apiServer = await loadWebApiServer();
        } else {
          final activeServer = ServerConfigService.getActiveServer();
          if (activeServer != null) {
            apiServer = activeServer.serverUrl;
          }
        }

        if (apiServer == null || apiServer.isEmpty) {
          continue;
        }

        String urlString = apiServer;
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }

        // Fetch user info
        try {
          final response = await ApiService.get('$urlString/people/list');
          if (response.statusCode == 200) {
            final users = response.data is List ? response.data as List : [];
            final user = users.firstWhere(
              (u) => u['uuid'] == participant.userId,
              orElse: () => null,
            );

            if (user != null) {
              setState(() {
                _selectedParticipants.add({
                  'id': user['uuid'],
                  'name': user['displayName'] ?? '',
                  'email': user['email'] ?? '',
                });
              });
            }
          }
        } catch (e) {
          debugPrint(
            '[MEETING_DIALOG] Error fetching user ${participant.userId}: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('[MEETING_DIALOG] Error loading participants: $e');
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _participantSearchController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  DateTime get _combinedStartDateTime {
    return DateTime(
      _startDate.year,
      _startDate.month,
      _startDate.day,
      _startTime.hour,
      _startTime.minute,
    );
  }

  DateTime get _combinedEndDateTime {
    return DateTime(
      _endDate.year,
      _endDate.month,
      _endDate.day,
      _endTime.hour,
      _endTime.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.meeting != null;

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            _buildHeader(isEdit),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitleField(),
                      const SizedBox(height: 16),
                      _buildDescriptionField(),
                      const SizedBox(height: 24),
                      _buildDateTimeSection(),
                      const SizedBox(height: 24),
                      _buildSettingsSection(),
                    ],
                  ),
                ),
              ),
            ),

            // Footer
            _buildFooter(isEdit),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isEdit) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Row(
        children: [
          Icon(isEdit ? Icons.edit : Icons.add, size: 28),
          const SizedBox(width: 12),
          Text(
            isEdit ? 'Edit Meeting' : 'Create Meeting',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleField() {
    return TextFormField(
      controller: _titleController,
      decoration: const InputDecoration(
        labelText: 'Meeting Title',
        hintText: 'Enter meeting title',
        prefixIcon: Icon(Icons.title),
        border: OutlineInputBorder(),
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Please enter a meeting title';
        }
        return null;
      },
      autofocus: widget.meeting == null,
    );
  }

  Widget _buildDescriptionField() {
    return TextFormField(
      controller: _descriptionController,
      decoration: const InputDecoration(
        labelText: 'Description (Optional)',
        hintText: 'Enter meeting description',
        prefixIcon: Icon(Icons.description),
        border: OutlineInputBorder(),
      ),
      maxLines: 3,
    );
  }

  Widget _buildDateTimeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Schedule',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        // Start date/time
        Row(
          children: [
            Expanded(
              child: _buildDatePicker(
                label: 'Start Date',
                date: _startDate,
                onDateSelected: (date) => setState(() => _startDate = date),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildTimePicker(
                label: 'Start Time',
                time: _startTime,
                onTimeSelected: (time) => setState(() => _startTime = time),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // End date/time
        Row(
          children: [
            Expanded(
              child: _buildDatePicker(
                label: 'End Date',
                date: _endDate,
                onDateSelected: (date) => setState(() => _endDate = date),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildTimePicker(
                label: 'End Time',
                time: _endTime,
                onTimeSelected: (time) => setState(() => _endTime = time),
              ),
            ),
          ],
        ),

        // Validation message
        if (_combinedEndDateTime.isBefore(_combinedStartDateTime))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'End time must be after start time',
              style: TextStyle(color: Colors.red[700], fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _buildDatePicker({
    required String label,
    required DateTime date,
    required Function(DateTime) onDateSelected,
  }) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) {
          onDateSelected(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today),
          border: const OutlineInputBorder(),
        ),
        child: Text(DateFormat('MMM d, yyyy').format(date)),
      ),
    );
  }

  Widget _buildTimePicker({
    required String label,
    required TimeOfDay time,
    required Function(TimeOfDay) onTimeSelected,
  }) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: time,
        );
        if (picked != null) {
          onTimeSelected(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.access_time),
          border: const OutlineInputBorder(),
        ),
        child: Text(time.format(context)),
      ),
    );
  }

  Widget _buildSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Settings',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        SwitchListTile(
          title: const Text('Voice Only'),
          subtitle: const Text('Disable video, audio only'),
          value: _voiceOnly,
          onChanged: (value) => setState(() => _voiceOnly = value),
        ),

        SwitchListTile(
          title: const Text('Mute on Join'),
          subtitle: const Text('Participants join muted'),
          value: _muteOnJoin,
          onChanged: (value) => setState(() => _muteOnJoin = value),
        ),

        SwitchListTile(
          title: const Text('Allow External Guests'),
          subtitle: const Text('Generate invitation link for non-users'),
          value: _allowExternal,
          onChanged: (value) => setState(() => _allowExternal = value),
        ),

        const SizedBox(height: 24),

        _buildParticipantsSection(),

        if (_allowExternal) ...[
          const SizedBox(height: 24),
          _buildEmailInvitationsSection(),
        ],
      ],
    );
  }

  Widget _buildParticipantsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Participants',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Search and add participants to this meeting',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
        const SizedBox(height: 12),

        // Search field
        TextFormField(
          controller: _participantSearchController,
          decoration: InputDecoration(
            labelText: 'Search Users',
            hintText: 'Type name or email...',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            suffixIcon: _isSearching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: _searchUsers,
        ),

        // Search results
        if (_searchResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final user = _searchResults[index];
                final isSelected = _selectedParticipants.any(
                  (p) => p['id'] == user['id'],
                );

                return ListTile(
                  leading: CircleAvatar(
                    child: Text(user['name']![0].toUpperCase()),
                  ),
                  title: Text(user['name']!),
                  subtitle: Text(user['email']!),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : null,
                  onTap: () => _toggleParticipant(user),
                );
              },
            ),
          ),
        ],

        // Selected participants
        if (_selectedParticipants.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _selectedParticipants.map((participant) {
              return Chip(
                avatar: CircleAvatar(
                  child: Text(participant['name']![0].toUpperCase()),
                ),
                label: Text(participant['name']!),
                onDeleted: () => _toggleParticipant(participant),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildEmailInvitationsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'External Email Invitations',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Send meeting invitations to external guests via email',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
        const SizedBox(height: 12),

        // Email input
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email Address',
                  hintText: 'guest@example.com',
                  prefixIcon: Icon(Icons.email),
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value != null && value.isNotEmpty) {
                    final emailRegex = RegExp(
                      r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                    );
                    if (!emailRegex.hasMatch(value)) {
                      return 'Invalid email address';
                    }
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _addEmailInvitation,
              icon: const Icon(Icons.add_circle),
              iconSize: 32,
              color: Theme.of(context).primaryColor,
            ),
          ],
        ),

        // Email list
        if (_emailInvitations.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _emailInvitations.map((email) {
              return Chip(
                avatar: const Icon(Icons.email, size: 16),
                label: Text(email),
                onDeleted: () =>
                    setState(() => _emailInvitations.remove(email)),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  void _searchUsers(String query) async {
    if (query.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      // Get server URL
      String? apiServer;
      if (kIsWeb) {
        apiServer = await loadWebApiServer();
      } else {
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer != null) {
          apiServer = activeServer.serverUrl;
        }
      }

      if (apiServer == null || apiServer.isEmpty) {
        throw Exception('No API server configured');
      }

      String urlString = apiServer;
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }

      // Search users
      final response = await ApiService.get('$urlString/people/list');
      if (response.statusCode == 200) {
        final users = response.data is List ? response.data as List : [];
        final results = <Map<String, String>>[];

        for (final user in users) {
          final displayName = user['displayName'] ?? '';
          final email = user['email'] ?? '';
          if (displayName.toLowerCase().contains(query.toLowerCase()) ||
              email.toLowerCase().contains(query.toLowerCase())) {
            results.add({
              'id': user['uuid'],
              'name': displayName,
              'email': email,
            });
          }
        }

        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (e) {
      debugPrint('[MEETING_DIALOG] Search error: $e');
      setState(() => _isSearching = false);
    }
  }

  void _toggleParticipant(Map<String, String> user) {
    setState(() {
      final index = _selectedParticipants.indexWhere(
        (p) => p['id'] == user['id'],
      );
      if (index >= 0) {
        _selectedParticipants.removeAt(index);
      } else {
        _selectedParticipants.add(user);
      }
    });
  }

  void _addEmailInvitation() {
    if (_emailController.text.isEmpty) return;

    final email = _emailController.text.trim();
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');

    if (!emailRegex.hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid email address'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_emailInvitations.contains(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email already added'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _emailInvitations.add(email);
      _emailController.clear();
    });
  }

  Widget _buildFooter(bool isEdit) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _isSubmitting ? null : _handleSubmit,
            icon: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(isEdit ? Icons.save : Icons.add),
            label: Text(isEdit ? 'Update' : 'Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Validate date/time
    if (_combinedEndDateTime.isBefore(_combinedStartDateTime)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('End time must be after start time'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final meeting = widget.meeting;

      // Extract participant IDs
      final newParticipantIds = _selectedParticipants
          .map((p) => p['id']!)
          .toSet();

      String meetingId;
      Set<String> oldParticipantIds = {};

      if (meeting == null) {
        // Create new meeting (without participants initially)
        final createdMeeting = await _meetingService.createMeeting(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          startTime: _combinedStartDateTime,
          endTime: _combinedEndDateTime,
          allowExternal: _allowExternal,
          voiceOnly: _voiceOnly,
          muteOnJoin: _muteOnJoin,
          emailInvitations: _emailInvitations,
        );

        meetingId = createdMeeting.meetingId;
      } else {
        // Update existing meeting
        await _meetingService.updateMeeting(
          meeting.meetingId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          startTime: _combinedStartDateTime,
          endTime: _combinedEndDateTime,
          allowExternal: _allowExternal,
          voiceOnly: _voiceOnly,
          muteOnJoin: _muteOnJoin,
        );

        meetingId = meeting.meetingId;

        // Get existing participants to compare
        try {
          final existingParticipants = await _meetingService.getParticipants(
            meetingId,
          );
          oldParticipantIds = existingParticipants.map((p) => p.userId).toSet();
        } catch (e) {
          debugPrint(
            '[MEETING_DIALOG] Error fetching existing participants: $e',
          );
        }
      }

      // Add new participants
      final toAdd = newParticipantIds.difference(oldParticipantIds);
      for (final userId in toAdd) {
        try {
          await _meetingService.addParticipant(meetingId, userId);
        } catch (e) {
          debugPrint('[MEETING_DIALOG] Error adding participant $userId: $e');
        }
      }

      // Remove participants (only in edit mode)
      if (meeting != null) {
        final toRemove = oldParticipantIds.difference(newParticipantIds);
        for (final userId in toRemove) {
          try {
            await _meetingService.removeParticipant(meetingId, userId);
          } catch (e) {
            debugPrint(
              '[MEETING_DIALOG] Error removing participant $userId: $e',
            );
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              meeting == null
                  ? 'Meeting created successfully'
                  : 'Meeting updated successfully',
            ),
          ),
        );
        Navigator.of(context).pop(true); // Return true to indicate success
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save meeting: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}
