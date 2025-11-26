import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'dart:convert';
import 'event_bus.dart';
// Import auth service conditionally
import 'auth_service_web.dart' if (dart.library.io) 'auth_service_native.dart';
import 'session_auth_service.dart';
import 'server_config_web.dart' if (dart.library.io) 'server_config_native.dart';
import 'clientid_native.dart' if (dart.library.js) 'clientid_web_stub.dart';
import 'server_connection_service.dart';

/// Callback for handling 401 Unauthorized responses
typedef UnauthorizedCallback = void Function();

/// Global callback for 401 handling (set by app)
UnauthorizedCallback? _globalUnauthorizedCallback;

/// Set global 401 handler
void setGlobalUnauthorizedHandler(UnauthorizedCallback callback) {
  _globalUnauthorizedCallback = callback;
}

/// Interceptor for handling 401 Unauthorized responses
/// Only triggers auto-logout if user is already logged in
class UnauthorizedInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    // ✅ Report successful API response (server is reachable)
    if (!kIsWeb) {
      ServerConnectionService.instance.reportSuccess();
    }
    
    if (response.statusCode == 401) {
      // For native: If SessionAuth was attempted (we see the error message), trigger logout
      // For web: Only trigger if already logged in
      // The key insight: if SessionAuth tried to authenticate but got 401, session is invalid
      debugPrint('[API] 401 detected - isLoggedIn: ${AuthService.isLoggedIn}, isWeb: $kIsWeb');
      if (AuthService.isLoggedIn || !kIsWeb) {
        debugPrint('[API] ⚠️  401 Unauthorized detected - triggering auto-logout');
        debugPrint('[API] Callback exists: ${_globalUnauthorizedCallback != null}');
        _globalUnauthorizedCallback?.call();
      } else {
        debugPrint('[API] 401 Unauthorized - user not logged in yet, ignoring');
      }
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // ❌ Report connection errors (only on native)
    if (!kIsWeb) {
      ServerConnectionService.instance.reportHttpError(err);
    }
    
    if (err.response?.statusCode == 401) {
      // For native: Always trigger auto-logout on 401
      // For web: Only trigger if already logged in
      debugPrint('[API] 401 error detected - isLoggedIn: ${AuthService.isLoggedIn}, isWeb: $kIsWeb');
      if (AuthService.isLoggedIn || !kIsWeb) {
        debugPrint('[API] ⚠️  401 Unauthorized detected in error - triggering auto-logout');
        debugPrint('[API] Callback exists: ${_globalUnauthorizedCallback != null}');
        _globalUnauthorizedCallback?.call();
      } else {
        debugPrint('[API] 401 Unauthorized error - user not logged in yet, ignoring');
      }
    }
    super.onError(err, handler);
  }
}

/// Interceptor for adding HMAC authentication headers to native client requests
class SessionAuthInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    // Only add auth headers for native platforms
    if (!kIsWeb) {
      try {
        // Get active server
        final activeServer = ServerConfigService.getActiveServer();
        
        if (activeServer != null) {
          // Set base URL if not already set or if it's a relative path
          if (!options.path.startsWith('http://') && !options.path.startsWith('https://')) {
            final baseUrl = activeServer.serverUrl;
            // Ensure baseUrl ends without slash and path starts with slash
            final cleanBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
            final cleanPath = options.path.startsWith('/') ? options.path : '/$options.path';
            options.path = '$cleanBase$cleanPath';
            debugPrint('[SessionAuth] Set full URL: ${options.path}');
          }
          
          // Get client ID from device
          final clientId = await ClientIdService.getClientId();
          
          // Check if we have a session
          final hasSession = await SessionAuthService().hasSession(clientId);
          
          if (hasSession) {
            // Extract just the path from the full URL for signature calculation
            // Dio's options.path contains the full URL, but server expects just the path part
            final uri = Uri.parse(options.path);
            final pathOnly = uri.path;
            
            // Generate auth headers
            final authHeaders = await SessionAuthService().generateAuthHeaders(
              clientId: clientId,
              requestPath: pathOnly,
              requestBody: options.data != null ? json.encode(options.data) : null,
            );
            
            // Add headers to request
            options.headers.addAll(authHeaders);
            debugPrint('[SessionAuth] Added auth headers for request: ${options.path} (path: $pathOnly)');
          } else {
            debugPrint('[SessionAuth] No session found for client: $clientId');
          }
        }
      } catch (e) {
        debugPrint('[SessionAuth] Error adding auth headers: $e');
        // Continue with request even if auth fails
      }
    }
    
    super.onRequest(options, handler);
  }
}

