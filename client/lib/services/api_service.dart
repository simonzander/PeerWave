import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'event_bus.dart';
// Import auth service conditionally
import 'auth_service_web.dart' if (dart.library.io) 'auth_service_native.dart';

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
    if (response.statusCode == 401) {
      // Only trigger auto-logout if user is logged in
      // This prevents triggering on initial session check when user visits site
      if (AuthService.isLoggedIn) {
        debugPrint('[API] ⚠️  401 Unauthorized detected - triggering auto-logout');
        _globalUnauthorizedCallback?.call();
      } else {
        debugPrint('[API] 401 Unauthorized - user not logged in yet, ignoring');
      }
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401) {
      // Only trigger auto-logout if user is logged in
      if (AuthService.isLoggedIn) {
        debugPrint('[API] ⚠️  401 Unauthorized detected in error - triggering auto-logout');
        _globalUnauthorizedCallback?.call();
      } else {
        debugPrint('[API] 401 Unauthorized error - user not logged in yet, ignoring');
      }
    }
    super.onError(err, handler);
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
        return handler.resolve(response);
      } catch (e) {
        if (e is DioException) {
          return super.onError(e, handler);
        }
        return handler.reject(err);
      }
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
      if (!kIsWeb) {
        dio.interceptors.add(CookieManager(cookieJar));
      }
      
      // Add 401 Unauthorized interceptor (should be first)
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
    final response = await post(
      '$host/client/channels',
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
    final response = await dio.put(
      '$host/client/channels/$channelId',
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
  
  /// Delete a channel
  /// Automatically emits AppEvent.channelDeleted on success
  static Future<Response> deleteChannel(String host, String channelId) async {
    final response = await delete('$host/client/channels/$channelId');
    
    // Emit event on success
    if (response.statusCode == 200 || response.statusCode == 204) {
      debugPrint('[API SERVICE] Channel deleted successfully');
      emitEvent(AppEvent.channelDeleted, {'channelId': channelId});
    }
    
    return response;
  }
}
