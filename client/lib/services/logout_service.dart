import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'dart:html' as html show window;
import 'package:go_router/go_router.dart';
import 'socket_service.dart';
import 'signal_setup_service.dart';
import 'user_profile_service.dart';
import 'api_service.dart';
import '../web_config.dart';
import 'webauthn_service.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';
// Import auth service conditionally
import 'auth_service_web.dart' if (dart.library.io) 'auth_service_native.dart';

/// Centralized logout service
/// Handles all cleanup and navigation on logout
class LogoutService {
  static final LogoutService instance = LogoutService._internal();
  factory LogoutService() => instance;
  LogoutService._internal();

  bool _isLoggingOut = false;
  bool _logoutComplete = false;

  /// Check if logout was just completed (for redirect handler)
  bool get isLogoutComplete => _logoutComplete;

  /// Perform logout with full cleanup
  /// 
  /// This should be called:
  /// - When user clicks logout button
  /// - When 401 Unauthorized is received
  /// - When session expires
  Future<void> logout(BuildContext? context, {bool showMessage = true}) async {
    if (_isLoggingOut) {
      debugPrint('[LOGOUT] Already logging out, skipping duplicate call');
      return;
    }

    _isLoggingOut = true;
    _logoutComplete = false;

    try {
      debugPrint('[LOGOUT] ========================================');
      debugPrint('[LOGOUT] Starting logout process...');
      debugPrint('[LOGOUT] ========================================');

      // 1. Disconnect socket
      if (SocketService().isConnected) {
        debugPrint('[LOGOUT] Disconnecting socket...');
        SocketService().disconnect();
      }

      // 2. Cleanup SignalSetupService
      debugPrint('[LOGOUT] Cleaning up Signal setup...');
      SignalSetupService.instance.cleanupOnLogout();

      // 3. Clear user profiles cache
      debugPrint('[LOGOUT] Clearing user profiles...');
      UserProfileService.instance.clearCache();

      // 4. Clear WebAuthn encryption data
      debugPrint('[LOGOUT] Clearing WebAuthn encryption data...');
      try {
        // Clear encryption key from SessionStorage
        final deviceId = DeviceIdentityService.instance.deviceId;
        if (deviceId.isNotEmpty) {
          WebAuthnCryptoService.instance.clearKeyFromSession(deviceId);
          debugPrint('[LOGOUT] ✓ Encryption key cleared from SessionStorage');
        }
        
        // Clear device identity
        DeviceIdentityService.instance.clearDeviceIdentity();
        debugPrint('[LOGOUT] ✓ Device identity cleared');
        
        // Clear WebAuthn response data
        WebAuthnService.instance.clearWebAuthnData();
        debugPrint('[LOGOUT] ✓ WebAuthn data cleared');
        
        // CRITICAL: Clear ALL SessionStorage keys to prevent data leakage between users
        if (kIsWeb) {
          try {
            // Clear peerwave_encryption_key_* keys
            final storage = html.window.sessionStorage;
            final keysToRemove = <String>[];
            for (var i = 0; i < storage.length; i++) {
              final key = storage.keys.elementAt(i);
              if (key.startsWith('peerwave_encryption_key_')) {
                keysToRemove.add(key);
              }
            }
            for (var key in keysToRemove) {
              storage.remove(key);
              debugPrint('[LOGOUT] ✓ Removed SessionStorage key: $key');
            }
            
            // Clear device_identity_* keys
            final deviceKeys = <String>[];
            for (var i = 0; i < storage.length; i++) {
              final key = storage.keys.elementAt(i);
              if (key.startsWith('device_identity_')) {
                deviceKeys.add(key);
              }
            }
            for (var key in deviceKeys) {
              storage.remove(key);
              debugPrint('[LOGOUT] ✓ Removed SessionStorage key: $key');
            }
            
            debugPrint('[LOGOUT] ✓ All encryption keys cleared from SessionStorage');
          } catch (e) {
            debugPrint('[LOGOUT] ⚠ Error clearing SessionStorage: $e');
          }
          
          // CRITICAL: Remove deprecated localStorage items (clientid, email)
          try {
            final localStorage = html.window.localStorage;
            if (localStorage.containsKey('clientid')) {
              localStorage.remove('clientid');
              debugPrint('[LOGOUT] ✓ Removed deprecated localStorage key: clientid');
            }
            debugPrint('[LOGOUT] ✓ Cleaned up deprecated localStorage items');
          } catch (e) {
            debugPrint('[LOGOUT] ⚠ Error clearing localStorage: $e');
          }
        }
      } catch (e) {
        debugPrint('[LOGOUT] ⚠ Error clearing encryption data: $e');
      }

      // Note: Roles and unread messages will be cleared by redirect handler
      // when AuthService.isLoggedIn becomes false

      // 5. Call server logout endpoint FIRST
      try {
        debugPrint('[LOGOUT] Calling server logout endpoint...');
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        
        ApiService.init();
        await ApiService.post('$urlString/auth/logout');
        debugPrint('[LOGOUT] ✓ Server logout successful');
      } catch (e) {
        debugPrint('[LOGOUT] ⚠ Server logout failed (may already be logged out): $e');
      }

      // 6. Clear local auth state
      debugPrint('[LOGOUT] Clearing local auth state...');
      AuthService.isLoggedIn = false;
      _logoutComplete = true;

      debugPrint('[LOGOUT] ========================================');
      debugPrint('[LOGOUT] ✅ Logout complete');
      debugPrint('[LOGOUT] ========================================');

      // 7. Show message if requested (BEFORE navigation)
      final validContext = context;
      if (showMessage && validContext != null && validContext.mounted) {
        try {
          ScaffoldMessenger.of(validContext).showSnackBar(
            const SnackBar(
              content: Text('Logged out successfully'),
              duration: Duration(seconds: 2),
            ),
          );
        } catch (e) {
          debugPrint('[LOGOUT] ⚠ Could not show logout message (ScaffoldMessenger not available): $e');
        }
      }

      // 8. Navigate to login screen LAST
      // Use a small delay to ensure the state is fully updated
      await Future.delayed(const Duration(milliseconds: 50));
      
      // After logout, we need to navigate to login
      // This is tricky because the context might not have GoRouter available
      // The strategy is:
      // 1. Try to use context.go if available
      // 2. If that fails, just set a flag and let redirect handler catch it on next navigation
      // 3. The redirect handler will see isLoggedIn = false and redirect to /login
      
      if (validContext != null && validContext.mounted) {
        try {
          debugPrint('[LOGOUT] Attempting navigation to login screen...');
          
          // Try to get GoRouter and navigate
          try {
            final router = GoRouter.of(validContext);
            
            // Refresh the router to trigger redirect logic with new isLoggedIn state
            router.refresh();
            debugPrint('[LOGOUT] ✓ Router refreshed');
            
            // Then navigate to login after a brief delay
            await Future.delayed(const Duration(milliseconds: 100));
            router.go('/login');
            debugPrint('[LOGOUT] ✓ Navigation to /login triggered');
          } catch (routerError) {
            // GoRouter not available in this context
            // This happens when logout is called from unauthorized handlers
            // before the router is fully initialized
            debugPrint('[LOGOUT] ⚠ GoRouter not in context (expected during initialization)');
            
            // Force a page reload to trigger redirect
            // In web, we can reload the page which will check auth state
            if (kIsWeb) {
              debugPrint('[LOGOUT] 🔄 Reloading page to trigger auth check...');
              // Use a small delay to ensure cleanup is complete
              await Future.delayed(const Duration(milliseconds: 200));
              html.window.location.reload();
            } else {
              // On native, redirect handler will catch it
              debugPrint('[LOGOUT] Waiting for redirect handler to catch navigation');
            }
          }
        } catch (e) {
          debugPrint('[LOGOUT] ⚠ Navigation error: $e');
        }
        
        // Reset logout complete flag after navigation
        await Future.delayed(const Duration(milliseconds: 500));
        _logoutComplete = false;
      } else {
        debugPrint('[LOGOUT] No valid context - relying on redirect handler');
        // Reset logout complete flag
        await Future.delayed(const Duration(milliseconds: 500));
        _logoutComplete = false;
      }
    } finally {
      _isLoggingOut = false;
    }
  }

