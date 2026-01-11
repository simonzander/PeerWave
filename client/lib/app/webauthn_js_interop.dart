// Web-only JS interop implementations
import 'dart:js_interop';

@JS('window.localStorage.getItem')
external JSString? _localStorageGetItem(JSString key);

@JS('webauthnRegister')
external JSPromise _webauthnRegister(JSString serverUrl, JSString email);

String? getLocalStorageEmail() {
  try {
    final email = _localStorageGetItem('email'.toJS)?.toDart;
    return email;
  } catch (e) {
    return null;
  }
}

Future<bool> webauthnRegister(String serverUrl, String email) async {
  try {
    final result = await _webauthnRegister(serverUrl.toJS, email.toJS).toDart;
    return result.dartify() == true;
  } catch (e) {
    return false;
  }
}
