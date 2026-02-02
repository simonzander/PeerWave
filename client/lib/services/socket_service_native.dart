import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../core/metrics/network_metrics.dart';
import 'server_config_native.dart';
import 'auth_service_native.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart';

/// Callback for handling socket unauthorized events
typedef SocketUnauthorizedCallback = void Function();

/// Global callback for socket unauthorized handling
SocketUnauthorizedCallback? _socketUnauthorizedCallback;

/// Set global socket unauthorized handler
void setSocketUnauthorizedHandler(SocketUnauthorizedCallback callback) {
  _socketUnauthorizedCallback = callback;
}

/// Multi-server socket service - maintains connections to ALL configured servers
/// Receives notifications from all servers while user actively uses one
class SocketService {
  static final SocketService _instance = SocketService._internal();
  static SocketService get instance => _instance;

  // Map of serverId -> Socket instance (one socket per server)
  final Map<String, io.Socket> _sockets = {};
  final Map<String, bool> _serverConnecting = {};
  final Map<String, bool> _serverListenersRegistered = {};
  final Map<String, bool> _serverIsConnected = {};
  final Map<String, Completer<void>?> _serverConnectionCompleters = {};

  String? _activeServerId; // Which server is currently active in UI

  // Named listener storage: registrationName -> (eventName, originalCallback)
  final Map<String, Map<String, Function(dynamic)>> _namedListeners = {};

  // Track wrapped callbacks per socket: serverId -> eventName -> registrationName -> wrappedCallback
  final Map<String, Map<String, Map<String, Function(dynamic)>>>
  _socketCallbacks = {};

  /// Private constructor for singleton
  SocketService._internal() {
    debugPrint(
      '[SOCKET SERVICE] 🏗️ Creating singleton instance (native multi-server)',
    );
  }

  // Get socket for active server
  io.Socket? get socket {
    if (_activeServerId == null) {
      debugPrint('[SOCKET SERVICE] socket getter: _activeServerId is null');
      return null;
    }

    final socket = _sockets[_activeServerId];
    if (socket == null) {
      debugPrint(
        '[SOCKET SERVICE] socket getter: No socket for activeServerId=$_activeServerId '
        '(available servers: ${_sockets.keys.toList()})',
      );
    }

    return socket;
  }

  bool get isReady =>
      _activeServerId != null &&
      (_serverListenersRegistered[_activeServerId] ?? false) &&
      (_sockets[_activeServerId]?.connected ?? false);

  bool get isConnected {
    if (_activeServerId == null) {
      debugPrint(
        '[SOCKET SERVICE] isConnected: false (_activeServerId is null)',
      );
      return false;
    }

    final socket = _sockets[_activeServerId];
    final socketConnected = socket?.connected ?? false;
    final internalConnected = _serverIsConnected[_activeServerId] ?? false;

    final result = internalConnected && socketConnected;

    if (!result) {
      debugPrint(
        '[SOCKET SERVICE] isConnected: false (serverId: $_activeServerId, '
        'socketConnected: $socketConnected, internalConnected: $internalConnected)',
      );
    }

    return result;
  }

  /// Connect to ALL configured servers (for background notifications)
  Future<void> connectAllServers() async {
    final servers = ServerConfigService.getAllServers();
    debugPrint('[SOCKET SERVICE] Connecting to ${servers.length} servers...');

    final activeServer = ServerConfigService.getActiveServer();
    if (activeServer != null) {
      _activeServerId = activeServer.id;
    }

    for (final server in servers) {
      try {
        await _connectToServer(server);
      } catch (e) {
        debugPrint(
          '[SOCKET SERVICE] Failed to connect to ${server.serverUrl}: $e',
        );
      }
    }
  }

  /// Set which server is currently active (for UI interactions)
  void setActiveServer(String serverId) {
    debugPrint('[SOCKET SERVICE] Setting active server: $serverId');
    _activeServerId = serverId;
  }

  /// Connect to active server only (legacy compatibility)
  Future<void> connect() async {
    final activeServer = ServerConfigService.getActiveServer();
    if (activeServer == null) {
      debugPrint('[SOCKET SERVICE] No active server configured');
      return;
    }

    _activeServerId = activeServer.id;
    await _connectToServer(activeServer);
  }

