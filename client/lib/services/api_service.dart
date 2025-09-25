import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

class ApiService {
  static final Dio dio = Dio();
  static final CookieJar cookieJar = CookieJar();
  static bool _initialized = false;

  static void init() {
    if (!_initialized) {
      dio.interceptors.add(CookieManager(cookieJar));
      _initialized = true;
    }
  }
}