  /// Auto-logout on 401 Unauthorized
  /// This is called from interceptors when server returns 401
  Future<void> autoLogout(BuildContext? context) async {
    debugPrint('[LOGOUT] ⚠️  401 Unauthorized detected - auto-logout');
    
    // Perform logout first (without showing success message)
    await logout(context, showMessage: false);
    
    // Then show persistent snackbar with login link
    final validContext = context;
    if (validContext != null && validContext.mounted) {
      try {
        ScaffoldMessenger.of(validContext).showSnackBar(
          SnackBar(
            content: const Text('Session expired. Please login again.'),
            duration: const Duration(seconds: 10),
            backgroundColor: Colors.orange,
            action: SnackBarAction(
              label: 'Login',
              textColor: Colors.white,
              onPressed: () {
                if (validContext.mounted) {
                  try {
                    GoRouter.of(validContext).go('/login');
                  } catch (e) {
                    debugPrint('[LOGOUT] Could not navigate to login: $e');
                  }
                }
              },
            ),
          ),
        );
      } catch (e) {
        debugPrint('[LOGOUT] ⚠ Could not show session expired message (ScaffoldMessenger not available): $e');
      }
    } else {
      debugPrint('[LOGOUT] No valid context - session expired, redirect handler will navigate to /login');
    }
  }
}