  /// Connect to a specific server
  Future<void> _connectToServer(ServerConfig server) async {
    final serverId = server.id;

    // Check if already connected
    final existingSocket = _sockets[serverId];
    if (existingSocket?.connected ?? false) {
      debugPrint(
        '[SOCKET SERVICE] Already connected to ${server.serverUrl} '
        '(serverId: $serverId, activeServerId: $_activeServerId)',
      );

      // Ensure internal state is consistent with actual socket state
      final currentInternalState = _serverIsConnected[serverId] ?? false;
      final currentListenersState =
          _serverListenersRegistered[serverId] ?? false;

      debugPrint(
        '[SOCKET SERVICE] State check: internalConnected=$currentInternalState, '
        'listenersRegistered=$currentListenersState',
      );

      if (!currentInternalState) {
        debugPrint(
          '[SOCKET SERVICE] ⚠️ Socket connected but internal state was false, updating...',
        );
        _serverIsConnected[serverId] = true;

        // Trigger clientReady if listeners not registered
        if (!currentListenersState) {
          debugPrint(
            '[SOCKET SERVICE] ⚠️ Triggering clientReady for already-connected socket...',
          );
          // Set the server as active temporarily to send clientReady
          final previousActiveServer = _activeServerId;
          _activeServerId = serverId;
          notifyClientReady();
          // Restore previous active server if different
          if (previousActiveServer != null &&
              previousActiveServer != serverId) {
            _activeServerId = previousActiveServer;
          }
        }
      }

      return;
    }

    // Check if connection in progress
    if (_serverConnecting[serverId] == true) {
      debugPrint(
        '[SOCKET SERVICE] Connection to ${server.serverUrl} in progress, waiting...',
      );
      await _serverConnectionCompleters[serverId]?.future;
      return;
    }

    _serverConnecting[serverId] = true;
    _serverConnectionCompleters[serverId] = Completer<void>();

    try {
      debugPrint(
        '[SOCKET SERVICE] Connecting to: ${server.serverUrl} (id: $serverId)',
      );

      String urlString = server.serverUrl;
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }

      final socket = io.io(urlString, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
        'reconnection': true,
        'reconnectionDelay': 2000,
        'reconnectionAttempts': 5,
        'forceNew': false,
        'timeout': 20000,
      });

      _sockets[serverId] = socket;

      socket.on('connect', (_) async {
        debugPrint('[SOCKET SERVICE] ✅ Connected to ${server.serverUrl}');
        _serverIsConnected[serverId] = true;
        await _authenticateServer(serverId, server);
      });

      socket.on('authenticated', (data) {
        debugPrint('[SOCKET SERVICE] ✅ Authenticated to ${server.serverUrl}');
        _handleAuthenticated(serverId, data);

        if (data is Map && data['authenticated'] == true) {
          if (!(_serverConnectionCompleters[serverId]?.isCompleted ?? true)) {
            _serverConnectionCompleters[serverId]?.complete();
          }
        } else if (data is Map && data['authenticated'] == false) {
          if (!(_serverConnectionCompleters[serverId]?.isCompleted ?? true)) {
            _serverConnectionCompleters[serverId]?.completeError(
              'Authentication failed: ${data['error']}',
            );
          }
        }
      });

      socket.on('disconnect', (reason) {
        debugPrint(
          '[SOCKET SERVICE] ❌ Disconnected from ${server.serverUrl}: $reason',
        );
        _serverIsConnected[serverId] = false;
      });

