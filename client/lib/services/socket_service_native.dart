import 'package:flutter/foundation.dart' show debugPrint;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'signal_service.dart';
import 'server_config_native.dart';
import 'auth_service_native.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart';

/// Native multi-server socket service
/// Manages separate socket connections for each configured server
/// Implements automatic reconnection with exponential backoff (up to 5 minutes)
class SocketServiceNative {
  static final SocketServiceNative _instance = SocketServiceNative._internal();
  factory SocketServiceNative() => _instance;
  SocketServiceNative._internal();

  // Map of server ID -> socket connection
  final Map<String, IO.Socket> _sockets = {};
  
  // Map of server ID -> event listeners
  final Map<String, Map<String, List<void Function(dynamic)>>> _listeners = {};
  
  // Map of server ID -> ready state
  final Map<String, bool> _readyStates = {};
  
  // Map of server ID -> connecting state
  final Map<String, bool> _connectingStates = {};
  
  // Map of server ID -> reconnection attempt count
  final Map<String, int> _reconnectAttempts = {};
  
  // Currently active server ID
  String? _activeServerId;
  
  // Unauthorized callback for logout
  void Function()? _unauthorizedCallback;
  
  /// Set the unauthorized callback (for auto-logout)
  void setUnauthorizedCallback(void Function() callback) {
    _unauthorizedCallback = callback;
  }
  
  /// Get the active server ID
  String? get activeServerId => _activeServerId;
  
  /// Set the active server and ensure it's connected
  Future<void> setActiveServer(String serverId) async {
    _activeServerId = serverId;
    
    // Ensure socket is connected for active server
    if (!isConnected(serverId)) {
      await connectServer(serverId);
    }
    
    debugPrint('[SOCKET SERVICE NATIVE] Active server set to: $serverId');
  }
  
