/// Example integration of ServerConnectionService with API calls and WebSocket
/// 
/// This file shows how to integrate the connection monitoring into your existing
/// HTTP requests and WebSocket connections.

import 'package:http/http.dart' as http;
import 'server_connection_service.dart';

/// Example: Wrap your HTTP calls with error reporting
class ApiClient {
  final String baseUrl;
  
  ApiClient(this.baseUrl);

  /// Example GET request with connection monitoring
  Future<http.Response> get(String path) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl$path'))
          .timeout(const Duration(seconds: 10));
      
      // ✅ Report success on any response (even 404/500 means server is reachable)
      ServerConnectionService.instance.reportSuccess();
      
      return response;
    } catch (e, stackTrace) {
      // ❌ Report connection errors (timeout, network unreachable, etc.)
      ServerConnectionService.instance.reportHttpError(e, stackTrace);
      rethrow;
    }
  }

  /// Example POST request with connection monitoring
  Future<http.Response> post(String path, {Map<String, dynamic>? body}) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl$path'),
            body: body,
          )
          .timeout(const Duration(seconds: 10));
      
      // ✅ Report success
      ServerConnectionService.instance.reportSuccess();
      
      return response;
    } catch (e, stackTrace) {
      // ❌ Report error
      ServerConnectionService.instance.reportHttpError(e, stackTrace);
      rethrow;
    }
  }
}

/// Example: WebSocket connection monitoring
/// 
/// For WebSocket/Socket.io connections, report errors in your connection handler
/// 
/// Example for web_socket_channel:
/// ```dart
/// import 'package:web_socket_channel/web_socket_channel.dart';
/// 
/// class SocketClient {
///   WebSocketChannel? _channel;
///   
///   Future<void> connect(String url) async {
///     try {
///       _channel = WebSocketChannel.connect(Uri.parse(url));
///       
///       // ✅ Report success on connection
///       ServerConnectionService.instance.reportSuccess();
///       
///       _channel!.stream.listen(
///         (message) {
///           // Handle messages
///         },
///         onError: (error) {
///           // ❌ Report socket error
///           ServerConnectionService.instance.reportSocketError(error);
///         },
///         onDone: () {
///           // Connection closed
///         },
///       );
///     } catch (e, stackTrace) {
///       // ❌ Report connection error
///       ServerConnectionService.instance.reportSocketError(e, stackTrace);
///       rethrow;
///     }
///   }
/// }
/// ```
/// 
/// Example for socket_io_client:
/// ```dart
/// import 'package:socket_io_client/socket_io_client.dart' as IO;
/// 
/// class SocketIoClient {
///   IO.Socket? _socket;
///   
///   void connect(String url) {
///     _socket = IO.io(url, <String, dynamic>{
///       'transports': ['websocket'],
///       'autoConnect': false,
///     });
///     
///     _socket!.onConnect((_) {
///       // ✅ Report success
///       ServerConnectionService.instance.reportSuccess();
///     });
///     
///     _socket!.onConnectError((error) {
///       // ❌ Report connection error
///       ServerConnectionService.instance.reportSocketError(error);
///     });
///     
///     _socket!.onError((error) {
///       // ❌ Report error
///       ServerConnectionService.instance.reportSocketError(error);
///     });
///     
///     _socket!.connect();
///   }
/// }
/// ```
