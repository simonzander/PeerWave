import 'dart:convert';
import 'dart:io' show Platform, File, Directory;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../services/server_config_native.dart';
import '../widgets/registration_progress_bar.dart';
import '../widgets/app_drawer.dart';

/// Native implementation for BackupCodeListPage
/// Backup codes are available for mobile WebAuthn (iOS/Android)
/// Desktop native uses magic key authentication (no backup codes)
class BackupCodeListPage extends StatefulWidget {
  final String? serverUrl; // Server URL for mobile registration
  final String? email; // Email from OTP verification

  const BackupCodeListPage({super.key, this.serverUrl, this.email});

  @override
  State<BackupCodeListPage> createState() => _BackupCodeListPageState();
}

class _BackupCodeListPageState extends State<BackupCodeListPage> {
  final TextEditingController backupCodesController = TextEditingController();
  bool _acknowledged = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final isMobile = Platform.isIOS || Platform.isAndroid;
    if (isMobile) {
      _fetchBackupCodes();
    } else {
      _loading = false;
    }
  }

  Future<void> _fetchBackupCodes() async {
    try {
      // For mobile during registration, use full URL; otherwise use relative path
      final endpoint = widget.serverUrl != null && widget.serverUrl!.isNotEmpty
          ? '${widget.serverUrl}/backupcode/list'
          : '/backupcode/list';
      debugPrint('[BackupCode] Fetching from: $endpoint');

      final resp = await ApiService.get(endpoint);
      if (resp.statusCode == 200 && resp.data != null) {
        final data = resp.data is String ? json.decode(resp.data) : resp.data;
        if (data is Map && data['backupCodes'] is List) {
          setState(() {
            backupCodesController.text = data['backupCodes'].join('\n');
            _loading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching backup codes: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _saveBackupCodes(BuildContext context) async {
    try {
      final codes = backupCodesController.text;

      if (Platform.isAndroid) {
        // Android: Use FilePicker to let user choose save location (no permission needed)
        final codesContent = 'PeerWave Backup Codes\n\n$codes';
        final bytes = utf8.encode(codesContent);

        final filePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Backup Codes',
          fileName: 'peerwave_backup_codes.txt',
          bytes: Uint8List.fromList(bytes),
        );

        if (filePath == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('File save cancelled')),
            );
          }
          return;
        }

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Backup codes saved to $filePath'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
        return;
      }

      // iOS/Desktop: Save to appropriate directory
      Directory directory;

      if (Platform.isIOS) {
        // iOS: Save to Documents folder (accessible via Files app)
        directory = await getApplicationDocumentsDirectory();
      } else {
        // Desktop: Use downloads directory
        directory =
            await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
      }

      final file = File('${directory.path}/peerwave_backup_codes.txt');
      await file.writeAsString('PeerWave Backup Codes\n\n$codes');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup codes saved to ${file.path}'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('[BackupCodes] Save error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check if platform is mobile (iOS or Android)
    final isMobile = Platform.isIOS || Platform.isAndroid;

    if (isMobile) {
      // Mobile: Show backup codes UI with exit confirmation
      final colorScheme = Theme.of(context).colorScheme;

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
            title: const Text('Backup Codes'),
            backgroundColor: colorScheme.surface,
            elevation: 0,
          ),
          drawer: AppDrawer(
            isAuthenticated: false,
            currentRoute: '/register/backupcode',
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    const RegistrationProgressBar(currentStep: 2),
                    Expanded(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          width: 350,
                          margin: const EdgeInsets.symmetric(horizontal: 20),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Backup Codes',
                                  style: TextStyle(
                                    fontSize: 20,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'Save these backup codes in a secure location. Each code can be used once if you lose access to your biometric authentication.',
                                  style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                  textAlign: TextAlign.left,
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: backupCodesController,
                                  maxLines: 4,
                                  readOnly: true,
                                  decoration: InputDecoration(
                                    hintText: 'your backup codes',
                                    filled: true,
                                    fillColor:
                                        colorScheme.surfaceContainerHighest,
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    // Copy button
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: colorScheme.primary,
                                          side: BorderSide(
                                            color: colorScheme.outline,
                                          ),
                                        ),
                                        icon: Icon(
                                          Icons.copy,
                                          color: colorScheme.primary,
                                        ),
                                        label: const Text('Copy'),
                                        onPressed: () {
                                          Clipboard.setData(
                                            ClipboardData(
                                              text: backupCodesController.text,
                                            ),
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: const Text(
                                                'Backup codes copied to clipboard',
                                              ),
                                              backgroundColor:
                                                  colorScheme.primary,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // Save button
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: colorScheme.primary,
                                          foregroundColor:
                                              colorScheme.onPrimary,
                                        ),
                                        icon: Icon(
                                          Icons.download,
                                          color: colorScheme.onPrimary,
                                        ),
                                        label: const Text('Save'),
                                        onPressed: () async {
                                          await _saveBackupCodes(context);
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Checkbox(
                                      value: _acknowledged,
                                      onChanged: (val) {
                                        setState(() {
                                          _acknowledged = val ?? false;
                                        });
                                      },
                                    ),
                                    Expanded(
                                      child: Text(
                                        'I have saved my backup codes',
                                        style: TextStyle(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                ElevatedButton(
                                  onPressed: _acknowledged
                                      ? () async {
                                          // Save server config now that backup codes are acknowledged
                                          if (widget.serverUrl != null &&
                                              widget.serverUrl!.isNotEmpty) {
                                            final serverConfig =
                                                await ServerConfigService.addServer(
                                                  serverUrl: widget.serverUrl!,
                                                  credentials:
                                                      '', // WebAuthn uses session cookies
                                                );
                                            await ServerConfigService.setActiveServer(
                                              serverConfig.id,
                                            );
                                            debugPrint(
                                              '[BackupCode] Server saved and activated: ${serverConfig.id}',
                                            );
                                          }
                                          if (mounted) {
                                            // For mobile, complete WebAuthn registration before going to app
                                            if (Platform.isAndroid ||
                                                Platform.isIOS) {
                                              context.go(
                                                '/register/webauthn',
                                                extra: {
                                                  'serverUrl': widget.serverUrl,
                                                  'email': widget.email,
                                                },
                                              );
                                            } else {
                                              context.go('/app');
                                            }
                                          }
                                        }
                                      : null,
                                  child: const Text('Continue'),
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

    // Desktop: Show not available message
    return Scaffold(
      appBar: AppBar(title: const Text('Backup Codes')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 64, color: Colors.grey),
              SizedBox(height: 24),
              Text(
                'Backup Codes Not Available',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 16),
              Text(
                'Backup codes are only available for WebAuthn authentication (web and mobile apps).',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              SizedBox(height: 8),
              Text(
                'This desktop client uses magic key authentication instead.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
