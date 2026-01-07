// Fixed web implementation of passkeys that doesn't crash
// This allows mobile passkeys to work while web uses custom JavaScript
library passkeys_web;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Fixed web implementation that doesn't crash during initialization
/// Web platform uses custom JavaScript WebAuthn (see web/index.html)
class PasskeysWeb {
  /// Register the web plugin - does nothing to avoid crash
  static void registerWith(Registrar registrar) {
    // Empty implementation - prevents null reference crash
    // Web uses custom JavaScript WebAuthn implementation
    print(
        '[PasskeysWeb] ✓ Fixed stub registered - using custom JavaScript WebAuthn');
  }

  /// Dummy constructor
  PasskeysWeb();
}
