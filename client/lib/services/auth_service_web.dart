
import 'package:flutter/foundation.dart';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:js/js_util.dart' as js_util;
import 'package:js/js.dart';
import '../web_config.dart';
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
      if (kIsWeb) {
        final requestInit = JSObject();
        requestInit['method'] = 'GET'.toJS;
        final headers = JSObject();
        headers['Accept'] = 'application/json'.toJS;
        requestInit['headers'] = headers;
        requestInit['credentials'] = 'include'.toJS;
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        final promise = fetch('$urlString/webauthn/check', requestInit);
        final response = await promise.toDart;
        if (response != null) {
          final textPromise = (response as JSObject).callMethod('text'.toJS, <JSAny>[].toJS);
          final body = textPromise != null ? await js_util.promiseToFuture(textPromise) as String : '';
          if (body.contains('"authenticated":true')) {
            isLoggedIn = true;
            return true;
          }
        }
      }
    } catch (e) {
      isLoggedIn = false;
      return false;
    }
    // Ensure a bool is always returned
    isLoggedIn = false;
    return false;
  }
}

