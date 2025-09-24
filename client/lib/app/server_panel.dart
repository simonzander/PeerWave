import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service_native.dart';
import '../services/clientid_native.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class ServerPanel extends StatefulWidget {
  final void Function()? onAddServer;

  const ServerPanel({
    super.key,
    required this.onAddServer,
  });

  @override
  State<ServerPanel> createState() => _ServerPanelState();
}

class _ServerPanelState extends State<ServerPanel> {
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

  Future<void> _loadServers() async {
    final hostMailList = await AuthService().getHostMailList(); // [{host: ..., mail: ...}, ...]
    final List<_ServerMeta> loaded = [];
    for (final entry in hostMailList) {
      final host = entry['host'] ?? '';
      final mail = entry['mail'] ?? '';
      await _tryLoadServer(host, mail, loaded, true);
    }
    setState(() {
      servers = loaded;
    });
  }

  Future<void> _tryLoadServer(String host, String mail, List<_ServerMeta> loaded, bool add) async {
    try {
      final uri = Uri.parse('$host/client/meta');
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final meta = jsonDecode(resp.body);
        final loginResp = await http.post(
          Uri.parse('$host/client/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'clientid': await ClientIdService.getClientId(),
            'email': mail,
          }),
        );
        if(loginResp.statusCode == 200) {
          // Successfully logged in
          if (add) {
            loaded.add(_ServerMeta(
              host: host,
              mail: mail,
              name: meta['name'] ?? host,
              hasServerError: false,
              hasAuthError: false,
              missedNotifications: meta['missedNotifications'] ?? 0,
            ));
          }
          final socket = IO.io(host, <String, dynamic>{
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
              if(data.authenticated == true) {
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
          loaded.add(_ServerMeta(
            host: host,
            mail: mail,
            name: host,
            hasServerError: false,
            hasAuthError: true,
            missedNotifications: 0,
          ));
          }
        }
      } else {
        if (add) {
        loaded.add(_ServerMeta(
          host: host,
          mail: mail,
          name: host,
          hasServerError: true,
          hasAuthError: false,
          missedNotifications: 0,
        ));
        }
      }
    } catch (e) {
      if (add) {
      loaded.add(_ServerMeta(
        host: host,
        mail: mail,
        name: host,
        hasServerError: true,
        hasAuthError: false,
        missedNotifications: 0,
      ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: const Color(0xFF202225),
      child: Column(
        children: [
          const SizedBox(height: 16),
          ...servers.map((server) => _ServerIcon(server: server)).toList(),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.add_circle, color: Colors.white, size: 36),
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

  _ServerMeta({
    required this.host,
    required this.mail,
    required this.name,
    required this.hasServerError,
    required this.hasAuthError,
    required this.missedNotifications,
  });
}

class _ServerIcon extends StatelessWidget {
  final _ServerMeta server;

  const _ServerIcon({required this.server});

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
                  GoRouter.of(context).go('/login');
                }
                if(server.hasServerError) {
                  // Try to reload server meta and status
                  final parentState = context.findAncestorStateOfType<_ServerPanelState>();
                  if (parentState != null) {
                    parentState._tryLoadServer(server.host, server.mail, parentState.servers, false);
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Cannot connect to server: ${server.host}. Try to reconnect.')),
                  );
                }
              },
              onSecondaryTapDown: (details) async {
                // Show context menu on right click
                final parentState = context.findAncestorStateOfType<_ServerPanelState>();
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
                    final parentState = context.findAncestorStateOfType<_ServerPanelState>();
                    if (parentState != null) {
                      parentState.setState(() {
                        final idx = parentState.servers.indexWhere((s) => s.host == server.host);
                        if (idx != -1) {
                          final s = parentState.servers[idx];
                          parentState.servers[idx] = _ServerMeta(
                            host: s.host,
                            mail: s.mail,
                            name: s.name,
                            hasServerError: s.hasServerError,
                            hasAuthError: true,
                            missedNotifications: s.missedNotifications,
                          );
                        }
                      });
                    }
                    //GoRouter.of(context).go('/login');
                  }
                }
              },
              child: CircleAvatar(
                radius: 28,
                backgroundColor: server.hasServerError ? Colors.red[200] : Colors.blue[400],
                child: Icon(Icons.cloud, color: Colors.white),
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
                  backgroundColor: Colors.yellow[700],
                  child: Icon(Icons.warning, color: Colors.black, size: 14),
                )
              : (server.missedNotifications > 0
                  ? CircleAvatar(
                      radius: 10,
                      backgroundColor: Colors.orange,
                      child: Text(
                        '${server.missedNotifications}',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    )
                  : const SizedBox.shrink()),
        ),
      ],
    );
  }
}