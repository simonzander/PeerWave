import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';

// Meeting screens and views
import '../../screens/meetings_screen.dart';
import '../../views/external_prejoin_view.dart';
import '../../views/meeting_prejoin_view.dart';
import '../../views/meeting_video_conference_view.dart';
import '../../views/guest_meeting_video_view.dart';
import '../../screens/meeting_rsvp_confirmation_screen.dart';
import '../../services/meeting_authorization_service.dart';
import '../../app/app_layout.dart';

/// Returns external participant routes (guests) for web platform
/// These routes are outside ShellRoute to allow unauthenticated access
List<GoRoute> getMeetingRoutesExternal() {
  if (!kIsWeb) return []; // External routes are web-only

  return [
    // Unified guest join - key generation + pre-join in one view
    GoRoute(
      path: '/join/meeting/:token',
      builder: (context, state) {
        final token = state.pathParameters['token'];
        if (token == null || token.isEmpty) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'Invalid or missing invitation token',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Please check your invitation link and try again.',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        }

        return ExternalPreJoinView(
          invitationToken: token,
          onAdmitted: () {
            debugPrint(
              '[EXTERNAL] Guest admitted, navigating to conference...',
            );

            // Get meeting ID from session storage (web only)
            if (kIsWeb) {
              try {
                // Web-specific session storage logic handled in ExternalPreJoinView
              } catch (e) {
                debugPrint('[EXTERNAL] Error navigating to conference: $e');
              }
            }
          },
          onDeclined: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Meeting access declined'),
                backgroundColor: Colors.orange,
              ),
            );
          },
        );
      },
    ),

    // RSVP confirmation route
    GoRoute(
      path: '/meeting/rsvp',
      builder: (context, state) {
        final qp = state.uri.queryParameters;
        final meetingId = qp['meetingId'] ?? '';
        final status = qp['status'] ?? '';
        final email = qp['email'] ?? '';
        final token = qp['token'] ?? '';

        if (meetingId.isEmpty ||
            status.isEmpty ||
            email.isEmpty ||
            token.isEmpty) {
          return const Scaffold(
            body: Center(child: Text('Missing RSVP parameters')),
          );
        }

        return MeetingRsvpConfirmationScreen(
          meetingId: meetingId,
          status: status,
          email: email,
          token: token,
        );
      },
    ),

    // Meeting video route (outside ShellRoute for guest support)
    GoRoute(
      path: '/meeting/video/:meetingId',
      redirect: (context, state) async {
        final meetingId = state.pathParameters['meetingId']!;
        final extra = state.extra as Map<String, dynamic>?;
        final isExternal =
            extra?['isExternal'] == true ||
            state.uri.queryParameters['external'] == 'true';

        // Skip auth check for external guests
        if (isExternal) {
          return null;
        }

        // Check authorization for authenticated users
        final hasAccess = await MeetingAuthorizationService.instance
            .checkMeetingAccess(meetingId);
        if (!hasAccess) {
          debugPrint('[ROUTER] ❌ Unauthorized access to meeting: $meetingId');
          return '/app/meetings';
        }
        return null;
      },
      builder: (context, state) {
        final meetingId = state.pathParameters['meetingId']!;
        final extra = state.extra as Map<String, dynamic>?;
        final isExternal =
            extra?['isExternal'] == true ||
            state.uri.queryParameters['external'] == 'true';

        debugPrint('[ROUTE_BUILDER] WEB Meeting video route builder called');
        debugPrint('[ROUTE_BUILDER] meetingId: $meetingId');
        debugPrint('[ROUTE_BUILDER] extra: $extra');
        debugPrint(
          '[ROUTE_BUILDER] query params: ${state.uri.queryParameters}',
        );
        debugPrint('[ROUTE_BUILDER] isExternal: $isExternal');
        debugPrint(
          '[ROUTE_BUILDER] Loading view: ${isExternal ? "GuestMeetingVideoView" : "MeetingVideoConferenceView"}',
        );

        // Use guest view for external participants
        if (isExternal) {
          return GuestMeetingVideoView(
            meetingId: meetingId,
            meetingTitle: extra?['meetingTitle'] ?? 'Meeting',
            selectedCamera: extra?['selectedCamera'],
            selectedMicrophone: extra?['selectedMicrophone'],
          );
        }

        // For authenticated users, wrap in AppLayout
        return AppLayout(
          child: MeetingVideoConferenceView(
            meetingId: meetingId,
            meetingTitle: extra?['meetingTitle'] ?? 'Meeting',
            selectedCamera: extra?['selectedCamera'],
            selectedMicrophone: extra?['selectedMicrophone'],
          ),
        );
      },
    ),
  ];
}

/// Returns meeting routes for authenticated users (inside ShellRoute)
/// These routes are available to logged-in users on both web and native platforms
List<GoRoute> getMeetingRoutes() {
  return [
    GoRoute(
      path: '/app/meetings',
      builder: (context, state) => const MeetingsScreen(),
    ),
    GoRoute(
      path: '/meeting/prejoin/:meetingId',
      redirect: (context, state) async {
        final meetingId = state.pathParameters['meetingId']!;
        final hasAccess = await MeetingAuthorizationService.instance
            .checkMeetingAccess(meetingId);
        if (!hasAccess) {
          debugPrint('[ROUTER] ❌ Unauthorized access to meeting: $meetingId');
          return '/app/meetings';
        }
        return null;
      },
      builder: (context, state) {
        final meetingId = state.pathParameters['meetingId']!;
        return MeetingPreJoinView(meetingId: meetingId);
      },
    ),
    // Native meeting video route (inside ShellRoute, no guest support)
    if (!kIsWeb)
      GoRoute(
        path: '/meeting/video/:meetingId',
        redirect: (context, state) async {
          final meetingId = state.pathParameters['meetingId']!;
          final extra = state.extra as Map<String, dynamic>?;
          final isExternal =
              extra?['isExternal'] == true ||
              state.uri.queryParameters['external'] == 'true';

          // Skip auth check for external guests
          if (isExternal) {
            return null;
          }

          // Check authorization for authenticated users
          final hasAccess = await MeetingAuthorizationService.instance
              .checkMeetingAccess(meetingId);
          if (!hasAccess) {
            debugPrint('[ROUTER] ❌ Unauthorized access to meeting: $meetingId');
            return '/app/meetings';
          }
          return null;
        },
        builder: (context, state) {
          final meetingId = state.pathParameters['meetingId']!;
          final extra = state.extra as Map<String, dynamic>?;
          final isExternal =
              extra?['isExternal'] == true ||
              state.uri.queryParameters['external'] == 'true';

          // Use guest view for external participants (rare on native)
          if (isExternal) {
            return GuestMeetingVideoView(
              meetingId: meetingId,
              meetingTitle: extra?['meetingTitle'] ?? 'Meeting',
              selectedCamera: extra?['selectedCamera'],
              selectedMicrophone: extra?['selectedMicrophone'],
            );
          }

          // Use standard view for authenticated users
          return MeetingVideoConferenceView(
            meetingId: meetingId,
            meetingTitle: extra?['meetingTitle'] ?? 'Meeting',
            selectedCamera: extra?['selectedCamera'],
            selectedMicrophone: extra?['selectedMicrophone'],
          );
        },
      ),
  ];
}
