import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_html/html.dart' as html;
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import '../services/auth_service_web.dart'
    if (dart.library.io) '../services/auth_service_native.dart';
import '../services/custom_tab_auth_service.dart';
import '../services/server_config_web.dart'
    if (dart.library.io) '../services/server_config_native.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';
import '../widgets/app_drawer.dart';

class RegisterProfilePage extends StatefulWidget {
  const RegisterProfilePage({super.key});

  @override
  State<RegisterProfilePage> createState() => _RegisterProfilePageState();
}

class _RegisterProfilePageState extends State<RegisterProfilePage> {
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _atNameController = TextEditingController();
  bool _loading = false;
  String? _error;
  Uint8List? _imageBytes;
  String? _imageFileName;
  bool _atNameManuallyEdited = false;

  Future<void> _pickImage() async {
    try {
      Uint8List? imageBytes;
      String? fileName;

      if (kIsWeb) {
        // Web implementation
        final html.FileUploadInputElement input = html.FileUploadInputElement()
          ..accept = 'image/*';

        input.click();

        await input.onChange.first;

        if (input.files!.isEmpty) return;

        final file = input.files![0];
        final reader = html.FileReader();

        reader.readAsArrayBuffer(file);

        await reader.onLoad.first;

        final bytes = reader.result as List<int>;

        // Check file size (max 1MB)
        if (bytes.length > 1 * 1024 * 1024) {
          setState(() {
            _error = 'Image is too large. Maximum size is 1MB.';
          });
          return;
        }

        imageBytes = Uint8List.fromList(bytes);
        fileName = file.name;
      } else {
        // Mobile/Desktop implementation using ImagePicker
        final picker = ImagePicker();
        final pickedFile = await picker.pickImage(source: ImageSource.gallery);

        if (pickedFile == null) return;

        final bytes = await pickedFile.readAsBytes();

        // Check file size (max 1MB)
        if (bytes.length > 1 * 1024 * 1024) {
          setState(() {
            _error = 'Image is too large. Maximum size is 1MB.';
          });
          return;
        }

        imageBytes = bytes;
        fileName = pickedFile.name;
      }

      setState(() {
        _imageBytes = imageBytes;
        _imageFileName = fileName;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to pick image: $e';
      });
    }
  }

