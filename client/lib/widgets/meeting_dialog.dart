import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import '../models/meeting.dart';
import '../services/meeting_service.dart';
import '../services/api_service.dart';
import '../services/signal_service.dart';
import '../theme/semantic_colors.dart';

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

  // RSVP status tracking by normalized key (userId or email)
  final Map<String, String> _inviteeStatusByKey = {};

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

      // Load existing invitees (persisted in invited_participants)
      _loadExistingInvitees();
    } else {
      // Create mode - default to 1 hour from now
      final now = DateTime.now();
      _startDate = now.add(const Duration(hours: 1));
      _startTime = TimeOfDay(hour: _startDate.hour, minute: 0);
      _endDate = _startDate.add(const Duration(hours: 1));
      _endTime = TimeOfDay(hour: _endDate.hour, minute: 0);
    }
  }

  String _normalizeInviteeKey(String value) => value.trim().toLowerCase();

  bool _isValidEmail(String value) {
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,}$');
    return emailRegex.hasMatch(value.trim());
  }

  Future<void> _loadExistingInvitees() async {
    try {
      final meeting = await _meetingService.getMeeting(
        widget.meeting!.meetingId,
      );

      final invited = meeting.invitedParticipants;
      final invitedStatuses = meeting.invitedRsvpStatuses ?? const {};

      // Fetch all users once and map by uuid
      final response = await ApiService.get('/people/list');
      final users = response.data is List ? response.data as List : [];
      final byId = <String, Map<String, dynamic>>{};
      for (final u in users) {
        final id = (u['uuid'] ?? '').toString();
        if (id.isNotEmpty) {
          byId[id] = (u as Map).cast<String, dynamic>();
        }
      }

      final selected = <Map<String, String>>[];
      final emails = <String>[];
      final statusByKey = <String, String>{};

      for (final raw in invited) {
        final key = _normalizeInviteeKey(raw);
        if (key.isEmpty) continue;
        final status = (invitedStatuses[key] ?? 'invited')
            .toString()
            .toLowerCase();
        statusByKey[key] = status;

        if (raw.contains('@')) {
          emails.add(key);
          continue;
        }

        final user = byId[raw];
        selected.add({
          'id': raw,
          'name': (user?['displayName'] ?? '').toString(),
          'email': (user?['email'] ?? '').toString(),
        });
      }

      if (!mounted) return;
      setState(() {
        _selectedParticipants = selected;
        _emailInvitations = emails;
        _inviteeStatusByKey
          ..clear()
          ..addAll(statusByKey);
      });
    } catch (e) {
      debugPrint('[MEETING_DIALOG] Error loading invitees: $e');
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
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
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
      decoration: InputDecoration(
        labelText: 'Meeting Title',
        hintText: 'Enter meeting title',
        prefixIcon: const Icon(Icons.title),
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
      decoration: InputDecoration(
        labelText: 'Description (Optional)',
        hintText: 'Enter meeting description',
        prefixIcon: const Icon(Icons.description),
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
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
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
          title: Text(
            'Voice Only',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          subtitle: Text(
            'Disable video, audio only',
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          value: _voiceOnly,
          onChanged: (value) => setState(() => _voiceOnly = value),
        ),

        SwitchListTile(
          title: Text(
            'Mute on Join',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          subtitle: Text(
            'Participants join muted',
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          value: _muteOnJoin,
          onChanged: (value) => setState(() => _muteOnJoin = value),
        ),

        SwitchListTile(
          title: Text(
            'Allow External Guests',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          subtitle: Text(
            'Generate invitation link for non-users',
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          value: _allowExternal,
          onChanged: (value) => setState(() => _allowExternal = value),
        ),

        const SizedBox(height: 24),

        _buildParticipantsSection(),
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
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
          onFieldSubmitted: (value) {
            if (!_allowExternal) return;
            final email = value.trim();
            if (_isValidEmail(email)) {
              _addEmailInvitationFromValue(email);
              _participantSearchController.clear();
              setState(() => _searchResults = []);
            }
          },
        ),

        if (_allowExternal) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _emailController,
                  decoration: InputDecoration(
                    labelText: 'Invite External by Email',
                    hintText: 'guest@example.com',
                    prefixIcon: const Icon(Icons.email),
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                  keyboardType: TextInputType.emailAddress,
                  onFieldSubmitted: (value) =>
                      _addEmailInvitationFromValue(value),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () =>
                    _addEmailInvitationFromValue(_emailController.text),
                icon: const Icon(Icons.add_circle),
                iconSize: 32,
                color: Theme.of(context).primaryColor,
              ),
            ],
          ),
        ],

        // Search results
        if (_searchResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
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
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.success,
                        )
                      : null,
                  onTap: () => _toggleParticipant(user),
                );
              },
            ),
          ),
        ],

        // Selected participants
        if (_selectedParticipants.isNotEmpty ||
            _emailInvitations.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildInviteeBuckets(),
        ],
      ],
    );
  }

  Widget _buildInviteeBuckets() {
    Widget buildSection(String title, List<Widget> chips) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (chips.isEmpty)
            Text(
              'None',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          const SizedBox(height: 12),
        ],
      );
    }

    String statusForKey(String key) =>
        _inviteeStatusByKey[_normalizeInviteeKey(key)] ?? 'invited';

    List<Widget> userChipsFor(String status) {
      return _selectedParticipants
          .where((p) => statusForKey(p['id'] ?? '') == status)
          .map((participant) {
            final name = (participant['name'] ?? '').trim();
            final email = (participant['email'] ?? '').trim();
            final label = name.isNotEmpty
                ? name
                : (email.isNotEmpty ? email : (participant['id'] ?? 'User'));
            return Chip(
              avatar: CircleAvatar(
                child: Text(label.isNotEmpty ? label[0].toUpperCase() : '?'),
              ),
              label: Text(label),
              onDeleted: () => _toggleParticipant(participant),
            );
          })
          .toList();
    }

    List<Widget> emailChipsFor(String status) {
      return _emailInvitations.where((e) => statusForKey(e) == status).map((
        email,
      ) {
        return Chip(
          avatar: const Icon(Icons.email, size: 16),
          label: Text(email),
          onDeleted: () => setState(() {
            _inviteeStatusByKey.remove(_normalizeInviteeKey(email));
            _emailInvitations.remove(email);
          }),
        );
      }).toList();
    }

    List<Widget> chipsFor(String status) {
      return [...userChipsFor(status), ...emailChipsFor(status)];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSection('Invited', chipsFor('invited')),
        buildSection('Accepted', chipsFor('accepted')),
        buildSection('Tentative', chipsFor('tentative')),
        buildSection('Declined', chipsFor('declined')),
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
      final response = await ApiService.get('/people/list');
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
        _inviteeStatusByKey.remove(_normalizeInviteeKey(user['id'] ?? ''));
      } else {
        _selectedParticipants.add(user);
        _inviteeStatusByKey[_normalizeInviteeKey(user['id'] ?? '')] = 'invited';
      }
    });
  }

  void _addEmailInvitationFromValue(String value) {
    final email = value.trim().toLowerCase();
    if (email.isEmpty) return;

    if (!_isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter a valid email address'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    if (_emailInvitations.contains(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Email already added'),
          backgroundColor: Theme.of(context).colorScheme.warning,
        ),
      );
      return;
    }

    setState(() {
      _emailInvitations.add(email);
      _inviteeStatusByKey[_normalizeInviteeKey(email)] = 'invited';
      _emailController.clear();
    });
  }

  Widget _buildFooter(bool isEdit) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
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
        SnackBar(
          content: const Text('End time must be after start time'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final meeting = widget.meeting;

      final participantIds = _selectedParticipants
          .map((p) => p['id']!)
          .toList();
      final invitedParticipants = <String>{
        ...participantIds,
        ..._emailInvitations.map((e) => e.trim().toLowerCase()),
      }.where((e) => e.isNotEmpty).toList();

      Future<void> sendInviteMessagesTo(
        List<String> userIds,
        Meeting meeting,
      ) async {
        if (userIds.isEmpty) return;

        final signal = SignalService.instance;
        final senderId = signal.currentUserId;
        if (senderId == null || senderId.isEmpty) return;

        final meetingTitle = meeting.title;
        final payload = jsonEncode({
          'meetingId': meeting.meetingId,
          'title': meetingTitle,
          'startTime': meeting.scheduledStart?.toIso8601String(),
        });

        for (final uid in userIds) {
          if (uid.isEmpty) continue;
          if (uid == senderId) continue;
          try {
            await signal.sendItem(
              recipientUserId: uid,
              type: 'system:meetingInvite',
              payload: payload,
            );
          } catch (e) {
            // Best-effort only: meeting save must still succeed.
            debugPrint('[MEETING INVITE] Failed to send invite DM to $uid: $e');
          }
        }
      }

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
          participantIds: participantIds,
          emailInvitations: _emailInvitations,
        );

        // In-app invite notification as 1:1 DM (best-effort)
        await sendInviteMessagesTo(participantIds, createdMeeting);
      } else {
        // Update existing meeting
        final previousInternalInvites = meeting.invitedParticipants
            .where((v) => v.contains('-'))
            .map((v) => v.toLowerCase())
            .toSet();
        final nextInternalInvites = participantIds
            .map((v) => v.toLowerCase())
            .toSet();
        final newlyAdded = nextInternalInvites
            .difference(previousInternalInvites)
            .toList();

        final updatedMeeting = await _meetingService.updateMeeting(
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
          invitedParticipants: invitedParticipants,
        );

        // In-app invite notification as 1:1 DM (best-effort, only newly added)
        await sendInviteMessagesTo(newlyAdded, updatedMeeting);
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
            backgroundColor: Theme.of(context).colorScheme.error,
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
