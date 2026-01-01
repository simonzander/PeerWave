import 'webauthn_provider.dart';
import 'webauthn_provider_web.dart';

/// Stub implementation - should never be called
IWebAuthnProvider createProvider() {
  return WebAuthnProviderWeb();
}
