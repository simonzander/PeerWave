import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../widgets/registration_progress_bar.dart';

/// Native stub for WebAuthn registration
/// WebAuthn is web-only, native uses magic links

Future<bool> webauthnRegister(String serverUrl, String email) async {
  return false;
}

String localStorageGetItem(String key) {
  return '';
}

class RegisterWebauthnPage extends StatelessWidget {
  const RegisterWebauthnPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const RegistrationProgressBar(currentStep: 2),
              const SizedBox(height: 48),
              const Icon(
                Icons.lock_outline,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 24),
              Text(
                'WebAuthn Not Available',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              const Text(
                'WebAuthn registration is only available on web.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 8),
              const Text(
                'Native clients use magic link authentication.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => context.go('/app'),
                child: const Text('Continue to App'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
