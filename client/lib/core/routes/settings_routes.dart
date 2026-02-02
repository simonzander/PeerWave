import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// Settings pages
import '../../app/settings_sidebar.dart';
import '../../app/profile_page.dart';
import '../../app/settings/general_settings_page.dart';
import '../../app/settings/server_settings_page.dart';
import '../../app/settings/sessions_page.dart';
import '../../app/settings/notification_settings_page.dart';
import '../../app/settings/voice_video_settings_page.dart';
import '../../app/settings/system_tray_settings_page.dart';
import '../../app/webauthn_page_wrapper.dart';
import '../../app/backupcode_settings_page.dart'
    if (dart.library.io) '../../app/backupcode_settings_page_native.dart';

// Admin pages
import '../../screens/admin/role_management_screen.dart';
import '../../screens/admin/user_management_screen.dart';
import '../../screens/settings/blocked_users_page.dart';
import '../../screens/settings/abuse_center_page.dart';

// Troubleshoot feature
import '../../features/troubleshoot/pages/troubleshoot_page.dart';
import '../../features/troubleshoot/state/troubleshoot_provider.dart';
import '../../services/troubleshoot/troubleshoot_service.dart';

// Role provider
import '../../providers/role_provider.dart';
import '../../services/server_settings_service.dart';
import 'package:flutter/material.dart';

/// Returns the settings routes wrapped in a ShellRoute with SettingsSidebar
/// This includes all settings-related pages accessible from the app settings menu
ShellRoute getSettingsRoutes() {
  return ShellRoute(
    builder: (context, state, child) => SettingsSidebar(child: child),
    routes: [
      GoRoute(
        path: '/app/settings',
        redirect: (context, state) => '/app/settings/general',
      ),
      GoRoute(
        path: '/app/settings/webauthn',
        builder: (context, state) => const WebauthnPageWrapper(),
      ),
      GoRoute(
        path: '/app/settings/backupcode/list',
        builder: (context, state) => const BackupCodeSettingsPage(),
      ),
      GoRoute(
        path: '/app/settings/general',
        builder: (context, state) => const GeneralSettingsPage(),
      ),
      GoRoute(
        path: '/app/settings/profile',
        builder: (context, state) => const ProfilePage(),
      ),
      GoRoute(
        path: '/app/settings/sessions',
        builder: (context, state) => const SessionsPage(),
      ),
      GoRoute(
        path: '/app/settings/notifications',
        builder: (context, state) => const NotificationSettingsPage(),
      ),
      GoRoute(
        path: '/app/settings/voice-video',
        builder: (context, state) => const VoiceVideoSettingsPage(),
      ),
      GoRoute(
        path: '/app/settings/server',
        builder: (context, state) => const ServerSettingsPage(),
        redirect: (context, state) {
          final roleProvider = context.read<RoleProvider>();
          if (!roleProvider.hasServerPermission('server.manage')) {
            return '/app/settings';
          }
          return null;
        },
      ),
      GoRoute(
        path: '/app/settings/troubleshoot',
        builder: (context, state) {
          // Use FutureBuilder to load SignalClient asynchronously
          return FutureBuilder(
            future: ServerSettingsService.instance.getOrCreateSignalClient(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Center(
                  child: Text('Error loading troubleshoot: ${snapshot.error}'),
                );
              }

              final signalClient = snapshot.data;
              if (signalClient == null) {
                return const Center(child: Text('SignalClient not available'));
              }

              const troubleshootService = TroubleshootService();

              return ChangeNotifierProvider(
                create: (_) =>
                    TroubleshootProvider(service: troubleshootService),
                child: const TroubleshootPage(),
              );
            },
          );
        },
      ),
      GoRoute(
        path: '/app/settings/system-tray',
        builder: (context, state) => const SystemTraySettingsPage(),
      ),
      GoRoute(
        path: '/app/settings/roles',
        builder: (context, state) => const RoleManagementScreen(),
        redirect: (context, state) {
          final roleProvider = context.read<RoleProvider>();
          if (!roleProvider.isAdmin) {
            return '/app/settings';
          }
          return null;
        },
      ),
      GoRoute(
        path: '/app/settings/users',
        builder: (context, state) => const UserManagementScreen(),
        redirect: (context, state) {
          final roleProvider = context.read<RoleProvider>();
          if (!roleProvider.hasServerPermission('user.manage')) {
            return '/app/settings';
          }
          return null;
        },
      ),
      GoRoute(
        path: '/app/settings/blocked-users',
        builder: (context, state) => const BlockedUsersPage(),
      ),
      GoRoute(
        path: '/app/settings/abuse-center',
        builder: (context, state) => const AbuseCenterPage(),
        redirect: (context, state) {
          final roleProvider = context.read<RoleProvider>();
          if (!roleProvider.hasServerPermission('server.manage')) {
            return '/app/settings';
          }
          return null;
        },
      ),
    ],
  );
}
