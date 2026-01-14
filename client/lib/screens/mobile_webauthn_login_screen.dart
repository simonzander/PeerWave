import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../widgets/app_drawer.dart';
import '../services/api_service.dart';
import '../services/webauthn_service_mobile.dart';
import '../services/clientid_native.dart';
import '../services/device_identity_service.dart';
import '../services/server_config_native.dart';
import '../services/session_auth_service.dart';
import '../services/custom_tab_auth_service.dart';

/// Mobile WebAuthn login screen for iOS/Android
///
/// Second step after server selection - provides biometric authentication
/// (Face ID, Touch ID, fingerprint) for login and registration.
class MobileWebAuthnLoginScreen extends StatefulWidget {
  final String? serverUrl;

  const MobileWebAuthnLoginScreen({super.key, this.serverUrl});

  @override
  State<MobileWebAuthnLoginScreen> createState() =>
      _MobileWebAuthnLoginScreenState();
}

class _MobileWebAuthnLoginScreenState extends State<MobileWebAuthnLoginScreen>
    with WidgetsBindingObserver {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _serverUrl;
  bool _isLoading = false;
  bool _isBiometricAvailable = false;
  String? _errorMessage;
  String _registrationMode = 'open';
  bool _authInProgress = false; // Track if Chrome Custom Tab is open
  // bool _hasAttemptedAutoAuth = false; // Removed - auto-auth disabled

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serverUrl = widget.serverUrl;
    if (_serverUrl == null) {
      _loadSavedServer();
    }
    _checkBiometricAvailability();
    _loadServerSettings();
    // Auto-auth disabled - user must manually click login button
    // _emailController.addListener(_onEmailFocusChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Cancel any in-progress authentication when leaving the screen
    CustomTabAuthService.instance.cancelAuth();
    // _emailController.removeListener(_onEmailFocusChanged);
    _emailController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // If app comes back to foreground while auth was in progress,
    // assume user cancelled the Chrome Custom Tab
    if (state == AppLifecycleState.resumed && _authInProgress) {
      debugPrint(
        '[MobileWebAuthnLogin] App resumed, checking if auth was cancelled',
      );

      // Give a small delay to see if callback arrives
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_authInProgress && mounted) {
          debugPrint(
            '[MobileWebAuthnLogin] No callback received, cancelling auth',
          );
          CustomTabAuthService.instance.cancelAuth();
          setState(() {
            _isLoading = false;
            _authInProgress = false;
            _errorMessage = 'Authentication cancelled';
          });
        }
      });
    }
  }

  /// Trigger passkey selection when user starts typing email
  /// DISABLED - Auto-auth removed per user request
  /*
  void _onEmailFocusChanged() {
    if (!_hasAttemptedAutoAuth && _emailController.text.isNotEmpty) {
      _hasAttemptedAutoAuth = true;
      // Small delay to let user see they're typing
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && _isBiometricAvailable) {
          _attemptDiscoverableAuth();
        }
      });
    }
  }
  */

  /// Attempt discoverable authentication (shows passkey picker)
  /// DISABLED - Auto-auth removed per user request
  /*
  Future<void> _attemptDiscoverableAuth() async {
    if (_serverUrl == null || _isLoading) return;

    try {
      // Trigger authentication which will show the passkey picker
      // No need to check hasCredential - let Credential Manager handle it
      final email = _emailController.text.trim();
      if (email.isNotEmpty) {
        await _handleWebAuthnLogin(email: email);
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Auto-auth failed: $e');
      // Silently fail - user can still click login button
    }
  }
  */

  Future<void> _checkBiometricAvailability() async {
    final available = await MobileWebAuthnService.instance
        .isBiometricAvailable();

    setState(() {
      _isBiometricAvailable = available;
    });

    debugPrint('[MobileWebAuthnLogin] Biometric available: $available');
  }

  Future<void> _loadSavedServer() async {
    try {
      final activeServer = ServerConfigService.getActiveServer();
      if (activeServer != null) {
        setState(() {
          _serverUrl = activeServer.serverUrl;
        });
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Error loading saved server: $e');
    }
  }

  Future<void> _loadServerSettings() async {
    if (_serverUrl == null || _serverUrl!.isEmpty) {
      return;
    }

    try {
      final response = await ApiService.dio.get('$_serverUrl/client/meta');

      if (response.statusCode == 200) {
        final data = response.data;
        setState(() {
          _registrationMode = data['registrationMode'] ?? 'open';
        });
        debugPrint(
          '[MobileWebAuthnLogin] Registration mode: $_registrationMode',
        );
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Failed to load server settings: $e');
    }
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your email';
    }

    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value)) {
      return 'Invalid email format';
    }

    return null;
  }

  /// Handles WebAuthn login with automatic credential discovery
  /// If email is provided, uses it. Otherwise attempts discoverable authentication.
  Future<void> _handleWebAuthnLogin({String? email}) async {
    // Prevent double-clicks while auth is in progress
    if (_isLoading) {
      debugPrint(
        '[MobileWebAuthnLogin] Auth already in progress, ignoring click',
      );
      return;
    }

    if (email == null || email.isEmpty) {
      if (!_formKey.currentState!.validate()) {
        return;
      }
      email = _emailController.text.trim();
    }

    if (_serverUrl == null || _serverUrl!.isEmpty) {
      setState(() {
        _errorMessage = 'Server URL is required';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _authInProgress = true; // Track that Chrome Custom Tab is opening
      _errorMessage = null;
    });

    try {
      debugPrint(
        '[MobileWebAuthnLogin] Starting Chrome Custom Tab authentication',
      );

      // Set base URL for API service before authentication
      ApiService.setBaseUrl(_serverUrl!);

      // Use Chrome Custom Tab for authentication (bypasses Android Credential Manager limitations)
      // This allows full WebAuthn spec compliance and cross-RP passkey support
      final success = await CustomTabAuthService.instance.authenticate(
        serverUrl: _serverUrl!,
        email: email,
      );

      if (!mounted) return;

      // Clear auth in progress flag
      _authInProgress = false;

      if (!success) {
        setState(() {
          _errorMessage = 'Authentication failed. Please try again.';
          _isLoading = false;
        });
        return;
      }

      // Server is now saved in CustomTabAuthService.finishLogin
      // No need to save again here to avoid duplicates

      // Clear loading state before navigation
      if (mounted) {
        setState(() {
          _isLoading = false;
          _authInProgress = false;
        });
      }

      // CustomTabAuthService already handles session setup
      debugPrint(
        '[MobileWebAuthnLogin] ✓ Login successful via Chrome Custom Tab',
      );

      // Small delay to ensure setState completes before navigation
      await Future.delayed(const Duration(milliseconds: 100));

      if (mounted) {
        context.go('/app');
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Error: $e');
      if (!mounted) return;
      _authInProgress = false; // Clear flag on error
      setState(() {
        _errorMessage = 'Login failed: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleWebAuthnRegister() async {
    // Prevent double-clicks while loading
    if (_isLoading) {
      debugPrint(
        '[MobileWebAuthnLogin] Registration already in progress, ignoring click',
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your email';
      });
      return;
    }

    if (_serverUrl == null || _serverUrl!.isEmpty) {
      setState(() {
        _errorMessage = 'Server URL is required';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      debugPrint('[MobileWebAuthnLogin] Checking registration mode...');

      // Check if server requires invitation (match web flow)
      if (_registrationMode == 'invitation_only') {
        debugPrint(
          '[MobileWebAuthnLogin] Invitation required, navigating to invitation page',
        );
        setState(() => _isLoading = false);
        if (mounted) {
          context.go(
            '/register/invitation',
            extra: {'email': email, 'serverUrl': _serverUrl},
          );
        }
        return;
      }

      // If open or email_suffix mode, proceed directly to OTP
      debugPrint('[MobileWebAuthnLogin] Calling /register for email: $email');
      debugPrint('[MobileWebAuthnLogin] Server URL: $_serverUrl');

      // Call /register endpoint to send OTP email
      final response = await MobileWebAuthnService.instance
          .sendRegistrationRequestWithData(
            serverUrl: _serverUrl!,
            data: {'email': email},
          );

      debugPrint('[MobileWebAuthnLogin] Register response: $response');

      // Navigate to OTP page with wait time from server
      if (mounted) {
        final wait = response['wait'] ?? 0;
        debugPrint('[MobileWebAuthnLogin] Navigating to OTP with wait: $wait');

        context.go(
          '/otp',
          extra: {'email': email, 'serverUrl': _serverUrl!, 'wait': wait},
        );
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Registration error: $e');
      setState(() {
        _errorMessage = 'Registration failed: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  String _getBiometricName() {
    // Passkeys uses platform-specific biometrics
    if (Platform.isIOS) {
      return 'Face ID or Touch ID';
    } else {
      return 'Biometric';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Sign In'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
      ),
      drawer: AppDrawer(
        isAuthenticated: false,
        currentRoute: '/mobile-webauthn',
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 48),

                // Logo and title
                Center(
                  child: Column(
                    children: [
                      Image.asset(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'assets/images/peerwave.png'
                            : 'assets/images/peerwave_dark.png',
                        width: 100,
                        height: 100,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'PeerWave',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in with ${_getBiometricName()}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if (_serverUrl != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _serverUrl!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 48),

                // Email input with passkey autofill support
                TextFormField(
                  controller: _emailController,
                  autofillHints: const [
                    AutofillHints.email,
                    AutofillHints.username,
                  ],
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    hintText: 'you@example.com',
                    hintStyle: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withOpacity(0.6),
                    ),
                    prefixIcon: const Icon(Icons.email),
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  validator: _validateEmail,
                  enabled: !_isLoading,
                ),

                const SizedBox(height: 24),

                // Error message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (_errorMessage != null) const SizedBox(height: 24),

                // Biometric status
                if (_isBiometricAvailable)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Platform.isIOS ? Icons.face : Icons.fingerprint,
                          size: 24,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '${_getBiometricName()} is ready',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Biometric authentication not available',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 24),

                // Login button
                FilledButton.icon(
                  onPressed: _isLoading || !_isBiometricAvailable
                      ? null
                      : _handleWebAuthnLogin,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fingerprint),
                  label: Text(_isLoading ? 'Authenticating...' : 'Sign In'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),

                const SizedBox(height: 12),

                // Register button
                OutlinedButton.icon(
                  onPressed: !_isBiometricAvailable
                      ? null
                      : _handleWebAuthnRegister,
                  icon: const Icon(Icons.add_moderator),
                  label: const Text('Create Account'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),

                const SizedBox(height: 24),

                // Fallback to magic key
                const Divider(),
                const SizedBox(height: 16),

                // Backup code login button
                Center(
                  child: TextButton.icon(
                    onPressed: () {
                      context.go(
                        '/mobile-backupcode-login',
                        extra: {'serverUrl': _serverUrl},
                      );
                    },
                    icon: const Icon(Icons.vpn_key),
                    label: const Text('Login with Backup Code'),
                  ),
                ),

                const SizedBox(height: 8),

                Center(
                  child: TextButton.icon(
                    onPressed: () {
                      context.go('/mobile-server-selection');
                    },
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Change Server'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
