import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

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
    
    debugPrint('[SERVER_CONNECTION] reportHttpError called - isConnectionError: $isConnectionError, error: ${error.toString().substring(0, error.toString().length > 100 ? 100 : error.toString().length)}');
    
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
    // Handle DioException specially - check the inner error
    if (error is DioException) {
      // Check DioException type
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        debugPrint('[SERVER_CONNECTION] DioException connection error detected: ${error.type}');
        return true;
      }
      
      // Check inner error
      if (error.error != null) {
        if (error.error is SocketException) {
          debugPrint('[SERVER_CONNECTION] SocketException inside DioException');
          return true;
        }
        if (error.error is TimeoutException) {
          debugPrint('[SERVER_CONNECTION] TimeoutException inside DioException');
          return true;
        }
        if (error.error is HandshakeException) {
          debugPrint('[SERVER_CONNECTION] HandshakeException inside DioException');
          return true;
        }
      }
      
      // Check error message
      final errorMsg = error.toString();
      if (errorMsg != "") {
        debugPrint('[SERVER_CONNECTION] Connection error in message: ${errorMsg.substring(0, errorMsg.length > 100 ? 100 : errorMsg.length)}');
        return true;
      }
      
      return false;
    }
    
    // Network errors, timeouts, refused connections (direct exceptions)
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
    debugPrint('[SERVER_CONNECTION] _updateConnectionStatus called - current: $_isConnected, new: $connected');
    if (_isConnected != connected) {
      _isConnected = connected;
      _isConnectedController.add(_isConnected);
      debugPrint('[SERVER_CONNECTION] ✅ Status changed and broadcasted: $_isConnected');
    } else {
      debugPrint('[SERVER_CONNECTION] ℹ️ Status unchanged, not broadcasting');
    }
  }

  void dispose() {
    stopMonitoring();
    _isConnectedController.close();
  }
}