      socket.on('reconnect', (_) async {
        debugPrint('[SOCKET SERVICE] 🔄 Reconnected to ${server.serverUrl}');
        await _authenticateServer(serverId, server);

        if (_serverListenersRegistered[serverId] ?? false) {
          socket.emit('clientReady', {
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      });

      socket.on('connect_error', (error) {
        debugPrint(
          '[SOCKET SERVICE] ⚠️ Connection error to ${server.serverUrl}: $error',
        );
      });

      socket.on('unauthorized', (_) {
        if (AuthService.isLoggedIn) {
          _socketUnauthorizedCallback?.call();
        }
      });

      socket.on('error', (data) {
        debugPrint(
          '[SOCKET SERVICE] ❌ Socket error on ${server.serverUrl}: $data',
        );
        if (!(_serverConnectionCompleters[serverId]?.isCompleted ?? true)) {
          _serverConnectionCompleters[serverId]?.completeError(
            'Socket error: $data',
          );
        }
      });

      // Initialize socket callbacks tracking for this server
      _socketCallbacks[serverId] = {};

      // Register all stored named listeners on this socket
      _namedListeners.forEach((registrationName, listenerInfo) {
        listenerInfo.forEach((event, originalCallback) {
          void wrappedCallback(dynamic data) {
            NetworkMetrics.recordSocketReceive(1);
            // Pass serverId context to callback
            if (data is Map) {
              originalCallback({'_serverId': serverId, ...data});
            } else {
              originalCallback({'_serverId': serverId, 'data': data});
            }
          }

          // Store wrapped callback for later removal
          _socketCallbacks[serverId]!.putIfAbsent(
            event,
            () => {},
          )[registrationName] = wrappedCallback;
          socket.on(event, wrappedCallback);

          debugPrint(
            '[SOCKET SERVICE] Registered [$registrationName] for event "$event" on ${server.serverUrl}',
          );
        });
      });

      debugPrint(
        '[SOCKET SERVICE] Starting socket connection to ${server.serverUrl}...',
      );
      socket.connect();

      // Wait for authentication (with timeout)
      await _serverConnectionCompleters[serverId]!.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          debugPrint(
            '[SOCKET SERVICE] ⏱️ Connection timeout to ${server.serverUrl}',
          );
          throw TimeoutException('Socket connection timeout');
        },
      );

      debugPrint(
        '[SOCKET SERVICE] ✅ Fully connected and authenticated to ${server.serverUrl}',
      );
    } catch (e) {
      debugPrint(
        '[SOCKET SERVICE] ❌ Connection error to ${server.serverUrl}: $e',
      );
      if (!(_serverConnectionCompleters[serverId]?.isCompleted ?? true)) {
        _serverConnectionCompleters[serverId]?.completeError(e);
      }
      rethrow;
    } finally {
      _serverConnecting[serverId] = false;
    }
  }

  void _handleAuthenticated(String serverId, dynamic data) {
    if (data is Map && data['authenticated'] == false) {
      if (AuthService.isLoggedIn) _socketUnauthorizedCallback?.call();
      return;
    }

    if (data is Map && data['authenticated'] == true) {
      // SignalClient gets user info via callbacks on initialization
      // No need to set it here via deprecated SignalService

      // Send clientReady if listeners are registered
      if (_serverListenersRegistered[serverId] ?? false) {
        final socket = _sockets[serverId];
        if (socket?.connected ?? false) {
          socket!.emit('clientReady', {
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      }
    }
  }

  Future<void> _authenticateServer(String serverId, ServerConfig server) async {
    try {
      final clientId = await ClientIdService.getClientId();
      final authHeaders = await SessionAuthService().generateAuthHeaders(
        clientId: clientId,
        requestPath: '/socket.io/auth',
        serverUrl: server.serverUrl,
        requestBody: null,
      );

      final socket = _sockets[serverId];
      socket?.emit('authenticate', authHeaders);
    } catch (e) {
      debugPrint('[SOCKET SERVICE] ❌ Auth error for ${server.serverUrl}: $e');
      rethrow;
    }
  }

  void disconnect() {
    // Clean up all named listeners
    _namedListeners.clear();
    _socketCallbacks.clear();

    // Disconnect all sockets
    _sockets.values.forEach((socket) => socket.disconnect());
    _sockets.clear();
    _serverConnecting.clear();
    _serverListenersRegistered.clear();
    _serverIsConnected.clear();
    _serverConnectionCompleters.clear();
    _activeServerId = null;
  }

  /// Register a named listener that works across all connected sockets
  /// [registrationName] - Unique name for this registration (e.g., "MessageListenerService", "SignalService")
  /// [event] - Socket event name to listen for
  /// [callback] - Callback function that will receive data with _serverId context
  void registerListener(
    String event,
    Function(dynamic) callback, {
    String registrationName = 'default',
  }) {
    // Store the named listener
    final listenerInfo = _namedListeners.putIfAbsent(
      registrationName,
      () => {},
    );

    // Check if this exact registration already exists
    if (listenerInfo.containsKey(event)) {
      debugPrint(
        '[SOCKET SERVICE] ⚠️ Listener [$registrationName] for event "$event" already registered, skipping',
      );
      return;
    }

    listenerInfo[event] = callback;
    debugPrint(
      '[SOCKET SERVICE] Registering named listener [$registrationName] for event "$event"',
    );

    // Register on ALL connected sockets
    _sockets.forEach((serverId, socket) {
      if (socket.connected) {
        void wrappedCallback(dynamic data) {
          NetworkMetrics.recordSocketReceive(1);
          // Pass serverId context
          if (data is Map) {
            callback({'_serverId': serverId, ...data});
          } else {
            callback({'_serverId': serverId, 'data': data});
          }
        }

        // Store wrapped callback for later removal
        _socketCallbacks.putIfAbsent(serverId, () => {});
        _socketCallbacks[serverId]!.putIfAbsent(
          event,
          () => {},
        )[registrationName] = wrappedCallback;
        socket.on(event, wrappedCallback);

        debugPrint(
          '[SOCKET SERVICE] Registered [$registrationName] for "$event" on server $serverId',
        );

        // Mark this server as having listeners registered
        if (!(_serverListenersRegistered[serverId] ?? false)) {
          _serverListenersRegistered[serverId] = true;
          // Send clientReady for this server
          socket.emit('clientReady', {
            'timestamp': DateTime.now().toIso8601String(),
          });
          debugPrint(
            '[SOCKET SERVICE] ✅ clientReady sent to server $serverId after first listener registration',
          );
        }
      }
    });
  }

  void notifyClientReady() {
    debugPrint('[SOCKET SERVICE] 📞 notifyClientReady called');

    // Mark active server as ready
    if (_activeServerId != null) {
      _serverListenersRegistered[_activeServerId!] = true;

      final socket = _sockets[_activeServerId];
      if (socket?.connected ?? false) {
        socket!.emit('clientReady', {
          'timestamp': DateTime.now().toIso8601String(),
        });
        debugPrint('[SOCKET SERVICE] ✅ clientReady sent to active server');
      }
    }
  }

  void resetReadyState() {
    if (_activeServerId != null) {
      _serverListenersRegistered[_activeServerId!] = false;
    }
  }

  /// Unregister a named listener from all sockets
  /// [registrationName] - The name used when registering
  /// [event] - Optional specific event to unregister (if null, unregisters all events for this name)
  void unregisterListener(String event, {String registrationName = 'default'}) {
    final listenerInfo = _namedListeners[registrationName];
    if (listenerInfo == null) {
      debugPrint(
        '[SOCKET SERVICE] No listener found with name [$registrationName]',
      );
      return;
    }

    // Remove from named listeners
    listenerInfo.remove(event);
    if (listenerInfo.isEmpty) {
      _namedListeners.remove(registrationName);
    }

    // Remove from all sockets
    _sockets.forEach((serverId, socket) {
      final serverCallbacks = _socketCallbacks[serverId];
      if (serverCallbacks != null) {
        final eventCallbacks = serverCallbacks[event];
        if (eventCallbacks != null) {
          final wrappedCallback = eventCallbacks[registrationName];
          if (wrappedCallback != null) {
            socket.off(event, wrappedCallback);
            eventCallbacks.remove(registrationName);
            debugPrint(
              '[SOCKET SERVICE] Unregistered [$registrationName] for "$event" from server $serverId',
            );
          }
        }
      }
    });
  }

  /// Unregister all events for a named registration
  void unregisterAllForName(String registrationName) {
    final listenerInfo = _namedListeners[registrationName];
    if (listenerInfo == null) return;

    final events = listenerInfo.keys.toList();
    for (final event in events) {
      unregisterListener(event, registrationName: registrationName);
    }
  }

  void emit(String event, dynamic data) {
    // Emit only to active server
    final socket = _sockets[_activeServerId];
    socket?.emit(event, data);
    NetworkMetrics.recordSocketEmit(1);
  }

  void authenticate() {
    // Re-authenticate active server
    if (_activeServerId != null) {
      final server = ServerConfigService.getAllServers().firstWhere(
        (s) => s.id == _activeServerId,
      );
      _authenticateServer(_activeServerId!, server);
    }
  }
}
