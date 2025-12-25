import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';
import '../services/server_settings_service.dart';
import '../web_config.dart';
import '../services/server_config_web.dart'
    if (dart.library.io) '../services/server_config_native.dart';

class InvitationEntryPage extends StatefulWidget {
  final String email;
  const InvitationEntryPage({super.key, required this.email});

  @override
  State<InvitationEntryPage> createState() => _InvitationEntryPageState();
}

class _InvitationEntryPageState extends State<InvitationEntryPage> {
  final TextEditingController _tokenController = TextEditingController();
  bool _verifying = false;
  String? _error;
  String? _serverName;

  @override
  void initState() {
    super.initState();
    _loadServerName();
  }

  Future<void> _loadServerName() async {
    final settings = await ServerSettingsService.instance.getSettings();
    setState(() {
      _serverName = settings['serverName'] ?? 'PeerWave Server';
    });
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _verifyAndProceed() async {
    final token = _tokenController.text.trim();

    if (token.isEmpty) {
      setState(() => _error = 'Please enter your invitation code');
      return;
    }

    if (token.length != 6 || !RegExp(r'^\d+$').hasMatch(token)) {
      setState(() => _error = 'Invitation code must be 6 digits');
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });

    try {
      String urlString = '';
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      // Verify invitation token
      final verifyResp = await ApiService.post(
        '/api/invitations/verify',
        data: {'email': widget.email, 'token': token},
      );

      if (verifyResp.statusCode == 200 && verifyResp.data['valid'] == true) {
        // Token is valid, proceed with registration
        final registerResp = await ApiService.post(
          '/register',
          data: {'email': widget.email, 'invitationToken': token},
        );

        if (registerResp.statusCode == 200) {
          final data = registerResp.data;
          if (data['status'] == 'otp' || data['status'] == 'waitotp') {
            if (mounted) {
              context.go(
                '/otp',
                extra: {
                  'email': widget.email,
                  'serverUrl': urlString,
                  'wait': int.parse(data['wait'].toString()),
                },
              );
            }
          } else {
            setState(() => _error = 'Unexpected response from server');
          }
        } else {
          String errorMsg = 'Registration failed';
          if (registerResp.data != null && registerResp.data['error'] != null) {
            errorMsg = registerResp.data['error'];
          }
          setState(() => _error = errorMsg);
        }
      } else {
        final message =
            verifyResp.data?['message'] ?? 'Invalid or expired invitation code';
        setState(() => _error = message);
      }
    } catch (e) {
      debugPrint('Invitation verification failed: $e');
      setState(() => _error = 'Verification failed. Please try again.');
    } finally {
      setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth < 600
        ? screenWidth * 0.9
        : screenWidth < 840
        ? 400.0
        : 450.0;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(24),
            width: cardWidth,
            constraints: const BoxConstraints(maxWidth: 500),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Back button
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.go('/login'),
                  tooltip: 'Back to login',
                ),
                const SizedBox(height: 8),

                // Header
                Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.mail_outline,
                        size: 64,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Invitation Required',
                        style: GoogleFonts.nunitoSans(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _serverName ?? 'This server',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'requires an invitation to register',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // Email display
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.email,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.email,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Instructions
                Text(
                  'Enter your 6-digit invitation code',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),

                // Token input
                TextField(
                  controller: _tokenController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    letterSpacing: 8,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: '000000',
                    counterText: '',
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colorScheme.outline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colorScheme.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: colorScheme.primary,
                        width: 2,
                      ),
                    ),
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: colorScheme.error,
                        width: 2,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _verifyAndProceed(),
                ),
                const SizedBox(height: 16),

                // Error message
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.error, width: 1),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: colorScheme.onErrorContainer,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),

                // Verify button
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  onPressed: _verifying ? null : _verifyAndProceed,
                  child: _verifying
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              colorScheme.onPrimary,
                            ),
                          ),
                        )
                      : Text(
                          'Verify & Continue',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(height: 16),

                // Help text
                Center(
                  child: Text(
                    'Check your email for the invitation code',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
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
