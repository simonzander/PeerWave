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

    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
      body: Column(
        children: [
          // Progress Bar
          const RegistrationProgressBar(currentStep: 4),
          // Content
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(32),
                width: 450,
                decoration: BoxDecoration(
                  color: const Color(0xFF23272A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Setup Your Profile',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Complete your profile to finish registration',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    // Profile Picture
                    Center(
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 60,
                            backgroundColor: const Color(0xFF40444B),
                            backgroundImage: _imageBytes != null
                                ? MemoryImage(_imageBytes!)
                                : null,
                            child: _imageBytes == null
                                ? const Icon(
                                    Icons.person,
                                    size: 60,
                                    color: Colors.white54,
                                  )
                                : null,
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: CircleAvatar(
                              radius: 20,
                              backgroundColor: Colors.blueAccent,
                              child: IconButton(
                                icon: const Icon(Icons.camera_alt, size: 20),
                                color: Colors.white,
                                onPressed: _pickImage,
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Click camera icon to upload profile picture (optional)',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    // Display Name Field
                    TextField(
                      controller: _displayNameController,
                      decoration: const InputDecoration(
                        labelText: 'Display Name *',
                        labelStyle: TextStyle(color: Colors.white70),
                        hintText: 'Enter your display name',
                        hintStyle: TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Color(0xFF40444B),
                        border: OutlineInputBorder(),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF40444B)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.blueAccent),
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '* Required field',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 24),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    // Complete Registration Button
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: (_loading || !isFormValid) ? null : _completeRegistration,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Complete Registration',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ],
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
