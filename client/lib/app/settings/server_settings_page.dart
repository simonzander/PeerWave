import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import '../../services/server_config_web.dart'
    if (dart.library.io) '../../services/server_config_native.dart';
import '../../web_config.dart';
import '../../extensions/snackbar_extensions.dart';
import 'package:provider/provider.dart';
import '../../providers/role_provider.dart';

class ServerSettingsPage extends StatefulWidget {
  const ServerSettingsPage({super.key});

  @override
  State<ServerSettingsPage> createState() => _ServerSettingsPageState();
}

class _ServerSettingsPageState extends State<ServerSettingsPage> {
  final TextEditingController _serverNameController = TextEditingController();
  final TextEditingController _emailSuffixesController =
      TextEditingController();
  final TextEditingController _inviteEmailController = TextEditingController();

  bool _loading = false;
  bool _loadingSettings = true;
  bool _sendingInvite = false;
  String? _error;

  Uint8List? _imageBytes;
  String? _imageFileName;
  Uint8List? _currentImageBytes;

  String _registrationMode = 'open';
  List<dynamic> _invitations = [];

  // License information
  bool _loadingLicense = true;
  String _licenseType = 'non-commercial';
  String? _licenseExpires;
  int? _maxUsers;
  int? _currentUsers;
  int? _gracePeriod;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadLicenseInfo();
  }

  @override
  void dispose() {
    _serverNameController.dispose();
    _emailSuffixesController.dispose();
    _inviteEmailController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _loadingSettings = true);

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

      // Load server settings
      final resp = await ApiService.instance.get('/api/server/settings');

      if (resp.statusCode == 200) {
        final data = resp.data['settings'];
        setState(() {
          _serverNameController.text = data['serverName'] ?? '';
          _registrationMode = data['registrationMode'] ?? 'open';

          // Load current server picture
          if (data['serverPicture'] != null &&
              data['serverPicture'].isNotEmpty) {
            final base64Data = (data['serverPicture'] as String)
                .split(',')
                .last;
            _currentImageBytes = base64Decode(base64Data);
          }

          // Load allowed email suffixes
          final suffixes = data['allowedEmailSuffixes'] as List? ?? [];
          _emailSuffixesController.text = suffixes.join(', ');
        });
      }

      // Load active invitations if in invitation-only mode
      if (_registrationMode == 'invitation_only') {
        await _loadInvitations();
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
    } finally {
      setState(() => _loadingSettings = false);
    }
  }

  Future<void> _loadInvitations() async {
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

      final resp = await ApiService.instance.get('/api/server/invitations');

      if (resp.statusCode == 200) {
        setState(() {
          _invitations = resp.data['invitations'] ?? [];
        });
      }
    } catch (e) {
      debugPrint('Error loading invitations: $e');
    }
  }

  Future<void> _pickImage() async {
    if (kIsWeb) {
      final html.FileUploadInputElement input = html.FileUploadInputElement()
        ..accept = 'image/*';
      input.click();

      input.onChange.listen((e) async {
        final files = input.files;
        if (files != null && files.isNotEmpty) {
          final reader = html.FileReader();
          reader.readAsArrayBuffer(files[0]);
          reader.onLoadEnd.listen((e) {
            setState(() {
              _imageBytes = reader.result as Uint8List;
              _imageFileName = files[0].name;
            });
          });
        }
      });
    } else {
      // TODO: Implement file picker for native
      if (mounted) {
        context.showErrorSnackBar(
          'Image selection not yet implemented for native clients',
        );
      }
    }
  }

  Future<void> _loadLicenseInfo() async {
    setState(() => _loadingLicense = true);

    try {
      final resp = await ApiService.instance.get('/api/license-info');

      if (resp.statusCode == 200) {
        final data = resp.data;
        setState(() {
          _licenseType = data['type'] ?? 'non-commercial';

          // Only load detailed info for commercial licenses
          if (_licenseType == 'commercial') {
            _licenseExpires = data['expires'];
            _maxUsers = data['maxUsers'];
            _currentUsers = data['activeUsers'];
            _gracePeriod = data['gracePeriod'];
          }

          _loadingLicense = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading license info: $e');
      setState(() => _loadingLicense = false);
    }
  }

  Future<void> _openBuyLicense() async {
    final url = Uri.parse('https://peerwave.org');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _updateSettings() async {
    if (_serverNameController.text.trim().isEmpty) {
      setState(() {
        _error = 'Server name is required';
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
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
      } else {
        final server = ServerConfigService.getActiveServer();
        urlString = server?.serverUrl ?? '';
      }

      final Map<String, dynamic> data = {
        'serverName': _serverNameController.text.trim(),
        'registrationMode': _registrationMode,
      };

      // Add allowed email suffixes if in email_suffix mode
      if (_registrationMode == 'email_suffix' &&
          _emailSuffixesController.text.trim().isNotEmpty) {
        final suffixes = _emailSuffixesController.text
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        data['allowedEmailSuffixes'] = suffixes;
      }

      // Add image if selected
      if (_imageBytes != null) {
        final base64Image = base64Encode(_imageBytes!);
        data['serverPicture'] =
            'data:image/${_imageFileName?.split('.').last ?? 'png'};base64,$base64Image';
      }

      final resp = await ApiService.instance.post(
        '/api/server/settings',
        data: data,
      );

      if (resp.statusCode == 200) {
        setState(() {
          _loading = false;
          _error = null;
          _imageBytes = null;
        });

        // Reload settings to get updated data
        await _loadSettings();

        if (mounted) {
          context.showSuccessSnackBar('Server settings updated successfully');
        }
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to update settings: $e';
      });
    }
  }

  Future<void> _sendInvitation() async {
    final email = _inviteEmailController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      context.showErrorSnackBar('Please enter a valid email address');
      return;
    }

    setState(() => _sendingInvite = true);

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

      final resp = await ApiService.instance.post(
        '/api/server/invitations/send',
        data: {'email': email},
      );

      if (resp.statusCode == 200) {
        _inviteEmailController.clear();
        await _loadInvitations();

        if (mounted) {
          context.showSuccessSnackBar('Invitation sent to $email');
        }
      } else {
        // Handle non-200 responses
        final errorData = resp.data;
        final errorMessage = errorData is Map && errorData['message'] != null
            ? errorData['message']
            : 'Failed to send invitation (${resp.statusCode})';

        if (mounted) {
          context.showErrorSnackBar(errorMessage);
        }
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to send invitation: $e');
      }
    } finally {
      setState(() => _sendingInvite = false);
    }
  }

  Future<void> _deleteInvitation(int id) async {
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

      final resp = await ApiService.instance.delete(
        '/api/server/invitations/$id',
      );

      if (resp.statusCode == 200) {
        await _loadInvitations();

        if (mounted) {
          context.showSuccessSnackBar('Invitation revoked');
        }
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to revoke invitation: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final roleProvider = context.watch<RoleProvider>();
    final isAdmin = roleProvider.hasServerPermission('server.manage');

    if (!isAdmin) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(title: const Text('Server Settings')),
        body: const Center(
          child: Text('You do not have permission to access server settings'),
        ),
      );
    }

    if (_loadingSettings) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(title: const Text('Server Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Server Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/app/settings'),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Server Identity Section
                Text(
                  'Server Identity',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),

                // Server Picture
                Center(
                  child: GestureDetector(
                    onTap: _pickImage,
                    child: CircleAvatar(
                      radius: 60,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      backgroundImage: _imageBytes != null
                          ? MemoryImage(_imageBytes!)
                          : _currentImageBytes != null
                          ? MemoryImage(_currentImageBytes!)
                          : null,
                      child: (_imageBytes == null && _currentImageBytes == null)
                          ? Icon(
                              Icons.add_a_photo,
                              size: 32,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _pickImage,
                    child: const Text('Change Server Picture'),
                  ),
                ),
                const SizedBox(height: 24),

                // Server Name
                TextField(
                  controller: _serverNameController,
                  decoration: InputDecoration(
                    labelText: 'Server Name',
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 32),

                // Registration Settings Section
                Text(
                  'Registration Settings',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),

                // Registration Mode Dropdown
                DropdownButtonFormField<String>(
                  initialValue: _registrationMode,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  dropdownColor: Theme.of(context).colorScheme.surface,
                  decoration: InputDecoration(
                    labelText: 'Registration Mode',
                    filled: true,
                    fillColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'open',
                      child: Text(
                        'Open - Anyone can register',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'email_suffix',
                      child: Text(
                        'Email Suffix - Specific domains only',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'invitation_only',
                      child: Text(
                        'Invitation Only - Requires invite',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _registrationMode = value!;
                      if (value == 'invitation_only') {
                        _loadInvitations();
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),

                // Conditional: Email Suffixes field
                if (_registrationMode == 'email_suffix') ...[
                  TextField(
                    controller: _emailSuffixesController,
                    decoration: InputDecoration(
                      labelText: 'Allowed Email Suffixes',
                      hintText: 'example.com, company.org',
                      helperText:
                          'Comma-separated list of allowed email domains',
                      filled: true,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Error message
                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Save button
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _loading ? null : _updateSettings,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save Settings'),
                  ),
                ),

                // License Section
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 24),

                Text(
                  'License',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),

                if (_loadingLicense)
                  const Center(child: CircularProgressIndicator())
                else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // License Type
                          Row(
                            children: [
                              Text(
                                'Type: ',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                _licenseType == 'commercial'
                                    ? 'Commercial'
                                    : 'Non-Commercial',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),

                          // Commercial license details
                          if (_licenseType == 'commercial') ...[
                            const SizedBox(height: 12),
                            if (_licenseExpires != null) ...[
                              Row(
                                children: [
                                  Text(
                                    'Expires: ',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    DateTime.parse(
                                      _licenseExpires!,
                                    ).toString().split(' ')[0],
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_maxUsers != null) ...[
                              Row(
                                children: [
                                  Text(
                                    'Maximum Active Users: ',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    _maxUsers.toString(),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_currentUsers != null) ...[
                              Row(
                                children: [
                                  Text(
                                    'Current Active Users: ',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    _currentUsers.toString(),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (_gracePeriod != null) ...[
                              Row(
                                children: [
                                  Text(
                                    'Grace Period: ',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    '$_gracePeriod days',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ],
                          ],

                          // Buy License Button
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _openBuyLicense,
                              icon: const Icon(Icons.shopping_cart),
                              label: const Text('Buy License'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Conditional: Invitation Management
                if (_registrationMode == 'invitation_only') ...[
                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 24),

                  Text(
                    'Invitation Management',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),

                  // Send Invitation Form
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inviteEmailController,
                          decoration: InputDecoration(
                            labelText: 'Email Address',
                            hintText: 'user@example.com',
                            filled: true,
                            fillColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.emailAddress,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _sendingInvite ? null : _sendInvitation,
                        child: _sendingInvite
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Send Invite'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Active Invitations List
                  Text(
                    'Active Invitations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),

                  if (_invitations.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Center(
                          child: Text(
                            'No active invitations',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _invitations.length,
                      itemBuilder: (context, index) {
                        final invitation = _invitations[index];
                        final expiresAt = DateTime.parse(
                          invitation['expiresAt'],
                        );
                        final hoursLeft = expiresAt
                            .difference(DateTime.now())
                            .inHours;

                        return Card(
                          child: ListTile(
                            leading: Icon(
                              Icons.mail_outline,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(invitation['email']),
                            subtitle: Text(
                              'Token: ${invitation['token']} • Expires in ${hoursLeft}h',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              onPressed: () =>
                                  _deleteInvitation(invitation['id']),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
