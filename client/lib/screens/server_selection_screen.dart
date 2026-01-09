import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:go_router/go_router.dart';
import '../services/magic_key_service.dart';
import '../services/server_config_native.dart';
import '../services/clientid_native.dart';
import '../services/device_identity_service.dart';
import '../services/native_crypto_service.dart';
import '../services/auth_service_web.dart'
    if (dart.library.io) '../services/auth_service_native.dart';
import '../widgets/app_drawer.dart';

/// Server selection screen for native clients
/// Shown on first launch or when adding a new server
class ServerSelectionScreen extends StatefulWidget {
  final bool
  isAddingServer; // true if adding to existing servers, false if first launch

  const ServerSelectionScreen({super.key, this.isAddingServer = false});

  @override
  State<ServerSelectionScreen> createState() => _ServerSelectionScreenState();
}

class _ServerSelectionScreenState extends State<ServerSelectionScreen> {
  final _magicKeyController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _showQRScanner = false;
  String? _errorMessage;
  MobileScannerController? _scannerController;

  // Check if platform supports mobile scanner (iOS/Android only)
  bool get _isMobilePlatform => Platform.isIOS || Platform.isAndroid;

  @override
  void dispose() {
    _magicKeyController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _handleMagicKey(String magicKey) async {
    debugPrint(
      '[ServerSelection] ========== Starting magic key flow ==========',
    );
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Validate format
      if (!MagicKeyService.isValidFormat(magicKey)) {
        setState(() {
          _errorMessage = 'Invalid magic key format';
          _isLoading = false;
        });
        return;
      }

      // Check expiration
      if (MagicKeyService.isExpired(magicKey)) {
        setState(() {
          _errorMessage = 'Magic key has expired';
          _isLoading = false;
        });
        return;
      }

      // Get server URL
      final serverUrl = MagicKeyService.getServerUrl(magicKey);
      if (serverUrl == null) {
        setState(() {
          _errorMessage = 'Could not extract server URL from magic key';
          _isLoading = false;
        });
        return;
      }

      // Generate client ID
      final clientId = await ClientIdService.getClientId();
      debugPrint('[ServerSelection] Client ID: $clientId');

      // Verify with server
      debugPrint('[ServerSelection] Verifying magic key with server...');
      final response = await MagicKeyService.verifyWithServer(
        magicKey,
        clientId,
      );
      debugPrint(
        '[ServerSelection] Verification response: success=${response.success}, message=${response.message}',
      );

      if (!response.success) {
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });
        return;
      }

      // Success! The session secret is already stored in SessionAuthService
      debugPrint('[ServerSelection] ✓ Magic key verified successfully');

      // Initialize device identity for native clients
      // For native, we generate a synthetic credential ID based on client ID + server URL
      // This ensures consistent device identity across app restarts
      if (!kIsWeb) {
        debugPrint(
          '[ServerSelection] Initializing device identity for native client...',
        );
        final data = response.data ?? {};
        final email = data['email'] as String? ?? 'native@device';
        // Generate synthetic credential ID: use serverUrl directly (no hashCode!)
        // CRITICAL: hashCode is NOT stable across Dart VM restarts!
        // This was causing new deviceId → new database → prekeys regenerated every time
        final syntheticCredId = serverUrl
            .replaceAll('-', '')
            .replaceAll(':', '')
            .replaceAll('/', '');
        await DeviceIdentityService.instance.setDeviceIdentity(
          email,
          syntheticCredId,
          clientId,
          serverUrl: serverUrl, // Pass serverUrl for multi-server storage
        );
        debugPrint('[ServerSelection] ✓ Device identity initialized');

        // Generate and store encryption key for native client
        debugPrint('[ServerSelection] Generating encryption key...');
        final deviceId = DeviceIdentityService.instance.deviceId;
        await NativeCryptoService.instance.getOrCreateKey(deviceId);
        debugPrint('[ServerSelection] ✓ Encryption key generated and stored');
      }

      // Add server to config (or update credentials if exists)
      // Note: credentials field is not used for authentication (SessionAuthService handles that)
      debugPrint('[ServerSelection] Adding/updating server config...');
      final serverConfig = await ServerConfigService.addServer(
        serverUrl: serverUrl,
        credentials:
            'hmac-session', // Placeholder - actual session is in SessionAuthService
        displayName: null, // Will extract from URL
      );

      debugPrint(
        '[ServerSelection] Server configured: ${serverConfig.getDisplayName()}',
      );

      // Session is now stored in SessionAuthService
      // Check session to update isLoggedIn flag
      debugPrint('[ServerSelection] Calling checkSession...');
      await AuthService.checkSession();
      debugPrint(
        '[ServerSelection] ✓ Session checked, isLoggedIn: ${AuthService.isLoggedIn}',
      );

      // Clear loading state
      if (mounted) {
        debugPrint('[ServerSelection] Clearing loading state');
        setState(() {
          _isLoading = false;
        });
      }

