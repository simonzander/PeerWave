import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'guest_meeting_video_conference_view.dart';

/// Entry point for external guest meeting view
/// Routes to minimal guest implementation without socket/profile services
class GuestMeetingVideoView extends StatelessWidget {
  final String meetingId;
  final String meetingTitle;
  final lk.MediaDevice? selectedCamera;
  final lk.MediaDevice? selectedMicrophone;

  const GuestMeetingVideoView({
    super.key,
    required this.meetingId,
    required this.meetingTitle,
    this.selectedCamera,
    this.selectedMicrophone,
  });

  @override
  Widget build(BuildContext context) {
    return GuestMeetingVideoConferenceView(
      meetingId: meetingId,
      meetingTitle: meetingTitle,
      selectedCamera: selectedCamera,
      selectedMicrophone: selectedMicrophone,
    );
  }
}
