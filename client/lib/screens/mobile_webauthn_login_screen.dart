import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import '../services/api_service.dart';
import '../services/webauthn_service_mobile.dart';
import '../services/clientid_native.dart';
import '../services/device_identity_service.dart';
import '../services/server_config_native.dart';

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

class _MobileWebAuthnLoginScreenState extends State<MobileWebAuthnLoginScreen> {
  final _emailController = TextEditingController();
  final _invitationTokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _serverUrl;
  bool _isLoading = false;
  bool _isBiometricAvailable = false;
  List<BiometricType> _availableBiometrics = [];
  String? _errorMessage;
  bool _loadingSettings = false;
  String _registrationMode = 'open';

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.serverUrl;
    if (_serverUrl == null) {
      _loadSavedServer();
    }
    _checkBiometricAvailability();
    _loadServerSettings();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _invitationTokenController.dispose();
    super.dispose();
  }

  Future<void> _checkBiometricAvailability() async {
    final available = await MobileWebAuthnService.instance
        .isBiometricAvailable();
    final biometrics = await MobileWebAuthnService.instance
        .getAvailableBiometrics();

    setState(() {
      _isBiometricAvailable = available;
      _availableBiometrics = biometrics;
    });

    debugPrint(
      '[MobileWebAuthnLogin] Biometric available: $available, types: $biometrics',
    );
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

    setState(() {
      _loadingSettings = true;
    });

    try {
      final response = await ApiService.dio.get('$_serverUrl/client/meta');

      if (response.statusCode == 200) {
        final data = response.data;
        setState(() {
          _registrationMode = data['registrationMode'] ?? 'open';
          _loadingSettings = false;
        });
        debugPrint(
          '[MobileWebAuthnLogin] Registration mode: $_registrationMode',
        );
      } else {
        setState(() {
          _loadingSettings = false;
        });
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Failed to load server settings: $e');
      setState(() {
        _loadingSettings = false;
      });
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

  Future<void> _handleWebAuthnLogin() async {
    if (!_formKey.currentState!.validate()) {
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
      final email = _emailController.text.trim();

      // Check if credential exists
      final hasCredential = await MobileWebAuthnService.instance.hasCredential(
        _serverUrl!,
        email,
      );

      if (!hasCredential) {
        // No credential - need to register first
        setState(() {
          _errorMessage =
              'No credential found. Please register your device first.';
          _isLoading = false;
        });
        return;
      }

      // Authenticate with WebAuthn
      final authResult = await MobileWebAuthnService.instance.authenticate(
        serverUrl: _serverUrl!,
        email: email,
      );

      if (authResult == null) {
        setState(() {
          _errorMessage = 'Authentication failed. Please try again.';
          _isLoading = false;
        });
        return;
      }

      // Save server URL (TODO: Add server to ServerConfigService)
      // await ServerConfigService.addServer(serverUrl);

      // Set device identity and encryption key
      final clientId = await ClientIdService.getClientId();
      DeviceIdentityService.instance.setDeviceIdentity(
        email,
        authResult['credentialId'],
        clientId,
      );

      // Try to authenticate with server (TODO: Implement proper session verification)
      // For now, auto-navigate to app on successful WebAuthn
      debugPrint('[MobileWebAuthnLogin] ✓ Login successful');
      if (mounted) {
        context.go('/app');
      }
    } catch (e) {
      debugPrint('[MobileWebAuthnLogin] Error: $e');
      setState(() {
        _errorMessage = 'Login failed: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleWebAuthnRegister() async {
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
      debugPrint('[MobileWebAuthnLogin] Calling /register for email: $email');
      debugPrint('[MobileWebAuthnLogin] Server URL: $_serverUrl');

      // Prepare registration data
      final Map<String, dynamic> registrationData = {'email': email};

      // Add invitation token if provided and in invitation-only mode
      final invitationToken = _invitationTokenController.text.trim();
      if (invitationToken.isNotEmpty) {
        registrationData['invitationToken'] = invitationToken;
      }

      // Call /register endpoint to send OTP email
      final response = await MobileWebAuthnService.instance
          .sendRegistrationRequestWithData(
            serverUrl: _serverUrl!,
            data: registrationData,
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

  String _getBiometricIcon() {
    if (_availableBiometrics.contains(BiometricType.face)) {
      return '👤'; // Face ID
    } else if (_availableBiometrics.contains(BiometricType.fingerprint)) {
      return '👆'; // Fingerprint
    } else if (_availableBiometrics.contains(BiometricType.iris)) {
      return '👁️'; // Iris
    }
    return '🔒'; // Generic
  }

  String _getBiometricName() {
    if (_availableBiometrics.contains(BiometricType.face)) {
      return Platform.isIOS ? 'Face ID' : 'Face Recognition';
    } else if (_availableBiometrics.contains(BiometricType.fingerprint)) {
      return Platform.isIOS ? 'Touch ID' : 'Fingerprint';
    } else if (_availableBiometrics.contains(BiometricType.iris)) {
      return 'Iris Scan';
    }
    return 'Biometric';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
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

                // Email input
                TextFormField(
                  controller: _emailController,
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
                  textInputAction: _registrationMode == 'invitation_only'
                      ? TextInputAction.next
                      : TextInputAction.done,
                  validator: _validateEmail,
                  enabled: !_isLoading,
                ),

                // Invitation token field (only for invitation_only mode)
                if (_registrationMode == 'invitation_only') ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _invitationTokenController,
                    decoration: InputDecoration(
                      labelText: 'Invitation Token',
                      labelStyle: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      hintText: 'Enter your invitation token',
                      hintStyle: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withOpacity(0.6),
                      ),
                      prefixIcon: const Icon(Icons.vpn_key),
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                    ),
                    textInputAction: TextInputAction.done,
                    enabled: !_isLoading,
                  ),
                ],

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
                        Text(
                          _getBiometricIcon(),
                          style: const TextStyle(fontSize: 24),
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
                  onPressed: _isLoading || !_isBiometricAvailable
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
                    onPressed: _isLoading
                        ? null
                        : () {
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
                    onPressed: _isLoading
                        ? null
                        : () {
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