/// Custom retry interceptor for handling 503 (database busy) and network errors
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetries;
  final List<Duration> retryDelays;

  RetryInterceptor({
    required this.dio,
    this.maxRetries = 3,
    List<Duration>? retryDelays,
  }) : retryDelays = retryDelays ??
            const [
              Duration(seconds: 2),
              Duration(seconds: 4),
              Duration(seconds: 8),
            ];

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final extra = err.requestOptions.extra;
    final retryCount = extra['retryCount'] as int? ?? 0;

    // Check if we should retry
    if (_shouldRetry(err) && retryCount < maxRetries) {
      debugPrint('[API RETRY] Attempt ${retryCount + 1}/$maxRetries for ${err.requestOptions.path}');
      
      // Report connection error on first attempt (show overlay immediately)
      if (retryCount == 0 && !kIsWeb) {
        ServerConnectionService.instance.reportHttpError(err);
      }
      
      // Get delay from Retry-After header or use default
      final delay = _getRetryDelay(err, retryCount);
      debugPrint('[API RETRY] Waiting ${delay.inSeconds}s before retry...');
      
      await Future.delayed(delay);

      // Clone the request and increment retry count
      final options = err.requestOptions;
      options.extra['retryCount'] = retryCount + 1;

      try {
        debugPrint('[API RETRY] Retrying request to ${options.path}');
        final response = await dio.fetch(options);
        // ✅ Report success if retry succeeds
        if (!kIsWeb) {
          ServerConnectionService.instance.reportSuccess();
        }
        return handler.resolve(response);
      } catch (e) {
        if (e is DioException) {
          return super.onError(e, handler);
        }
        return handler.reject(err);
      }
    }

    // All retries exhausted - ensure error is reported
    if (!kIsWeb && _shouldRetry(err)) {
      ServerConnectionService.instance.reportHttpError(err);
    }

    return super.onError(err, handler);
  }

  bool _shouldRetry(DioException err) {
    // Retry on 503 Service Unavailable (database busy)
    if (err.response?.statusCode == 503) {
      debugPrint('[API RETRY] Database busy (503), will retry');
      return true;
    }

    // Retry on connection timeout
    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout) {
      debugPrint('[API RETRY] Network timeout, will retry');
      return true;
    }

    // Retry on connection error
    if (err.type == DioExceptionType.connectionError) {
      debugPrint('[API RETRY] Connection error, will retry');
      return true;
    }

    return false;
  }

  Duration _getRetryDelay(DioException err, int retryCount) {
    // Check for Retry-After header (from our server's 503 response)
    final retryAfter = err.response?.headers.value('retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null) {
        debugPrint('[API RETRY] Using Retry-After header: ${seconds}s');
        return Duration(seconds: seconds);
      }
    }

    // Use default delay based on retry count
    if (retryCount < retryDelays.length) {
      return retryDelays[retryCount];
    }

    // Fallback to last delay if exceeded array length
    return retryDelays.last;
  }
}

class ApiService {
  static final Dio dio = Dio();
  static final CookieJar cookieJar = CookieJar();
  static bool _initialized = false;

  static void init() {
    if (!_initialized) {
      // Add cookie manager for native clients
      if (!kIsWeb) {
        dio.interceptors.add(CookieManager(cookieJar));
      }
      
      // Add SessionAuth interceptor first (handles both baseUrl and auth headers for native)
      dio.interceptors.add(SessionAuthInterceptor());
      
      // Add 401 Unauthorized interceptor (should be after auth headers added)
      dio.interceptors.add(UnauthorizedInterceptor());
      
      // Add custom retry interceptor for handling 503 (database busy) and network errors
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          maxRetries: 3,
          retryDelays: const [
            Duration(seconds: 2),  // First retry after 2s
            Duration(seconds: 4),  // Second retry after 4s
            Duration(seconds: 8),  // Third retry after 8s
          ],
        ),
      );
      
