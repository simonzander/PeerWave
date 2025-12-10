import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../models/meeting.dart';
import '../services/meeting_service.dart';
import '../services/device_identity_service.dart';
import '../services/user_profile_service.dart';
import '../widgets/meeting_dialog.dart';

/// Meetings screen - displays list of meetings with filters
/// 
/// Features:
/// - Filter tabs: All, Upcoming, Past, My Meetings
/// - Meeting cards with title, time, participants count
/// - FAB for creating new meetings
/// - Real-time updates via MeetingService streams
/// - Pull-to-refresh
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});

  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

class _MeetingsScreenState extends State<MeetingsScreen> with SingleTickerProviderStateMixin {
  final _meetingService = MeetingService();
  late TabController _tabController;
  
  List<Meeting> _allMeetings = [];
  List<Meeting> _upcomingMeetings = [];
  List<Meeting> _pastMeetings = [];
  List<Meeting> _myMeetings = [];
  
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _loadMeetings();
      }
    });
    
    // Initialize listeners for real-time updates
    _meetingService.initializeListeners();
    
    // Listen to real-time meeting events
    _meetingService.onMeetingCreated.listen((meeting) {
      if (mounted) {
        _loadMeetings();
      }
    });
    
    _meetingService.onMeetingUpdated.listen((meeting) {
      if (mounted) {
        _loadMeetings();
      }
    });
    
    _meetingService.onMeetingCancelled.listen((meetingId) {
      if (mounted) {
        _loadMeetings();
      }
    });
    
    _ensureProfileLoaded();
    _loadMeetings();
  }
  
  /// Ensure user profile is loaded for owner check
  Future<void> _ensureProfileLoaded() async {
    if (UserProfileService.instance.currentUserUuid == null) {
      debugPrint('[MEETINGS] User profile not loaded yet, loading now...');
      try {
        await UserProfileService.instance.initProfiles();
        if (mounted) {
          setState(() {}); // Trigger rebuild with loaded profile
        }
        debugPrint('[MEETINGS] User profile loaded: ${UserProfileService.instance.currentUserUuid}');
      } catch (e) {
        debugPrint('[MEETINGS] Error loading user profile: $e');
      }
    } else {
      debugPrint('[MEETINGS] User profile already loaded: ${UserProfileService.instance.currentUserUuid}');
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadMeetings() async {
    if (!mounted) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      switch (_tabController.index) {
        case 0: // All
          _allMeetings = await _meetingService.getMeetings();
          break;
        case 1: // Upcoming
          _upcomingMeetings = await _meetingService.getUpcomingMeetings();
          break;
        case 2: // Past
          _pastMeetings = await _meetingService.getPastMeetings();
          break;
        case 3: // My Meetings
          _myMeetings = await _meetingService.getMyMeetings();
          break;
      }
      
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load meetings: $e';
        });
      }
    }
  }

  List<Meeting> get _currentMeetings {
    switch (_tabController.index) {
      case 0:
        return _allMeetings;
      case 1:
        return _upcomingMeetings;
      case 2:
        return _pastMeetings;
      case 3:
        return _myMeetings;
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meetings'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Upcoming'),
            Tab(text: 'Past'),
            Tab(text: 'My Meetings'),
          ],
        ),
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createMeeting,
        icon: const Icon(Icons.add),
        label: const Text('New Meeting'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _buildErrorView();
    }

    if (_currentMeetings.isEmpty) {
      return _buildEmptyView();
    }

    return RefreshIndicator(
      onRefresh: _loadMeetings,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _currentMeetings.length,
        itemBuilder: (context, index) {
          final meeting = _currentMeetings[index];
          final currentUserUuid = UserProfileService.instance.currentUserUuid;
          final isOwner = currentUserUuid != null && 
                         meeting.createdBy == currentUserUuid;
          
          debugPrint('[MEETINGS] Meeting "${meeting.title}" - createdBy: ${meeting.createdBy}, currentUser: $currentUserUuid, isOwner: $isOwner');
          
          return _MeetingCard(
            meeting: meeting,
            isOwner: isOwner,
            onTap: () => _openMeetingDetails(meeting),
            onEdit: isOwner ? () => _editMeeting(meeting) : null,
          );
        },
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _loadMeetings,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    String message;
    IconData icon;
    
    switch (_tabController.index) {
      case 0:
        message = 'No meetings found';
        icon = Icons.event_busy;
        break;
      case 1:
        message = 'No upcoming meetings';
        icon = Icons.event_available;
        break;
      case 2:
        message = 'No past meetings';
        icon = Icons.history;
        break;
      case 3:
        message = 'You are not part of any meetings';
        icon = Icons.person_off;
        break;
      default:
        message = 'No meetings';
        icon = Icons.event_busy;
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            message,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _createMeeting,
            icon: const Icon(Icons.add),
            label: const Text('Create Meeting'),
          ),
        ],
      ),
    );
  }

  void _createMeeting() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const MeetingDialog(),
    );
    
    if (result == true && mounted) {
      _loadMeetings();
    }
  }

  void _openMeetingDetails(Meeting meeting) async {
    final now = DateTime.now();
    final currentUserUuid = UserProfileService.instance.currentUserUuid;
    final isOwner = currentUserUuid != null && 
                   meeting.createdBy == currentUserUuid;
    
    // Check if meeting is in the future (more than 15 minutes)
    if (meeting.scheduledStart != null) {
      final timeUntilMeeting = meeting.scheduledStart!.difference(now);
      
      if (timeUntilMeeting.inMinutes > 15) {
        // Show future meeting dialog
        final shouldJoin = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Meeting Scheduled'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This meeting is scheduled for:',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  DateFormat('EEEE, MMMM d, y \'at\' h:mm a').format(meeting.scheduledStart!),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Starts in ${timeUntilMeeting.inHours} hours and ${timeUntilMeeting.inMinutes % 60} minutes.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.orange,
                  ),
                ),
                if (isOwner) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    'You are the meeting owner',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (isOwner)
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                    _editMeeting(meeting);
                  },
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit'),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Close'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Join Anyway'),
              ),
            ],
          ),
        );
        
        if (shouldJoin != true) return;
      }
    }
    
    // Navigate to prejoin page
    // TODO: Implement prejoin view for meetings
    context.go('/meeting/prejoin/${meeting.meetingId}');
  }
  
  void _editMeeting(Meeting meeting) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => MeetingDialog(meeting: meeting),
    );
    
    if (result == true && mounted) {
      _loadMeetings();
    }
  }
}

