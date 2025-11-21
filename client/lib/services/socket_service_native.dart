import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'signal_service.dart';
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

/// Native socket service - manages connection to active server
/// API-compatible with web SocketService
class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  String? _currentServerId;
  final Map<String, List<void Function(dynamic)>> _listeners = {};
  bool _connecting = false;
  bool _listenersRegistered = false;
  Completer<void>? _connectionCompleter;
  
  IO.Socket? get socket => _socket;
  bool get isReady => _listenersRegistered && (_socket?.connected ?? false);
  bool get isConnected => _socket?.connected ?? false;
  
  Future<void> connect() async {
    final activeServer = ServerConfigService.getActiveServer();
    if (activeServer == null) {
      debugPrint('[SOCKET SERVICE] No active server configured');
      return;
    }
    
    if (_socket != null && _socket!.connected && _currentServerId == activeServer.id) {
      debugPrint('[SOCKET SERVICE] Already connected to active server');
      return;
    }
    
    if (_connecting) {
      debugPrint('[SOCKET SERVICE] Connection in progress, waiting...');
      await _connectionCompleter?.future;
      return;
    }
    
    _connecting = true;
    _connectionCompleter = Completer<void>();
    
    try {
      if (_socket != null && _currentServerId != activeServer.id) {
        _socket!.disconnect();
        _socket = null;
      }
      
      debugPrint('[SOCKET SERVICE] Connecting to: ${activeServer.serverUrl}');
      _currentServerId = activeServer.id;
      
      String urlString = activeServer.serverUrl;
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      
      _socket = IO.io(urlString, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
        'reconnection': true,
        'reconnectionDelay': 2000,
        'reconnectionAttempts': 5,
        'forceNew': false,
        'timeout': 20000,
      });
      
      _socket!.on('connect', (_) async {
        debugPrint('[SOCKET SERVICE] Socket connected event');
        await _authenticate();
      });
      
      _socket!.on('authenticated', (data) {
        _handleAuthenticated(data);
        // Complete the connection future after successful authentication
        if (data is Map && data['authenticated'] == true) {
          if (!_connectionCompleter!.isCompleted) {
            _connectionCompleter!.complete();
            debugPrint('[SOCKET SERVICE] ✓ Connection and authentication complete');
          }
        }
      });
      
      _socket!.on('disconnect', (reason) {
        debugPrint('[SOCKET SERVICE] ❌ Socket disconnected. Reason: $reason');
        resetReadyState();
      });
      _socket!.on('reconnect', (_) async => await _authenticate());
      _socket!.on('unauthorized', (_) {
        if (AuthService.isLoggedIn) {
          _socketUnauthorizedCallback?.call();
        }
      });
      _socket!.on('error', (data) {
        debugPrint('[SOCKET SERVICE] Socket error: $data');
        if (data is Map && (data['message']?.toString().contains('unauthorized') ?? false)) {
          if (AuthService.isLoggedIn) _socketUnauthorizedCallback?.call();
        }
        // Complete with error if connection fails
        if (!_connectionCompleter!.isCompleted) {
          _connectionCompleter!.completeError('Socket connection error: $data');
        }
      });
      
      _listeners.forEach((event, callbacks) {
        for (var cb in callbacks) _socket!.on(event, cb);
      });
      
      debugPrint('[SOCKET SERVICE] Starting socket connection...');
      _socket!.connect();
      
      // Wait for authentication to complete (with timeout)
      await _connectionCompleter!.future.timeout(
        Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[SOCKET SERVICE] ❌ Connection timeout after 10 seconds');
          throw TimeoutException('Socket connection timeout');
        },
      );
      
      debugPrint('[SOCKET SERVICE] ✅ Connect method completing, socket connected: ${_socket?.connected}');
    } catch (e) {
      debugPrint('[SOCKET SERVICE] ❌ Connection error: $e');
      if (!_connectionCompleter!.isCompleted) {
        _connectionCompleter!.completeError(e);
      }
      rethrow;
    } finally {
      _connecting = false;
    }
  }
  
  void _handleAuthenticated(dynamic data) {
    debugPrint('[SOCKET SERVICE] Authenticated: $data');
    debugPrint('[SOCKET SERVICE] Socket state after auth: connected=${_socket?.connected}, id=${_socket?.id}');
    if (data is Map && data['authenticated'] == false) {
      if (AuthService.isLoggedIn) _socketUnauthorizedCallback?.call();
      return;
    }
    if (data is Map && data['authenticated'] == true && data['uuid'] != null && data['deviceId'] != null) {
      final deviceId = data['deviceId'] is int ? data['deviceId'] : int.parse(data['deviceId'].toString());
      SignalService.instance.setCurrentUserInfo(data['uuid'], deviceId);
      debugPrint('[SOCKET SERVICE] User info set, socket still connected: ${_socket?.connected}');
    }
  }
  
  Future<void> _authenticate() async {
    try {
      final clientId = await ClientIdService.getClientId();
      final authHeaders = await SessionAuthService().generateAuthHeaders(
        clientId: clientId,
        requestPath: '/socket.io/auth',
        requestBody: null,
      );
      _socket!.emit('authenticate', authHeaders);
    } catch (e) {
      debugPrint('[SOCKET SERVICE] Auth error: $e');
    }
  }

  void disconnect() {
    resetReadyState();
    _socket?.disconnect();
    _socket = null;
    _currentServerId = null;
  }

  void registerListener(String event, Function(dynamic) callback) {
    final callbacks = _listeners.putIfAbsent(event, () => []);
    if (!callbacks.contains(callback)) {
      callbacks.add(callback);
      _socket?.on(event, callback);
    }
  }
  
  void notifyClientReady() {
    if (_socket?.connected ?? false) {
      _listenersRegistered = true;
      debugPrint('[SOCKET SERVICE] 🚀 Client ready - notifying server');
      _socket!.emit('clientReady', {'timestamp': DateTime.now().toIso8601String()});
    } else {
      debugPrint('[SOCKET SERVICE] ⚠️ Cannot notify ready - socket not connected');
    }
  }
  
  void resetReadyState() => _listenersRegistered = false;
  void unregisterListener(String event, Function(dynamic) callback) {
    _listeners[event]?.remove(callback);
    _socket?.off(event, callback);
  }
  void emit(String event, dynamic data) => _socket?.emit(event, data);
  void authenticate() => _authenticate();
}
