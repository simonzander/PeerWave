import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'socket_service.dart';
import 'signal_setup_service.dart';
import 'user_profile_service.dart';
import 'api_service.dart';
import '../web_config.dart';
import '../providers/role_provider.dart';
import '../providers/unread_messages_provider.dart';
// Import auth service conditionally
import 'auth_service_web.dart' if (dart.library.io) 'auth_service_native.dart';

/// Centralized logout service
/// Handles all cleanup and navigation on logout
class LogoutService {
  static final LogoutService instance = LogoutService._internal();
  factory LogoutService() => instance;
  LogoutService._internal();

  bool _isLoggingOut = false;

  /// Perform logout with full cleanup
  /// 
  /// This should be called:
  /// - When user clicks logout button
  /// - When 401 Unauthorized is received
  /// - When session expires
  Future<void> logout(BuildContext context, {bool showMessage = true}) async {
    if (_isLoggingOut) {
      print('[LOGOUT] Already logging out, skipping duplicate call');
      return;
    }

    _isLoggingOut = true;

    try {
      print('[LOGOUT] ========================================');
      print('[LOGOUT] Starting logout process...');
      print('[LOGOUT] ========================================');

      // 1. Disconnect socket
      if (SocketService().isConnected) {
        print('[LOGOUT] Disconnecting socket...');
        SocketService().disconnect();
      }

      // 2. Cleanup SignalSetupService
      print('[LOGOUT] Cleaning up Signal setup...');
      SignalSetupService.instance.cleanupOnLogout();

      // 3. Clear user profiles cache
      print('[LOGOUT] Clearing user profiles...');
      UserProfileService.instance.clearCache();

      // 4. Clear roles
      if (context.mounted) {
        try {
          final roleProvider = context.read<RoleProvider>();
          print('[LOGOUT] Clearing roles...');
          roleProvider.clearRoles();
        } catch (e) {
          print('[LOGOUT] Error clearing roles: $e');
        }
      }

      // 5. Clear unread messages
      if (context.mounted) {
        try {
          final unreadProvider = context.read<UnreadMessagesProvider>();
          print('[LOGOUT] Clearing unread messages...');
          unreadProvider.resetAll();
        } catch (e) {
          print('[LOGOUT] Error clearing unread messages: $e');
        }
      }

      // 6. Call server logout endpoint
      try {
        print('[LOGOUT] Calling server logout endpoint...');
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        
        ApiService.init();
        await ApiService.post('$urlString/auth/logout');
        print('[LOGOUT] ✓ Server logout successful');
      } catch (e) {
        print('[LOGOUT] ⚠ Server logout failed (may already be logged out): $e');
      }

      // 7. Clear local auth state
      print('[LOGOUT] Clearing local auth state...');
      AuthService.isLoggedIn = false;

      print('[LOGOUT] ========================================');
      print('[LOGOUT] ✅ Logout complete');
      print('[LOGOUT] ========================================');

      // 8. Show message if requested
      if (showMessage && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Logged out successfully'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // 9. Navigate to login screen
      if (context.mounted) {
        print('[LOGOUT] Navigating to login screen...');
        GoRouter.of(context).go('/login');
      }
    } finally {
      _isLoggingOut = false;
    }
  }

  /// Auto-logout on 401 Unauthorized
  /// This is called from interceptors when server returns 401
  Future<void> autoLogout(BuildContext context) async {
    print('[LOGOUT] ⚠️  401 Unauthorized detected - auto-logout');
    
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session expired. Please login again.'),
          duration: Duration(seconds: 3),
          backgroundColor: Colors.orange,
        ),
      );
    }
    
    await logout(context, showMessage: false);
  }
}
