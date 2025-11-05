import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../web_config.dart';
import 'signal_service.dart';
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

  // Public getter for socket (needed by SocketFileClient)
  IO.Socket? get socket => _socket;
  
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
        print('[SOCKET SERVICE] Socket connected');
        // Authenticate with the server after connection
        _socket!.emit('authenticate', null);
      });
      _socket!.on('authenticated', (data) {
        print('[SOCKET SERVICE] Authentication response: $data');
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
        print('[SOCKET SERVICE] Socket disconnected');
      });
      _socket!.on('reconnect', (_) {
        print('[SOCKET SERVICE] Socket reconnected');
        // Re-authenticate after reconnection
        _socket!.emit('authenticate', null);
      });
      _socket!.on('reconnect_attempt', (_) {
        print('[SOCKET SERVICE] Socket reconnecting...');
      });
      // Listen for unauthorized/authentication errors
      _socket!.on('unauthorized', (_) {
        // Only trigger auto-logout if user is logged in
        if (AuthService.isLoggedIn) {
          print('[SOCKET SERVICE] ⚠️  Unauthorized - triggering auto-logout');
          _socketUnauthorizedCallback?.call();
        } else {
          print('[SOCKET SERVICE] Unauthorized - user not logged in yet, ignoring');
        }
      });
      _socket!.on('error', (data) {
        print('[SOCKET SERVICE] Socket error: $data');
        if (data is Map && (data['message']?.toString().contains('unauthorized') ?? false)) {
          // Only trigger auto-logout if user is logged in
          if (AuthService.isLoggedIn) {
            print('[SOCKET SERVICE] ⚠️  Unauthorized error - triggering auto-logout');
            _socketUnauthorizedCallback?.call();
          } else {
            print('[SOCKET SERVICE] Unauthorized error - user not logged in yet, ignoring');
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
      print('[SOCKET SERVICE] Manually connecting socket with credentials...');
      _socket!.connect();
    } finally {
      _connecting = false;
    }
  }

  void disconnect() {
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

  void unregisterListener(String event, Function(dynamic) callback) {
    _listeners[event]?.remove(callback);
    if (_socket != null) {
      _socket!.off(event, callback);
    }
  }

  void emit(String event, dynamic data) {
      _socket?.emit(event, data);
  }

  /// Manually trigger authentication (useful for re-authenticating)
  void authenticate() {
    print('[SOCKET SERVICE] Manually triggering authentication');
    _socket?.emit('authenticate', null);
  }

  bool get isConnected => _socket?.connected ?? false;
}
