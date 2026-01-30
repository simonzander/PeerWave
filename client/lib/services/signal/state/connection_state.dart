import 'package:flutter/foundation.dart';

/// Observable state for Signal service connectivity
///
/// Tracks connection status for:
/// - REST API availability
/// - Socket.IO real-time connection
/// - User authentication state
///
/// Usage:
/// ```dart
/// final connectionState = ConnectionState.instance;
/// connectionState.addListener(() {
///   print('Status: ${connectionState.status}');
///   print('Can send: ${connectionState.canSendMessages}');
/// });
/// ```
class ConnectionState extends ChangeNotifier {
  static final ConnectionState instance = ConnectionState._();
  ConnectionState._();

  bool _isApiConnected = false;
  bool _isSocketConnected = false;
  String? _userId;
  int? _deviceId;
  DateTime? _lastConnectionTime;
  String? _connectionError;

  // Getters
  bool get isApiConnected => _isApiConnected;
  bool get isSocketConnected => _isSocketConnected;
  String? get userId => _userId;
  int? get deviceId => _deviceId;
  DateTime? get lastConnectionTime => _lastConnectionTime;
  String? get connectionError => _connectionError;

  /// Overall connection status
  ConnectionStatus get status {
    if (!_isApiConnected && !_isSocketConnected) {
      return ConnectionStatus.disconnected;
    }
    if (_isApiConnected && _isSocketConnected && _userId != null) {
      return ConnectionStatus.ready;
    }
    return ConnectionStatus.connecting;
  }

  /// Whether messages can be sent
  bool get canSendMessages => status == ConnectionStatus.ready;

  /// Whether we're fully connected and authenticated
  bool get isReady => status == ConnectionStatus.ready;

  /// Mark API as connected
  void markApiConnected() {
    _isApiConnected = true;
    _connectionError = null;
    notifyListeners();
  }

  /// Mark API as disconnected
  void markApiDisconnected({String? error}) {
    _isApiConnected = false;
    _connectionError = error;
    notifyListeners();
  }

  /// Mark Socket.IO as connected
  void markSocketConnected() {
    _isSocketConnected = true;
    _lastConnectionTime = DateTime.now();
    _connectionError = null;
    notifyListeners();
  }

  /// Mark Socket.IO as disconnected
  void markSocketDisconnected({String? error}) {
    _isSocketConnected = false;
    _connectionError = error;
    notifyListeners();
  }

  /// Set user info after authentication
  void markClientReady(String userId, int deviceId) {
    _userId = userId;
    _deviceId = deviceId;
    _lastConnectionTime = DateTime.now();
    notifyListeners();
  }

  /// Reset on logout
  void reset() {
    _isApiConnected = false;
    _isSocketConnected = false;
    _userId = null;
    _deviceId = null;
    _lastConnectionTime = null;
    _connectionError = null;
    notifyListeners();
  }

  /// Get connection status description
  String get statusDescription {
    switch (status) {
      case ConnectionStatus.disconnected:
        return _connectionError ?? 'Disconnected';
      case ConnectionStatus.connecting:
        if (_isApiConnected && !_isSocketConnected) {
          return 'Connecting to real-time service...';
        }
        if (_isSocketConnected && !_isApiConnected) {
          return 'Connecting to API...';
        }
        return 'Connecting...';
      case ConnectionStatus.ready:
        return 'Connected';
    }
  }
}

/// Connection status levels
enum ConnectionStatus {
  /// No connection
  disconnected,

  /// Partially connected (API or Socket)
  connecting,

  /// Fully connected and ready
  ready,
}
