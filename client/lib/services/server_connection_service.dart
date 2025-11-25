import 'dart:async';
import 'dart:io';

/// Service to monitor server connection status based on actual API/Socket errors
class ServerConnectionService {
  static final ServerConnectionService instance = ServerConnectionService._();
  ServerConnectionService._();

  final _isConnectedController = StreamController<bool>.broadcast();
  Stream<bool> get isConnectedStream => _isConnectedController.stream;
  
  bool _isConnected = true;
  bool get isConnected => _isConnected;

  Timer? _reconnectTimer;
  static const _reconnectDelay = Duration(seconds: 5);

  /// Start monitoring (no active polling, reacts to errors)
  void startMonitoring() {
    _isConnected = true;
    _isConnectedController.add(true);
  }

  /// Stop monitoring
  void stopMonitoring() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Report HTTP error from API calls (404, 500, timeout, network error)
  void reportHttpError(Object error, [StackTrace? stackTrace]) {
    // Check if it's a connection-related error
    final isConnectionError = _isConnectionError(error);
    
    if (isConnectionError) {
      _updateConnectionStatus(false);
      _scheduleReconnect();
    }
  }

  /// Report WebSocket/Socket connection failure
  void reportSocketError(Object error, [StackTrace? stackTrace]) {
    _updateConnectionStatus(false);
    _scheduleReconnect();
  }

  /// Report successful API call or Socket connection
  void reportSuccess() {
    _updateConnectionStatus(true);
    _cancelReconnectTimer();
  }

  /// Check if error is connection-related
  bool _isConnectionError(Object error) {
    // Network errors, timeouts, refused connections
    if (error is SocketException) return true;
    if (error is TimeoutException) return true;
    if (error is HandshakeException) return true;
    
    // HTTP errors that indicate server issues
    if (error.toString().contains('Failed host lookup')) return true;
    if (error.toString().contains('Connection refused')) return true;
    if (error.toString().contains('Network is unreachable')) return true;
    
    return false;
  }

  /// Schedule automatic reconnect attempt
  void _scheduleReconnect() {
    _cancelReconnectTimer();
    
    _reconnectTimer = Timer.periodic(_reconnectDelay, (_) {
      // Try to recover connection by checking if server is back
      _attemptReconnect();
    });
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Attempt to reconnect (triggered by timer or manual retry)
  Future<void> _attemptReconnect() async {
    // This will be called by next API/Socket call
    // We just need to signal that we're ready to try again
    // The actual connection test happens naturally when app tries to communicate
  }

  /// Manual retry (called from UI)
  Future<void> checkConnection() async {
    // Signal that user wants to retry
    // Next API/Socket call will naturally test the connection
    _updateConnectionStatus(true);
    _cancelReconnectTimer();
  }

  void _updateConnectionStatus(bool connected) {
    if (_isConnected != connected) {
      _isConnected = connected;
      _isConnectedController.add(_isConnected);
    }
  }

  void dispose() {
    stopMonitoring();
    _isConnectedController.close();
  }
}
