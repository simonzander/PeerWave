
import 'dart:js_interop';
import '../web_config.dart';
import '../services/api_service.dart';
// Only for web:
// ignore: avoid_web_libraries_in_flutter


@JS('window.fetch')
external JSPromise fetch(
  String input,
  JSAny? init,
);

@JS()
class AuthService {
  static bool isLoggedIn = false;

  /*static Future<bool> login(String email, String password) async {
    await Future.delayed(const Duration(seconds: 1)); // Fake API Call
    isLoggedIn = true;
    return true;
  }

  static void logout() {
    isLoggedIn = false;
  }*/

  static Future<bool> checkSession() async {
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/webauthn/check');
      if (resp.statusCode == 200 && resp.data != null) {
        final body = resp.data.toString();
        if (body.contains('{authenticated: true}')) {
          isLoggedIn = true;
          return true;
        }
      }
    } catch (e) {
      isLoggedIn = false;
      return false;
    }
    isLoggedIn = false;
    return false;
  }
}


