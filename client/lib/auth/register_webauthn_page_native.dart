import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/webauthn_service_mobile.dart';
import '../services/clientid_native.dart';
import '../services/device_identity_service.dart';
import '../services/server_config_native.dart';
import '../services/api_service.dart';
import '../widgets/registration_progress_bar.dart';
import '../widgets/app_drawer.dart';
import '../extensions/snackbar_extensions.dart';

/// Native WebAuthn registration page
/// - Mobile (iOS/Android): List registered credentials and allow adding new biometric credentials
/// - Desktop: Show message that magic key authentication is used

class RegisterWebauthnPage extends StatefulWidget {
  final String? serverUrl;
  final String? email; // Email from registration flow

  const RegisterWebauthnPage({super.key, this.serverUrl, this.email});

  @override
  State<RegisterWebauthnPage> createState() => _RegisterWebauthnPageState();
}

class _RegisterWebauthnPageState extends State<RegisterWebauthnPage> {
  List<Map<String, dynamic>> webauthnCredentials = [];
  bool loading = false;
  String? _error;
  String? _serverUrl;

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.serverUrl;
    if (_serverUrl == null) {
      final activeServer = ServerConfigService.getActiveServer();
      _serverUrl = activeServer?.serverUrl;
    }

    // Load existing credentials
    if (Platform.isAndroid || Platform.isIOS) {
      _loadWebauthnCredentials();
    }
  }

  Future<void> _loadWebauthnCredentials() async {
    setState(() {
      loading = true;
      _error = null;
    });
    try {
      final resp = await ApiService.instance.get(
        _serverUrl != null ? '$_serverUrl/webauthn/list' : '/webauthn/list',
      );
      if (resp.statusCode == 200 && resp.data != null) {
        if (resp.data is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(resp.data);
          });
        } else if (resp.data is Map && resp.data['credentials'] is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(
              resp.data['credentials'],
            );
          });
        }
      }
    } catch (e) {
      debugPrint('[WebAuthnRegister] Error loading credentials: $e');
      setState(() {
        _error = 'Failed to load credentials: $e';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _addCredential() async {
    if (_serverUrl == null) {
      context.showErrorSnackBar('No server URL available');
      return;
    }

    setState(() {
      _error = null;
    });

    try {
      // Check if biometric is available first
      final isAvailable = await MobileWebAuthnService.instance
          .isBiometricAvailable();
      if (!isAvailable) {
        setState(() {
          _error =
              'Biometric authentication is not available on this device.\n\n'
              'Please ensure:\n'
              '1. Biometric authentication is set up in device settings\n'
              '2. You have enrolled a fingerprint or face\n'
              '3. The device supports biometric authentication';
        });
        return;
      }

      final clientId = await ClientIdService.getClientId();

      // Register the WebAuthn credential with biometric
      // Pass email from registration flow
      debugPrint('[WebAuthnRegister] Starting registration process...');
      final credentialId = await MobileWebAuthnService.instance.register(
        email: widget.email, // Use email from registration state
      );

      if (credentialId == null) {
        debugPrint(
          '[WebAuthnRegister] Registration returned null - check logs above for details',
        );
        throw Exception(
          'Failed to register biometric credential. '
          'Check logs for details. Common issues:\n'
          '1. Server not responding or session expired\n'
          '2. Biometric prompt was cancelled\n'
          '3. Challenge generation failed',
        );
      }

      debugPrint(
        '[WebAuthnRegister] Registration successful, credential ID: $credentialId',
      );

      // Set device identity with email from registration flow
      await DeviceIdentityService.instance.setDeviceIdentity(
        widget.email ?? '', // Use email from registration flow
        credentialId,
        clientId,
        serverUrl: _serverUrl,
      );

      // Reload the credentials list
      await _loadWebauthnCredentials();

      if (mounted) {
        context.showSuccessSnackBar('Security credential registered!');
      }
    } catch (e) {
      debugPrint('[WebAuthnRegister] Error adding credential: $e');
      final errorMsg = e.toString();

      // Provide helpful error messages
      String userFriendlyError;
      if (errorMsg.contains('uiUnavailable') ||
          errorMsg.contains('FragmentActivity')) {
        userFriendlyError =
            'Biometric authentication failed to initialize.\n\n'
            'Please ensure biometric authentication is properly set up in your device settings.';
      } else if (errorMsg.contains('NotAvailable')) {
        userFriendlyError =
            'Biometric authentication is not available on this device.\n'
            'Please set up fingerprint or face unlock in device settings.';
      } else {
        userFriendlyError = 'Failed to register: $errorMsg';
      }

      setState(() {
        _error = userFriendlyError;
      });
    }
  }

  Future<void> _deleteCredential(String credentialId) async {
    if (webauthnCredentials.length <= 1) {
      context.showErrorSnackBar('You must have at least one security key!');
      return;
    }

    setState(() {
      loading = true;
      _error = null;
    });
    try {
      final resp = await ApiService.instance.post(
        _serverUrl != null ? '$_serverUrl/webauthn/delete' : '/webauthn/delete',
        data: {'credentialId': credentialId},
      );
      if (resp.statusCode == 200) {
        await _loadWebauthnCredentials();
        if (mounted) {
          context.showSuccessSnackBar('Security key removed');
        }
      } else {
        setState(() {
          _error = 'Failed to delete credential';
        });
      }
    } catch (e) {
      debugPrint('[WebAuthnRegister] Error deleting credential: $e');
      setState(() {
        _error = 'Error deleting credential: $e';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  void _continueToProfile() {
    if (webauthnCredentials.isEmpty) {
      context.showErrorSnackBar('Please register at least one security key');
      return;
    }
    context.go('/register/profile');
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (!isMobile) {
      // Desktop: Show message that WebAuthn is not available
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const RegistrationProgressBar(currentStep: 3),
              const SizedBox(height: 48),
              Icon(
                Icons.desktop_windows,
                size: 64,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 24),
              Text(
                'WebAuthn Not Available',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              Text(
                'Desktop uses Magic Key authentication instead.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => context.go('/register/profile'),
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      );
    }

    // Mobile: Show credentials list with exit confirmation
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Show dialog to confirm exit
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              'Leave Registration?',
              style: TextStyle(color: colorScheme.onSurface),
            ),
            content: Text(
              'Your progress will be lost.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(
                  'Stay',
                  style: TextStyle(color: colorScheme.primary),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.error,
                ),
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  GoRouter.of(context).go('/login');
                },
                child: Text(
                  'Leave Registration',
                  style: TextStyle(color: colorScheme.onError),
                ),
              ),
            ],
          ),
        );
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          title: const Text('Add Credential'),
          backgroundColor: colorScheme.surface,
          elevation: 0,
        ),
        drawer: AppDrawer(
          isAuthenticated: false,
          currentRoute: '/register/webauthn',
        ),
        body: Column(
          children: [
            const RegistrationProgressBar(currentStep: 3),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    constraints: const BoxConstraints(maxWidth: 700),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: colorScheme.shadow.withValues(alpha: 0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Setup Security Key',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Register at least one security key using your device\'s biometric authentication.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        if (_error != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: colorScheme.error),
                            ),
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        // Credentials List
                        SizedBox(
                          height: 300,
                          child: loading && webauthnCredentials.isEmpty
                              ? Center(
                                  child: CircularProgressIndicator(
                                    color: colorScheme.primary,
                                  ),
                                )
                              : webauthnCredentials.isEmpty
                              ? Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant,
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.fingerprint,
                                        color: colorScheme.onSurfaceVariant,
                                        size: 48,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No security keys registered yet',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              color: colorScheme.onSurface,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Click "Add Security Key" below to get started',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                            ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                )
                              : Container(
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant,
                                    ),
                                  ),
                                  child: ListView.builder(
                                    itemCount: webauthnCredentials.length,
                                    itemBuilder: (context, index) {
                                      final cred = webauthnCredentials[index];
                                      return ListTile(
                                        leading: Icon(
                                          Icons.fingerprint,
                                          color: colorScheme.primary,
                                        ),
                                        title: Text(
                                          cred['name'] ??
                                              'Security Key ${index + 1}',
                                          style: theme.textTheme.bodyLarge
                                              ?.copyWith(
                                                color: colorScheme.onSurface,
                                              ),
                                        ),
                                        subtitle: Text(
                                          'Added: ${cred['createdAt'] ?? 'Unknown'}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                        trailing: webauthnCredentials.length > 1
                                            ? IconButton(
                                                icon: Icon(
                                                  Icons.delete_outline,
                                                  color: colorScheme.error,
                                                ),
                                                onPressed: () =>
                                                    _deleteCredential(
                                                      cred['credentialId'],
                                                    ),
                                              )
                                            : null,
                                      );
                                    },
                                  ),
                                ),
                        ),
                        const SizedBox(height: 24),
                        // Add Security Key Button
                        OutlinedButton.icon(
                          onPressed: loading ? null : _addCredential,
                          icon: Icon(Icons.add, color: colorScheme.primary),
                          label: Text(
                            'Add Security Key',
                            style: TextStyle(color: colorScheme.primary),
                          ),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            side: BorderSide(color: colorScheme.primary),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Continue Button
                        FilledButton(
                          onPressed: webauthnCredentials.isEmpty
                              ? null
                              : _continueToProfile,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                          ),
                          child: const Text('Continue to Profile'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
