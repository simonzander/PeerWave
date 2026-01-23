import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

// View Pages
import '../../app/views/activities_view_page.dart';
import '../../app/views/messages_view_page.dart';
import '../../app/views/channels_view_page.dart';
import '../../app/views/people_view_page.dart';
import '../../app/views/files_view_page.dart';
import '../../app/dashboard_page.dart';

// Services
import '../../web_config.dart';
import '../../services/server_config_native.dart'
    if (dart.library.js) '../../services/server_config_web.dart';

/// Returns the main app view routes for web platform
/// These routes handle the primary dashboard views (activities, messages, channels, people, files)
List<GoRoute> getAppRoutesWeb() {
  return [
    GoRoute(path: '/app', redirect: (context, state) => '/app/activities'),
    GoRoute(
      path: '/app/activities',
      builder: (context, state) {
        return FutureBuilder<String?>(
          future: loadWebApiServer(),
          builder: (context, snapshot) {
            final host = snapshot.data ?? 'localhost:3000';
            return ActivitiesViewPage(host: host);
          },
        );
      },
    ),
    GoRoute(
      path: '/app/messages/:id',
      builder: (context, state) {
        final contactUuid = state.pathParameters['id'];
        final extra = state.extra as Map<String, dynamic>?;
        final host = extra?['host'] as String? ?? 'localhost:3000';
        final displayName = extra?['displayName'] as String? ?? 'Unknown';

        return MessagesViewPage(
          host: host,
          initialContactUuid: contactUuid,
          initialDisplayName: displayName,
        );
      },
    ),
    GoRoute(
      path: '/app/messages',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final host = extra?['host'] as String? ?? 'localhost:3000';

        return MessagesViewPage(
          host: host,
          initialContactUuid: null,
          initialDisplayName: null,
        );
      },
    ),
    GoRoute(
      path: '/app/messages/:uuid',
      builder: (context, state) {
        final contactUuid = state.pathParameters['uuid'];
        final extra = state.extra as Map<String, dynamic>?;
        final host = extra?['host'] as String? ?? 'localhost:3000';
        final displayName = extra?['displayName'] as String? ?? 'Unknown';

        return MessagesViewPage(
          host: host,
          initialContactUuid: contactUuid,
          initialDisplayName: displayName,
        );
      },
    ),
    GoRoute(
      path: '/app/channels/:id',
      builder: (context, state) {
        final channelUuid = state.pathParameters['id'];
        final extra = state.extra as Map<String, dynamic>?;
        final host = extra?['host'] as String? ?? 'localhost:3000';
        final name = extra?['name'] as String? ?? 'Unknown';
        final type = extra?['type'] as String? ?? 'public';

        return ChannelsViewPage(
          host: host,
          initialChannelUuid: channelUuid,
          initialChannelName: name,
          initialChannelType: type,
        );
      },
    ),
    GoRoute(
      path: '/app/channels',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final host = extra?['host'] as String? ?? 'localhost:3000';

        return ChannelsViewPage(
          host: host,
          initialChannelUuid: null,
          initialChannelName: null,
          initialChannelType: null,
        );
      },
    ),
    GoRoute(
      path: '/app/people',
      builder: (context, state) {
        return FutureBuilder<String?>(
          future: loadWebApiServer(),
          builder: (context, snapshot) {
            final host = snapshot.data ?? 'localhost:3000';
            return PeopleViewPage(host: host);
          },
        );
      },
    ),
    GoRoute(
      path: '/app/files',
      builder: (context, state) {
        return FutureBuilder<String?>(
          future: loadWebApiServer(),
          builder: (context, snapshot) {
            final host = snapshot.data ?? 'localhost:3000';
            return FilesViewPage(host: host);
          },
        );
      },
    ),
  ];
}

/// Returns the main app view routes for native platform
/// These routes handle the primary dashboard views with server config support
List<GoRoute> getAppRoutesNative() {
  return [
    GoRoute(
      path: '/dashboard',
      pageBuilder: (context, state) {
        return const MaterialPage(child: DashboardPage());
      },
    ),
    GoRoute(path: '/app', builder: (context, state) => const SizedBox.shrink()),
    GoRoute(
      path: '/app/channels/:id',
      builder: (context, state) {
        final channelUuid = state.pathParameters['id'];
        final extra = state.extra as Map<String, dynamic>?;
        final server = ServerConfigService.getActiveServer();
        final host =
            extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';
        final name = extra?['name'] as String? ?? 'Unknown';
        final type = extra?['type'] as String? ?? 'public';

        return ChannelsViewPage(
          host: host,
          initialChannelUuid: channelUuid,
          initialChannelName: name,
          initialChannelType: type,
        );
      },
    ),
    GoRoute(
      path: '/app/channels',
      builder: (context, state) {
        final server = ServerConfigService.getActiveServer();
        final extra = state.extra as Map<String, dynamic>?;
        final host =
            extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';

        return ChannelsViewPage(
          host: host,
          initialChannelUuid: null,
          initialChannelName: null,
          initialChannelType: null,
        );
      },
    ),
    GoRoute(
      path: '/app/messages/:id',
      builder: (context, state) {
        final contactUuid = state.pathParameters['id'];
        final extra = state.extra as Map<String, dynamic>?;
        final server = ServerConfigService.getActiveServer();
        final host =
            extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';
        final displayName = extra?['displayName'] as String? ?? 'Unknown';

        return MessagesViewPage(
          host: host,
          initialContactUuid: contactUuid,
          initialDisplayName: displayName,
        );
      },
    ),
    GoRoute(
      path: '/app/messages',
      builder: (context, state) {
        final server = ServerConfigService.getActiveServer();
        final extra = state.extra as Map<String, dynamic>?;
        final host =
            extra?['host'] as String? ?? server?.serverUrl ?? 'localhost:3000';

        return MessagesViewPage(
          host: host,
          initialContactUuid: null,
          initialDisplayName: null,
        );
      },
    ),
    GoRoute(
      path: '/app/activities',
      builder: (context, state) {
        final server = ServerConfigService.getActiveServer();
        return ActivitiesViewPage(host: server?.serverUrl ?? 'localhost:3000');
      },
    ),
    GoRoute(
      path: '/app/people',
      builder: (context, state) {
        final server = ServerConfigService.getActiveServer();
        return PeopleViewPage(host: server?.serverUrl ?? 'localhost:3000');
      },
    ),
    GoRoute(
      path: '/app/files',
      builder: (context, state) {
        final server = ServerConfigService.getActiveServer();
        return FilesViewPage(host: server?.serverUrl ?? 'localhost:3000');
      },
    ),
  ];
}
