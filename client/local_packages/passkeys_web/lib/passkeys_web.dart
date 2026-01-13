// Web stub for passkeys package to prevent crashes on web
// This allows the passkeys package to work on mobile while web uses custom JavaScript

/// Stub web implementation of PasskeysWeb that doesn't crash
/// Web platform uses custom JavaScript WebAuthn (see web/index.html)
class PasskeysWeb {
  /// Register the web plugin - does nothing to avoid crash
  static void registerWith(dynamic registrar) {
    // Explicitly do nothing - no operations on registrar
    // This prevents any null check errors during plugin registration
    // Web platform uses custom JavaScript WebAuthn implementation
    return;
  }

  /// Dummy constructor
  PasskeysWeb();
}
