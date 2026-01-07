// Web stub for passkeys package to prevent crashes on web
// This allows the passkeys package to work on mobile while web uses custom JavaScript
library passkeys_web_stub;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Stub web implementation of PasskeysWeb that doesn't crash
/// Web platform uses custom JavaScript WebAuthn (see web/index.html)
class PasskeysWeb {
  static void registerWith(Registrar registrar) {
    // Do nothing - this prevents the crash
    // Web uses custom JavaScript WebAuthn implementation instead
    print('[PasskeysWeb] Stub registered - using custom JavaScript WebAuthn');
  }
}
