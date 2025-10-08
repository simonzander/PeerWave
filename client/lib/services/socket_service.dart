import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';
import '../web_config.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  final Map<String, List<void Function(dynamic)>> _listeners = {};
  bool _connecting = false;

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
        'autoConnect': true,
        'reconnection': true,
        'reconnectionDelay': 2000,
      });
      _socket!.on('connect', (_) {
        print('Socket connected');
      });
      _socket!.on('disconnect', (_) {
        print('Socket disconnected');
      });
      _socket!.on('reconnect_attempt', (_) {
        print('Socket reconnecting...');
      });
      // Register all listeners
      _listeners.forEach((event, callbacks) {
        for (var cb in callbacks) {
          _socket!.on(event, cb);
        }
      });
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

  bool get isConnected => _socket?.connected ?? false;
}
