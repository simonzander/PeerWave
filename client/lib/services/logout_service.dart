import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'socket_service.dart';
import 'signal_setup_service.dart';
import 'user_profile_service.dart';
import 'api_service.dart';
import '../web_config.dart';
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

      // Note: Roles and unread messages will be cleared by redirect handler
      // when AuthService.isLoggedIn becomes false

      // 4. Call server logout endpoint FIRST
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

      // 5. Clear local auth state
      debugPrint('[LOGOUT] Clearing local auth state...');
      AuthService.isLoggedIn = false;
      _logoutComplete = true;

      debugPrint('[LOGOUT] ========================================');
      debugPrint('[LOGOUT] ✅ Logout complete');
      debugPrint('[LOGOUT] ========================================');

      // 6. Show message if requested (BEFORE navigation)
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

      // 7. Navigate to login screen LAST
      // Use a small delay to ensure the state is fully updated
      await Future.delayed(const Duration(milliseconds: 50));
      if (validContext != null && validContext.mounted) {
        try {
          debugPrint('[LOGOUT] Navigating to login screen...');
          validContext.go('/login');
          debugPrint('[LOGOUT] ✓ Navigation to /login triggered');
        } catch (e) {
          debugPrint('[LOGOUT] ⚠ Could not navigate (GoRouter not available): $e');
          // If navigation fails, the redirect handler in main.dart will catch it
          debugPrint('[LOGOUT] Redirect handler will handle navigation to /login');
        }
        
        // Reset logout complete flag after navigation
        await Future.delayed(const Duration(milliseconds: 500));
        _logoutComplete = false;
      } else {
        debugPrint('[LOGOUT] No valid context for navigation - redirect handler will handle it');
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

