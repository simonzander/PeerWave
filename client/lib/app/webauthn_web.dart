import 'package:flutter/material.dart';
import 'package:js/js.dart';
import 'package:js/js_util.dart';
import '../web_config.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';

@JS('window.localStorage.getItem')
external String localStorageGetItem(String key);
@JS('webauthnRegister')
external Object _webauthnRegister(String serverUrl, String email);

Future<bool> webauthnRegister(String serverUrl, String email) async {
  final result = await promiseToFuture(_webauthnRegister(serverUrl, email));
  return result == true;
}

class WebauthnPage extends StatefulWidget {
  const WebauthnPage({Key? key}) : super(key: key);

  @override
  State<WebauthnPage> createState() => _WebauthnPageState();
}

class _WebauthnPageState extends State<WebauthnPage> {
  Future<void> _confirmAndRegenerateBackupCodes() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Regenerate Backup Codes?'),
        content: const Text('Do you really want to regenerate your codes? All unused codes will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              setState(() { loading = true; });
                  try {
                    final apiServer = await loadWebApiServer();
                    String urlString = apiServer ?? '';
                    if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
                      urlString = 'https://$urlString';
                    }
                    final resp = await ApiService.get('$urlString/backupcode/regenerate');
                    if (resp.statusCode == 200) {
                      GoRouter.of(context).go('/app/settings/backupcode/list');
                    }
                  } catch (e) {
                    // handle error, optionally show snackbar
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error regenerating backup codes: $e')),
                    );
                    setState(() { loading = false; });
                  } finally {
                    setState(() { loading = false; });
                  }
            },
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // TODO: Call API to regenerate backup codes
      // Optionally show a snackbar or reload codes
    }
  }
  List<Map<String, dynamic>> webauthnCredentials = [];
  List<Map<String, dynamic>> Clients = [];
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

  Future<void> _loadWebauthnCredentials() async {
    setState(() { loading = true; });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/webauthn/list');
      if (resp.statusCode == 200 && resp.data != null) {
        if (resp.data is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(resp.data);
          });
        } else if (resp.data is Map && resp.data['credentials'] is List) {
          setState(() {
            webauthnCredentials = List<Map<String, dynamic>>.from(resp.data['credentials']);
          });
        }
      }
    } catch (e) {
      // handle error, optionally show snackbar
    } finally {
      setState(() { loading = false; });
    }
  }

  Future<void> _loadClients() async {
    setState(() { loading = true; });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/client/list');
      if (resp.statusCode == 200 && resp.data != null) {
        if (resp.data is List) {
          setState(() {
            Clients = List<Map<String, dynamic>>.from(resp.data);
          });
        } else if (resp.data is Map && resp.data['clients'] is List) {
          setState(() {
            Clients = List<Map<String, dynamic>>.from(resp.data['clients']);
          });
        }
      }
    } catch (e) {
      // handle error, optionally show snackbar
    } finally {
      setState(() { loading = false; });
    }
  }

  Future<void> _deleteWebAuthnCredential(String credentialId) async {
    setState(() { loading = true; });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.post('$urlString/webauthn/delete', data: { 'credentialId': credentialId });
      if (resp.statusCode == 200) {
        _loadWebauthnCredentials();
      }
    } catch (e) {
      // handle error, optionally show snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting credential: $e')),
      );
      setState(() { loading = false; });
    } finally {
      setState(() { loading = false; });
    }
  }

  Future<void> _deleteClient(String clientId) async {
    setState(() { loading = true; });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.post('$urlString/client/delete', data: { 'clientId': clientId });
      if (resp.statusCode == 200) {
        _loadClients();
      }
    } catch (e) {
      // handle error, optionally show snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting client: $e')),
      );
      setState(() { loading = false; });
    } finally {
      setState(() { loading = false; });
    }
  }

  Future<void> _loadBackupUsage() async {
    setState(() { loading = true; });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.get('$urlString/backupcode/usage');
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
      setState(() { loading = false; });
    }
  }

  Future<void> _addCredential() async {
    final apiServer = await loadWebApiServer();
    String urlString = apiServer ?? '';
    if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
      urlString = 'https://$urlString';
    }
    final email = localStorageGetItem('email');
    await webauthnRegister(urlString, email);
    await _loadWebauthnCredentials();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('WebAuthn Management', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 32),
          // WebAuthn Credentials Table
          loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
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
                            DataRow(cells: [
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Container()),
                            ]),
                          ]
                        : webauthnCredentials.map((cred) => DataRow(cells: [
                              DataCell(Text(cred['id']?.toString() ?? '-')),
                              DataCell(Text(cred['browser']?.toString() ?? '-')),
                              DataCell(Text(cred['location']?.toString() ?? '-')),
                              DataCell(Text(cred['ip']?.toString() ?? '-')),
                              DataCell(Text(cred['created']?.toString() ?? '-')),
                              DataCell(Text(cred['lastLogin']?.toString() ?? '-')),
                              DataCell(
                                webauthnCredentials.length > 1
                                    ? IconButton(
                                        icon: const Icon(Icons.delete),
                                        onPressed: () {
                                          // Handle remove action
                                          _deleteWebAuthnCredential(cred['id']?.toString() ?? '');
                                        },
                                      )
                                    : Container(),
                              ),
                            ])).toList(),
                  ),
                ),
          // Add Credentials Button directly under table, right-aligned
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton.icon(
                onPressed: _addCredential,
                icon: const Icon(Icons.add),
                label: const Text('Add Credentials'),
              ),
            ],
          ),
          const SizedBox(height: 32),
          // Clients Table Section
          Text('Clients', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Id')),
                DataColumn(label: Text('Type')),
                DataColumn(label: Text('Location')),
                DataColumn(label: Text('IP Address')),
                DataColumn(label: Text('Created')),
                DataColumn(label: Text('Last Login')),
                DataColumn(label: Text('Remove')),
              ],
              rows: Clients.isEmpty
                        ? [
                            DataRow(cells: [
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Text('-')),
                              DataCell(Container()),
                            ]),
                          ]
                        : Clients.map((cred) => DataRow(cells: [
                              DataCell(Text(cred['clientid']?.toString() ?? '-')),
                              DataCell(Text(cred['browser']?.toString() ?? '-')),
                              DataCell(Text(cred['location']?.toString() ?? '-')),
                              DataCell(Text(cred['ip']?.toString() ?? '-')),
                              DataCell(Text(cred['createdAt']?.toString() ?? '-')),
                              DataCell(Text(cred['updatedAt']?.toString() ?? '-')),
                              DataCell(IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () {
                                  // Handle remove action
                                   _deleteClient(cred['id']?.toString() ?? '');
                                },
                              )),
                            ])).toList(),
            ),
          ),
          // Add Client Button right-aligned
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton.icon(
                onPressed: () {
                  // Handle add client action
                  GoRouter.of(context).go('/magic-link');
                },
                icon: const Icon(Icons.add),
                label: const Text('Add Client'),
              ),
            ],
          ),
          const SizedBox(height: 32),
          // Backup Codes Section
          Text('Backup Codes', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Example: keys 2 from keys 5
              Text('$backupUnusedCount codes from $backupTotalCount are unused', style: Theme.of(context).textTheme.bodyLarge),
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