  Future<void> _completeRegistration() async {
    if (_displayNameController.text.trim().isEmpty) {
      setState(() {
        _error = 'Display name is required';
      });
      return;
    }

    // Auto-generate atName if empty
    String atName = _atNameController.text.trim();
    if (atName.isEmpty) {
      atName = _displayNameController.text
          .trim()
          .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
          .toLowerCase();
      if (atName.isEmpty) {
        atName = 'user';
      }
    }

    // Remove @ if user added it
    if (atName.startsWith('@')) {
      atName = atName.substring(1);
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Initialize ApiService to ensure baseUrl is set correctly
      await ApiService.instance.init();

      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }

      // Prepare request data
      final Map<String, dynamic> data = {
        'displayName': _displayNameController.text.trim(),
        'atName': atName,
      };

      // Add image if selected
      if (_imageBytes != null) {
        final base64Image = base64Encode(_imageBytes!);
        data['picture'] =
            'data:image/${_imageFileName?.split('.').last ?? 'png'};base64,$base64Image';
      }

      final resp = await ApiService.instance.post(
        '/client/profile/setup',
        data: data,
      );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        // Registration complete

        // Check platform to determine post-registration flow
        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
          // Mobile: Open Chrome Custom Tab for authentication
          debugPrint(
            '[RegisterProfile] Mobile registration complete, opening Chrome Custom Tab for auth...',
          );

          if (mounted) {
            // Show loading message
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Complete authentication to access your account',
                ),
                duration: const Duration(seconds: 2),
                backgroundColor: Theme.of(context).colorScheme.primary,
              ),
            );
          }

          // Get server URL
          String serverUrl = '';
          if (kIsWeb) {
            final apiServer = await loadWebApiServer();
            serverUrl = apiServer ?? '';
          } else {
            // Mobile: Get from active server configuration
            final activeServer = ServerConfigService.getActiveServer();
            serverUrl = activeServer?.serverUrl ?? '';
          }

          if (serverUrl.isEmpty) {
            debugPrint('[RegisterProfile] ✗ No server URL available');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Server configuration missing'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
              );
              GoRouter.of(context).go('/mobile-server-selection');
            }
            return;
          }

          if (!serverUrl.startsWith('http://') &&
              !serverUrl.startsWith('https://')) {
            serverUrl = 'https://$serverUrl';
          }

          // Get email from API service or storage
          String? userEmail;
          try {
            final profileResp = await ApiService.instance.get(
              '/client/profile',
            );
            if (profileResp.statusCode == 200) {
              userEmail = profileResp.data['email'];
            }
          } catch (e) {
            debugPrint('[RegisterProfile] Could not get email: $e');
          }

          // Open Chrome Custom Tab for authentication
          final success = await CustomTabAuthService.instance.authenticate(
            serverUrl: serverUrl,
            email: userEmail,
            timeout: const Duration(minutes: 3),
          );

          if (!mounted) return;

          if (success) {
            // Authentication successful - navigate to app
            debugPrint(
              '[RegisterProfile] ✓ Authentication successful, navigating to /app',
            );
            GoRouter.of(context).go('/app');
          } else {
            // Authentication failed or cancelled - navigate to mobile login page
            debugPrint(
              '[RegisterProfile] ✗ Authentication cancelled/failed, navigating to login page',
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Authentication required. Please log in to continue.',
                ),
                duration: const Duration(seconds: 3),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
            await Future.delayed(const Duration(seconds: 1));
            if (!mounted) return;
            GoRouter.of(context).go('/mobile-webauthn', extra: serverUrl);
          }
        } else {
          // Web/Desktop: Log out and redirect to login (existing behavior)
          AuthService.isLoggedIn = false;

          if (mounted) {
            // Show success message
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Registration complete! Please log in to continue.',
                ),
                duration: Duration(seconds: 3),
                backgroundColor: Colors.green,
              ),
            );

            // Wait a moment for the user to see the message
            await Future.delayed(const Duration(seconds: 1));
            if (!mounted) return;

            // Navigate to login page
            GoRouter.of(context).go('/login');
          }
        }
      } else {
        // Server might return error if atName is taken
        final errorMsg = resp.data is Map
            ? (resp.data['error'] ?? resp.data['message'])
            : null;
        setState(() {
          _error = errorMsg ?? 'Failed to save profile. Please try again.';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error saving profile: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFormValid = _displayNameController.text.trim().isNotEmpty;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Responsive width
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth < 600
        ? screenWidth * 0.9
        : screenWidth < 840
        ? 500.0
        : 600.0;

    return PopScope(
      canPop: false, // Prevent back navigation during registration
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Show dialog to confirm exit
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Exit Registration?'),
            content: const Text(
              'Are you sure you want to exit? You will need to start the registration process again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  GoRouter.of(context).go('/login');
                },
                child: const Text('Exit'),
              ),
            ],
          ),
        );
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          title: const Text('Setup Profile'),
          backgroundColor: colorScheme.surface,
          elevation: 0,
        ),
        drawer: kIsWeb
            ? null
            : AppDrawer(
                isAuthenticated: false,
                currentRoute: '/register/profile',
              ),
        body: Column(
          children: [
            // Progress Bar
            const RegistrationProgressBar(currentStep: 4),
            // Content
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    width: cardWidth,
                    constraints: const BoxConstraints(maxWidth: 650),
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
                          'Setup Your Profile',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Complete your profile to finish registration',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                        // Profile Picture
                        Center(
                          child: Stack(
                            children: [
                              CircleAvatar(
                                radius: 60,
                                backgroundColor:
                                    colorScheme.surfaceContainerHigh,
                                backgroundImage: _imageBytes != null
                                    ? MemoryImage(_imageBytes!)
                                    : null,
                                child: _imageBytes == null
                                    ? Icon(
                                        Icons.person,
                                        size: 60,
                                        color: colorScheme.onSurfaceVariant,
                                      )
                                    : null,
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: CircleAvatar(
                                  radius: 20,
                                  backgroundColor: colorScheme.primary,
                                  child: IconButton(
                                    icon: const Icon(
                                      Icons.camera_alt,
                                      size: 20,
                                    ),
                                    color: colorScheme.onPrimary,
                                    onPressed: _pickImage,
                                    padding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Click camera icon to upload profile picture (optional)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                        // Display Name Field
                        TextField(
                          controller: _displayNameController,
                          decoration: InputDecoration(
                            labelText: 'Display Name *',
                            hintText: 'Enter your display name',
                            filled: true,
                            fillColor: colorScheme.surfaceContainerHigh,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.outline,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.outline,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            prefixIcon: Icon(
                              Icons.person_outline,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                          onChanged: (value) {
                            setState(() {});
                            // Auto-generate atName if not manually edited
                            if (!_atNameManuallyEdited && value.isNotEmpty) {
                              final generated = value
                                  .trim()
                                  .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
                                  .toLowerCase();
                              _atNameController.text = generated.isEmpty
                                  ? ''
                                  : generated;
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        // AtName Field
                        TextField(
                          controller: _atNameController,
                          decoration: InputDecoration(
                            labelText: 'Username (@atName) *',
                            hintText: 'Enter your username',
                            helperText:
                                'Used for mentions and unique identification',
                            filled: true,
                            fillColor: colorScheme.surfaceContainerHigh,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.outline,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.outline,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            prefixIcon: Icon(
                              Icons.alternate_email,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                          onChanged: (value) {
                            setState(() {
                              _atNameManuallyEdited = value.isNotEmpty;
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '* Required field',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
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
                        // Complete Registration Button
                        FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(double.infinity, 52),
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            disabledBackgroundColor:
                                colorScheme.surfaceContainerHighest,
                            disabledForegroundColor:
                                colorScheme.onSurfaceVariant,
                          ),
                          onPressed: (_loading || !isFormValid)
                              ? null
                              : _completeRegistration,
                          child: _loading
                              ? SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: colorScheme.onPrimary,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  'Complete Registration',
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
      ),
    );
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _atNameController.dispose();
    super.dispose();
  }
}
