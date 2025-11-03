import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'dart:html' as html;
import '../services/api_service.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';

class RegisterProfilePage extends StatefulWidget {
  const RegisterProfilePage({Key? key}) : super(key: key);

  @override
  State<RegisterProfilePage> createState() => _RegisterProfilePageState();
}

class _RegisterProfilePageState extends State<RegisterProfilePage> {
  final TextEditingController _displayNameController = TextEditingController();
  bool _loading = false;
  String? _error;
  Uint8List? _imageBytes;
  String? _imageFileName;

  Future<void> _pickImage() async {
    if (!kIsWeb) return;
    
    try {
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
      
      setState(() {
        _imageBytes = Uint8List.fromList(bytes);
        _imageFileName = file.name;
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

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }

      // Prepare request data
      final Map<String, dynamic> data = {
        'displayName': _displayNameController.text.trim(),
      };

      // Add image if selected
      if (_imageBytes != null) {
        final base64Image = base64Encode(_imageBytes!);
        data['picture'] = 'data:image/${_imageFileName?.split('.').last ?? 'png'};base64,$base64Image';
      }

      final resp = await ApiService.post(
        '$urlString/client/profile/setup',
        data: data,
      );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        // Registration complete, navigate to app
        if (mounted) {
          GoRouter.of(context).go('/app');
        }
      } else {
        setState(() {
          _error = 'Failed to save profile. Please try again.';
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

    return Scaffold(
      backgroundColor: colorScheme.surface,
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
                        color: colorScheme.shadow.withOpacity(0.1),
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
                            backgroundColor: colorScheme.surfaceContainerHigh,
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
                                icon: const Icon(Icons.camera_alt, size: 20),
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
                          borderSide: BorderSide(color: colorScheme.outline),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: colorScheme.outline),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: colorScheme.primary, width: 2),
                        ),
                        prefixIcon: Icon(Icons.person_outline, color: colorScheme.onSurfaceVariant),
                      ),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                      onChanged: (_) => setState(() {}),
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
                        disabledBackgroundColor: colorScheme.surfaceContainerHighest,
                        disabledForegroundColor: colorScheme.onSurfaceVariant,
                      ),
                      onPressed: (_loading || !isFormValid) ? null : _completeRegistration,
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
    );
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    super.dispose();
  }
}
