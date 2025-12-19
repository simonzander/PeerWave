import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_html/html.dart' as html;
import '../services/api_service.dart';
import '../services/server_config_web.dart' if (dart.library.io) '../services/server_config_native.dart';
import '../web_config.dart';
import '../extensions/snackbar_extensions.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _atNameController = TextEditingController();
  
  bool _loading = false;
  bool _loadingProfile = true;
  bool _checkingAtName = false;
  String? _error;
  String? _atNameError;
  
  Uint8List? _imageBytes;
  String? _imageFileName;
  Uint8List? _currentImageBytes;
  
  String? _uuid;
  String? _email;
  String? _currentAtName;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _atNameController.addListener(_onAtNameChanged);
  }

  @override
  void dispose() {
    _atNameController.removeListener(_onAtNameChanged);
    _displayNameController.dispose();
    _atNameController.dispose();
    super.dispose();
  }

  void _onAtNameChanged() {
    // Debounce: Check after user stops typing
    if (_atNameController.text.isNotEmpty && _atNameController.text != _currentAtName) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_atNameController.text.isNotEmpty && _atNameController.text != _currentAtName) {
          _checkAtNameAvailability(_atNameController.text);
        }
      });
    }
  }

  Future<void> _checkAtNameAvailability(String atName) async {
    if (atName.isEmpty || atName == _currentAtName) {
      setState(() => _atNameError = null);
      return;
    }

    setState(() {
      _checkingAtName = true;
      _atNameError = null;
    });

    try {
      String urlString = '';
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      final resp = await ApiService.get(
        '$urlString/client/profile/check-atname?atName=$atName',
      );

      if (resp.statusCode == 200) {
        final data = resp.data;
        setState(() {
          _atNameError = data['available'] == true ? null : 'This @name is already taken';
          _checkingAtName = false;
        });
      }
    } catch (e) {
      setState(() {
        _atNameError = 'Error checking @name availability';
        _checkingAtName = false;
      });
    }
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loadingProfile = true;
      _error = null;
    });

    try {
      String urlString = '';
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      final resp = await ApiService.get('$urlString/client/profile');

      if (resp.statusCode == 200) {
        final data = resp.data;
        
        setState(() {
          _displayNameController.text = data['displayName'] ?? '';
          _atNameController.text = data['atName'] ?? '';
          _currentAtName = data['atName'];
          _uuid = data['uuid'];
          _email = data['email'];
          
          // Load current profile picture
          if (data['picture'] != null) {
            try {
              final base64String = data['picture'] as String;
              if (base64String.startsWith('data:image')) {
                final base64Data = base64String.split(',')[1];
                _currentImageBytes = base64Decode(base64Data);
              } else {
                _currentImageBytes = base64Decode(base64String);
              }
            } catch (e) {
              debugPrint('Error decoding profile picture: $e');
            }
          }
          
          _loadingProfile = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to load profile: $e';
        _loadingProfile = false;
      });
    }
  }

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

  Future<void> _updateProfile() async {
    if (_displayNameController.text.trim().isEmpty) {
      setState(() {
        _error = 'Display name is required';
      });
      return;
    }

    if (_atNameError != null) {
      setState(() {
        _error = 'Please fix @name error';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      String urlString = '';
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      final Map<String, dynamic> data = {
        'displayName': _displayNameController.text.trim(),
      };

      // Add atName if provided
      if (_atNameController.text.trim().isNotEmpty) {
        data['atName'] = _atNameController.text.trim();
      }

      // Add image if selected
      if (_imageBytes != null) {
        final base64Image = base64Encode(_imageBytes!);
        data['picture'] = 'data:image/${_imageFileName?.split('.').last ?? 'png'};base64,$base64Image';
      }

      final resp = await ApiService.post(
        '$urlString/client/profile/update',
        data: data,
      );

      if (resp.statusCode == 200) {
        setState(() {
          _loading = false;
          _error = null;
          _imageBytes = null;
          _currentAtName = _atNameController.text.trim();
        });
        
        // Reload profile to get updated data
        await _loadProfile();
        
        if (mounted) {
          context.showSuccessSnackBar('Profile updated successfully');
        }
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to update profile: $e';
      });
    }
  }

  Future<void> _deleteAccount() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text(
          'Are you sure you want to delete your account?\n\n'
          'This action is PERMANENT and cannot be undone.\n'
          'All your data, messages, and settings will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete Account'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Second confirmation with typed confirmation
    final textConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final confirmController = TextEditingController();
        return AlertDialog(
          title: const Text('Final Confirmation'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Type "DELETE" to confirm account deletion:'),
              const SizedBox(height: 16),
              TextField(
                controller: confirmController,
                decoration: InputDecoration(
                  hintText: 'Type DELETE here',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () {
                if (confirmController.text == 'DELETE') {
                  Navigator.of(context).pop(true);
                } else {
                  context.showErrorSnackBar('Please type "DELETE" to confirm');
                }
              },
              child: const Text('Confirm Deletion'),
            ),
          ],
        );
      },
    );

    if (textConfirmed != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      String urlString = '';
      if (kIsWeb) {
        final apiServer = await loadWebApiServer();
        urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      final resp = await ApiService.delete('$urlString/client/profile/delete');

      if (resp.statusCode == 200) {
        if (mounted) {
          context.showSuccessSnackBar('Account deleted successfully');
          // Redirect to login
          context.go('/');
        }
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to delete account: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingProfile) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        padding: const EdgeInsets.all(24),
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title
                const Text(
                  'Profile Settings',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Manage your profile information',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        backgroundImage: _imageBytes != null
                            ? MemoryImage(_imageBytes!)
                            : (_currentImageBytes != null
                                ? MemoryImage(_currentImageBytes!)
                                : null),
                        child: (_imageBytes == null && _currentImageBytes == null)
                            ? Icon(Icons.person, size: 60, color: Theme.of(context).colorScheme.onSurfaceVariant)
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: CircleAvatar(
                          radius: 20,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: IconButton(
                            icon: Icon(Icons.camera_alt, size: 20, color: Theme.of(context).colorScheme.onPrimary),
                            onPressed: _pickImage,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // UUID (Read-only)
                TextField(
                  controller: TextEditingController(text: _uuid ?? ''),
                  decoration: InputDecoration(
                    labelText: 'UUID',
                    prefixIcon: const Icon(Icons.fingerprint),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                  ),
                  readOnly: true,
                  enabled: false,
                ),
                const SizedBox(height: 16),

                // Email (Read-only)
                TextField(
                  controller: TextEditingController(text: _email ?? ''),
                  decoration: InputDecoration(
                    labelText: 'Email',
                    prefixIcon: const Icon(Icons.email),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                  ),
                  readOnly: true,
                  enabled: false,
                ),
                const SizedBox(height: 16),

                // Display Name
                TextField(
                  controller: _displayNameController,
                  decoration: InputDecoration(
                    labelText: 'Display Name',
                    hintText: 'Your display name',
                    prefixIcon: const Icon(Icons.person),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                // @Name
                TextField(
                  controller: _atNameController,
                  decoration: InputDecoration(
                    labelText: '@Name (optional)',
                    hintText: 'username',
                    prefixText: '@',
                    prefixIcon: const Icon(Icons.alternate_email),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                    errorText: _atNameError,
                    suffixIcon: _checkingAtName
                        ? const Padding(
                            padding: EdgeInsets.all(12.0),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : (_atNameError == null && _atNameController.text.isNotEmpty && _atNameController.text != _currentAtName
                            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                            : null),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Choose a unique @name for mentions in chat',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),

                // Error Message
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(context).colorScheme.error),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_error != null) const SizedBox(height: 16),

                // Update Button
                ElevatedButton(
                  onPressed: _loading ? null : _updateProfile,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Update Profile', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 32),

                // Divider
                const Divider(),
                const SizedBox(height: 16),

                // Danger Zone
                Text(
                  'Danger Zone',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Once you delete your account, there is no going back.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),

                // Delete Account Button
                OutlinedButton(
                  onPressed: _loading ? null : _deleteAccount,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side: BorderSide(color: Theme.of(context).colorScheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_forever),
                      SizedBox(width: 8),
                      Text('Delete Account', style: TextStyle(fontSize: 16)),
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

