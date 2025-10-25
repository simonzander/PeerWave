import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:js/js.dart';
import 'package:js/js_util.dart';
import '../services/api_service.dart';
import '../web_config.dart';
import '../widgets/registration_progress_bar.dart';

@JS('window.localStorage.getItem')
external String localStorageGetItem(String key);

@JS('webauthnRegister')
external Object _webauthnRegister(String serverUrl, String email);

Future<bool> webauthnRegister(String serverUrl, String email) async {
  final result = await promiseToFuture(_webauthnRegister(serverUrl, email));
  return result == true;
}

class RegisterWebauthnPage extends StatefulWidget {
  const RegisterWebauthnPage({Key? key}) : super(key: key);

  @override
  State<RegisterWebauthnPage> createState() => _RegisterWebauthnPageState();
}

class _RegisterWebauthnPageState extends State<RegisterWebauthnPage> {
  List<Map<String, dynamic>> webauthnCredentials = [];
  bool loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWebauthnCredentials();
  }

  Future<void> _loadWebauthnCredentials() async {
    setState(() {
      loading = true;
      _error = null;
    });
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
      setState(() {
        _error = 'Failed to load credentials: $e';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _addCredential() async {
    setState(() {
      _error = null;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final email = localStorageGetItem('email');
      final success = await webauthnRegister(urlString, email);
      if (success) {
        await _loadWebauthnCredentials();
      } else {
        setState(() {
          _error = 'Failed to register security key';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error registering security key: $e';
      });
    }
  }

  Future<void> _deleteCredential(String credentialId) async {
    if (webauthnCredentials.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must have at least one security key!'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      loading = true;
      _error = null;
    });
    try {
      final apiServer = await loadWebApiServer();
      String urlString = apiServer ?? '';
      if (!urlString.startsWith('http://') && !urlString.startsWith('https://')) {
        urlString = 'https://$urlString';
      }
      final resp = await ApiService.post('$urlString/webauthn/delete', data: {'credentialId': credentialId});
      if (resp.statusCode == 200) {
        await _loadWebauthnCredentials();
      } else {
        setState(() {
          _error = 'Failed to delete credential';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error deleting credential: $e';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2C2F33),
      body: Column(
        children: [
          // Progress Bar
          const RegistrationProgressBar(currentStep: 3),
          // Content
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(32),
                width: 600,
                constraints: const BoxConstraints(maxHeight: 700),
                decoration: BoxDecoration(
                  color: const Color(0xFF23272A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Setup Security Key',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Register at least one security key (passkey) to secure your account. You can use your device\'s biometric authentication or a hardware security key.',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                      textAlign: TextAlign.center,
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
                    // Credentials List
                    Expanded(
                      child: loading && webauthnCredentials.isEmpty
                          ? const Center(
                              child: CircularProgressIndicator(color: Colors.blueAccent),
                            )
                          : webauthnCredentials.isEmpty
                              ? Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF40444B),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.security, color: Colors.white54, size: 48),
                                      SizedBox(height: 16),
                                      Text(
                                        'No security keys registered yet',
                                        style: TextStyle(color: Colors.white70, fontSize: 16),
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        'Click "Add Security Key" below to get started',
                                        style: TextStyle(color: Colors.white54, fontSize: 13),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                )
                              : Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF40444B),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: ListView.separated(
                                    padding: const EdgeInsets.all(8),
                                    itemCount: webauthnCredentials.length,
                                    separatorBuilder: (context, index) => const Divider(
                                      color: Color(0xFF2C2F33),
                                      height: 1,
                                    ),
                                    itemBuilder: (context, index) {
                                      final cred = webauthnCredentials[index];
                                      return ListTile(
                                        leading: const Icon(Icons.key, color: Colors.blueAccent),
                                        title: Text(
                                          cred['browser']?.toString() ?? 'Security Key ${index + 1}',
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                        subtitle: Text(
                                          'Created: ${cred['created']?.toString() ?? 'Unknown'}',
                                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                                        ),
                                        trailing: webauthnCredentials.length > 1
                                            ? IconButton(
                                                icon: const Icon(Icons.delete, color: Colors.red),
                                                onPressed: () => _deleteCredential(cred['id']?.toString() ?? ''),
                                              )
                                            : null,
                                      );
                                    },
                                  ),
                                ),
                    ),
                    const SizedBox(height: 16),
                    // Add Credential Button
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: loading ? null : _addCredential,
                      icon: const Icon(Icons.add),
                      label: const Text(
                        'Add Security Key',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Next Button
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: webauthnCredentials.isEmpty
                          ? null
                          : () {
                              GoRouter.of(context).go('/register/profile');
                            },
                      child: const Text(
                        'Next',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
}
