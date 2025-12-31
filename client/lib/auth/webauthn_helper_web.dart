// webauthn_helper_web.dart
// This file provides the web implementation for calling the JS WebAuthn function.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void webauthnLogin(String serverUrl, String email) {
  globalContext.callMethod('webauthnLogin'.toJS, serverUrl.toJS, email.toJS);
}
