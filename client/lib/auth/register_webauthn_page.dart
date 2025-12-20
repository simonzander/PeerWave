import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'dart:js_interop';
import '../services/api_service.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';
import '../extensions/snackbar_extensions.dart';

@JS('window.localStorage.getItem')
external JSString? localStorageGetItem(JSString key);

@JS('webauthnRegister')
external JSPromise _webauthnRegister(JSString serverUrl, JSString email);

Future<bool> webauthnRegister(String serverUrl, String email) async {
  if (!kIsWeb) {
    throw UnsupportedError('WebAuthn is only supported on web platform');
  }
  try {
    final result = await _webauthnRegister(serverUrl.toJS, email.toJS).toDart;
    return result.dartify() == true;
  } catch (e) {
    return false;
  }
}

class RegisterWebauthnPage extends StatefulWidget {
  const RegisterWebauthnPage({super.key});

  @override
  State<RegisterWebauthnPage> createState() => _RegisterWebauthnPageState();
}

class _RegisterWebauthnPageState extends State<RegisterWebauthnPage> {
  List<Map<String, dynamic>> webauthnCredentials = [];
  bool loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWebauthnCredentials();
  }

  Future<void> _loadWebauthnCredentials() async {
    setState(() {
      loading = true;
      _error = null;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/webauthn/list');
      if (resp.statusCode == 200 && resp.data != null) {
        if (resp.data is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(resp.data);
          });
        } else if (resp.data is Map && resp.data['credentials'] is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(resp.data['credentials']);
          });
        }
      }
    } catch (e) {
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
    setState(() {
      _error = null;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final email = localStorageGetItem('email'.toJS)?.toDart ?? '';
      final success = await webauthnRegister(urlString, email);
      if (success) {
        await _loadWebauthnCredentials();
      } else {
        setState(() {
          _error = 'Failed to register security key';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error registering security key: $e';
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
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.post('$urlString/webauthn/delete', data: {'credentialId': credentialId});
      if (resp.statusCode == 200) {
        await _loadWebauthnCredentials();
      } else {
        setState(() {
          _error = 'Failed to delete credential';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error deleting credential: $e';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    // Responsive width
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth < 600 
        ? screenWidth * 0.9
        : screenWidth < 840
            ? 550.0
            : 650.0;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Column(
        children: [
          // Progress Bar
          const RegistrationProgressBar(currentStep: 3),
          // Content
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Container(
                  padding: const EdgeInsets.all(32),
                  width: cardWidth,
                  constraints: const BoxConstraints(maxWidth: 700, maxHeight: 750),
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
                        'Register at least one security key (passkey) to secure your account. You can use your device\'s biometric authentication or a hardware security key.',
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
                    Expanded(
                      child: loading && webauthnCredentials.isEmpty
                          ? Center(
                              child: CircularProgressIndicator(color: colorScheme.primary),
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
                                        Icons.security, 
                                        color: colorScheme.onSurfaceVariant, 
                                        size: 48,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No security keys registered yet',
                                        style: theme.textTheme.titleMedium?.copyWith(
                                          color: colorScheme.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Click "Add Security Key" below to get started',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
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
                                  child: ListView.separated(
                                    padding: const EdgeInsets.all(8),
                                    itemCount: webauthnCredentials.length,
                                    separatorBuilder: (context, index) => Divider(
                                      color: colorScheme.outlineVariant,
                                      height: 1,
                                    ),
                                    itemBuilder: (context, index) {
                                      final cred = webauthnCredentials[index];
                                      return ListTile(
                                        leading: Icon(Icons.key, color: colorScheme.primary),
                                        title: Text(
                                          cred['browser']?.toString() ?? 'Security Key ${index + 1}',
                                          style: theme.textTheme.bodyLarge?.copyWith(
                                            color: colorScheme.onSurface,
                                          ),
                                        ),
                                        subtitle: Text(
                                          'Created: ${cred['created']?.toString() ?? 'Unknown'}',
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        trailing: webauthnCredentials.length > 1
                                            ? IconButton(
                                                icon: Icon(Icons.delete, color: colorScheme.error),
                                                onPressed: () => _deleteCredential(cred['id']?.toString() ?? ''),
                                              )
                                            : null,
                                      );
                                    },
                                  ),
                                ),
                    ),
                    const SizedBox(height: 16),
                    // Add Credential Button
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        foregroundColor: colorScheme.primary,
                        side: BorderSide(color: colorScheme.outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: loading ? null : _addCredential,
                      icon: const Icon(Icons.add),
                      label: Text(
                        'Add Security Key',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Next Button
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        disabledBackgroundColor: colorScheme.surfaceContainerHighest,
                        disabledForegroundColor: colorScheme.onSurfaceVariant,
                      ),
                      onPressed: webauthnCredentials.isEmpty
                          ? null
                          : () {
                              GoRouter.of(context).go('/register/profile');
                            },
                      child: Text(
                        'Next',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

