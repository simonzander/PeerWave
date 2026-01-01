import 'dart:io';
import 'webauthn_provider.dart';
import 'webauthn_provider_mobile.dart';
import 'webauthn_provider_desktop.dart';

/// IO implementation - selects between mobile and desktop
IWebAuthnProvider createProvider() {
  if (Platform.isAndroid || Platform.isIOS) {
    return WebAuthnProviderMobile();
  } else {
    return WebAuthnProviderDesktop();
  }
}
