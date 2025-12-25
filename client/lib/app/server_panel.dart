import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service_native.dart';
import '../services/clientid_native.dart';
import '../services/api_service.dart';
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as io;

class ServerPanel extends StatefulWidget {
  final void Function()? onAddServer;
  final BuildContext Function()? scaffoldContextProvider;

  const ServerPanel({
    super.key,
    required this.onAddServer,
    this.scaffoldContextProvider,
  });

  @override
  State<ServerPanel> createState() => _ServerPanelState();
}

class _ServerPanelState extends State<ServerPanel> {
  void _showSnackBar(String message) {
    final scaffoldContext = widget.scaffoldContextProvider?.call() ?? context;
    final messenger = ScaffoldMessenger.maybeOf(scaffoldContext);
    if (messenger != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _removeServer(String host) async {
    // Remove from persistent storage
    await AuthService().removeHost(host);
    setState(() {
      servers.removeWhere((s) => s.host == host);
    });
  }

  List<_ServerMeta> servers = [];

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  void _maybeNavigateToFirstServer() {
    if (servers.isNotEmpty) {
      final router = GoRouter.of(context);
      // Use ModalRoute to get current location
      final currentUri = GoRouterState.of(context).uri.toString();
      if (currentUri != '/dashboard') {
        router.go(
          '/dashboard',
          extra: {'socket': servers[0].socket, 'host': servers[0].host},
        );
      }
    }
  }

  Future<void> _loadServers() async {
    final hostMailList = await AuthService()
        .getHostMailList(); // [{host: ..., mail: ...}, ...]
    final List<_ServerMeta> loaded = [];
    for (final entry in hostMailList) {
      final host = entry['host'] ?? '';
      final mail = entry['mail'] ?? '';
      await tryLoadServer(host, mail, loaded, true);
    }
    setState(() {
      servers = loaded;
    });
    // After loading, navigate to first server if not already on dashboard
    _maybeNavigateToFirstServer();
  }

  Future<void> tryLoadServer(
    String host,
    String mail,
    List<_ServerMeta> loaded,
    bool add,
  ) async {
    try {
      // Get server meta
      final metaResp = await ApiService.get('/client/meta');
      if (metaResp.statusCode == 200) {
        final meta = metaResp.data is String
            ? jsonDecode(metaResp.data)
            : metaResp.data;
        // Login and persist session cookie
        final loginResp = await ApiService.post(
          '/client/login',
          data: {
            'clientid': await ClientIdService.getClientId(),
            'email': mail,
          },
        );
        if (loginResp.statusCode == 200) {
          // Successfully logged in
          if (add) {
            loaded.add(
              _ServerMeta(
                host: host,
                mail: mail,
                name: meta['name'] ?? host,
                hasServerError: false,
                hasAuthError: false,
                missedNotifications: meta['missedNotifications'] ?? 0,
              ),
            );
          }
          final socket = io.io(host, <String, dynamic>{
            'transports': ['websocket'],
            'autoConnect': true,
          });
          socket.on('connect', (_) async {
            setState(() {
              final idx = loaded.indexWhere((s) => s.host == host);
              if (idx != -1) {
                loaded[idx] = _ServerMeta(
                  host: host,
                  mail: mail,
                  name: meta['name'] ?? host,
                  hasServerError: false,
                  hasAuthError: false,
                  missedNotifications: meta['missedNotifications'] ?? 0,
                );
              }
            });

            socket.on('authenticated', (data) {
              if (data.authenticated == true) {
                debugPrint('Socket authenticated for $host');
                setState(() {
                  final idx = loaded.indexWhere((s) => s.host == host);
                  if (idx != -1) {
                    loaded[idx] = _ServerMeta(
                      host: host,
                      mail: mail,
                      name: meta['name'] ?? host,
                      hasServerError: false,
                      hasAuthError: false,
                      missedNotifications: meta['missedNotifications'] ?? 0,
                    );
                  }
                });
                socket.on('notification', (notif) {
                  setState(() {
                    final idx = loaded.indexWhere((s) => s.host == host);
                    if (idx != -1) {
                      final current = loaded[idx];
                      loaded[idx] = _ServerMeta(
                        host: current.host,
                        mail: current.mail,
                        name: current.name,
                        hasServerError: current.hasServerError,
                        hasAuthError: current.hasAuthError,
                        missedNotifications: current.missedNotifications + 1,
                        socket: current.socket,
                      );
                    }
                  });
                });
              } else {
                setState(() {
                  final idx = loaded.indexWhere((s) => s.host == host);
                  if (idx != -1) {
                    loaded[idx] = _ServerMeta(
                      host: host,
                      mail: mail,
                      name: meta['name'] ?? host,
                      hasServerError: false,
                      hasAuthError: true,
                      missedNotifications: meta['missedNotifications'] ?? 0,
                    );
                  }
                });
              }
            });

            socket.emit('authenticate');
          });
          socket.on('disconnect', (_) {
            setState(() {
              final idx = loaded.indexWhere((s) => s.host == host);
              if (idx != -1) {
                loaded[idx] = _ServerMeta(
                  host: host,
                  mail: mail,
                  name: meta['name'] ?? host,
                  hasServerError: true,
                  hasAuthError: false,
                  missedNotifications: meta['missedNotifications'] ?? 0,
                );
              }
            });
          });
          socket.connect();
        } else {
          if (add) {
            loaded.add(
              _ServerMeta(
                host: host,
                mail: mail,
                name: host,
                hasServerError: false,
                hasAuthError: true,
                missedNotifications: 0,
              ),
            );
          }
        }
      } else {
        if (add) {
          loaded.add(
            _ServerMeta(
              host: host,
              mail: mail,
              name: host,
              hasServerError: true,
              hasAuthError: false,
              missedNotifications: 0,
            ),
          );
        }
      }
    } catch (e) {
      if (add) {
        loaded.add(
          _ServerMeta(
            host: host,
            mail: mail,
            name: host,
            hasServerError: true,
            hasAuthError: false,
            missedNotifications: 0,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 16),
          ...servers.map(
            (server) =>
                _ServerIcon(server: server, onShowSnackBar: _showSnackBar),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.add_circle,
              color: Theme.of(context).colorScheme.onSurface,
              size: 36,
            ),
            onPressed: () {
              GoRouter.of(context).go('/login');
            },
            tooltip: 'Add Server',
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ServerMeta {
  final String host;
  final String name;
  final String mail;
  final bool hasServerError;
  final bool hasAuthError;
  final int missedNotifications;
  final io.Socket? socket;

  _ServerMeta({
    required this.host,
    required this.mail,
    required this.name,
    required this.hasServerError,
    required this.hasAuthError,
    required this.missedNotifications,
    this.socket,
  });
}

class _ServerIcon extends StatelessWidget {
  final _ServerMeta server;
  final void Function(String message)? onShowSnackBar;

  const _ServerIcon({required this.server, this.onShowSnackBar});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Tooltip(
          message: server.name,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: GestureDetector(
              onTap: () {
                if (server.hasAuthError) {
                  if (onShowSnackBar != null) {
                    onShowSnackBar!(
                      'Authentication error: ${server.host}. Please re-authenticate.',
                    );
                  }
                  GoRouter.of(
                    context,
                  ).go('/login', extra: {'host': server.host});
                }
                if (server.hasServerError) {
                  // Try to reload server meta and status
                  final parentState = context
                      .findAncestorStateOfType<_ServerPanelState>();
                  if (parentState != null) {
                    parentState.tryLoadServer(
                      server.host,
                      server.mail,
                      parentState.servers,
                      false,
                    );
                  }
                  if (onShowSnackBar != null) {
                    onShowSnackBar!(
                      'Cannot connect to server: ${server.host}. Try to reconnect.',
                    );
                  }
                }
                if (!server.hasAuthError && !server.hasServerError) {
                  GoRouter.of(context).go(
                    '/dashboard',
                    extra: {'socket': server.socket, 'host': server.host},
                  );
                }
              },
              onSecondaryTapDown: (details) async {
                // Show context menu on right click
                final parentState = context
                    .findAncestorStateOfType<_ServerPanelState>();
                if (parentState != null) {
                  final selected = await showMenu<String>(
                    context: context,
                    position: RelativeRect.fromLTRB(
                      details.globalPosition.dx,
                      details.globalPosition.dy,
                      details.globalPosition.dx,
                      details.globalPosition.dy,
                    ),
                    items: [
                      const PopupMenuItem<String>(
                        value: 'logout',
                        child: Text('Logout'),
                      ),
                      const PopupMenuItem<String>(
                        value: 'remove',
                        child: Text('Remove Server'),
                      ),
                    ],
                  );
                  if (selected == 'remove') {
                    parentState._removeServer(server.host);
                  }
                  if (selected == 'logout') {
                    await AuthService().removeMailFromHost(server.host);
                    if (!context.mounted) return;
                    final parentState = context
                        .findAncestorStateOfType<_ServerPanelState>();
                    if (parentState != null) {
                      final idx = parentState.servers.indexWhere(
                        (s) => s.host == server.host,
                      );
                      if (idx != -1) {
                        final s = parentState.servers[idx];
                        parentState.servers[idx] = _ServerMeta(
                          host: s.host,
                          mail: s.mail,
                          name: s.name,
                          hasServerError: s.hasServerError,
                          hasAuthError: true,
                          missedNotifications: s.missedNotifications,
                          socket: s.socket,
                        );
                      }
                      parentState._loadServers(); // Trigger rebuild
                    }
                    //GoRouter.of(context).go('/login');
                  }
                }
              },
              child: CircleAvatar(
                radius: 28,
                backgroundColor: server.hasServerError
                    ? Theme.of(context).colorScheme.error.withValues(alpha: 0.3)
                    : Theme.of(context).colorScheme.primary,
                child: Icon(
                  Icons.cloud,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
        // Badge in the top-right corner
        Positioned(
          right: 0,
          top: 0,
          child: server.hasAuthError || server.hasServerError
              ? CircleAvatar(
                  radius: 10,
                  backgroundColor: Colors.amber.shade600,
                  child: Icon(
                    Icons.warning,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 14,
                  ),
                )
              : (server.missedNotifications > 0
                    ? CircleAvatar(
                        radius: 10,
                        backgroundColor: Colors.orange,
                        child: Text(
                          '${server.missedNotifications}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : const SizedBox.shrink()),
        ),
      ],
    );
  }
}
