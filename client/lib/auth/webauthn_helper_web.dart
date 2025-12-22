// webauthn_helper_web.dart
// This file provides the web implementation for calling the JS WebAuthn function.

import 'dart:js' as js;

void webauthnLogin(String serverUrl, String email) {
  js.context.callMethod('webauthnLogin', [serverUrl, email]);
}
