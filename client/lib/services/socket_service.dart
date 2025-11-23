import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../web_config.dart';
import 'signal_service.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart' if (dart.library.js) 'clientid_web_stub.dart';
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
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  final Map<String, List<void Function(dynamic)>> _listeners = {};
  bool _connecting = false;
  bool _listenersRegistered = false; // 🔒 Track listener registration state
  
  // Public getter for socket (needed by SocketFileClient)
  IO.Socket? get socket => _socket;
  
  /// Check if listeners are registered and client is ready
  bool get isReady => _listenersRegistered && (_socket?.connected ?? false);
  
  Future<void> connect() async {
    if (_socket != null && _socket!.connected) return;
    if (_connecting) return;
    _connecting = true;
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      _socket = IO.io(urlString, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false, // Manually connect after setup to ensure cookies are ready
        'reconnection': true,
        'reconnectionDelay': 2000,
        'withCredentials': true, // Send cookies for session management
      });
      _socket!.on('connect', (_) {
        debugPrint('[SOCKET SERVICE] Socket connected');
        // Authenticate with the server after connection
        _authenticateSocket();
      });
      _socket!.on('authenticated', (data) {
        debugPrint('[SOCKET SERVICE] Authentication response: $data');
        // Check if authentication failed
        if (data is Map && data['authenticated'] == false) {
          // Only trigger auto-logout if user is logged in
          if (AuthService.isLoggedIn) {
            debugPrint('[SOCKET SERVICE] ⚠️  Authentication failed - triggering auto-logout');
            _socketUnauthorizedCallback?.call();
          } else {
            debugPrint('[SOCKET SERVICE] Authentication failed - user not logged in yet, ignoring');
          }
          return;
        }
        // Store user info in SignalService for device filtering
        if (data is Map && data['authenticated'] == true && data['uuid'] != null && data['deviceId'] != null) {
          // Parse deviceId as int (server sends String)
          final deviceId = data['deviceId'] is int
              ? data['deviceId'] as int
              : int.parse(data['deviceId'].toString());
          SignalService.instance.setCurrentUserInfo(data['uuid'], deviceId);
        }
      });
      _socket!.on('disconnect', (_) {
        debugPrint('[SOCKET SERVICE] Socket disconnected');
        resetReadyState(); // Reset ready state on disconnect
      });
      _socket!.on('reconnect', (_) {
        debugPrint('[SOCKET SERVICE] Socket reconnected');
        // Re-authenticate after reconnection
        _authenticateSocket();
      });
      _socket!.on('reconnect_attempt', (_) {
        debugPrint('[SOCKET SERVICE] Socket reconnecting...');
      });
      // Listen for unauthorized/authentication errors
      _socket!.on('unauthorized', (_) {
        // Only trigger auto-logout if user is logged in
        if (AuthService.isLoggedIn) {
          debugPrint('[SOCKET SERVICE] ⚠️  Unauthorized - triggering auto-logout');
          _socketUnauthorizedCallback?.call();
        } else {
          debugPrint('[SOCKET SERVICE] Unauthorized - user not logged in yet, ignoring');
        }
      });
      _socket!.on('error', (data) {
        debugPrint('[SOCKET SERVICE] Socket error: $data');
        if (data is Map && (data['message']?.toString().contains('unauthorized') ?? false)) {
          // Only trigger auto-logout if user is logged in
          if (AuthService.isLoggedIn) {
            debugPrint('[SOCKET SERVICE] ⚠️  Unauthorized error - triggering auto-logout');
            _socketUnauthorizedCallback?.call();
          } else {
            debugPrint('[SOCKET SERVICE] Unauthorized error - user not logged in yet, ignoring');
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
      debugPrint('[SOCKET SERVICE] Manually connecting socket with credentials...');
      _socket!.connect();
    } finally {
      _connecting = false;
    }
  }

  void disconnect() {
    resetReadyState(); // Reset ready state before disconnect
    _socket?.disconnect();
    _socket = null;
  }

  void registerListener(String event, Function(dynamic) callback) {
    final callbacks = _listeners.putIfAbsent(event, () => []);
    if (!callbacks.contains(callback)) {
      callbacks.add(callback);
      if (_socket != null) {
        _socket!.on(event, callback);
      }
    }
  }
  
  /// Notify server that all listeners are registered and client is ready
  /// Call this AFTER all PreKeys are generated and listeners registered
  void notifyClientReady() {
    if (_socket?.connected ?? false) {
      _listenersRegistered = true;
      debugPrint('[SOCKET SERVICE] 🚀 Client ready - notifying server');
      _socket!.emit('clientReady', {
        'timestamp': DateTime.now().toIso8601String(),
      });
    } else {
      debugPrint('[SOCKET SERVICE] ⚠️ Cannot notify ready - socket not connected');
    }
  }
  
  /// Reset ready state (called on disconnect or logout)
  void resetReadyState() {
    _listenersRegistered = false;
    debugPrint('[SOCKET SERVICE] Ready state reset');
  }

  void unregisterListener(String event, Function(dynamic) callback) {
    _listeners[event]?.remove(callback);
    if (_socket != null) {
      _socket!.off(event, callback);
    }
  }

  void emit(String event, dynamic data) {
      _socket?.emit(event, data);
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
        final hasSession = await SessionAuthService().hasSession(clientId);
        
        if (!hasSession) {
          debugPrint('[SOCKET SERVICE] ⚠️ No HMAC session found for socket auth');
          _socket?.emit('authenticate', null);
          return;
        }
        
        // Generate auth headers for Socket.IO authentication
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final nonce = const Uuid().v4();
        
        final sessionSecret = await SessionAuthService().getSessionSecret(clientId);
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

  bool get isConnected => _socket?.connected ?? false;
}

