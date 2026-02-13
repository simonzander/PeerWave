import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'dart:async';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../services/device_identity_service.dart';
import '../services/webauthn_service_mobile.dart';

// Conditional import for web_config
import '../web_config_stub.dart' if (dart.library.html) '../web_config.dart';

// Conditional import for JS interop (web-only)
import 'webauthn_js_interop_stub.dart'
    if (dart.library.html) 'webauthn_js_interop.dart';

class WebauthnPage extends StatefulWidget {
  const WebauthnPage({super.key});

  @override
  State<WebauthnPage> createState() => _WebauthnPageState();
}

class _WebauthnPageState extends State<WebauthnPage> {
  // Magic Key state (NEW)
  String? _magicKey;
  DateTime? _expiresAt;
  Timer? _countdownTimer;
  bool _isLoadingKey = false;
  bool _showAsQR = true; // Toggle between QR and text

  // Existing state
  List<Map<String, dynamic>> webauthnCredentials = [];
  List<Map<String, dynamic>> clients = [];
  bool loading = false;
  int backupUnusedCount = 0;
  int backupTotalCount = 0;
  bool backupButtonEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadWebauthnCredentials();
    _loadClients();
    _loadBackupUsage();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  // NEW: Magic Key generation methods
  Future<void> _generateMagicKey() async {
    setState(() {
      _isLoadingKey = true;
    });

    try {
      final response = await ApiService.instance.get('/magic/generate');

      if (response.statusCode == 200) {
        final data = response.data;
        setState(() {
          _magicKey = data['magicKey'];
          _expiresAt = DateTime.fromMillisecondsSinceEpoch(data['expiresAt']);
          _isLoadingKey = false;
        });

        // Start countdown timer
        _countdownTimer?.cancel();
        _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
            setState(() {
              _magicKey = null;
              _expiresAt = null;
            });
            timer.cancel();
          } else {
            setState(() {}); // Trigger rebuild for countdown
          }
        });
      } else {
        _showError('Failed to generate magic key');
        setState(() {
          _isLoadingKey = false;
        });
      }
    } catch (e) {
      _showError('Error generating magic key: $e');
      setState(() {
        _isLoadingKey = false;
      });
    }
  }

  String _getRemainingTime() {
    if (_expiresAt == null) return '';
    final remaining = _expiresAt!.difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  // Existing methods
  Future<void> _confirmAndRegenerateBackupCodes() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Regenerate Backup Codes?'),
        content: const Text(
          'Do you really want to regenerate your codes? All unused codes will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop(true);
              setState(() {
                loading = true;
              });
              try {
                final apiServer = await loadWebApiServer();
                String urlString = apiServer ?? '';
                if (!urlString.startsWith('http://') &&
                    !urlString.startsWith('https://')) {
                  urlString = 'https://$urlString';
                }
                final resp = await ApiService.instance.get(
                  '/backupcode/regenerate',
                );
                if (!mounted) return;
                if (resp.statusCode == 200) {
                  if (!mounted) return;
                  // ignore: use_build_context_synchronously
                  GoRouter.of(context).go('/app/settings/backupcode/list');
                }
              } catch (e) {
                _showError('Error regenerating backup codes: $e');
              } finally {
                setState(() {
                  loading = false;
                });
              }
            },
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadWebauthnCredentials() async {
    setState(() {
      loading = true;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.instance.get('/webauthn/list');
      if (resp.statusCode == 200 && resp.data != null) {
        if (resp.data is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(resp.data);
          });
        } else if (resp.data is Map && resp.data['credentials'] is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(
              resp.data['credentials'],
            );
          });
        }
      }
    } catch (e) {
      // handle error, optionally show snackbar
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _loadClients() async {
    setState(() {
      loading = true;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.instance.get('/client/list');
      if (resp.statusCode == 200 && resp.data != null) {
        if (resp.data is List) {
          setState(() {
            clients = List<Map<String, dynamic>>.from(resp.data);
          });
        } else if (resp.data is Map && resp.data['clients'] is List) {
          setState(() {
            clients = List<Map<String, dynamic>>.from(resp.data['clients']);
          });
        }
      }
    } catch (e) {
      // handle error, optionally show snackbar
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _deleteWebAuthnCredential(String credentialId) async {
    setState(() {
      loading = true;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.instance.post(
        '/webauthn/delete',
        data: {'credentialId': credentialId},
      );
      if (resp.statusCode == 200) {
        _loadWebauthnCredentials();
      }
    } catch (e) {
      _showError('Error deleting credential: $e');
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _deleteClient(String clientId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Device'),
        content: Text(
          'Are you sure you want to remove this device?\n\nThis will revoke access and require a new magic key to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        loading = true;
      });
      try {
        final apiServer = await loadWebApiServer();
        String urlString = apiServer ?? '';
        if (!urlString.startsWith('http://') &&
            !urlString.startsWith('https://')) {
          urlString = 'https://$urlString';
        }
        final resp = await ApiService.instance.delete('/client/$clientId');
        if (resp.statusCode == 200) {
          _showSuccess('Device removed successfully');
          _loadClients();
        } else {
          _showError('Failed to remove device');
        }
      } catch (e) {
        _showError('Error removing device: $e');
      } finally {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> _loadBackupUsage() async {
    setState(() {
      loading = true;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.instance.get('/backupcode/usage');
      if (resp.statusCode == 200 && resp.data != null) {
        final used = resp.data["usedCount"] ?? 0;
        final total = resp.data["totalCount"] ?? 0;
        final unused = total - used;
        setState(() {
          backupUnusedCount = unused;
          backupTotalCount = total;
          backupButtonEnabled = unused <= 2;
        });
      }
    } catch (e) {
      // handle error, optionally show snackbar
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _addCredential() async {
    // Get server URL - use ApiService on mobile, loadWebApiServer on web
    String urlString = '';

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      // Mobile: Get from ApiService which has the proper base URL
      ApiService.instance.init();
      urlString = ApiService.instance.buildUrl("");
      debugPrint('[WEBAUTHN] Using mobile base URL: $urlString');
    } else {
      // Web: Use web config
      final apiServer = await loadWebApiServer();
      urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') &&
          !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      debugPrint('[WEBAUTHN] Using web base URL: $urlString');
    }

    // Use mobile passkeys on Android/iOS, web WebAuthn on web/desktop
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      // Mobile: Use native passkeys
      try {
        setState(() {
          loading = true;
        });

        final result = await MobileWebAuthnService.instance.register();

        if (result != null && mounted) {
          _showSuccess('Passkey added successfully');
          await _loadWebauthnCredentials();
        } else if (mounted) {
          _showError('Failed to add passkey');
        }
      } catch (e) {
        if (mounted) {
          _showError('Error adding passkey: $e');
        }
      } finally {
        if (mounted) {
          setState(() {
            loading = false;
          });
        }
      }
    } else {
      // Web: Use browser WebAuthn API
      final email = getLocalStorageEmail() ?? '';
      await webauthnRegister(urlString, email);
      await _loadWebauthnCredentials();
    }
  }

  String _formatTimestamp(String timestamp) {
    try {
      final date = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inMinutes < 1) return 'Just now';
      if (difference.inMinutes < 60) {
        return '${difference.inMinutes} minutes ago';
      }
      if (difference.inHours < 24) return '${difference.inHours} hours ago';
      return '${difference.inDays} days ago';
    } catch (e) {
      return timestamp;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Credentials Management',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Manage your connected devices and credentials',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),

          // NEW: Magic Key Generation Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.vpn_key,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Add New Client',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Generate a magic key to connect a new native client (Windows, Linux, macOS). The key expires in 5 minutes and can only be used once.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),

                  if (_magicKey == null)
                    Center(
                      child: ElevatedButton.icon(
                        onPressed: _isLoadingKey ? null : _generateMagicKey,
                        icon: _isLoadingKey
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add),
                        label: Text(
                          _isLoadingKey
                              ? 'Generating...'
                              : 'Generate Magic Key',
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                        ),
                      ),
                    )
                  else
                    Column(
                      children: [
                        // Timer
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 20,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.timer,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Expires in: ${_getRemainingTime()}',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Toggle buttons
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('QR Code'),
                              icon: Icon(Icons.qr_code),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('Text'),
                              icon: Icon(Icons.text_fields),
                            ),
                          ],
                          selected: {_showAsQR},
                          onSelectionChanged: (Set<bool> selection) {
                            setState(() {
                              _showAsQR = selection.first;
                            });
                          },
                        ),
                        const SizedBox(height: 20),

                        // Display QR or Text
                        if (_showAsQR)
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                            child: QrImageView(
                              data: _magicKey!,
                              version: QrVersions.auto,
                              size: 300,
                              backgroundColor: Colors.white,
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                            child: Column(
                              children: [
                                SelectableText(
                                  _magicKey!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(fontFamily: 'monospace'),
                                ),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: () {
                                    Clipboard.setData(
                                      ClipboardData(text: _magicKey!),
                                    );
                                    _showSuccess(
                                      'Magic key copied to clipboard',
                                    );
                                  },
                                  icon: const Icon(Icons.copy),
                                  label: const Text('Copy to Clipboard'),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _magicKey = null;
                              _expiresAt = null;
                            });
                            _countdownTimer?.cancel();
                          },
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // WebAuthn Credentials Table
          Text(
            'WebAuthn Management',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          loading
              ? const Center(child: CircularProgressIndicator())
              : (defaultTargetPlatform == TargetPlatform.android ||
                    defaultTargetPlatform == TargetPlatform.iOS)
              ? // Mobile Layout - ListView
                webauthnCredentials.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Text(
                            'No credentials found',
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: webauthnCredentials.length,
                        separatorBuilder: (context, index) => const Divider(),
                        itemBuilder: (context, index) {
                          final cred = webauthnCredentials[index];
                          return ListTile(
                            leading: Icon(
                              Icons.fingerprint,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(
                              cred['browser']?.toString() ?? 'Unknown Device',
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Location: ${cred['location'] ?? 'Unknown'}',
                                ),
                                Text('IP: ${cred['ip'] ?? 'Unknown'}'),
                                Text(
                                  'Created: ${cred['created'] ?? 'Unknown'}',
                                ),
                                if (cred['lastLogin'] != null &&
                                    cred['lastLogin'].toString().isNotEmpty)
                                  Text('Last Login: ${cred['lastLogin']}'),
                              ],
                            ),
                            trailing: webauthnCredentials.length > 1
                                ? IconButton(
                                    icon: Icon(
                                      Icons.delete,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                    onPressed: () {
                                      _deleteWebAuthnCredential(
                                        cred['id']?.toString() ?? '',
                                      );
                                    },
                                    tooltip: 'Remove credential',
                                  )
                                : null,
                          );
                        },
                      )
              : // Desktop Layout - DataTable
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Id')),
                      DataColumn(label: Text('Browser')),
                      DataColumn(label: Text('Location')),
                      DataColumn(label: Text('IP Address')),
                      DataColumn(label: Text('Created')),
                      DataColumn(label: Text('Last Login')),
                      DataColumn(label: Text('Remove')),
                    ],
                    rows: webauthnCredentials.isEmpty
                        ? [
                            DataRow(
                              cells: [
                                DataCell(Text('-')),
                                DataCell(Text('-')),
                                DataCell(Text('-')),
                                DataCell(Text('-')),
                                DataCell(Text('-')),
                                DataCell(Text('-')),
                                DataCell(Container()),
                              ],
                            ),
                          ]
                        : webauthnCredentials
                              .map(
                                (cred) => DataRow(
                                  cells: [
                                    DataCell(
                                      Text(cred['id']?.toString() ?? '-'),
                                    ),
                                    DataCell(
                                      Text(cred['browser']?.toString() ?? '-'),
                                    ),
                                    DataCell(
                                      Text(cred['location']?.toString() ?? '-'),
                                    ),
                                    DataCell(
                                      Text(cred['ip']?.toString() ?? '-'),
                                    ),
                                    DataCell(
                                      Text(cred['created']?.toString() ?? '-'),
                                    ),
                                    DataCell(
                                      Text(
                                        cred['lastLogin']?.toString() ?? '-',
                                      ),
                                    ),
                                    DataCell(
                                      webauthnCredentials.length > 1
                                          ? IconButton(
                                              icon: const Icon(Icons.delete),
                                              onPressed: () {
                                                _deleteWebAuthnCredential(
                                                  cred['id']?.toString() ?? '',
                                                );
                                              },
                                            )
                                          : Container(),
                                    ),
                                  ],
                                ),
                              )
                              .toList(),
                  ),
                ),
          // Add Credentials Button (only show on web and mobile, not desktop native)
          if (kIsWeb ||
              defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton.icon(
                  onPressed: _addCredential,
                  icon: const Icon(Icons.add),
                  label: Text(kIsWeb ? 'Add Credentials' : 'Add Passkey'),
                ),
              ],
            ),
          const SizedBox(height: 32),

          // Connected Devices Section (UPDATED)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.devices,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Connected Devices',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: loading ? null : _loadClients,
                        tooltip: 'Refresh',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  if (loading)
                    const Center(child: CircularProgressIndicator())
                  else if (clients.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Text(
                          'No connected devices',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: clients.length,
                      separatorBuilder: (context, index) => const Divider(),
                      itemBuilder: (context, index) {
                        final device = clients[index];
                        final isNative = !(device['browser'] ?? '')
                            .toLowerCase()
                            .contains('mozilla');

                        // Check if this is the current device
                        final deviceClientId =
                            device['clientid'] ??
                            device['id']?.toString() ??
                            '';
                        String? currentClientId;
                        bool isCurrentDevice = false;

                        try {
                          if (DeviceIdentityService.instance.isInitialized) {
                            currentClientId =
                                DeviceIdentityService.instance.clientId;
                            isCurrentDevice = deviceClientId == currentClientId;
                          }
                        } catch (e) {
                          // Device identity not initialized, skip check
                        }

                        return ListTile(
                          leading: Icon(
                            isNative ? Icons.computer : Icons.web,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  device['browser'] ?? 'Unknown Device',
                                ),
                              ),
                              if (isCurrentDevice)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    'This Device',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimaryContainer,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Location: ${device['location'] ?? 'Unknown'}',
                              ),
                              Text('IP: ${device['ip'] ?? 'Unknown'}'),
                              if (device['device_id'] != null)
                                Text('Device ID: ${device['device_id']}'),
                              if (device['updatedAt'] != null)
                                Text(
                                  'Last active: ${_formatTimestamp(device['updatedAt'])}',
                                ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              Icons.delete,
                              color: isCurrentDevice
                                  ? Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.3)
                                  : Theme.of(context).colorScheme.error,
                            ),
                            onPressed: isCurrentDevice
                                ? null
                                : () => _deleteClient(deviceClientId),
                            tooltip: isCurrentDevice
                                ? 'Cannot remove current device'
                                : 'Remove device',
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Backup Codes Section
          Text('Backup Codes', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$backupUnusedCount codes from $backupTotalCount are unused',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              ElevatedButton(
                onPressed: backupButtonEnabled
                    ? _confirmAndRegenerateBackupCodes
                    : null,
                child: const Text('Regenerate Backup Codes'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
