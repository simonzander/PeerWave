import 'webauthn_provider.dart';
import 'webauthn_provider_stub.dart'
    if (dart.library.html) 'webauthn_provider_web.dart'
    if (dart.library.io) 'webauthn_provider_io.dart';

/// Factory to get the correct WebAuthn provider based on platform
class WebAuthnProviderFactory {
  static IWebAuthnProvider? _instance;

  /// Get the WebAuthn provider for the current platform
  static IWebAuthnProvider getInstance() {
    _instance ??= createProvider();
    return _instance!;
  }
}
