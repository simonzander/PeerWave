// Web stub for passkeys package to prevent crashes on web
// This allows the passkeys package to work on mobile while web uses custom JavaScript

/// Stub web implementation of PasskeysWeb that doesn't crash
/// Web platform uses custom JavaScript WebAuthn (see web/index.html)
class PasskeysWeb {
  /// Register the web plugin - does nothing to avoid crash
  static void registerWith(dynamic registrar) {
    // Empty implementation - prevents null reference crash
    // Web uses custom JavaScript WebAuthn implementation
  }

  /// Dummy constructor
  PasskeysWeb();
}