/// Meeting card widget - displays meeting information
class _MeetingCard extends StatelessWidget {
  final Meeting meeting;
  final bool isOwner;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  const _MeetingCard({
    required this.meeting,
    required this.isOwner,
    required this.onTap,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title and status
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meeting.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildStatusChip(context),
                  if (isOwner && onEdit != null) ...[
                    const SizedBox(width: 4),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onEdit,
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.edit,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              
              if (meeting.description != null) ...[
                const SizedBox(height: 8),
                Text(
                  meeting.description!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              
              const SizedBox(height: 12),
              
              // Meeting details
              Row(
                children: [
                  Icon(Icons.access_time, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _formatMeetingTime(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 4),
              
              // Participants count
              if (meeting.participantCount != null && meeting.participantCount! > 0)
                Row(
                  children: [
                    Icon(Icons.people, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      '${meeting.participantCount} participant${meeting.participantCount != 1 ? 's' : ''} joined',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              
              if (meeting.participantCount != null && meeting.participantCount! > 0)
                const SizedBox(height: 4),
              
              // Meeting type and settings
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (meeting.isInstantCall)
                    _buildInfoChip(Icons.phone, 'Instant Call', context),
                  if (meeting.voiceOnly)
                    _buildInfoChip(Icons.mic, 'Voice Only', context),
                  if (meeting.allowExternal)
                    _buildInfoChip(Icons.link, 'External Guests', context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    }

  Widget _buildStatusChip(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    String label;
    
    if (meeting.isActive) {
      backgroundColor = Colors.green[100]!;
      textColor = Colors.green[900]!;
      label = 'In Progress';
    } else if (meeting.isScheduled) {
      backgroundColor = Colors.blue[100]!;
      textColor = Colors.blue[900]!;
      label = 'Scheduled';
    } else if (meeting.isCompleted) {
      backgroundColor = Colors.grey[300]!;
      textColor = Colors.grey[800]!;
      label = 'Completed';
    } else if (meeting.isCancelled) {
      backgroundColor = Colors.red[100]!;
      textColor = Colors.red[900]!;
      label = 'Cancelled';
    } else {
      backgroundColor = Colors.grey[200]!;
      textColor = Colors.grey[700]!;
      label = meeting.status;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label, BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey[700]),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  String _formatMeetingTime() {
    final startTime = meeting.scheduledStart;
    final endTime = meeting.scheduledEnd;
    
    // Handle null times - show created time
    if (startTime == null) {
      return 'Created ${DateFormat('MMM d, y \\at h:mm a').format(meeting.createdAt)}';
    }
    
    final now = DateTime.now();
    
    // Format: "Today at 3:00 PM" or "Tomorrow at 10:30 AM" or "Dec 15 at 2:00 PM"
    String datePrefix;
    if (startTime.year == now.year &&
        startTime.month == now.month &&
        startTime.day == now.day) {
      datePrefix = 'Today';
    } else if (startTime.year == now.year &&
        startTime.month == now.month &&
        startTime.day == now.day + 1) {
      datePrefix = 'Tomorrow';
    } else {
      datePrefix = DateFormat('MMM d').format(startTime);
    }
    
    final timeString = DateFormat('h:mm a').format(startTime);
    
    // Add duration if endTime is available
    if (endTime != null) {
      final duration = endTime.difference(startTime);
      final durationMinutes = duration.inMinutes;
      return '$datePrefix at $timeString ($durationMinutes min)';
    }
    
    return '$datePrefix at $timeString';
  }
}