      _initialized = true;
    }
  }

  /// Ensure host has http:// or https:// prefix
  /// This prevents CORS errors when constructing API URLs
  static String ensureHttpPrefix(String host) {
    if (host.startsWith('http://') || host.startsWith('https://')) {
      return host;
    }
    return 'http://$host';
  }

  static Future<Response> get(String url, {Map<String, dynamic>? queryParameters, Options? options}) {
    options ??= Options();
    options = options.copyWith(contentType: 'application/json', extra: {...?options.extra, 'withCredentials': true});
    return dio.get(url, queryParameters: queryParameters, options: options);
  }

  static Future<Response> post(String url, {dynamic data, Options? options}) {
    options ??= Options();
    options = options.copyWith(contentType: 'application/json',extra: {...?options.extra, 'withCredentials': true});
    return dio.post(url, data: data, options: options);
  }

  static Future<Response> delete(String url, {dynamic data, Options? options}) {
    options ??= Options();
    options = options.copyWith(contentType: 'application/json',extra: {...?options.extra, 'withCredentials': true});
    return dio.delete(url, data: data, options: options);
  }
  
  // ========================================================================
  // EVENT BUS INTEGRATION
  // ========================================================================
  
  /// Emit API-related events to EventBus
  /// Call this after successful API operations that affect app state
  static void emitEvent(AppEvent event, dynamic data) {
    debugPrint('[API SERVICE] → EVENT_BUS: $event');
    EventBus.instance.emit(event, data);
  }
  
  // ========================================================================
  // CHANNEL API WRAPPERS WITH EVENT EMISSION
  // ========================================================================
  
  /// Create a new channel
  /// Automatically emits AppEvent.newChannel on success
  static Future<Response> createChannel(
    String host, {
    required String name,
    String? description,
    bool? isPrivate,
    String? type,
    String? defaultRoleId,
  }) async {
    final url = ensureHttpPrefix(host);
    final response = await post(
      '$url/client/channels',
      data: {
        'name': name,
        if (description != null) 'description': description,
        if (isPrivate != null) 'private': isPrivate,
        if (type != null) 'type': type,
        if (defaultRoleId != null) 'defaultRoleId': defaultRoleId,
      },
    );
    
    // Emit event on success
    if (response.statusCode == 201) {
      debugPrint('[API SERVICE] Channel created successfully');
      emitEvent(AppEvent.newChannel, response.data);
    }
    
    return response;
  }
  
  /// Update an existing channel
  /// Automatically emits AppEvent.channelUpdated on success
  static Future<Response> updateChannel(
    String host,
    String channelId, {
    String? name,
    String? description,
    bool? isPrivate,
  }) async {
    final url = ensureHttpPrefix(host);
    final response = await dio.put(
      '$url/client/channels/$channelId',
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (isPrivate != null) 'private': isPrivate,
      },
      options: Options(
        contentType: 'application/json',
        extra: {'withCredentials': true},
      ),
    );
    
    // Emit event on success
    if (response.statusCode == 200) {
      debugPrint('[API SERVICE] Channel updated successfully');
      emitEvent(AppEvent.channelUpdated, response.data);
    }
    
    return response;
  }
  
  /// Delete a channel (owner only)
  /// Automatically emits AppEvent.channelDeleted on success
  static Future<Response> deleteChannel(String host, String channelId) async {
    final url = ensureHttpPrefix(host);
    final response = await delete('$url/api/channels/$channelId');
    
    // Emit event on success
    if (response.statusCode == 200 || response.statusCode == 204) {
      debugPrint('[API SERVICE] Channel deleted successfully');
      emitEvent(AppEvent.channelDeleted, {'channelId': channelId});
    }
    
    return response;
  }
  
  /// Leave a channel
  /// Automatically emits AppEvent.channelLeft on success
  static Future<Response> leaveChannel(String host, String channelId) async {
    final url = ensureHttpPrefix(host);
    final response = await post('$url/api/channels/$channelId/leave');
    
    // Emit event on success
    if (response.statusCode == 200) {
      debugPrint('[API SERVICE] Left channel successfully');
      emitEvent(AppEvent.channelLeft, {'channelId': channelId});
    }
    
    return response;
  }
  
  /// Kick a user from a channel (requires owner or user.kick permission)
  /// Automatically emits AppEvent.userKicked on success
  static Future<Response> kickUserFromChannel(String host, String channelId, String userId) async {
    final url = ensureHttpPrefix(host);
    final response = await delete('$url/api/channels/$channelId/members/$userId');
    
    // Emit event on success
    if (response.statusCode == 200) {
      debugPrint('[API SERVICE] User kicked from channel successfully');
      emitEvent(AppEvent.userKicked, {'channelId': channelId, 'userId': userId});
    }
    
    return response;
  }
  
  /// Join a public channel
  /// Automatically emits AppEvent.channelJoined on success
  static Future<Response> joinChannel(String host, String channelId) async {
    final url = ensureHttpPrefix(host);
    final response = await post('$url/client/channels/$channelId/join');
    
    // Emit event on success
    if (response.statusCode == 200) {
      debugPrint('[API SERVICE] Channel joined successfully');
      emitEvent(AppEvent.channelJoined, response.data);
    }
    
    return response;
  }
}