      // Navigate to main app
      if (mounted) {
        debugPrint('[ServerSelection] ✓ Navigating to /app');
        context.go('/app');
        debugPrint('[ServerSelection] ✓ Navigation triggered');
      } else {
        debugPrint('[ServerSelection] ⚠️ Widget not mounted, cannot navigate');
      }
    } catch (e) {
      debugPrint('[ServerSelection] Error: $e');
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  void _toggleQRScanner() {
    if (!_isMobilePlatform) {
      setState(() {
        _errorMessage = 'QR scanning is only available on mobile devices';
      });
      return;
    }

    setState(() {
      _showQRScanner = !_showQRScanner;
      if (_showQRScanner) {
        _scannerController = MobileScannerController(
          detectionSpeed: DetectionSpeed.normal,
          facing: CameraFacing.back,
        );
      } else {
        _scannerController?.dispose();
        _scannerController = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('Connect to Server'),
        backgroundColor: colorScheme.surface,
        elevation: 0,
      ),
      drawer: AppDrawer(
        isAuthenticated: false,
        currentRoute: GoRouterState.of(context).matchedLocation,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // App Logo/Title
                  Image.asset(
                    Theme.of(context).brightness == Brightness.dark
                        ? 'assets/images/peerwave.png'
                        : 'assets/images/peerwave_dark.png',
                    width: 120,
                    height: 120,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'PeerWave',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.isAddingServer
                        ? 'Add New Server'
                        : 'Connect to Your Server',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),
                  // Instructions Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Theme.of(context).colorScheme.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'How to Connect',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildInstructionStep(
                            '1',
                            'Open PeerWave in your web browser',
                          ),
                          _buildInstructionStep(
                            '2',
                            'Go to Settings → Credentials',
                          ),
                          _buildInstructionStep('3', 'Click "Add New Client"'),
                          _buildInstructionStep(
                            '4',
                            'Scan the QR code or copy the magic key',
                          ),
                          _buildInstructionStep(
                            '5',
                            'Paste it below or scan it with your camera',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // QR Scanner or Magic Key Input
                  if (_showQRScanner)
                    _buildQRScanner()
                  else
                    _buildMagicKeyInput(),

                  const SizedBox(height: 16),

                  // Toggle Scanner Button (only on mobile)
                  if (_isMobilePlatform)
                    TextButton.icon(
                      onPressed: _isLoading ? null : _toggleQRScanner,
                      icon: Icon(
                        _showQRScanner ? Icons.keyboard : Icons.qr_code_scanner,
                      ),
                      label: Text(
                        _showQRScanner ? 'Enter Key Manually' : 'Scan QR Code',
                      ),
                    ),

                  // Error Message
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
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
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Cancel Button (only when adding server)
                  if (widget.isAddingServer) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _isLoading ? null : () => context.pop(),
                      child: const Text('Cancel'),
                    ),
                  ],

                  // Back to Mobile Server Selection (only on mobile)
                  if (_isMobilePlatform && !widget.isAddingServer) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => context.go('/mobile-server-selection'),
                      child: const Text('Back to Server Selection'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              number,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _buildQRScanner() {
    // Don't build scanner on desktop platforms
    if (!_isMobilePlatform) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.qr_code_scanner,
                size: 64,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 16),
              Text(
                'QR Scanning Not Available',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'QR code scanning is only available on mobile devices. Please enter your magic key manually.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 400,
          child: Stack(
            children: [
              if (_scannerController != null)
                MobileScanner(
                  controller: _scannerController,
                  onDetect: (capture) {
                    final List<Barcode> barcodes = capture.barcodes;
                    if (barcodes.isNotEmpty && !_isLoading) {
                      final code = barcodes.first.rawValue;
                      if (code != null && code.isNotEmpty) {
                        _scannerController?.stop();
                        _handleMagicKey(code);
                      }
                    }
                  },
                ),
              // Scanning overlay
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                margin: const EdgeInsets.all(60),
              ),
              // Instructions overlay
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Position the QR code within the frame',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              if (_isLoading)
                Container(
                  color: Colors.black54,
                  child: const Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMagicKeyInput() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _magicKeyController,
            decoration: InputDecoration(
              labelText: 'Magic Key',
              hintText: 'Paste your magic key here',
              prefixIcon: const Icon(Icons.vpn_key),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    _magicKeyController.text = data!.text!;
                  }
                },
                tooltip: 'Paste from clipboard',
              ),
            ),
            maxLines: 3,
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter a magic key';
              }
              if (!MagicKeyService.isValidFormat(value)) {
                return 'Invalid magic key format';
              }
              if (MagicKeyService.isExpired(value)) {
                return 'Magic key has expired';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _isLoading
                ? null
                : () {
                    if (_formKey.currentState!.validate()) {
                      _handleMagicKey(_magicKeyController.text.trim());
                    }
                  },
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(_isLoading ? 'Connecting...' : 'Connect to Server'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}
