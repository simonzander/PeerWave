import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

class ApiService {
  static final Dio dio = Dio();
  static final CookieJar cookieJar = CookieJar();
  static bool _initialized = false;

  static void init() {
    if (!_initialized) {
      if (!kIsWeb) {
        dio.interceptors.add(CookieManager(cookieJar));
      }
      _initialized = true;
    }
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
}
