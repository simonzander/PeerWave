import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/server_config_native.dart';

/// Mobile server selection screen - first step for mobile authentication
///
/// Allows user to enter server URL before proceeding to WebAuthn or Magic Key login
class MobileServerSelectionScreen extends StatefulWidget {
  const MobileServerSelectionScreen({super.key});

  @override
  State<MobileServerSelectionScreen> createState() =>
      _MobileServerSelectionScreenState();
}

class _MobileServerSelectionScreenState
    extends State<MobileServerSelectionScreen> {
  final _serverUrlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isValidating = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSavedServer();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedServer() async {
    try {
      final activeServer = ServerConfigService.getActiveServer();
      if (activeServer != null) {
        setState(() {
          _serverUrlController.text = activeServer.serverUrl;
        });
      }
    } catch (e) {
      debugPrint('[MobileServerSelection] Error loading saved server: $e');
    }
  }

  String? _validateServerUrl(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a server URL';
    }

    // Auto-add https:// if missing
    String url = value;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    // Basic URL validation
    try {
      final uri = Uri.parse(url);
      if (!uri.hasScheme || !uri.hasAuthority) {
        return 'Invalid URL format';
      }
    } catch (e) {
      return 'Invalid URL format';
    }

    return null;
  }

  Future<void> _handleEnterServer() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isValidating = true;
      _errorMessage = null;
    });

    try {
      var serverUrl = _serverUrlController.text.trim();
      debugPrint('[MobileServerSelection] Input URL: $serverUrl');

      // Normalize server URL
      if (!serverUrl.startsWith('http://') &&
          !serverUrl.startsWith('https://')) {
        // Use http:// for localhost/emulator addresses, https:// for others
        if (serverUrl.startsWith('localhost') ||
            serverUrl.startsWith('127.0.0.1') ||
            serverUrl.startsWith('10.0.2.2')) {
          serverUrl = 'http://$serverUrl';
        } else {
          serverUrl = 'https://$serverUrl';
        }
      }
      debugPrint('[MobileServerSelection] After protocol: $serverUrl');

      serverUrl = serverUrl.replaceAll(
        RegExp(r'/+$'),
        '',
      ); // Remove trailing slashes

      // TODO: Optionally validate server is reachable by making a test request
      // For now, just proceed to registration screen with the server URL

      debugPrint('[MobileServerSelection] Server URL validated: $serverUrl');

      // Don't save server yet - it will be saved after successful authentication
      // Just pass the URL through the registration flow

      if (mounted) {
        // Navigate to mobile WebAuthn screen (will show login/register options)
        context.go('/mobile-webauthn', extra: serverUrl);
      }
    } catch (e) {
      debugPrint('[MobileServerSelection] Error: $e');
      setState(() {
        _errorMessage = 'Failed to connect to server: ${e.toString()}';
        _isValidating = false;
      });
    }
  }

  void _handleUseMagicKey() {
    // Navigate to magic key login (traditional desktop flow)
    context.go('/server-selection');
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
                const SizedBox(height: 80),

                // Logo and title
                Center(
                  child: Column(
                    children: [
                      Image.asset(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'assets/images/peerwave.png'
                            : 'assets/images/peerwave_dark.png',
                        width: 120,
                        height: 120,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'PeerWave',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Connect to Your Server',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 64),

                // Server URL input
                TextFormField(
                  controller: _serverUrlController,
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    hintText: 'app.peerwave.org',
                    hintStyle: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withOpacity(0.6),
                    ),
                    prefixIcon: const Icon(Icons.dns),
                    border: const OutlineInputBorder(),
                    helperText: 'Your PeerWave server address',
                    helperStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  validator: _validateServerUrl,
                  enabled: !_isValidating,
                  onFieldSubmitted: (_) => _handleEnterServer(),
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

                // Enter Server button
                FilledButton.icon(
                  onPressed: _isValidating ? null : _handleEnterServer,
                  icon: _isValidating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_forward),
                  label: Text(_isValidating ? 'Connecting...' : 'Enter Server'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),

                const SizedBox(height: 32),

                // Divider
                const Divider(),
                const SizedBox(height: 24),

                // Fallback to magic key
                Center(
                  child: TextButton.icon(
                    onPressed: _isValidating ? null : _handleUseMagicKey,
                    icon: const Icon(Icons.key),
                    label: const Text('Use Magic Key Instead'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
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
