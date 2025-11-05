import 'dart:js_interop';

@JS('webauthnLogin')
external JSPromise webauthnLoginJs(String serverUrl, String email);