  /// Connect to a specific server
  Future<void> connectServer(String serverId) async {
    final server = ServerConfigService.getServerById(serverId);
    if (server == null) {
      debugPrint('[SOCKET SERVICE NATIVE] Server not found: $serverId');
      return;
    }
    
    // Skip if already connected
    if (_sockets[serverId]?.connected ?? false) {
      debugPrint('[SOCKET SERVICE NATIVE] Already connected to: ${server.getDisplayName()}');
      return;
    }
    
    // Skip if already connecting
    if (_connectingStates[serverId] ?? false) {
      debugPrint('[SOCKET SERVICE NATIVE] Already connecting to: ${server.getDisplayName()}');
      return;
    }
    
    _connectingStates[serverId] = true;
    
    try {
      debugPrint('[SOCKET SERVICE NATIVE] Connecting to: ${server.getDisplayName()}');
      
      // Create socket connection
      final socket = IO.io(server.serverUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
        'reconnection': true,
        'reconnectionDelay': _getReconnectionDelay(serverId),
        'reconnectionDelayMax': 300000, // Max 5 minutes
        'reconnectionAttempts': 999999, // Essentially infinite
        'withCredentials': true,
      });
      
      // Setup event handlers
      _setupSocketHandlers(serverId, socket, server);
      
      // Register existing listeners
      final listeners = _listeners[serverId];
      if (listeners != null) {
        listeners.forEach((event, callbacks) {
          for (var cb in callbacks) {
            socket.on(event, cb);
          }
        });
      }
      
      // Store socket and connect
      _sockets[serverId] = socket;
      socket.connect();
      
    } catch (e) {
      debugPrint('[SOCKET SERVICE NATIVE] Error connecting to server: $e');
      _connectingStates[serverId] = false;
      _incrementReconnectAttempt(serverId);
    }
  }
  
  /// Setup event handlers for a socket
  void _setupSocketHandlers(String serverId, IO.Socket socket, ServerConfig server) {
    socket.on('connect', (_) async {
      debugPrint('[SOCKET SERVICE NATIVE] Connected to: ${server.getDisplayName()}');
      _connectingStates[serverId] = false;
      _reconnectAttempts[serverId] = 0; // Reset on successful connect
      
      // Get client ID and generate auth headers
      try {
        final clientId = await ClientIdService.getClientId();
        final hasSession = await SessionAuthService().hasSession(clientId);
        
        if (hasSession) {
          // Generate auth headers for socket authentication
          final authHeaders = await SessionAuthService().generateAuthHeaders(
            clientId: clientId,
            requestPath: '/socket.io/auth',
            requestBody: null,
          );
          
          // Authenticate with session headers
          socket.emit('authenticate', authHeaders);
        } else {
          // Fallback to basic authentication
          socket.emit('authenticate', null);
        }
      } catch (e) {
        debugPrint('[SOCKET SERVICE NATIVE] Error generating auth headers: $e');
        socket.emit('authenticate', null);
      }
    });
    
    socket.on('authenticated', (data) {
      debugPrint('[SOCKET SERVICE NATIVE] Authenticated with: ${server.getDisplayName()}');
      
      // Check for authentication failure
      if (data is Map && data['authenticated'] == false) {
        if (AuthService.isLoggedIn) {
          debugPrint('[SOCKET SERVICE NATIVE] ⚠️ Authentication failed - triggering logout');
          _unauthorizedCallback?.call();
        }
        return;
      }
      
      // Store user info for signal service
      if (data is Map && data['authenticated'] == true && data['uuid'] != null && data['deviceId'] != null) {
        final deviceId = data['deviceId'] is int
            ? data['deviceId'] as int
            : int.parse(data['deviceId'].toString());
        SignalService.instance.setCurrentUserInfo(data['uuid'], deviceId);
      }
    });
    
    socket.on('disconnect', (reason) {
      debugPrint('[SOCKET SERVICE NATIVE] Disconnected from: ${server.getDisplayName()} - Reason: $reason');
      _readyStates[serverId] = false;
      _connectingStates[serverId] = false;
    });
    
    socket.on('reconnect', (attemptNumber) {
      debugPrint('[SOCKET SERVICE NATIVE] Reconnected to: ${server.getDisplayName()} after $attemptNumber attempts');
      _reconnectAttempts[serverId] = 0;
      
      // Re-authenticate
      socket.emit('authenticate', null);
    });
    
    socket.on('reconnect_attempt', (attemptNumber) {
      debugPrint('[SOCKET SERVICE NATIVE] Reconnecting to: ${server.getDisplayName()} (attempt $attemptNumber)');
      _incrementReconnectAttempt(serverId);
    });
    
    socket.on('unauthorized', (_) {
      if (AuthService.isLoggedIn) {
        debugPrint('[SOCKET SERVICE NATIVE] ⚠️ Unauthorized from: ${server.getDisplayName()}');
        _unauthorizedCallback?.call();
      }
    });
    
    socket.on('error', (data) {
      debugPrint('[SOCKET SERVICE NATIVE] Error from ${server.getDisplayName()}: $data');
      if (data is Map && (data['message']?.toString().contains('unauthorized') ?? false)) {
        if (AuthService.isLoggedIn) {
          _unauthorizedCallback?.call();
        }
      }
    });
  }
  
  /// Get reconnection delay with exponential backoff
  int _getReconnectionDelay(String serverId) {
    final attempts = _reconnectAttempts[serverId] ?? 0;
    
    // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s (4.2min), 300s (5min)
    final delay = (2000 * (1 << attempts.clamp(0, 7))).clamp(2000, 300000);
    
    return delay;
  }
  
  /// Increment reconnection attempt count
  void _incrementReconnectAttempt(String serverId) {
    _reconnectAttempts[serverId] = (_reconnectAttempts[serverId] ?? 0) + 1;
  }
  
  /// Disconnect from a specific server
  void disconnectServer(String serverId) {
    final socket = _sockets[serverId];
    if (socket != null) {
      debugPrint('[SOCKET SERVICE NATIVE] Disconnecting from server: $serverId');
      _readyStates[serverId] = false;
      socket.disconnect();
      _sockets.remove(serverId);
    }
    
    // Clean up state
    _connectingStates.remove(serverId);
    _reconnectAttempts.remove(serverId);
  }
  
  /// Disconnect from all servers
  void disconnectAll() {
    debugPrint('[SOCKET SERVICE NATIVE] Disconnecting from all servers');
    
    for (final serverId in _sockets.keys.toList()) {
      disconnectServer(serverId);
    }
    
    _listeners.clear();
    _readyStates.clear();
    _activeServerId = null;
  }
  
  /// Register a listener for a specific server and event
  void registerListener(String serverId, String event, void Function(dynamic) callback) {
    final serverListeners = _listeners.putIfAbsent(serverId, () => {});
    final callbacks = serverListeners.putIfAbsent(event, () => []);
    
    if (!callbacks.contains(callback)) {
      callbacks.add(callback);
      
      // Register with socket if it exists
      final socket = _sockets[serverId];
      if (socket != null) {
        socket.on(event, callback);
      }
    }
  }
  
  /// Unregister a listener
  void unregisterListener(String serverId, String event, void Function(dynamic) callback) {
    final serverListeners = _listeners[serverId];
    if (serverListeners != null) {
      serverListeners[event]?.remove(callback);
      
      // Unregister from socket if it exists
      final socket = _sockets[serverId];
      if (socket != null) {
        socket.off(event, callback);
      }
    }
  }
  
  /// Emit an event to the active server
  void emit(String event, dynamic data) {
    if (_activeServerId == null) {
      debugPrint('[SOCKET SERVICE NATIVE] No active server - cannot emit $event');
      return;
    }
    
    emitToServer(_activeServerId!, event, data);
  }
  
  /// Emit an event to a specific server
  void emitToServer(String serverId, String event, dynamic data) {
    final socket = _sockets[serverId];
    if (socket?.connected ?? false) {
      socket!.emit(event, data);
    } else {
      debugPrint('[SOCKET SERVICE NATIVE] Server $serverId not connected - cannot emit $event');
    }
  }
  
  /// Notify server that client is ready
  void notifyClientReady(String serverId) {
    final socket = _sockets[serverId];
    if (socket?.connected ?? false) {
      _readyStates[serverId] = true;
      debugPrint('[SOCKET SERVICE NATIVE] 🚀 Client ready for: $serverId');
      socket!.emit('clientReady', {
        'timestamp': DateTime.now().toIso8601String(),
      });
    } else {
      debugPrint('[SOCKET SERVICE NATIVE] Cannot notify ready - not connected to: $serverId');
    }
  }
  
  /// Reset ready state for a server
  void resetReadyState(String serverId) {
    _readyStates[serverId] = false;
    debugPrint('[SOCKET SERVICE NATIVE] Ready state reset for: $serverId');
  }
  
  /// Check if connected to a server
  bool isConnected(String serverId) {
    return _sockets[serverId]?.connected ?? false;
  }
  
  /// Check if client is ready for a server
  bool isReady(String serverId) {
    return _readyStates[serverId] ?? false;
  }
  
  /// Get socket for a server (needed by SocketFileClient)
  IO.Socket? getSocket(String serverId) {
    return _sockets[serverId];
  }
  
  /// Get active socket
  IO.Socket? get socket {
    if (_activeServerId == null) return null;
    return _sockets[_activeServerId];
  }
  
  /// Check if active server is connected
  bool get isActiveServerConnected {
    if (_activeServerId == null) return false;
    return _sockets[_activeServerId]?.connected ?? false;
  }
  
  /// Check if active server is ready
  bool get isActiveServerReady {
    if (_activeServerId == null) return false;
    return _readyStates[_activeServerId] ?? false;
  }
  
  /// Authenticate with a server
  void authenticate(String serverId) {
    final socket = _sockets[serverId];
    if (socket?.connected ?? false) {
      debugPrint('[SOCKET SERVICE NATIVE] Manually triggering authentication for: $serverId');
      socket!.emit('authenticate', null);
    }
  }
  
  /// Connect to all configured servers
  Future<void> connectAllServers() async {
    final servers = ServerConfigService.getAllServers();
    
    debugPrint('[SOCKET SERVICE NATIVE] Connecting to ${servers.length} servers');
    
    for (final server in servers) {
      await connectServer(server.id);
    }
  }
  
  /// Ensure active server from ServerConfigService
  Future<void> ensureActiveServer() async {
    final activeServer = ServerConfigService.getActiveServer();
    if (activeServer != null) {
      await setActiveServer(activeServer.id);
    }
  }
}
