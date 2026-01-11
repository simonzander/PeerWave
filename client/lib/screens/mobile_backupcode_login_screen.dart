import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../widgets/app_drawer.dart';
import '../services/api_service.dart';
import '../services/clientid_native.dart';
import '../services/device_identity_service.dart';
import '../services/server_config_native.dart';

/// Mobile backup code login screen for iOS/Android
///
/// Allows users to login with a backup code if biometric authentication
/// is not available or they lost access to their registered device.
class MobileBackupcodeLoginScreen extends StatefulWidget {
  final String? serverUrl;

  const MobileBackupcodeLoginScreen({super.key, this.serverUrl});

  @override
  State<MobileBackupcodeLoginScreen> createState() =>
      _MobileBackupcodeLoginScreenState();
}

class _MobileBackupcodeLoginScreenState
    extends State<MobileBackupcodeLoginScreen> {
  final _emailController = TextEditingController();
  final _backupcodeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _serverUrl;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.serverUrl;
    if (_serverUrl == null) {
      _loadSavedServer();
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _backupcodeController.dispose();
    super.dispose();
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
      debugPrint('[MobileBackupcodeLogin] Error loading saved server: $e');
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

  String? _validateBackupcode(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your backup code';
    }

    // Backup codes are typically 8 characters
    if (value.length < 8) {
      return 'Backup code must be at least 8 characters';
    }

    return null;
  }

  Future<void> _handleBackupcodeLogin() async {
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
      final backupcode = _backupcodeController.text.trim();
      final clientId = await ClientIdService.getClientId();

      debugPrint('[MobileBackupcodeLogin] Attempting login for: $email');

      // Set base URL for API service
      ApiService.setBaseUrl(_serverUrl!);

      // Call mobile backup code login endpoint (creates HMAC session)
      final response = await ApiService.dio.post(
        '$_serverUrl/backupcode/mobile-verify',
        data: {'email': email, 'backupCode': backupcode, 'clientId': clientId},
      );

      debugPrint('[MobileBackupcodeLogin] Response: ${response.statusCode}');

      if (response.statusCode == 200 && response.data['status'] == 'ok') {
        // Login successful - extract HMAC session credentials
        final sessionSecret = response.data['sessionSecret'] as String?;
        final userId = response.data['userId'] as String?;

        if (sessionSecret != null && userId != null) {
          // Store HMAC session credentials
          await DeviceIdentityService.instance.setDeviceIdentity(
            email,
            'backupcode_$email', // Placeholder credential ID
            clientId,
            serverUrl: _serverUrl,
          );

          // Save server configuration with HMAC credentials
          await ServerConfigService.addServer(
            serverUrl: _serverUrl!,
            credentials: sessionSecret,
          );

          debugPrint(
            '[MobileBackupcodeLogin] ✓ Login successful with HMAC session',
          );

          if (mounted) {
            // Navigate to app - user is authenticated
            context.go('/app');
          }
        } else {
          setState(() {
            _errorMessage = 'Authentication succeeded but session setup failed';
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _errorMessage = 'Invalid email or backup code';
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[MobileBackupcodeLogin] Error: $e');

      String errorMsg = 'Login failed';
      if (e.toString().contains('401')) {
        errorMsg = 'Invalid email or backup code';
      } else if (e.toString().contains('429')) {
        errorMsg = 'Too many attempts. Please wait and try again.';
      } else if (e.toString().contains('Network')) {
        errorMsg = 'Network error. Please check your connection.';
      } else {
        errorMsg = 'Login failed: ${e.toString()}';
      }

      setState(() {
        _errorMessage = errorMsg;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Backup Code Login'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      drawer: AppDrawer(
        isAuthenticated: false,
        currentRoute: '/mobile-backupcode',
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),

                // Logo and title
                Center(
                  child: Column(
                    children: [
                      Image.asset(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'assets/images/peerwave.png'
                            : 'assets/images/peerwave_dark.png',
                        width: 80,
                        height: 80,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Sign in with Backup Code',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Use one of your backup codes to login',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        textAlign: TextAlign.center,
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
                  textInputAction: TextInputAction.next,
                  validator: _validateEmail,
                  enabled: !_isLoading,
                ),

                const SizedBox(height: 16),

                // Backup code input
                TextFormField(
                  controller: _backupcodeController,
                  decoration: InputDecoration(
                    labelText: 'Backup Code',
                    labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    hintText: 'Enter your backup code',
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
                  validator: _validateBackupcode,
                  enabled: !_isLoading,
                  onFieldSubmitted: (_) => _handleBackupcodeLogin(),
                ),

                const SizedBox(height: 24),

                // Error message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 24),
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

                // Login button
                FilledButton.icon(
                  onPressed: _isLoading ? null : _handleBackupcodeLogin,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(_isLoading ? 'Logging in...' : 'Login'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Info card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'About Backup Codes',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Backup codes were provided during registration. Each code can only be used once. After logging in with a backup code, you should add a new biometric credential.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
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
