import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:universal_html/html.dart' as html show window;
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import 'socket_service.dart' if (dart.library.io) 'socket_service_native.dart';
import 'signal_setup_service.dart';
import 'user_profile_service.dart';
import 'api_service.dart';
import '../web_config.dart';
import 'webauthn_service.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';
import 'native_crypto_service.dart';
import 'session_auth_service.dart';
import 'clientid_native.dart';
import 'server_config_web.dart' if (dart.library.io) 'server_config_native.dart';
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
  /// - When user clicks logout button (userInitiated = true)
  /// - When 401 Unauthorized is received (userInitiated = false)
  /// - When session expires (userInitiated = false)
  Future<void> logout(BuildContext? context, {bool showMessage = true, bool userInitiated = false}) async {
    if (_isLoggingOut) {
      debugPrint('[LOGOUT] Already logging out, skipping duplicate call');
      return;
    }

    _isLoggingOut = true;
    _logoutComplete = false;

    try {
      debugPrint('[LOGOUT] ========================================');
      debugPrint('[LOGOUT] Starting logout process... (userInitiated: $userInitiated)');
      debugPrint('[LOGOUT] ========================================');

      // NATIVE ONLY: Check authentication status before proceeding with logout
      // BUT: Skip check if user explicitly clicked logout button
      if (!kIsWeb && !userInitiated) {
        try {
          debugPrint('[LOGOUT] Native: Checking authentication status before auto-logout...');
          
          final clientId = await ClientIdService.getClientId();
          final hasSession = await SessionAuthService().hasSession(clientId);
          
          if (hasSession) {
            // Generate auth headers
            final authHeaders = await SessionAuthService().generateAuthHeaders(
              clientId: clientId,
              requestPath: '/client/auth/check',
              requestBody: null,
            );
            
            // Make request to auth check endpoint
            String? urlString;
            if (kIsWeb) {
              final apiServer = await loadWebApiServer();
              urlString = apiServer ?? '';
              if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
                urlString = 'https://$urlString';
              }
            } else {
              // Native: Use active server from ServerConfigService
              final activeServer = ServerConfigService.getActiveServer();
              if (activeServer == null) {
                debugPrint('[LOGOUT] No active server configured, proceeding with logout');
                // No server configured, can't check auth, proceed with logout
                urlString = null;
              } else {
                urlString = activeServer.serverUrl;
              }
            }
            
            if (urlString == null || urlString.isEmpty) {
              debugPrint('[LOGOUT] No server URL available, proceeding with logout');
              // Continue with logout below
            } else {
              final response = await ApiService.dio.get(
                '$urlString/client/auth/check',
                options: Options(
                  headers: authHeaders,
                  validateStatus: (status) => true, // Accept any status code
                ),
              );
              
              debugPrint('[LOGOUT] Auth check response: ${response.statusCode}');
              
              if (response.statusCode == 200 && response.data != null) {
                final authData = response.data as Map<String, dynamic>;
                final isAuthenticated = authData['authenticated'] == true;
                
                if (isAuthenticated) {
                  debugPrint('[LOGOUT] ✓ Session is still valid - preventing auto-logout');
                  
                  // Show snackbar that user doesn't have permission to logout
                  final validContext = context;
                  if (validContext != null && validContext.mounted) {
                    ScaffoldMessenger.of(validContext).showSnackBar(
                      const SnackBar(
                        content: Text('You don\'t have permission for this action'),
                        duration: Duration(seconds: 3),
                        backgroundColor: Colors.orange,
                      ),
                    );
                    
                    // Redirect to /app
                    await Future.delayed(const Duration(milliseconds: 100));
                    if (!validContext.mounted) return;
                    GoRouter.of(validContext).go('/app');
                  }
                  
                  _isLoggingOut = false;
                  return; // Stop logout procedure
                } else {
                  debugPrint('[LOGOUT] Session invalid (${authData['reason']}), proceeding with logout');
                }
              } else {
                debugPrint('[LOGOUT] Auth check failed (status: ${response.statusCode}), proceeding with logout');
              }
            }
          } else {
            debugPrint('[LOGOUT] No session found, proceeding with logout');
          }
        } catch (e) {
          debugPrint('[LOGOUT] Auth check error: $e, proceeding with logout');
          // Continue with logout on error
        }
      } else if (!kIsWeb && userInitiated) {
        debugPrint('[LOGOUT] User-initiated logout - skipping auth check');
      }

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

      // 4. For NATIVE: Clear HMAC session (but keep database)
      if (!kIsWeb) {
        try {
          debugPrint('[LOGOUT] Clearing HMAC session for native client...');
          final clientId = await ClientIdService.getClientId();
          await SessionAuthService().clearSession(clientId);
          debugPrint('[LOGOUT] ✓ HMAC session cleared (database preserved)');
        } catch (e) {
          debugPrint('[LOGOUT] ⚠ Error clearing HMAC session: $e');
        }
      }

      // 5. Clear encryption data (platform-specific)
      if (kIsWeb) {
        debugPrint('[LOGOUT] Clearing WebAuthn encryption data...');
        try {
          // Clear encryption key from SessionStorage
          final deviceId = DeviceIdentityService.instance.deviceId;
        if (deviceId.isNotEmpty) {
          WebAuthnCryptoService.instance.clearKeyFromSession(deviceId);
          debugPrint('[LOGOUT] ✓ Encryption key cleared from SessionStorage');
        }
        
        // Clear device identity
        await DeviceIdentityService.instance.clearDeviceIdentity();
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
      } else {
        // Native: Clear encryption key and device identity from secure storage
        debugPrint('[LOGOUT] Clearing native encryption data...');
        try {
          final deviceId = DeviceIdentityService.instance.deviceId;
          if (deviceId.isNotEmpty) {
            await NativeCryptoService.instance.clearKey(deviceId);
            debugPrint('[LOGOUT] ✓ Encryption key cleared from secure storage');
          }
          
          // Clear device identity for current server only (preserve other servers)
          final activeServer = ServerConfigService.getActiveServer();
          if (activeServer != null) {
            await DeviceIdentityService.instance.clearDeviceIdentity(
              serverUrl: activeServer.serverUrl
            );
            debugPrint('[LOGOUT] ✓ Device identity cleared for server: ${activeServer.serverUrl}');
          } else {
            await DeviceIdentityService.instance.clearDeviceIdentity();
            debugPrint('[LOGOUT] ✓ Device identity cleared (no active server)');
          }
        } catch (e) {
          debugPrint('[LOGOUT] ⚠ Error clearing native encryption data: $e');
        }
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
        await ApiService.post('$urlString/logout');
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

  /// Auto-logout using navigator key (for interceptors that don't have valid context)
  Future<void> autoLogoutWithNavigatorKey(GlobalKey<NavigatorState> navigatorKey) async {
    debugPrint('[LOGOUT] 🔴 Auto-logout triggered - 401 Unauthorized (using navigator key)');
    debugPrint('[LOGOUT] Platform: ${kIsWeb ? "Web" : "Native"}');
    
    // Perform logout first (without showing success message)
    await logout(null, showMessage: false);
    
    // Get context from navigator key
    final context = navigatorKey.currentContext;
    debugPrint('[LOGOUT] Navigator context available: ${context != null}');
    
    if (context != null && context.mounted) {
      try {
        if (!kIsWeb) {
          // Native: Go to server selection for re-authentication
          debugPrint('[LOGOUT] Native: Redirecting to server selection for re-authentication');
          
          // Navigate to server-selection (works for both re-auth and adding new servers)
          GoRouter.of(context).go('/server-selection');
          
          // Show message after navigation
          Future.delayed(const Duration(milliseconds: 300), () {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Session expired. Please scan a new magic key to re-authenticate.'),
                  duration: Duration(seconds: 5),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          });
        } else {
          // Web: Show login link
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Session expired. Please login again.'),
              duration: const Duration(seconds: 10),
              backgroundColor: Colors.orange,
              action: SnackBarAction(
                label: 'Login',
                textColor: Colors.white,
                onPressed: () {
                  if (context.mounted) {
                    try {
                      GoRouter.of(context).go('/login');
                    } catch (e) {
                      debugPrint('[LOGOUT] Could not navigate to login: $e');
                    }
                  }
                },
              ),
            ),
          );
        }
      } catch (e) {
        debugPrint('[LOGOUT] ⚠️ Could not show session expired message: $e');
      }
    } else {
      debugPrint('[LOGOUT] ⚠️ No valid context available from navigator key');
    }
  }

  /// Auto-logout on 401 Unauthorized
  /// This is called from interceptors when server returns 401
  Future<void> autoLogout(BuildContext? context) async {
    debugPrint('[LOGOUT] 🔴 Auto-logout triggered - 401 Unauthorized');
    debugPrint('[LOGOUT] Context provided: ${context != null}');
    debugPrint('[LOGOUT] Context mounted: ${context?.mounted}');
    debugPrint('[LOGOUT] Platform: ${kIsWeb ? "Web" : "Native"}');
    
    // Perform logout first (without showing success message)
    await logout(context, showMessage: false);
    
    // For native: Navigate to server selection (they can re-auth with magic key)
    // For web: Navigate to login
    final validContext = context;
    if (validContext != null && validContext.mounted) {
      try {
        if (!kIsWeb) {
          // Native: Go to server selection where they can scan magic key
          debugPrint('[LOGOUT] Native: Redirecting to server selection for re-authentication');
          ScaffoldMessenger.of(validContext).showSnackBar(
            const SnackBar(
              content: Text('Session expired. Please scan a new magic key to re-authenticate.'),
              duration: Duration(seconds: 5),
              backgroundColor: Colors.orange,
            ),
          );
          await Future.delayed(const Duration(milliseconds: 100));
          if (!validContext.mounted) return;
          GoRouter.of(validContext).go('/server-selection');
        } else {
          // Web: Show login link
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
        }
      } catch (e) {
        debugPrint('[LOGOUT] ⚠ Could not show session expired message: $e');
      }
    } else {
      debugPrint('[LOGOUT] No valid context - session expired, redirect handler will navigate');
    }
  }
}

