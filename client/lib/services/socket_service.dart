import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../web_config.dart';
import '../core/metrics/network_metrics.dart';
import 'signal_service.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart' if (dart.library.js) 'clientid_web.dart';
import 'server_connection_service.dart';
import 'server_config_web.dart'
    if (dart.library.io) 'server_config_native.dart';
// Import auth service conditionally
import 'auth_service_web.dart' if (dart.library.io) 'auth_service_native.dart';

/// Callback for handling socket unauthorized events
typedef SocketUnauthorizedCallback = void Function();

/// Global callback for socket unauthorized handling
SocketUnauthorizedCallback? _socketUnauthorizedCallback;

/// Set global socket unauthorized handler
void setSocketUnauthorizedHandler(SocketUnauthorizedCallback callback) {
  _socketUnauthorizedCallback = callback;
}

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() {
    debugPrint(
      '[SOCKET SERVICE] 🏭 Factory constructor called, returning instance: ${_instance.hashCode}',
    );
    return _instance;
  }
  SocketService._internal() {
    debugPrint(
      '[SOCKET SERVICE] 🏗️ Private constructor called, creating NEW instance',
    );
  }

  io.Socket? _socket;
  final Map<String, List<void Function(dynamic)>> _listeners = {};
  bool _connecting = false;
  bool _listenersRegistered = false; // 🔒 Track listener registration state
  bool _isConnected = false; // Internal connection state tracking

  // Named listener storage for compatibility with native multi-server API
  // On web, we only have one socket, but we track registrations by name
  final Map<String, Map<String, Function(dynamic)>> _namedListeners = {};
  final Map<String, Function(dynamic)> _wrappedCallbacks =
      {}; // event_registrationName -> wrappedCallback

  // Public getter for socket (needed by SocketFileClient)
  io.Socket? get socket => _socket;

  /// Check if listeners are registered and client is ready
  bool get isReady => _listenersRegistered && (_socket?.connected ?? false);

  /// Connect to all servers (web only supports single server - this is for API compatibility)
  Future<void> connectAllServers() async {
    debugPrint(
      '[SOCKET SERVICE] Web: connectAllServers called (single server mode)',
    );
    await connect();
  }

  Future<void> connect() async {
    // Check if socket exists and is truly connected
    if (_socket != null) {
      if (_socket!.connected) {
        debugPrint(
          '[SOCKET SERVICE] Socket already connected (id: ${_socket!.id})',
        );
        return;
      } else {
        // Socket exists but not connected - dispose and recreate
        debugPrint(
          '[SOCKET SERVICE] ⚠️ Socket exists but disconnected - disposing and reconnecting',
        );
        debugPrint('[SOCKET SERVICE] Stack trace: ${StackTrace.current}');
        _socket?.disconnect();
        _socket?.dispose();
        _socket = null;
      }
    }

    if (_connecting) return;
    _connecting = true;
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      _socket = io.io(urlString, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect':
            false, // Manually connect after setup to ensure cookies are ready
        'reconnection': true,
        'reconnectionDelay': 2000,
        'withCredentials': true, // Send cookies for session management
      });
      _socket!.on('connect', (_) {
        debugPrint(
          '[SOCKET SERVICE] ==========================================',
        );
        debugPrint('[SOCKET SERVICE] 🔌 Socket connected event fired');
        debugPrint(
          '[SOCKET SERVICE]    Socket object exists: ${_socket != null}',
        );
        debugPrint('[SOCKET SERVICE]    Socket ID: ${_socket?.id}');
        debugPrint(
          '[SOCKET SERVICE]    Stored listeners count: ${_listeners.length}',
        );
        debugPrint(
          '[SOCKET SERVICE] ==========================================',
        );

        // Set internal connection state
        _isConnected = true;

        // ✅ Report successful socket connection (only on native)
        if (!kIsWeb) {
          ServerConnectionService.instance.reportSuccess();
        }
        // Re-register all stored listeners on connect
        _reregisterAllListeners();
        // Authenticate with the server after connection
        _authenticateSocket();
      });
      _socket!.on('authenticated', (data) {
        debugPrint('[SOCKET SERVICE] Authentication response: $data');
        // Check if authentication failed
        if (data is Map && data['authenticated'] == false) {
          // Only trigger auto-logout if user is logged in
          if (AuthService.isLoggedIn) {
            debugPrint(
              '[SOCKET SERVICE] ⚠️  Authentication failed - triggering auto-logout',
            );
            _socketUnauthorizedCallback?.call();
          } else {
            debugPrint(
              '[SOCKET SERVICE] Authentication failed - user not logged in yet, ignoring',
            );
          }
          return;
        }
        // Store user info in SignalService for device filtering
        if (data is Map &&
            data['authenticated'] == true &&
            data['uuid'] != null &&
            data['deviceId'] != null) {
          // Parse deviceId as int (server sends String)
          final deviceId = data['deviceId'] is int
              ? data['deviceId'] as int
              : int.parse(data['deviceId'].toString());
          SignalService.instance.setCurrentUserInfo(data['uuid'], deviceId);
          debugPrint(
            '[SOCKET SERVICE] User info set, socket still connected: ${_socket?.connected}',
          );

          // 🚀 CRITICAL: If listeners are already registered, notify server immediately after auth
          if (_listenersRegistered) {
            debugPrint(
              '[SOCKET SERVICE] 🚀 Authentication complete & listeners registered - notifying server',
            );
            if (_socket?.connected ?? false) {
              _socket!.emit('clientReady', {
                'timestamp': DateTime.now().toIso8601String(),
              });
              debugPrint(
                '[SOCKET SERVICE] ✅ clientReady sent immediately after auth',
              );
            } else {
              debugPrint(
                '[SOCKET SERVICE] ⚠️ Socket not connected, cannot send clientReady yet',
              );
            }
          } else {
            debugPrint(
              '[SOCKET SERVICE] Authentication complete but listeners not yet registered - will notify when ready',
            );
          }
        }
      });
      _socket!.on('disconnect', (_) {
        debugPrint('[SOCKET SERVICE] Socket disconnected');
        _isConnected = false; // Update internal state
        resetReadyState(); // Reset ready state on disconnect
      });
      _socket!.on('reconnect', (_) {
        debugPrint('[SOCKET SERVICE] 🔄 Socket reconnected');
        // Re-register all stored listeners
        _reregisterAllListeners();
        // Re-authenticate after reconnection
        _authenticateSocket();
        // After successful reconnect and auth, notify ready if listeners were registered
        if (_listenersRegistered) {
          debugPrint(
            '[SOCKET SERVICE] 🔄 Reconnected - re-sending clientReady',
          );
          _socket!.emit('clientReady', {
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      });
      _socket!.on('reconnect_attempt', (_) {
        debugPrint('[SOCKET SERVICE] Socket reconnecting...');
      });
      // Listen for unauthorized/authentication errors
      _socket!.on('unauthorized', (_) {
        // ❌ Report socket error (only on native)
        if (!kIsWeb) {
          ServerConnectionService.instance.reportSocketError(
            'Socket unauthorized',
          );
        }
        // Only trigger auto-logout if user is logged in
        if (AuthService.isLoggedIn) {
          debugPrint(
            '[SOCKET SERVICE] ⚠️  Unauthorized - triggering auto-logout',
          );
          _socketUnauthorizedCallback?.call();
        } else {
          debugPrint(
            '[SOCKET SERVICE] Unauthorized - user not logged in yet, ignoring',
          );
        }
      });
      _socket!.on('error', (data) {
        debugPrint('[SOCKET SERVICE] Socket error: $data');
        // ❌ Report socket error (only on native)
        if (!kIsWeb) {
          ServerConnectionService.instance.reportSocketError(data);
        }
        if (data is Map &&
            (data['message']?.toString().contains('unauthorized') ?? false)) {
          // Only trigger auto-logout if user is logged in
          if (AuthService.isLoggedIn) {
            debugPrint(
              '[SOCKET SERVICE] ⚠️  Unauthorized error - triggering auto-logout',
            );
            _socketUnauthorizedCallback?.call();
          } else {
            debugPrint(
              '[SOCKET SERVICE] Unauthorized error - user not logged in yet, ignoring',
            );
          }
        }
      });
      // Register all listeners
      _listeners.forEach((event, callbacks) {
        for (var cb in callbacks) {
          _socket!.on(event, cb);
        }
      });

      // Manually connect after everything is set up
      debugPrint(
        '[SOCKET SERVICE] Manually connecting socket with credentials...',
      );
      _socket!.connect();
    } finally {
      _connecting = false;
    }
  }

  void disconnect() {
    debugPrint(
      '[SOCKET SERVICE] ⚠️ disconnect() called - setting socket to null',
    );
    debugPrint('[SOCKET SERVICE] Stack trace: ${StackTrace.current}');
    resetReadyState(); // Reset ready state before disconnect
    _namedListeners.clear();
    _wrappedCallbacks.clear();
    _socket?.disconnect();
    _socket = null;
  }

  /// Register a named listener (web single-socket version)
  /// [event] - Socket event name to listen for
  /// [callback] - Callback function
  /// [registrationName] - Optional unique name for this registration (for tracking/removal)
  void registerListener(
    String event,
    Function(dynamic) callback, {
    String registrationName = 'default',
  }) {
    // Debug: Check socket state
    debugPrint(
      '[SOCKET SERVICE] 🔍 registerListener($event) called - socket: ${_socket != null ? "EXISTS (id=${_socket!.id})" : "NULL"}',
    );

    // Store named listener
    final listenerInfo = _namedListeners.putIfAbsent(
      registrationName,
      () => {},
    );
    if (listenerInfo.containsKey(event)) {
      debugPrint(
        '[SOCKET SERVICE] ⚠️ Listener [$registrationName] for event "$event" already registered, skipping',
      );
      return;
    }
    listenerInfo[event] = callback;

    // Legacy listener storage (keep for _reregisterAllListeners)
    final callbacks = _listeners.putIfAbsent(event, () => []);
    if (!callbacks.contains(callback)) {
      // Wrap the callback to track socket receives
      void wrappedCallback(dynamic data) {
        NetworkMetrics.recordSocketReceive(1);
        callback(data);
      }

      // Store wrapped callback for removal
      _wrappedCallbacks['${event}_$registrationName'] = wrappedCallback;
      callbacks.add(callback);

      // Check socket state and register accordingly
      if (_socket == null) {
        // Socket doesn't exist yet - store for later registration
        debugPrint(
          '[SOCKET SERVICE] 📦 Socket is null, listener [$registrationName] for $event stored (will register on connect)',
        );
      } else {
        // Socket exists - register with wrapped callback
        _socket!.on(event, wrappedCallback);
        if (_socket!.connected) {
          debugPrint(
            '[SOCKET SERVICE] ✅ Registered listener [$registrationName] for $event (socket connected)',
          );
        } else {
          debugPrint(
            '[SOCKET SERVICE] 📝 Registered listener for $event (socket connecting...)',
          );
        }
      }
    } else {
      debugPrint('[SOCKET SERVICE] ℹ️ Listener for $event already exists');
    }
  }

  /// Re-register all stored listeners (called after reconnect or initial connect)
  void _reregisterAllListeners() {
    if (_socket == null) {
      debugPrint(
        '[SOCKET SERVICE] Cannot re-register listeners - socket is null',
      );
      return;
    }

    debugPrint(
      '[SOCKET SERVICE] 🔄 Re-registering ${_listeners.length} event listeners',
    );
    int count = 0;
    _listeners.forEach((event, callbacks) {
      for (final callback in callbacks) {
        // Wrap callback to track receives
        void wrappedCallback(dynamic data) {
          NetworkMetrics.recordSocketReceive(1);
          callback(data);
        }

        _socket!.on(event, wrappedCallback);
        count++;
      }
    });
    debugPrint('[SOCKET SERVICE] ✅ Re-registered $count listeners');
  }

  /// Notify server that all listeners are registered and client is ready
  /// Call this AFTER all PreKeys are generated and listeners registered
  void notifyClientReady() {
    debugPrint(
      '[SOCKET SERVICE] 📞 notifyClientReady called - socket connected: ${_socket?.connected}',
    );
    debugPrint(
      '[SOCKET SERVICE]    Current state: _listenersRegistered=$_listenersRegistered',
    );

    if (_socket?.connected ?? false) {
      _listenersRegistered = true;
      debugPrint('[SOCKET SERVICE] 🚀 Client ready - notifying server');
      _socket!.emit('clientReady', {
        'timestamp': DateTime.now().toIso8601String(),
      });
      debugPrint('[SOCKET SERVICE] ✅ clientReady event emitted successfully');
    } else {
      debugPrint(
        '[SOCKET SERVICE] ⚠️ Cannot notify ready - socket not connected',
      );
      debugPrint('[SOCKET SERVICE] Socket object exists: ${_socket != null}');
      if (_socket != null) {
        debugPrint(
          '[SOCKET SERVICE] Socket ID: ${_socket!.id}, Connected: ${_socket!.connected}',
        );
      }

      // Set flag anyway so it will be sent after connection completes
      _listenersRegistered = true;
      debugPrint(
        '[SOCKET SERVICE] ⏳ Marked listeners as registered - will send clientReady after connection',
      );
    }
  }

  /// Reset ready state (called on disconnect or logout)
  void resetReadyState() {
    _listenersRegistered = false;
    debugPrint('[SOCKET SERVICE] Ready state reset');
  }

  /// Unregister a named listener
  /// [event] - The event to unregister
  /// [registrationName] - Optional name used when registering (default: 'default')
  void unregisterListener(String event, {String registrationName = 'default'}) {
    // Remove from named listeners
    final listenerInfo = _namedListeners[registrationName];
    if (listenerInfo != null) {
      final callback = listenerInfo.remove(event);
      if (listenerInfo.isEmpty) {
        _namedListeners.remove(registrationName);
      }

      // Remove from legacy storage
      if (callback != null) {
        _listeners[event]?.remove(callback);
      }

      // Remove wrapped callback from socket
      final wrappedCallback = _wrappedCallbacks.remove(
        '${event}_$registrationName',
      );
      if (_socket != null && wrappedCallback != null) {
        _socket!.off(event, wrappedCallback);
        debugPrint(
          '[SOCKET SERVICE] Unregistered [$registrationName] for "$event"',
        );
      }
    }
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
    _socket?.emit(event, data);
    // Track socket emit
    NetworkMetrics.recordSocketEmit(1);
  }

  /// Internal method to authenticate socket connection
  Future<void> _authenticateSocket() async {
    if (kIsWeb) {
      // Web uses cookie-based session authentication
      debugPrint('[SOCKET SERVICE] Web client - using cookie auth');
      _socket?.emit('authenticate', null);
    } else {
      // Native uses HMAC authentication
      try {
        debugPrint('[SOCKET SERVICE] Native client - using HMAC auth');

        // Import necessary services
        final clientId = await ClientIdService.getClientId();

        // Get active server URL for multi-server support
        final activeServer = ServerConfigService.getActiveServer();
        if (activeServer == null) {
          debugPrint('[SOCKET SERVICE] ⚠️ No active server configured');
          _socket?.emit('authenticate', null);
          return;
        }
        final serverUrl = activeServer.serverUrl;

        final hasSession = await SessionAuthService().hasSession(
          clientId: clientId,
          serverUrl: serverUrl,
        );

        if (!hasSession) {
          debugPrint(
            '[SOCKET SERVICE] ⚠️ No HMAC session found for socket auth @ $serverUrl',
          );
          _socket?.emit('authenticate', null);
          return;
        }

        // Generate auth headers for Socket.IO authentication
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final nonce = const Uuid().v4();

        final sessionSecret = await SessionAuthService().getSessionSecret(
          clientId,
          serverUrl: serverUrl,
        );
        if (sessionSecret == null) {
          debugPrint('[SOCKET SERVICE] ⚠️ No session secret found');
          _socket?.emit('authenticate', null);
          return;
        }

        // Generate signature for socket authentication
        // Path is always '/socket.io/auth' for socket authentication
        final message = '$clientId:$timestamp:$nonce:/socket.io/auth:';
        final key = utf8.encode(sessionSecret);
        final bytes = utf8.encode(message);
        final hmac = Hmac(sha256, key);
        final digest = hmac.convert(bytes);
        final signature = digest.toString();

        final authData = {
          'X-Client-ID': clientId,
          'X-Timestamp': timestamp.toString(),
          'X-Nonce': nonce,
          'X-Signature': signature,
        };

        debugPrint('[SOCKET SERVICE] Sending HMAC auth for socket connection');
        _socket?.emit('authenticate', authData);
      } catch (e) {
        debugPrint('[SOCKET SERVICE] ⚠️ Error generating socket auth: $e');
        _socket?.emit('authenticate', null);
      }
    }
  }

  /// Manually trigger authentication (useful for re-authenticating)
  void authenticate() {
    debugPrint('[SOCKET SERVICE] Manually triggering authentication');
    _authenticateSocket();
  }

  bool get isConnected => _isConnected && (_socket?.connected ?? false);
}
